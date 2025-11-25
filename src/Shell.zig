const Shell = @This();

const std = @import("std");
const types = @import("types.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const glob = @import("glob.zig");
const hist = @import("history.zig");
const tty = @import("tty.zig");
const input_mod = @import("input.zig");
const completion_mod = @import("completion.zig");
const eval = @import("eval.zig");
const git = @import("git.zig");

// Re-export from input module
const VimMode = input_mod.VimMode;
const WordBoundary = input_mod.WordBoundary;
const HistoryDirection = input_mod.HistoryDirection;
const SearchDirection = input_mod.SearchDirection;
const MoveCursorAction = input_mod.MoveCursorAction;
const DeleteAction = input_mod.DeleteAction;
const YankAction = input_mod.YankAction;
const PasteAction = input_mod.PasteAction;
const InsertAtPosition = input_mod.InsertAtPosition;
const VimModeAction = input_mod.VimModeAction;
const Action = input_mod.Action;
const CycleDirection = input_mod.CycleDirection;

// Control key constants
const CTRL_C = input_mod.CTRL_C;
const CTRL_T = input_mod.CTRL_T;
const CTRL_L = input_mod.CTRL_L;
const CTRL_D = input_mod.CTRL_D;
const CTRL_B = input_mod.CTRL_B;

// global shell instance for signal handler
var global_shell: ?*Shell = null;

// ansi color codes for zsh-like colorful prompt
const Colors = struct {
    const default_color = tty.Color.reset;
    const path = tty.Color.cyan;
    const userhost = tty.Color.green;
    const normal_mode = tty.Color.red;
    const insert_mode = tty.Color.yellow;
};

allocator: std.mem.Allocator,
running: bool,
history: ?*hist.History,
vim_mode: VimMode,
vim_mode_enabled: bool,
cursor_pos: usize,
history_index: i32,
history_search_prefix_len: usize,
current_command: []u8,
current_command_len: usize,
original_termios: ?std.posix.termios = null,
aliases: std.StringHashMap([]const u8),
variables: std.StringHashMap([]const u8),
functions: std.StringHashMap([]const u8), // name -> body source
last_exit_code: u8 = 0,

// vim clipboard for yank/paste operations
clipboard: []u8,
clipboard_len: usize = 0,
// search state
search_mode: bool = false,
search_buffer: []u8,
search_len: usize = 0,
// paste mode (bracketed paste)
paste_mode: bool = false,
// completion state
completion_mode: bool = false,
completion_matches: std.ArrayList([]const u8),
completion_index: usize = 0,
completion_word_start: usize = 0,
completion_word_end: usize = 0,
completion_original_len: usize = 0,
completion_pattern_len: usize = 0,
completion_menu_lines: usize = 0,
completion_displayed: bool = false,

// git info display (set via .zishrc: set git_prompt on)
show_git_info: bool = false,

// track displayed command lines for proper clearing
displayed_cmd_lines: usize = 1,

// terminal resize handling
terminal_resized: bool = false,
terminal_width: usize = 80,
terminal_height: usize = 24,
last_resize_time: i64 = 0,

stdout_writer: std.fs.File.Writer,
log_file: ?std.fs.File = null,

pub fn init(allocator: std.mem.Allocator) !*Shell {
    const shell = try allocator.create(Shell);

    // try to initialize history, but don't fail if it doesn't work
    const history = hist.History.init(allocator, null) catch null;

    // allocate buffer for current command editing
    const cmd_buffer = try allocator.alloc(u8, types.MAX_COMMAND_LENGTH);
    const clipboard_buffer = try allocator.alloc(u8, types.MAX_COMMAND_LENGTH);
    const search_buffer = try allocator.alloc(u8, 256); // search queries are usually short

    const writer_buffer = try allocator.alloc(u8, types.MAX_COMMAND_LENGTH + types.MAX_PROMPT_LENGTH);

    shell.* = .{
        .allocator = allocator,
        .running = false,
        .history = history,
        .vim_mode = .insert,
        .vim_mode_enabled = true,
        .cursor_pos = 0,
        .history_index = -1,
        .history_search_prefix_len = 0,
        .current_command = cmd_buffer,
        .current_command_len = 0,
        .original_termios = null,
        .aliases = std.StringHashMap([]const u8).init(allocator),
        .variables = std.StringHashMap([]const u8).init(allocator),
        .functions = std.StringHashMap([]const u8).init(allocator),
        .clipboard = clipboard_buffer,
        .clipboard_len = 0,
        .search_mode = false,
        .search_buffer = search_buffer,
        .search_len = 0,
        .completion_mode = false,
        .completion_matches = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 },
        .completion_index = 0,
        .completion_word_start = 0,
        .completion_word_end = 0,
        .completion_original_len = 0,
        .completion_pattern_len = 0,
        .completion_menu_lines = 0,
        .completion_displayed = false,
        .stdout_writer = .init(.stdout(), writer_buffer),
    };

    // don't enable raw mode here - will be enabled by run() for interactive mode
    // this prevents issues with child processes in non-interactive mode

    // load aliases from ~/.zishrc
    shell.loadAliases() catch {}; // don't fail if no config file

    return shell;
}

pub fn deinit(self: *Shell) void {
    // restore terminal mode before cleanup
    self.disableRawMode();

    // restore default cursor style
    self.setCursorStyle(.default) catch {};

    // cleanup aliases
    var it = self.aliases.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.aliases.deinit();

    // cleanup variables
    var var_it = self.variables.iterator();
    while (var_it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.variables.deinit();

    // cleanup functions
    var fn_it = self.functions.iterator();
    while (fn_it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.functions.deinit();

    if (self.history) |h| h.deinit();

    // cleanup completion matches
    for (self.completion_matches.items) |match| {
        self.allocator.free(match);
    }
    self.completion_matches.deinit(self.allocator);

    self.allocator.free(self.current_command);
    self.allocator.free(self.clipboard);
    self.allocator.free(self.search_buffer);
    self.allocator.free(self.stdout().buffer);
    self.allocator.destroy(self);
}

pub fn run(self: *Shell) !void {
    self.running = true;

    // enable raw mode for interactive input handling
    try self.enableRawMode();

    // setup signal handler for terminal resize
    self.setupResizeHandler();

    // initialize terminal dimensions
    const initial_size = self.getTerminalSize();
    self.terminal_width = initial_size.width;
    self.terminal_height = initial_size.height;

    // set initial cursor style based on vim mode
    const initial_cursor = if (self.vim_mode_enabled and self.vim_mode == .normal)
        CursorStyle.block
    else
        CursorStyle.bar;
    try self.setCursorStyle(initial_cursor);

    try self.printFancyPrompt();
    try self.stdout().flush();

    var last_action: Action = .none;

    while (self.running) {
        // handle terminal resize
        if (self.terminal_resized) {
            self.terminal_resized = false;
            try self.handleResize();
        }

        try self.log(last_action);
        last_action = try self.readNextAction();
        try self.handleAction(last_action);
        try self.stdout().flush();
    }
}

pub inline fn stdout(self: *Shell) *std.Io.Writer {
    return &self.stdout_writer.interface;
}

// cursor styles for vim modes
const CursorStyle = enum {
    block, // normal mode
    bar, // insert mode
    default, // restore terminal default

    fn escapeCode(self: CursorStyle) []const u8 {
        return switch (self) {
            .block => "\x1b[2 q", // steady block cursor
            .bar => "\x1b[6 q", // steady bar cursor
            .default => "\x1b[0 q", // reset to default
        };
    }
};

fn setCursorStyle(self: *Shell, style: CursorStyle) !void {
    try self.stdout().writeAll(style.escapeCode());
}

const TerminalSize = struct {
    width: usize,
    height: usize,
};

fn getTerminalSize(_: *Shell) TerminalSize {
    const TIOCGWINSZ = if (@hasDecl(std.posix.system, "T")) std.posix.system.T.IOCGWINSZ else 0x5413;

    const winsize = extern struct {
        ws_row: u16,
        ws_col: u16,
        ws_xpixel: u16,
        ws_ypixel: u16,
    };

    var ws: winsize = undefined;
    const result = std.posix.system.ioctl(std.posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws));

    if (result == 0 and ws.ws_col > 0 and ws.ws_row > 0) {
        return .{ .width = ws.ws_col, .height = ws.ws_row };
    }

    return .{ .width = 80, .height = 24 }; // fallback if ioctl fails
}

fn getTerminalWidth(self: *Shell) usize {
    return self.getTerminalSize().width;
}

fn handleSigwinch(_: c_int) callconv(.c) void {
    if (global_shell) |shell| {
        shell.terminal_resized = true;
    }
}

fn setupResizeHandler(self: *Shell) void {
    global_shell = self;

    const SIGWINCH = if (@hasDecl(std.posix.SIG, "WINCH")) std.posix.SIG.WINCH else 28;

    const empty_mask: std.posix.sigset_t = std.mem.zeroes(std.posix.sigset_t);

    var act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigwinch },
        .mask = empty_mask,
        .flags = 0,
    };

    std.posix.sigaction(SIGWINCH, &act, null);
}

fn handleResize(self: *Shell) !void {
    // get current terminal size
    const new_size = self.getTerminalSize();

    // check if dimensions actually changed
    if (new_size.width == self.terminal_width and new_size.height == self.terminal_height) {
        return; // spurious SIGWINCH, nothing changed
    }

    // debounce rapid resizes
    const now = std.time.milliTimestamp();
    const debounce_ms = 50; // wait 50ms between redraws
    if (now - self.last_resize_time < debounce_ms) {
        // schedule another check by keeping the flag set
        self.terminal_resized = true;
        return;
    }
    self.last_resize_time = now;

    const old_width = self.terminal_width;
    const old_height = self.terminal_height;

    // update stored dimensions
    self.terminal_width = new_size.width;
    self.terminal_height = new_size.height;

    if (self.completion_mode and self.completion_displayed) {
        // smart clearing: only clear if we're shrinking or need to reflow
        if (new_size.width < old_width or new_size.height < old_height) {
            // terminal shrank, need full clear
            if (self.completion_menu_lines > 0) {
                try self.stdout().print("\x1b[{d}A", .{self.completion_menu_lines});
            }
            try self.stdout().writeAll("\x1b[J");
        } else {
            // terminal grew, just reposition
            if (self.completion_menu_lines > 0) {
                try self.stdout().print("\x1b[{d}A", .{self.completion_menu_lines});
            }
            try self.stdout().writeAll("\x1b[J");
        }

        // redraw with new dimensions
        try self.displayCompletions();
    } else {
        // just redraw the current line
        try self.redrawLine();
    }
}

fn printFancyPrompt(self: *Shell) !void {
    // get current user
    const user = std.process.getEnvVarOwned(self.allocator, "USER") catch "unknown";
    defer if (std.mem.eql(u8, user, "unknown")) {} else self.allocator.free(user);

    // get hostname
    var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = std.posix.gethostname(&hostname_buf) catch "localhost";

    // get current directory
    var cwd_buf: [4096]u8 = undefined;
    const full_cwd = std.posix.getcwd(&cwd_buf) catch "/";

    // simplify path - show ~ for home directory
    const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch null;
    defer if (home) |h| self.allocator.free(h);

    const display_path = if (home) |h| blk: {
        if (std.mem.startsWith(u8, full_cwd, h)) {
            if (std.mem.eql(u8, full_cwd, h)) {
                break :blk "~";
            } else {
                // create ~/ + rest of path
                var path_buf: [4096]u8 = undefined;
                const rest = full_cwd[h.len..];
                break :blk std.fmt.bufPrint(&path_buf, "~{s}", .{rest}) catch full_cwd;
            }
        } else {
            break :blk full_cwd;
        }
    } else full_cwd;

    // print colorful zsh-like prompt
    const effective_mode = if (self.vim_mode_enabled) self.vim_mode else .insert;
    const mode_color = switch (effective_mode) {
        .insert => tty.Color.yellow,
        .normal => tty.Color.red,
    };
    const mode_indicator = if (self.vim_mode_enabled) switch (effective_mode) {
        .insert => "I",
        .normal => "N",
    } else "E"; // E for emacs/normal editing mode

    // git info on separate line above prompt (if enabled)
    if (self.show_git_info) {
        if (git.getInfo(self.allocator)) |info| {
            var git_info = info;
            defer git_info.deinit(self.allocator);

            const dirty_indicator: []const u8 = if (git_info.dirty) "*" else "";
            if (git_info.commit.len > 0) {
                try self.stdout().print("{f}{s}{f} {s}{s}\n", .{
                    tty.Color.magenta, git_info.branch, tty.Color.reset,
                    git_info.commit, dirty_indicator,
                });
            } else {
                try self.stdout().print("{f}{s}{s}{f}\n", .{
                    tty.Color.magenta, git_info.branch, dirty_indicator, tty.Color.reset,
                });
            }
        }
    }

    // clean 80-char prompt: [mode] user@host ~/path $
    try self.stdout().print("{f}[{f}{s}{f}] {f}{s}@{s}{f} {f}{s}{f} $ ", .{
        tty.Style.bold,  mode_color,   mode_indicator,  tty.Color.reset,
        Colors.userhost, user,         hostname,        tty.Color.reset,
        Colors.path,     display_path, tty.Color.reset,
    });
}

fn log(self: *Shell, last_action: Action) !void {
    if (self.log_file) |file| {
        var buff: [1024 * 256]u8 = undefined;
        const slice = try std.fmt.bufPrint(
            buff[0..],
            "\x1b[H\x1b[J" ++
                "State:\n" ++
                "\tcursor_pos: {}\n" ++
                "\tvim_mode: {s}\n" ++
                "\tvim_mode_enabled: {}\n" ++
                "\thistory_index: {}\n" ++
                "\tcurrent_command_len: {}\n" ++
                "\tclipboard_len: {}\n" ++
                "\tsearch_mode: {}\n" ++
                "\tsearch_len: {}\n" ++
                "\tcurrent_command: '{s}'\n" ++
                "\tsearch_buffer: '{s}'\n" ++
                "\tlast_action: '{}'\n",
            .{
                self.cursor_pos,                                   @tagName(self.vim_mode),
                self.vim_mode_enabled,                             self.history_index,
                self.current_command_len,                          self.clipboard_len,
                self.search_mode,                                  self.search_len,
                self.current_command[0..self.current_command_len], self.search_buffer[0..self.search_len],
                last_action,
            },
        );
        try file.writeAll(slice);
    }
}

fn handleAction(self: *Shell, action: Action) !void {
    switch (action) {
        .none => {},

        .cancel => {
            self.exitCompletionMode();
            self.current_command_len = 0;
            self.cursor_pos = 0;
            self.history_index = -1;
            self.history_search_prefix_len = 0;
            self.vim_mode = .insert; // Always return to insert mode
            try self.setCursorStyle(.bar);
            try self.stdout().writeByte('\n');
            try self.printFancyPrompt();
        },

        .exit_shell => {
            self.running = false;
            try self.stdout().writeByte('\n');
        },

        .toggle_bookmark => {
            const h = self.history orelse return;

            if (self.history_index >= 0 and self.history_index < @as(i32, @intCast(h.entries.items.len))) {
                // Bookmark history entry we're viewing
                const idx: usize = @intCast(self.history_index);
                const is_now_bookmarked = !h.isEntryBookmarked(idx);
                h.toggleBookmark(idx) catch {};
                // Show indicator and redraw to clear it
                try self.stdout().writeAll(if (is_now_bookmarked) " *" else " -");
                try self.stdout().flush();
                std.Thread.sleep(80 * std.time.ns_per_ms);
                try self.redrawLine();
            } else if (self.current_command_len > 0) {
                // Bookmark current command being typed
                const cmd = self.current_command[0..self.current_command_len];
                // Add to history and bookmark it
                h.addCommand(cmd, 0) catch {};
                const cmd_hash = std.hash.Wyhash.hash(0, cmd);
                if (h.hash_map.get(cmd_hash)) |idx| {
                    h.toggleBookmark(idx) catch {};
                    try self.stdout().writeAll(" *");
                    try self.stdout().flush();
                    std.Thread.sleep(80 * std.time.ns_per_ms);
                    try self.redrawLine();
                }
            }
        },

        .input_char => |char| {
            // exit completion mode when typing
            self.exitCompletionMode();

            if (self.search_mode) {
                // Add to search buffer
                if (self.search_len < self.search_buffer.len) {
                    self.search_buffer[self.search_len] = char;
                    self.search_len += 1;
                    try self.stdout().writeByte(char);
                }
            } else {
                // Add to command buffer
                if (self.current_command_len >= self.current_command.len)
                    return error.InputTooLong;

                // Make room for the new character if inserting in middle
                if (self.cursor_pos < self.current_command_len) {
                    // Shift everything right by 1, starting from the end
                    var i = self.current_command_len;
                    while (i > self.cursor_pos) : (i -= 1) {
                        self.current_command[i] = self.current_command[i - 1];
                    }
                }

                // Insert the character at cursor position
                self.current_command[self.cursor_pos] = char;
                self.current_command_len += 1;
                self.cursor_pos += 1;

                // Update display
                if (char == '\n') {
                    // Newline requires full redraw for multiline support
                    try self.redrawLine();
                } else if (self.cursor_pos == self.current_command_len) {
                    // At end of line - just echo the character
                    try self.stdout().writeByte(char);
                } else {
                    // In middle of line - need to redraw from cursor onwards
                    // Write the new character and everything after it
                    try self.stdout().writeAll(self.current_command[self.cursor_pos - 1 .. self.current_command_len]);
                    // Move cursor back to correct position
                    const chars_to_move_back = self.current_command_len - self.cursor_pos;
                    if (chars_to_move_back > 0) {
                        try self.stdout().print("\x1b[{d}D", .{chars_to_move_back});
                    }
                }
            }
        },

        .backspace => {
            if (self.search_mode) {
                if (self.search_len > 0) {
                    self.search_len -= 1;
                    try self.stdout().writeAll("\x08 \x08");
                }
            } else {
                if (self.cursor_pos > 0 and self.current_command_len > 0) {
                    // Delete character before cursor
                    @memmove(
                        self.current_command[self.cursor_pos - 1 .. self.current_command_len - 1],
                        self.current_command[self.cursor_pos..self.current_command_len],
                    );
                    self.cursor_pos -= 1;
                    self.current_command_len -= 1;
                    try self.redrawLine();
                }
            }
        },

        .delete => |delete_action| {
            switch (delete_action) {
                .char_under_cursor => {
                    if (self.cursor_pos < self.current_command_len) {
                        @memmove(
                            self.current_command[self.cursor_pos .. self.current_command_len - 1],
                            self.current_command[self.cursor_pos + 1 .. self.current_command_len],
                        );
                        self.current_command_len -= 1;
                        try self.redrawLine();
                    }
                },
                .to_line_end => {
                    if (self.cursor_pos < self.current_command_len) {
                        // Copy to clipboard
                        const delete_len = self.current_command_len - self.cursor_pos;
                        @memcpy(
                            self.clipboard[0..delete_len],
                            self.current_command[self.cursor_pos..self.current_command_len],
                        );
                        self.clipboard_len = delete_len;
                        // Delete
                        self.current_command_len = self.cursor_pos;
                        try self.redrawLine();
                    }
                },
                .char_at => |pos| {
                    if (pos < self.current_command_len) {
                        @memmove(
                            self.current_command[pos .. self.current_command_len - 1],
                            self.current_command[pos + 1 .. self.current_command_len],
                        );
                        self.current_command_len -= 1;
                        try self.redrawLine();
                    }
                },
            }
        },

        .execute_command => {
            if (self.search_mode) {
                // In search mode, treat enter as exit search
                try self.handleAction(.{ .exit_search_mode = true });
            } else {
                self.exitCompletionMode();

                const command = std.mem.trim(u8, self.current_command[0..self.current_command_len], " \t\n\r");

                try self.stdout().writeByte('\n');
                try self.stdout().flush();

                if (command.len > 0) {
                    self.last_exit_code = try self.executeCommand(command);

                    // Add to history
                    if (self.history) |h| {
                        h.addCommand(command, self.last_exit_code) catch {};
                    }
                }

                self.current_command_len = 0;
                self.cursor_pos = 0;
                self.history_index = -1;
                self.history_search_prefix_len = 0;
                self.vim_mode = .insert;
                try self.setCursorStyle(.bar);

                if (self.running)
                    try self.printFancyPrompt();
            }
        },

        .redraw_line => try self.redrawLine(),

        .clear_screen => {
            try self.stdout().writeAll("\x1b[2J\x1b[H");
            try self.printFancyPrompt();
            if (self.current_command_len > 0) {
                try self.stdout().writeAll(self.current_command[0..self.current_command_len]);
            }
        },

        .vim_mode => |mode_action| {
            switch (mode_action) {
                .set_mode => |mode| {
                    self.vim_mode = mode;
                    // entering normal mode should exit paste mode
                    if (mode == .normal) self.paste_mode = false;
                },
                .toggle_enabled => {
                    self.vim_mode_enabled = !self.vim_mode_enabled;
                },
                .toggle_mode => {
                    self.vim_mode = if (self.vim_mode == .normal) .insert else .normal;
                    if (self.vim_mode == .normal) self.paste_mode = false;
                },
            }
            // update cursor style to match vim mode
            const cursor = if (self.vim_mode_enabled and self.vim_mode == .normal)
                CursorStyle.block
            else
                CursorStyle.bar;
            try self.setCursorStyle(cursor);
            return self.redrawLine();
        },

        .tap_complete => {
            if (self.completion_mode) {
                try self.handleCompletionCycle(.forward);
            } else {
                try self.handleTabCompletion();
            }
        },

        .cycle_complete => |direction| {
            if (self.completion_mode) {
                try self.handleCompletionCycle(direction);
            } else {
                try self.handleTabCompletion();
            }
        },

        .move_cursor => |move| {
            try self.handleCursorMovement(move);
        },

        .history_nav => |direction| {
            try self.handleHistoryNavigation(direction);
        },

        .enter_search_mode => |direction| {
            self.search_mode = true;
            self.search_len = 0;
            const search_char: u8 = if (direction == .forward) '/' else '?';
            try self.stdout().writeByte(search_char);
        },

        .exit_search_mode => |execute| {
            self.search_mode = false;

            if (execute and self.search_len > 0 and self.history != null) {
                const search_term = self.search_buffer[0..self.search_len];
                const matches = self.history.?.fuzzySearch(search_term, self.allocator) catch {
                    try self.redrawLine();
                    return;
                };
                defer self.allocator.free(matches);

                if (matches.len > 0) {
                    const entry_idx = matches[0].entry_index;
                    const entry = self.history.?.entries.items[entry_idx];
                    const cmd = self.history.?.getCommand(entry);

                    const copy_len = @min(cmd.len, self.current_command.len);
                    @memcpy(self.current_command[0..copy_len], cmd[0..copy_len]);
                    self.current_command_len = copy_len;
                    self.cursor_pos = copy_len;
                }
            }

            self.search_len = 0;
            try self.redrawLine();
        },

        .yank => |yank_action| {
            switch (yank_action) {
                .line => {
                    @memcpy(
                        self.clipboard[0..self.current_command_len],
                        self.current_command[0..self.current_command_len],
                    );
                    self.clipboard_len = self.current_command_len;
                },
                .selection => |sel| {
                    if (sel.end > sel.start and sel.end <= self.current_command_len) {
                        const len = sel.end - sel.start;
                        @memcpy(
                            self.clipboard[0..len],
                            self.current_command[sel.start..sel.end],
                        );
                        self.clipboard_len = len;
                    }
                },
            }
        },

        .paste => |paste_action| {
            if (self.clipboard_len == 0) return;
            if (self.current_command_len + self.clipboard_len >= self.current_command.len)
                return error.InputTooLong;

            const insert_pos = switch (paste_action) {
                .after_cursor => blk: {
                    // paste after the character under cursor
                    // if at end of line, paste at end; otherwise paste after current char
                    break :blk if (self.cursor_pos < self.current_command_len)
                        self.cursor_pos + 1
                    else
                        self.cursor_pos;
                },
                .before_cursor => self.cursor_pos, // paste before (at) the character under cursor
            };

            // Shift content right
            @memmove(
                self.current_command[insert_pos + self.clipboard_len .. self.current_command_len + self.clipboard_len],
                self.current_command[insert_pos..self.current_command_len],
            );

            // Insert clipboard
            @memcpy(
                self.current_command[insert_pos .. insert_pos + self.clipboard_len],
                self.clipboard[0..self.clipboard_len],
            );

            self.current_command_len += self.clipboard_len;
            self.cursor_pos = insert_pos + self.clipboard_len;
            try self.redrawLine();
        },

        .insert_at_position => |pos_type| {
            switch (pos_type) {
                .cursor => {},
                .after_cursor => {
                    if (self.cursor_pos < self.current_command_len) {
                        self.cursor_pos += 1;
                        try self.handleCursorMovement(.{ .relative = 1 });
                    }
                },
                .line_start => {
                    self.cursor_pos = 0;
                    try self.handleCursorMovement(.to_line_start);
                },
                .line_end => {
                    self.cursor_pos = self.current_command_len;
                    try self.handleCursorMovement(.to_line_end);
                },
            }
            self.vim_mode = .insert;
            try self.setCursorStyle(.bar);
            try self.redrawLine();
        },

        .undo => {
            self.current_command_len = 0;
            self.cursor_pos = 0;
            try self.redrawLine();
        },

        .enter_paste_mode => {
            self.paste_mode = true;
        },

        .exit_paste_mode => {
            self.paste_mode = false;
            try self.redrawLine();
        },
    }
}

fn handleCursorMovement(self: *Shell, move_action: MoveCursorAction) !void {
    const old_pos = self.cursor_pos;
    const max_pos = self.current_command_len;
    const cmd = self.current_command[0..self.current_command_len];

    // Handle line up/down specially - may need history fallback
    // In insert mode, always use history navigation for up/down
    switch (move_action) {
        .line_up => {
            if (!self.vim_mode_enabled or self.vim_mode == .insert) {
                // Insert mode: just do history navigation
                try self.handleHistoryNavigation(.up);
                try self.redrawLine();
            } else {
                // Normal mode: line movement with history fallback
                const result = self.findLinePosition(cmd, old_pos, true);
                if (result.found) {
                    self.cursor_pos = result.pos;
                    try self.redrawLine();
                } else {
                    try self.handleHistoryNavigation(.up);
                    try self.redrawLine();
                }
            }
            return;
        },
        .line_down => {
            if (!self.vim_mode_enabled or self.vim_mode == .insert) {
                // Insert mode: just do history navigation
                try self.handleHistoryNavigation(.down);
                try self.redrawLine();
            } else {
                // Normal mode: line movement with history fallback
                const result = self.findLinePosition(cmd, old_pos, false);
                if (result.found) {
                    self.cursor_pos = result.pos;
                    try self.redrawLine();
                } else {
                    try self.handleHistoryNavigation(.down);
                    try self.redrawLine();
                }
            }
            return;
        },
        else => {},
    }

    // Calculate new position (clamped to valid range)
    const new_pos = switch (move_action) {
        .relative => |steps| blk: {
            const new = @as(isize, @intCast(self.cursor_pos)) + steps;
            break :blk @as(usize, @intCast(@max(0, @min(new, @as(isize, @intCast(max_pos))))));
        },
        .absolute => |pos| @min(pos, max_pos),
        .to_line_start => self.findCurrentLineStart(cmd, old_pos),
        .to_line_end => self.findCurrentLineEnd(cmd, old_pos),
        .word_forward => |boundary| self.findWordForward(boundary),
        .word_backward => |boundary| self.findWordBackward(boundary),
        .line_up, .line_down => unreachable,
    };

    if (new_pos == old_pos) return;

    self.cursor_pos = new_pos;

    // For multiline content, use redrawLine for proper positioning
    if (std.mem.indexOfScalar(u8, cmd, '\n') != null) {
        try self.redrawLine();
    } else {
        const steps = if (new_pos > old_pos)
            new_pos - old_pos
        else
            old_pos - new_pos;

        if (new_pos > old_pos) {
            try self.stdout().print("\x1b[{d}C", .{steps});
        } else {
            try self.stdout().print("\x1b[{d}D", .{steps});
        }
    }
}

fn findLinePosition(self: *Shell, cmd: []const u8, pos: usize, going_up: bool) struct { found: bool, pos: usize } {
    _ = self;

    // Find current line start and column
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < pos) : (i += 1) {
        if (cmd[i] == '\n') {
            line_start = i + 1;
        }
    }
    const col = pos - line_start;

    if (going_up) {
        // Find previous line
        if (line_start == 0) return .{ .found = false, .pos = 0 };

        // Find start of previous line
        var prev_line_start: usize = 0;
        if (line_start >= 2) {
            i = line_start - 2; // skip the newline before current line
            while (i > 0) : (i -= 1) {
                if (cmd[i] == '\n') {
                    prev_line_start = i + 1;
                    break;
                }
            }
        }

        // Find end of previous line
        const prev_line_end = line_start - 1;
        const prev_line_len = prev_line_end - prev_line_start;

        // Target position on previous line
        const target_col = @min(col, prev_line_len);
        return .{ .found = true, .pos = prev_line_start + target_col };
    } else {
        // Find next line
        var next_line_start: usize = 0;
        i = pos;
        while (i < cmd.len) : (i += 1) {
            if (cmd[i] == '\n') {
                next_line_start = i + 1;
                break;
            }
        }

        if (next_line_start == 0 or next_line_start >= cmd.len) {
            return .{ .found = false, .pos = 0 };
        }

        // Find end of next line
        var next_line_end = cmd.len;
        i = next_line_start;
        while (i < cmd.len) : (i += 1) {
            if (cmd[i] == '\n') {
                next_line_end = i;
                break;
            }
        }

        const next_line_len = next_line_end - next_line_start;
        const target_col = @min(col, next_line_len);
        return .{ .found = true, .pos = next_line_start + target_col };
    }
}

fn findCurrentLineStart(self: *Shell, cmd: []const u8, pos: usize) usize {
    _ = self;
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0) : (i -= 1) {
        if (cmd[i] == '\n') return i + 1;
    }
    if (cmd[0] == '\n') return 1;
    return 0;
}

fn findCurrentLineEnd(self: *Shell, cmd: []const u8, pos: usize) usize {
    _ = self;
    var i = pos;
    while (i < cmd.len) : (i += 1) {
        if (cmd[i] == '\n') return i;
    }
    return cmd.len;
}

fn findWordForward(self: *Shell, boundary: WordBoundary) usize {
    const buf = self.current_command[0..self.current_command_len];
    var pos = self.cursor_pos;
    const max = self.current_command_len;

    if (pos >= max) return max;

    return switch (boundary) {
        .word => blk: {
            // Skip current word (alphanumeric + underscore)
            while (pos < max and isWordChar(buf[pos])) : (pos += 1) {}
            // Skip whitespace
            while (pos < max and isWhitespace(buf[pos])) : (pos += 1) {}
            break :blk pos;
        },
        .WORD => blk: {
            // Skip non-whitespace
            while (pos < max and !isWhitespace(buf[pos])) : (pos += 1) {}
            // Skip whitespace
            while (pos < max and isWhitespace(buf[pos])) : (pos += 1) {}
            break :blk pos;
        },
        .word_end => blk: {
            // Move forward one if we're on the last char of a word
            if (pos < max and isWordChar(buf[pos]) and
                (pos + 1 >= max or !isWordChar(buf[pos + 1])))
            {
                pos += 1;
            }
            // Skip whitespace
            while (pos < max and isWhitespace(buf[pos])) : (pos += 1) {}
            // Move to end of word
            while (pos < max and isWordChar(buf[pos])) : (pos += 1) {}
            // Back up one to be ON the last character
            if (pos > self.cursor_pos) pos -= 1;
            break :blk pos;
        },
        .WORD_end => blk: {
            // Move forward one if we're on the last char of a WORD
            if (pos < max and !isWhitespace(buf[pos]) and
                (pos + 1 >= max or isWhitespace(buf[pos + 1])))
            {
                pos += 1;
            }
            // Skip whitespace
            while (pos < max and isWhitespace(buf[pos])) : (pos += 1) {}
            // Move to end of WORD
            while (pos < max and !isWhitespace(buf[pos])) : (pos += 1) {}
            // Back up one to be ON the last character
            if (pos > self.cursor_pos) pos -= 1;
            break :blk pos;
        },
    };
}

fn findWordBackward(self: *Shell, boundary: WordBoundary) usize {
    const buf = self.current_command[0..self.current_command_len];
    if (self.cursor_pos == 0) return 0;

    var pos = self.cursor_pos - 1;

    return switch (boundary) {
        .word, .word_end => blk: {
            // Skip whitespace
            while (pos > 0 and isWhitespace(buf[pos])) : (pos -= 1) {}
            // Skip to beginning of word
            while (pos > 0 and isWordChar(buf[pos - 1])) : (pos -= 1) {}
            break :blk pos;
        },
        .WORD, .WORD_end => blk: {
            // Skip whitespace
            while (pos > 0 and isWhitespace(buf[pos])) : (pos -= 1) {}
            // Skip to beginning of WORD
            while (pos > 0 and !isWhitespace(buf[pos - 1])) : (pos -= 1) {}
            break :blk pos;
        },
    };
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

fn readNextAction(self: *Shell) !Action {
    var temp_buf: [1]u8 = undefined;
    const count = try std.fs.File.stdin().read(temp_buf[0..]);
    const char = temp_buf[0];

    if (count == 0) return .none;

    // Always check for escape sequences (arrow keys, Ctrl+arrows, paste end, etc.)
    if (char == '\x1b') {
        return escapeSequenceAction();
    }

    // In paste mode (and insert mode), buffer content for editing
    // In normal mode, don't capture chars as input even if paste_mode is stuck
    if (self.paste_mode and (!self.vim_mode_enabled or self.vim_mode == .insert)) {
        if (char == CTRL_C) {
            self.paste_mode = false;
            return .cancel;
        }
        // Store newlines for multiline editing
        if (char == '\n' or char == '\r') {
            return .{ .input_char = '\n' };
        }
        if (char >= 32 and char <= 126) {
            return .{ .input_char = char };
        }
        return .none;
    }

    if (self.search_mode) {
        return self.getSearchModeAction(char);
    }

    // Check if vim mode is enabled
    if (self.vim_mode_enabled) {
        return switch (self.vim_mode) {
            .normal => normalModeAction(char),
            .insert => insertModeAction(char),
        };
    } else {
        return insertModeAction(char);
    }
}

fn insertModeAction(char: u8) Action {
    return switch (char) {
        '\n' => .execute_command,
        CTRL_C => .cancel,
        CTRL_T => .{ .vim_mode = .toggle_enabled },
        CTRL_L => .clear_screen,
        CTRL_D => .exit_shell,
        CTRL_B => .toggle_bookmark,
        '\t' => .tap_complete,
        8, 127 => .backspace,
        32...126 => .{ .input_char = char },
        else => .none,
    };
}

fn normalModeAction(char: u8) Action {
    return switch (char) {
        'h' => .{ .move_cursor = .{ .relative = -1 } },
        'l' => .{ .move_cursor = .{ .relative = 1 } },
        '0' => .{ .move_cursor = .to_line_start },
        '$' => .{ .move_cursor = .to_line_end },

        'w' => .{ .move_cursor = .{ .word_forward = .word } },
        'W' => .{ .move_cursor = .{ .word_forward = .WORD } },
        'b' => .{ .move_cursor = .{ .word_backward = .word } },
        'B' => .{ .move_cursor = .{ .word_backward = .WORD } },
        'e' => .{ .move_cursor = .{ .word_forward = .word_end } },
        'E' => .{ .move_cursor = .{ .word_forward = .WORD_end } },

        'j' => .{ .move_cursor = .line_down },
        'k' => .{ .move_cursor = .line_up },

        'i' => .{ .vim_mode = .{ .set_mode = .insert } },

        'a' => .{ .insert_at_position = .after_cursor },
        'A' => .{ .insert_at_position = .line_end },
        'I' => .{ .insert_at_position = .line_start },

        'x' => .{ .delete = .char_under_cursor },
        'D' => .{ .delete = .to_line_end },

        'p' => .{ .paste = .after_cursor },
        'P' => .{ .paste = .before_cursor },

        'y' => .{ .yank = .line },

        'u' => .undo,

        '/' => .{ .enter_search_mode = .forward },
        '?' => .{ .enter_search_mode = .backward },

        '\n' => .execute_command,

        CTRL_C => .cancel,
        CTRL_T => .{ .vim_mode = .toggle_enabled },

        else => .none,
    };
}

fn escapeSequenceAction() !Action {
    const stdin = std.fs.File.stdin();
    var temp_buf: [3]u8 = undefined;

    // Set stdin to non-blocking mode to check if there's more data
    // If fcntl fails, default to 0 flags (safe fallback for non-blocking check)
    const flags = std.posix.fcntl(stdin.handle, std.posix.F.GETFL, 0) catch 0;
    // Attempt to set non-blocking mode. If it fails, stdin remains blocking
    // which is acceptable - we'll just wait for input instead of detecting ESC immediately
    _ = std.posix.fcntl(stdin.handle, std.posix.F.SETFL, flags | 0o4000) catch {}; // O_NONBLOCK

    // If read fails in non-blocking mode, treat as no data available (ESC key press)
    const bytes_read = stdin.read(&temp_buf) catch 0;

    // Restore blocking mode. If this fails, subsequent input may behave unexpectedly
    // but the shell will still function. Terminal state is restored on shell exit.
    _ = std.posix.fcntl(stdin.handle, std.posix.F.SETFL, flags) catch {};

    // If no following bytes or not '[', it's just ESC key press
    if (bytes_read == 0 or temp_buf[0] != '[') {
        return .{ .vim_mode = .{ .set_mode = .normal } };
    }

    // Need at least 2 bytes for a valid escape sequence
    if (bytes_read < 2) return .none;

    const cmd_byte = temp_buf[1];

    return switch (cmd_byte) {
        'A' => .{ .history_nav = .up }, // Up arrow
        'B' => .{ .history_nav = .down }, // Down arrow
        'C' => .{ .move_cursor = .{ .relative = 1 } }, // Right arrow
        'D' => .{ .move_cursor = .{ .relative = -1 } }, // Left arrow
        'Z' => .{ .cycle_complete = .backward }, // Shift+Tab
        'H' => .{ .move_cursor = .to_line_start }, // Home key
        'F' => .{ .move_cursor = .to_line_end }, // End key
        '1' => blk: {
            // Ctrl+arrows, Home, End (ESC[1;5X or ESC[1~)
            if (bytes_read >= 3) {
                break :blk try handleExtendedEscapeSequence(temp_buf[2]);
            }
            break :blk try handleExtendedEscapeSequence(0);
        },
        '2' => blk: {
            // Bracketed paste (ESC[200~ or ESC[201~)
            if (bytes_read >= 3) {
                break :blk try handleBracketedPaste(temp_buf[2], bytes_read);
            }
            break :blk .none;
        },
        '3' => blk: {
            // Delete key (ESC[3~)
            if (bytes_read >= 3 and temp_buf[2] == '~') {
                break :blk .{ .delete = .char_under_cursor };
            }
            break :blk .none;
        },
        '4' => blk: {
            // End key (ESC[4~) in some terminals
            if (bytes_read >= 3 and temp_buf[2] == '~') {
                break :blk .{ .move_cursor = .to_line_end };
            }
            break :blk .none;
        },
        '7' => blk: {
            // Home key (ESC[7~) in some terminals
            if (bytes_read >= 3 and temp_buf[2] == '~') {
                break :blk .{ .move_cursor = .to_line_start };
            }
            break :blk .none;
        },
        '8' => blk: {
            // End key (ESC[8~) in some terminals
            if (bytes_read >= 3 and temp_buf[2] == '~') {
                break :blk .{ .move_cursor = .to_line_end };
            }
            break :blk .none;
        },
        else => .none,
    };
}

fn handleExtendedEscapeSequence(third_byte: u8) !Action {
    const stdin = std.fs.File.stdin();
    var temp_buf: [2]u8 = undefined;

    // check if we already have the semicolon
    const semicolon = if (third_byte != 0) third_byte else blk: {
        const semicolon_read = stdin.read(temp_buf[0..1]) catch return .none;
        if (semicolon_read == 0) return .none;
        break :blk temp_buf[0];
    };

    // handle ESC[1~ (Home key in some terminals)
    if (semicolon == '~') {
        return .{ .move_cursor = .to_line_start };
    }

    // expect semicolon for modified keys
    if (semicolon != ';') return .none;

    // read modifier (5 = Ctrl)
    const modifier_read = stdin.read(temp_buf[0..1]) catch return .none;
    if (modifier_read == 0 or temp_buf[0] != '5') return .none;

    // read direction key
    const direction_read = stdin.read(temp_buf[0..1]) catch return .none;
    if (direction_read == 0) return .none;

    return switch (temp_buf[0]) {
        'C' => .{ .move_cursor = .{ .word_forward = .word } },      // Ctrl+Right
        'D' => .{ .move_cursor = .{ .word_backward = .word } },     // Ctrl+Left
        'A' => .{ .move_cursor = .to_line_start },                   // Ctrl+Up
        'B' => .{ .move_cursor = .to_line_end },                     // Ctrl+Down
        'H' => .{ .move_cursor = .to_line_start },                   // Ctrl+Home
        'F' => .{ .move_cursor = .to_line_end },                     // Ctrl+End
        else => .none,
    };
}

fn handleBracketedPaste(third_byte: u8, bytes_read: usize) !Action {
    const stdin = std.fs.File.stdin();

    // We already have the third byte from the initial read
    // Sequence is ESC[200~ or ESC[201~
    // We need to check: '0' (third_byte), then read '0' or '1', then '~'

    if (bytes_read < 3 or third_byte != '0') return .none;

    var buf: [2]u8 = undefined;
    const read_count = stdin.read(&buf) catch return .none;
    if (read_count < 2) return .none;

    // Check for '0~' (paste start: 200~) or '1~' (paste end: 201~)
    if (buf[1] != '~') return .none;

    return switch (buf[0]) {
        '0' => .enter_paste_mode,
        '1' => .exit_paste_mode,
        else => .none,
    };
}

fn getSearchModeAction(self: *Shell, char: u8) Action {
    return switch (char) {
        '\n' => .{ .exit_search_mode = true },
        '\x1b' => .{ .exit_search_mode = false },
        8, 127 => blk: {
            if (self.search_len > 0) {
                break :blk .backspace;
            }
            break :blk .none;
        },
        32...126 => .{ .input_char = char },
        else => .none,
    };
}

pub fn enableRawMode(self: *Shell) !void {
    const stdin_fd = std.posix.STDIN_FILENO;

    // get current terminal attributes
    var termios = std.posix.tcgetattr(stdin_fd) catch return;

    // save original for restoration
    self.original_termios = termios;

    // modify terminal attributes for raw mode
    // disable canonical mode and echo
    termios.lflag.ICANON = false;
    termios.lflag.ECHO = false;
    termios.lflag.ISIG = false; // disable ctrl+c/ctrl+z signals

    // set minimum characters to read and timeout
    termios.cc[@intFromEnum(std.posix.V.MIN)] = 1; // read 1 char at a time
    termios.cc[@intFromEnum(std.posix.V.TIME)] = 0; // no timeout

    // apply the changes
    std.posix.tcsetattr(stdin_fd, .NOW, termios) catch return;

    // enable bracketed paste mode
    try self.stdout().writeAll("\x1b[?2004h");
}

pub fn disableRawMode(self: *Shell) void {
    // disable bracketed paste mode
    self.stdout().writeAll("\x1b[?2004l") catch {};

    if (self.original_termios) |original| {
        const stdin_fd = std.posix.STDIN_FILENO;
        std.posix.tcsetattr(stdin_fd, .NOW, original) catch {};
    }
}

fn handleHistoryNavigation(self: *Shell, direction: HistoryDirection) !void {
    const h = self.history orelse return;

    switch (direction) {
        .up => {
            // Save current command if we're starting history navigation
            if (self.history_index == -1) {
                self.history_index = @intCast(h.entries.items.len);
                // Save prefix for prefix-based search
                self.history_search_prefix_len = self.current_command_len;
            }

            // Move up in history with optional prefix filtering
            if (self.history_index > 0) {
                if (self.history_search_prefix_len > 0) {
                    // Prefix search - find previous matching entry
                    const prefix = self.current_command[0..self.history_search_prefix_len];
                    var idx = self.history_index - 1;
                    while (idx >= 0) : (idx -= 1) {
                        const entry = h.entries.items[@intCast(idx)];
                        const cmd = h.getCommand(entry);
                        if (cmd.len >= prefix.len and std.mem.eql(u8, cmd[0..prefix.len], prefix)) {
                            self.history_index = idx;
                            try self.loadHistoryEntry(h);
                            break;
                        }
                        if (idx == 0) break;
                    }
                } else {
                    // No prefix - simple navigation
                    self.history_index -= 1;
                    try self.loadHistoryEntry(h);
                }
            }
        },
        .down => {
            // Can't go down if not in history navigation
            if (self.history_index == -1) return;

            if (self.history_search_prefix_len > 0) {
                // Prefix search - find next matching entry
                const prefix = self.current_command[0..self.history_search_prefix_len];
                var idx = self.history_index + 1;
                const max_idx: i32 = @intCast(h.entries.items.len);
                while (idx < max_idx) : (idx += 1) {
                    const entry = h.entries.items[@intCast(idx)];
                    const cmd = h.getCommand(entry);
                    if (cmd.len >= prefix.len and std.mem.eql(u8, cmd[0..prefix.len], prefix)) {
                        self.history_index = idx;
                        try self.loadHistoryEntry(h);
                        break;
                    }
                } else {
                    // No more matches - restore prefix
                    self.history_index = -1;
                    self.current_command_len = self.history_search_prefix_len;
                    self.cursor_pos = self.history_search_prefix_len;
                    self.history_search_prefix_len = 0;
                }
            } else {
                self.history_index += 1;

                // Reached the end - clear command (back to empty current line)
                if (self.history_index >= @as(i32, @intCast(h.entries.items.len))) {
                    self.history_index = -1;
                    self.current_command_len = 0;
                    self.cursor_pos = 0;
                } else {
                    try self.loadHistoryEntry(h);
                }
            }
        },
    }

    // Redraw the line with new content
    try self.redrawLine();
}

fn loadHistoryEntry(self: *Shell, h: *hist.History) !void {
    const entry = h.entries.items[@intCast(self.history_index)];
    const history_cmd = h.getCommand(entry);

    // Copy history command to current_command buffer
    const copy_len = @min(history_cmd.len, self.current_command.len);
    @memcpy(self.current_command[0..copy_len], history_cmd[0..copy_len]);

    // Update current command length and cursor position
    self.current_command_len = copy_len;
    self.cursor_pos = copy_len;
}

fn tryGitCompletion(self: *Shell, cmd: []const u8, word_result: WordResult) !bool {
    // check if command starts with "git "
    if (!std.mem.startsWith(u8, cmd, "git ")) return false;
    if (!git.isRepo()) return false;

    // parse git subcommand
    const after_git = cmd[4..];
    var parts = std.mem.splitScalar(u8, after_git, ' ');
    const subcommand = parts.next() orelse return false;

    // get matches based on subcommand
    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
    defer {
        for (matches.items) |m| self.allocator.free(m);
        matches.deinit(self.allocator);
    }

    const pattern = word_result.word;

    if (std.mem.eql(u8, subcommand, "add") or
        std.mem.eql(u8, subcommand, "restore") or
        std.mem.eql(u8, subcommand, "diff"))
    {
        // complete with modified/deleted/untracked files
        if (git.getStatus(self.allocator)) |s| {
            var status = s;
            defer status.deinit();

            for (status.modified.items) |file| {
                if (std.mem.startsWith(u8, file, pattern)) {
                    matches.append(self.allocator, self.allocator.dupe(u8, file) catch continue) catch {};
                }
            }
            for (status.deleted.items) |file| {
                if (std.mem.startsWith(u8, file, pattern)) {
                    matches.append(self.allocator, self.allocator.dupe(u8, file) catch continue) catch {};
                }
            }
            for (status.untracked.items) |file| {
                if (std.mem.startsWith(u8, file, pattern)) {
                    matches.append(self.allocator, self.allocator.dupe(u8, file) catch continue) catch {};
                }
            }
        }
    } else if (std.mem.eql(u8, subcommand, "checkout") or
        std.mem.eql(u8, subcommand, "switch") or
        std.mem.eql(u8, subcommand, "merge") or
        std.mem.eql(u8, subcommand, "rebase"))
    {
        // complete with branches
        try self.getGitBranches(&matches, pattern);
    } else if (std.mem.eql(u8, subcommand, "branch")) {
        // check for -d flag
        var has_delete = false;
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, "-d") or std.mem.eql(u8, part, "-D") or
                std.mem.eql(u8, part, "--delete"))
            {
                has_delete = true;
                break;
            }
        }
        if (has_delete) {
            try self.getGitBranches(&matches, pattern);
        }
    } else {
        return false; // not a git subcommand we handle
    }

    if (matches.items.len == 0) return false;

    // apply completion
    if (matches.items.len == 1) {
        return try self.applySingleCompletion(matches.items[0], word_result);
    } else {
        return try self.showCompletionMatches(&matches, word_result, pattern);
    }
}

fn getGitBranches(self: *Shell, matches: *std.ArrayList([]const u8), pattern: []const u8) !void {
    // read branches from .git/refs/heads/
    const refs_dir = std.fs.cwd().openDir(".git/refs/heads", .{ .iterate = true }) catch return;
    var dir = refs_dir;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, pattern)) {
            const branch = try self.allocator.dupe(u8, entry.name);
            try matches.append(self.allocator, branch);
        }
    }
}

fn applySingleCompletion(self: *Shell, match: []const u8, word_result: WordResult) !bool {
    const pattern = word_result.word;
    const word_end = word_result.end;
    const comp_str = match[pattern.len..];

    const new_len = self.current_command_len + comp_str.len;
    if (new_len >= self.current_command.len) return error.InputTooLong;

    if (word_end < self.current_command_len) {
        @memmove(
            self.current_command[word_end + comp_str.len .. new_len],
            self.current_command[word_end..self.current_command_len],
        );
    }

    @memcpy(self.current_command[word_end .. word_end + comp_str.len], comp_str);
    self.current_command_len = new_len;
    self.cursor_pos = word_end + comp_str.len;
    try self.redrawLine();
    return true;
}

fn showCompletionMatches(self: *Shell, matches: *std.ArrayList([]const u8), word_result: WordResult, pattern: []const u8) !bool {
    // find longest common prefix among all matches
    if (matches.items.len == 0) return false;

    var common_prefix_len: usize = matches.items[0].len;
    for (matches.items[1..]) |match| {
        var i: usize = 0;
        while (i < common_prefix_len and i < match.len and matches.items[0][i] == match[i]) : (i += 1) {}
        common_prefix_len = i;
    }

    // if common prefix is longer than pattern, complete to that first
    if (common_prefix_len > pattern.len) {
        const common_prefix = matches.items[0][0..common_prefix_len];
        const comp_str = common_prefix[pattern.len..];
        const word_end = word_result.end;

        // insert completion
        if (word_end + comp_str.len < types.MAX_COMMAND_LENGTH) {
            // shift existing text to make room
            const tail_len = self.current_command_len - word_end;
            if (tail_len > 0) {
                std.mem.copyBackwards(u8, self.current_command[word_end + comp_str.len ..], self.current_command[word_end .. word_end + tail_len]);
            }
            @memcpy(self.current_command[word_end .. word_end + comp_str.len], comp_str);
            self.current_command_len += comp_str.len;
            self.cursor_pos = word_end + comp_str.len;
            try self.redrawLine();
        }
        return true;
    }

    // common prefix equals pattern, show all matches
    self.exitCompletionMode();

    for (matches.items) |match| {
        const owned = try self.allocator.dupe(u8, match);
        try self.completion_matches.append(self.allocator, owned);
    }

    self.completion_mode = true;
    self.completion_index = self.completion_matches.items.len;
    self.completion_word_start = word_result.start;
    self.completion_word_end = word_result.end;
    self.completion_original_len = self.current_command_len;
    self.completion_pattern_len = word_result.word.len;

    try self.displayCompletions();
    return true;
}

fn handleTabCompletion(self: *Shell) !void {
    if (self.current_command_len == 0) return;

    // find the word at cursor position
    const cmd = self.current_command[0..self.current_command_len];
    const word_result = self.extractWordAtCursor(cmd) orelse return;

    const word = word_result.word;
    const word_end = word_result.end;

    // check for git-aware completion
    if (try self.tryGitCompletion(cmd, word_result)) return;

    // determine base directory and search pattern
    // expand ~ to home directory if needed
    var expanded_dir_buf: [4096]u8 = undefined;
    const search_dir: []const u8 = if (std.mem.lastIndexOf(u8, word, "/")) |last_slash| blk: {
        if (last_slash == 0) {
            // absolute path like "/etc"
            break :blk "/";
        } else {
            const dir_part = word[0..last_slash];
            // expand ~ at start
            if (std.mem.startsWith(u8, dir_part, "~")) {
                const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch break :blk dir_part;
                defer self.allocator.free(home);
                const rest = dir_part[1..]; // skip ~
                const expanded_len = home.len + rest.len;
                if (expanded_len < expanded_dir_buf.len) {
                    @memcpy(expanded_dir_buf[0..home.len], home);
                    @memcpy(expanded_dir_buf[home.len..expanded_len], rest);
                    break :blk expanded_dir_buf[0..expanded_len];
                }
            }
            break :blk dir_part;
        }
    } else if (std.mem.eql(u8, word, "~")) blk: {
        // just "~" - expand to home
        const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch break :blk ".";
        defer self.allocator.free(home);
        if (home.len < expanded_dir_buf.len) {
            @memcpy(expanded_dir_buf[0..home.len], home);
            break :blk expanded_dir_buf[0..home.len];
        }
        break :blk ".";
    } else "."; // no slash, search in current directory

    const pattern = if (std.mem.lastIndexOf(u8, word, "/")) |last_slash|
        word[last_slash + 1 ..]
    else if (std.mem.eql(u8, word, "~"))
        "" // empty pattern to match all in home
    else
        word;

    // find matches
    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
    defer {
        for (matches.items) |match| {
            self.allocator.free(match);
        }
        matches.deinit(self.allocator);
    }

    // collect existing arguments to filter out
    var existing_args = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
    defer existing_args.deinit(self.allocator);

    var arg_start: usize = 0;
    var in_arg = false;
    for (cmd, 0..) |c, idx| {
        if (c == ' ' or c == '\t' or c == '\n') {
            if (in_arg and idx > arg_start) {
                // don't include the word we're currently completing
                if (arg_start != word_result.start) {
                    existing_args.append(self.allocator, cmd[arg_start..idx]) catch {};
                }
            }
            in_arg = false;
        } else {
            if (!in_arg) {
                arg_start = idx;
                in_arg = true;
            }
        }
    }
    // handle last argument if not whitespace terminated
    if (in_arg and arg_start != word_result.start and self.current_command_len > arg_start) {
        existing_args.append(self.allocator, cmd[arg_start..self.current_command_len]) catch {};
    }

    const dir = std.fs.cwd().openDir(search_dir, .{ .iterate = true }) catch return;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, pattern)) {
            // check if this entry is already in the command
            var already_exists = false;
            for (existing_args.items) |existing| {
                // compare just the filename part of existing arg
                const existing_name = if (std.mem.lastIndexOf(u8, existing, "/")) |slash|
                    existing[slash + 1 ..]
                else
                    existing;

                if (std.mem.eql(u8, entry.name, existing_name)) {
                    already_exists = true;
                    break;
                }
                // also check with trailing slash for directories
                if (entry.kind == .directory) {
                    const with_slash = std.fmt.allocPrint(self.allocator, "{s}/", .{entry.name}) catch continue;
                    defer self.allocator.free(with_slash);
                    if (std.mem.eql(u8, with_slash, existing_name)) {
                        already_exists = true;
                        break;
                    }
                }
            }

            if (!already_exists) {
                const full_name = if (entry.kind == .directory)
                    try std.fmt.allocPrint(self.allocator, "{s}/", .{entry.name})
                else
                    try self.allocator.dupe(u8, entry.name);
                try matches.append(self.allocator, full_name);
            }
        }
    }

    if (matches.items.len == 0) {
        // no matches, do nothing
        return;
    } else if (matches.items.len == 1) {
        // single match - complete it
        const match = matches.items[0];
        const comp_str = match[pattern.len..];

        // insert completion at cursor
        const new_len = self.current_command_len + comp_str.len;
        if (new_len >= self.current_command.len) return error.InputTooLong;

        // shift content after word_end to make room
        if (word_end < self.current_command_len) {
            @memmove(
                self.current_command[word_end + comp_str.len .. new_len],
                self.current_command[word_end..self.current_command_len],
            );
        }

        // insert completion
        @memcpy(
            self.current_command[word_end .. word_end + comp_str.len],
            comp_str,
        );

        self.current_command_len = new_len;
        self.cursor_pos = word_end + comp_str.len;
        try self.redrawLine();
    } else {
        // multiple matches - first try common prefix completion
        var common_prefix_len: usize = matches.items[0].len;
        for (matches.items[1..]) |match| {
            var i: usize = 0;
            while (i < common_prefix_len and i < match.len and matches.items[0][i] == match[i]) : (i += 1) {}
            common_prefix_len = i;
        }

        // if common prefix is longer than pattern, complete to that first
        if (common_prefix_len > pattern.len) {
            const common_prefix = matches.items[0][0..common_prefix_len];
            const comp_str = common_prefix[pattern.len..];

            // insert completion
            if (word_end + comp_str.len < types.MAX_COMMAND_LENGTH) {
                const tail_len = self.current_command_len - word_end;
                if (tail_len > 0) {
                    std.mem.copyBackwards(u8, self.current_command[word_end + comp_str.len ..], self.current_command[word_end .. word_end + tail_len]);
                }
                @memcpy(self.current_command[word_end .. word_end + comp_str.len], comp_str);
                self.current_command_len += comp_str.len;
                self.cursor_pos = word_end + comp_str.len;
                try self.redrawLine();
            }
            return;
        }

        // common prefix equals pattern - enter completion mode
        self.exitCompletionMode();

        for (matches.items) |match| {
            const owned = try self.allocator.dupe(u8, match);
            try self.completion_matches.append(self.allocator, owned);
        }

        self.completion_mode = true;
        self.completion_index = self.completion_matches.items.len; // invalid index = nothing selected
        self.completion_word_start = word_result.start;
        self.completion_word_end = word_end;
        self.completion_original_len = self.current_command_len;
        self.completion_pattern_len = pattern.len;

        // just show all matches without selecting any (zsh-style)
        try self.displayCompletions();
    }
}

const WordResult = struct {
    word: []const u8,
    start: usize,
    end: usize,
};

fn extractWordAtCursor(self: *Shell, cmd: []const u8) ?WordResult {
    if (cmd.len == 0) return null;

    // find word boundaries around cursor
    var start = self.cursor_pos;
    var end = self.cursor_pos;

    // find start of word (go backwards until space or start)
    while (start > 0 and cmd[start - 1] != ' ') {
        start -= 1;
    }

    // find end of word (go forward until space or end)
    while (end < cmd.len and cmd[end] != ' ') {
        end += 1;
    }

    // Allow empty pattern (cursor after space) - will match all files
    return WordResult{
        .word = cmd[start..end],
        .start = start,
        .end = end,
    };
}

fn exitCompletionMode(self: *Shell) void {
    if (!self.completion_mode) return;

    // free all completion matches
    for (self.completion_matches.items) |match| {
        self.allocator.free(match);
    }
    self.completion_matches.clearRetainingCapacity();

    self.completion_mode = false;
    self.completion_index = 0;
    self.completion_pattern_len = 0;
    self.completion_menu_lines = 0;
    self.completion_displayed = false;
}

fn handleCompletionCycle(self: *Shell, direction: CycleDirection) !void {
    if (self.completion_matches.items.len == 0) return;

    const old_index = self.completion_index;
    const nothing_selected = old_index >= self.completion_matches.items.len;

    // cycle index
    switch (direction) {
        .forward => {
            if (nothing_selected) {
                self.completion_index = 0; // first selection
            } else {
                self.completion_index = (self.completion_index + 1) % self.completion_matches.items.len;
            }
        },
        .backward => {
            if (nothing_selected) {
                self.completion_index = self.completion_matches.items.len - 1; // select last
            } else if (self.completion_index == 0) {
                self.completion_index = self.completion_matches.items.len - 1;
            } else {
                self.completion_index -= 1;
            }
        },
    }

    // apply the new completion
    try self.applyCompletion(self.completion_pattern_len);

    if (self.completion_displayed) {
        // menu already shown - just update highlight
        try self.updateCompletionHighlight(old_index);
    } else {
        // display menu for first time
        try self.displayCompletions();
    }
}

fn applyCompletion(self: *Shell, pattern_len: usize) !void {
    if (self.completion_matches.items.len == 0) return;

    const match = self.completion_matches.items[self.completion_index];

    // calculate how much of the match to add (skip the pattern prefix)
    const comp_str = match[pattern_len..];

    // restore command to original state first
    self.current_command_len = self.completion_original_len;

    // calculate new length
    const new_len = self.current_command_len + comp_str.len;
    if (new_len >= self.current_command.len) return error.InputTooLong;

    // shift content after word_end to make room
    if (self.completion_word_end < self.current_command_len) {
        @memmove(
            self.current_command[self.completion_word_end + comp_str.len .. new_len],
            self.current_command[self.completion_word_end..self.current_command_len],
        );
    }

    // insert completion
    @memcpy(
        self.current_command[self.completion_word_end .. self.completion_word_end + comp_str.len],
        comp_str,
    );

    self.current_command_len = new_len;
    self.cursor_pos = self.completion_word_end + comp_str.len;
}

fn displayCompletions(self: *Shell) !void {
    if (self.completion_matches.items.len == 0) return;

    const term_width = self.terminal_width;
    const term_height = self.terminal_height;

    // calculate available space: terminal height - prompt line - input line - 1 for safety
    const max_menu_height = if (term_height > 3) term_height - 3 else 1;

    // in narrow terminals, use simple single-column display to avoid wrapping issues
    if (term_width < 80) {
        try self.stdout().writeByte('\n');

        // cap the number of items displayed to available height
        const items_to_show = @min(self.completion_matches.items.len, max_menu_height);

        // if we can't show all items, show context around selected item
        const start_idx = if (self.completion_matches.items.len > items_to_show) blk: {
            // center the selected item in the visible window
            const half_window = items_to_show / 2;
            if (self.completion_index < half_window) {
                break :blk 0;
            } else if (self.completion_index + half_window >= self.completion_matches.items.len) {
                break :blk self.completion_matches.items.len - items_to_show;
            } else {
                break :blk self.completion_index - half_window;
            }
        } else 0;

        const end_idx = @min(start_idx + items_to_show, self.completion_matches.items.len);

        for (self.completion_matches.items[start_idx..end_idx], start_idx..) |match, i| {
            if (i == self.completion_index and self.completion_index < self.completion_matches.items.len) {
                try self.stdout().print("{f}{s}{f}\n", .{ tty.Style.reverse, match, tty.Style.reset });
            } else {
                try self.stdout().print("{s}\n", .{match});
            }
        }

        // show indicator if there are more items
        if (end_idx < self.completion_matches.items.len) {
            try self.stdout().print("... ({} more)\n", .{self.completion_matches.items.len - end_idx});
            self.completion_menu_lines = items_to_show + 1;
        } else if (start_idx > 0) {
            try self.stdout().print("... ({} hidden above)\n", .{start_idx});
            self.completion_menu_lines = items_to_show + 1;
        } else {
            self.completion_menu_lines = items_to_show;
        }

        try self.redrawLine();
        self.completion_displayed = true;
        return;
    }

    // for normal terminals, show matches in columns
    try self.stdout().writeByte('\n');

    // find max length but cap at reasonable width
    const max_item_width: usize = 30;
    var max_len: usize = 0;
    for (self.completion_matches.items) |match| {
        const display_len = @min(match.len, max_item_width);
        if (display_len > max_len) max_len = display_len;
    }
    const col_width = max_len + 2;
    const max_line_width: usize = 120; // limit total line width
    const effective_width = @min(term_width, max_line_width);
    const cols = @max(1, effective_width / col_width);

    const total_menu_lines = (self.completion_matches.items.len + cols - 1) / cols;
    const menu_lines = @min(total_menu_lines, max_menu_height);
    self.completion_menu_lines = menu_lines;

    // calculate how many items we can display
    const max_items = menu_lines * cols;
    const items_to_show = @min(self.completion_matches.items.len, max_items);

    for (self.completion_matches.items[0..items_to_show], 0..) |match, i| {
        // truncate if needed
        const display_name = if (match.len > max_item_width)
            match[0 .. max_item_width - 1]
        else
            match;
        const truncated = match.len > max_item_width;

        if (i == self.completion_index and self.completion_index < self.completion_matches.items.len) {
            try self.stdout().print("{f}{s}", .{ tty.Style.reverse, display_name });
            if (truncated) try self.stdout().writeByte('~');
            try self.stdout().print("{f}", .{tty.Style.reset});
        } else {
            try self.stdout().print("{s}", .{display_name});
            if (truncated) try self.stdout().writeByte('~');
        }

        const actual_len = if (truncated) max_item_width else match.len;
        const padding = col_width - actual_len;
        var j: usize = 0;
        while (j < padding) : (j += 1) {
            try self.stdout().writeByte(' ');
        }

        if ((i + 1) % cols == 0 or i == items_to_show - 1) {
            try self.stdout().writeByte('\n');
        }
    }

    // show indicator if there are more items
    if (items_to_show < self.completion_matches.items.len) {
        try self.stdout().print("... ({} more matches)\n", .{self.completion_matches.items.len - items_to_show});
        self.completion_menu_lines += 1;
    }

    try self.redrawLine();
    self.completion_displayed = true;
}

fn updateCompletionHighlight(self: *Shell, old_index: usize) !void {
    const term_width = self.terminal_width;

    // first selection - just highlight first item in existing menu
    if (old_index >= self.completion_matches.items.len) {
        const max_item_width: usize = 30;
        var max_len: usize = 0;
        for (self.completion_matches.items) |match| {
            const display_len = @min(match.len, max_item_width);
            if (display_len > max_len) max_len = display_len;
        }
        const col_width = max_len + 2;
        const max_line_width: usize = 120;
        const effective_width = @min(term_width, max_line_width);
        const cols = @max(1, effective_width / col_width);

        // new_index is 0 (first item)
        const new_row = self.completion_index / cols;
        const new_col = self.completion_index % cols;

        // move up from prompt to top of menu area
        const lines_up = self.completion_menu_lines + 1;
        try self.stdout().print("\x1b[{d}A", .{lines_up});

        // move down to first item row
        try self.stdout().print("\x1b[{d}B", .{new_row + 1});
        const new_col_pos = new_col * col_width;
        try self.stdout().print("\x1b[{d}G", .{new_col_pos + 1});
        // draw highlighted
        try self.stdout().print("{f}{s}{f}", .{ tty.Style.reverse, self.completion_matches.items[self.completion_index], tty.Style.reset });

        // move back to bottom of menu and below
        const current_row = new_row + 1;
        const rows_to_bottom = self.completion_menu_lines - current_row;
        if (rows_to_bottom > 0) {
            try self.stdout().print("\x1b[{d}B", .{rows_to_bottom});
        }
        try self.stdout().print("\x1b[{d}B", .{1});

        try self.stdout().writeAll("\r\x1b[K");
        try self.redrawLine();
        return;
    }

    // for narrow terminals, redisplay everything
    if (term_width < 80) {
        // move to beginning of current line, then move up to top of menu
        try self.stdout().writeAll("\r");
        if (self.completion_menu_lines > 0) {
            try self.stdout().print("\x1b[{d}A", .{self.completion_menu_lines});
        }
        // clear from here to end of screen
        try self.stdout().writeAll("\x1b[J");
        // redraw everything
        try self.displayCompletions();
        return;
    }

    // for normal terminals, use optimized cursor-based update
    const max_item_width: usize = 30;
    var max_len: usize = 0;
    for (self.completion_matches.items) |match| {
        const display_len = @min(match.len, max_item_width);
        if (display_len > max_len) max_len = display_len;
    }
    const col_width = max_len + 2;
    const max_line_width: usize = 120;
    const effective_width = @min(term_width, max_line_width);
    const cols = @max(1, effective_width / col_width);

    const old_row = old_index / cols;
    const old_col = old_index % cols;
    const new_row = self.completion_index / cols;
    const new_col = self.completion_index % cols;

    const lines_up = self.completion_menu_lines + 1;
    try self.stdout().print("\x1b[{d}A", .{lines_up});

    try self.stdout().print("\x1b[{d}B", .{old_row + 1});
    const old_col_pos = old_col * col_width;
    try self.stdout().print("\x1b[{d}G", .{old_col_pos + 1});
    try self.stdout().print("{s}", .{self.completion_matches.items[old_index]});

    if (new_row > old_row) {
        try self.stdout().print("\x1b[{d}B", .{new_row - old_row});
    } else if (old_row > new_row) {
        try self.stdout().print("\x1b[{d}A", .{old_row - new_row});
    }
    const new_col_pos = new_col * col_width;
    try self.stdout().print("\x1b[{d}G", .{new_col_pos + 1});
    try self.stdout().print("{f}{s}{f}", .{ tty.Style.reverse, self.completion_matches.items[self.completion_index], tty.Style.reset });

    const current_row = new_row + 1;
    const rows_to_bottom = self.completion_menu_lines - current_row;
    if (rows_to_bottom > 0) {
        try self.stdout().print("\x1b[{d}B", .{rows_to_bottom});
    }
    try self.stdout().print("\x1b[{d}B", .{1});

    try self.stdout().writeAll("\r\x1b[K");
    try self.redrawLine();
}

fn redrawLine(self: *Shell) !void {
    const prompt_len = self.calculatePromptLength();
    const term_width = if (self.terminal_width > 0) self.terminal_width else 80;
    const cmd = self.current_command[0..self.current_command_len];

    // Count total display lines (accounting for newlines, continuation markers, and wrapping)
    const continuation_marker_len: usize = 2; // "│ "
    var new_lines: usize = 1;
    var col: usize = prompt_len;
    for (cmd) |c| {
        if (c == '\n') {
            new_lines += 1;
            col = continuation_marker_len;
        } else {
            col += 1;
            if (col >= term_width) {
                new_lines += 1;
                col = 0;
            }
        }
    }

    // Use the larger of old and new line counts for clearing
    const lines_to_clear = @max(self.displayed_cmd_lines, new_lines);

    // Move to start of first line
    if (lines_to_clear > 1) {
        try self.stdout().print("\x1b[{d}F", .{lines_to_clear - 1});
    } else {
        try self.stdout().writeAll("\r");
    }

    // Clear all lines
    for (0..lines_to_clear) |i| {
        try self.stdout().writeAll("\x1b[2K");
        if (i < lines_to_clear - 1) {
            try self.stdout().writeAll("\x1b[1B");
        }
    }

    // Move back to start
    if (lines_to_clear > 1) {
        try self.stdout().print("\x1b[{d}A", .{lines_to_clear - 1});
    }
    try self.stdout().writeAll("\r");

    // Update tracked line count
    self.displayed_cmd_lines = new_lines;

    // Redraw prompt
    try self.printFancyPrompt();

    // Write current command buffer with continuation markers
    if (self.current_command_len > 0) {
        for (cmd) |c| {
            if (c == '\n') {
                try self.stdout().writeAll("\n\x1b[90m│\x1b[0m ");
            } else {
                try self.stdout().writeByte(c);
            }
        }
    }

    // Calculate cursor position (accounting for newlines, continuation markers, and wrapping)
    const continuation_len: usize = 2; // "│ "
    var cursor_line: usize = 0;
    var cursor_col: usize = prompt_len;
    for (cmd[0..self.cursor_pos]) |c| {
        if (c == '\n') {
            cursor_line += 1;
            cursor_col = continuation_len;
        } else {
            cursor_col += 1;
            if (cursor_col >= term_width) {
                cursor_line += 1;
                cursor_col = 0;
            }
        }
    }

    // Calculate end position
    var end_line: usize = 0;
    var end_col: usize = prompt_len;
    for (cmd) |c| {
        if (c == '\n') {
            end_line += 1;
            end_col = continuation_len;
        } else {
            end_col += 1;
            if (end_col >= term_width) {
                end_line += 1;
                end_col = 0;
            }
        }
    }

    // Move cursor from end position to desired position
    if (cursor_line < end_line) {
        try self.stdout().print("\x1b[{d}A", .{end_line - cursor_line});
    }

    // Move to correct column
    if (cursor_col == 0) {
        try self.stdout().writeAll("\r");
    } else {
        try self.stdout().print("\r\x1b[{d}C", .{cursor_col});
    }

    try self.stdout().flush();
}

fn calculatePromptLength(self: *Shell) usize {
    // approximate visible length of prompt (without ANSI codes)
    // format: [X] user@host path $
    const user = std.process.getEnvVarOwned(self.allocator, "USER") catch "unknown";
    defer if (!std.mem.eql(u8, user, "unknown")) self.allocator.free(user);

    var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = std.posix.gethostname(&hostname_buf) catch "localhost";

    var cwd_buf: [4096]u8 = undefined;
    const full_cwd = std.posix.getcwd(&cwd_buf) catch "/";

    const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch null;
    defer if (home) |h| self.allocator.free(h);

    const display_path = if (home) |h| blk: {
        if (std.mem.startsWith(u8, full_cwd, h)) {
            if (std.mem.eql(u8, full_cwd, h)) {
                break :blk "~";
            } else {
                var path_buf: [4096]u8 = undefined;
                const rest = full_cwd[h.len..];
                break :blk std.fmt.bufPrint(&path_buf, "~{s}", .{rest}) catch full_cwd;
            }
        } else {
            break :blk full_cwd;
        }
    } else full_cwd;

    // [X] user@host path $
    return 4 + user.len + 1 + hostname.len + 1 + display_path.len + 3;
}

fn loadAliases(self: *Shell) !void {
    // get home directory
    const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch return;
    defer self.allocator.free(home);

    // construct ~/.zishrc path
    const config_path = try std.fmt.allocPrint(self.allocator, "{s}/.zishrc", .{home});
    defer self.allocator.free(config_path);

    // try to open the file
    const file = std.fs.cwd().openFile(config_path, .{}) catch return;
    defer file.close();

    // read file contents
    const contents = try file.readToEndAlloc(self.allocator, 1024 * 1024); // max 1MB
    defer self.allocator.free(contents);

    // parse aliases and functions
    var lines = std.mem.splitSequence(u8, contents, "\n");
    var in_function = false;
    var func_name: []const u8 = "";
    var func_body = std.ArrayListUnmanaged(u8){};
    defer func_body.deinit(self.allocator);
    var brace_depth: u32 = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");

        // if we're inside a function, collect body
        if (in_function) {
            // count braces (skip inside ${...})
            var i: usize = 0;
            while (i < line.len) {
                if (i + 1 < line.len and line[i] == '$' and line[i + 1] == '{') {
                    // skip to matching }
                    i += 2;
                    var param_depth: usize = 1;
                    while (i < line.len and param_depth > 0) : (i += 1) {
                        if (line[i] == '{') param_depth += 1;
                        if (line[i] == '}') param_depth -= 1;
                    }
                    // i is now past the closing }, continue to next char
                    continue;
                }
                if (line[i] == '{') brace_depth += 1;
                if (line[i] == '}') {
                    if (brace_depth > 0) brace_depth -= 1;
                }
                i += 1;
            }

            if (brace_depth == 0) {
                // function ended, store it
                const name_copy = try self.allocator.dupe(u8, func_name);
                const body_copy = try self.allocator.dupe(u8, func_body.items);
                try self.functions.put(name_copy, body_copy);
                in_function = false;
                func_body.clearRetainingCapacity();
            } else {
                // add line to function body
                try func_body.appendSlice(self.allocator, line);
                try func_body.append(self.allocator, '\n');
            }
            continue;
        }

        // skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // look for function definitions: name() { or function name {
        if (std.mem.indexOf(u8, trimmed, "() {")) |paren_pos| {
            func_name = trimmed[0..paren_pos];
            in_function = true;
            brace_depth = 1;
            // check if body starts on same line after {
            if (std.mem.indexOf(u8, trimmed, "{")) |brace_pos| {
                const after_brace = trimmed[brace_pos + 1 ..];
                const after_trimmed = std.mem.trim(u8, after_brace, " \t");
                if (after_trimmed.len > 0 and !std.mem.eql(u8, after_trimmed, "}")) {
                    try func_body.appendSlice(self.allocator, after_trimmed);
                    try func_body.append(self.allocator, '\n');
                }
                // check for closing brace on same line
                for (after_brace) |c| {
                    if (c == '}') brace_depth -= 1;
                }
                if (brace_depth == 0) {
                    const name_copy = try self.allocator.dupe(u8, func_name);
                    const body_copy = try self.allocator.dupe(u8, func_body.items);
                    try self.functions.put(name_copy, body_copy);
                    in_function = false;
                    func_body.clearRetainingCapacity();
                }
            }
            continue;
        }

        // look for alias definitions: alias name=value
        if (std.mem.startsWith(u8, trimmed, "alias ")) {
            const alias_def = trimmed[6..]; // skip "alias "
            if (std.mem.indexOf(u8, alias_def, "=")) |eq_pos| {
                const name = std.mem.trim(u8, alias_def[0..eq_pos], " \t");
                var value = std.mem.trim(u8, alias_def[eq_pos + 1 ..], " \t");

                // remove quotes if present
                if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') {
                    value = value[1 .. value.len - 1];
                } else if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                    value = value[1 .. value.len - 1];
                }

                // store alias (make copies)
                const name_copy = try self.allocator.dupe(u8, name);
                const value_copy = try self.allocator.dupe(u8, value);
                try self.aliases.put(name_copy, value_copy);
            }
        }
    }
}

pub fn executeCommand(self: *Shell, command: []const u8) !u8 {
    // split on newlines and execute each line
    var exit_code: u8 = 0;
    var lines = std.mem.splitScalar(u8, command, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // check if command starts with an alias
        const resolved_command = self.resolveAlias(trimmed);
        defer if (!std.mem.eql(u8, resolved_command, trimmed)) self.allocator.free(resolved_command);

        exit_code = try self.executeCommandInternal(resolved_command);
        self.last_exit_code = exit_code;
    }
    return exit_code;
}

fn resolveAlias(self: *Shell, command: []const u8) []const u8 {
    // find first word (command name)
    const space_pos = std.mem.indexOf(u8, command, " ");
    const cmd_name = if (space_pos) |pos| command[0..pos] else command;

    // check if it's an alias
    if (self.aliases.get(cmd_name)) |alias_value| {
        // replace the command name with the alias value
        if (space_pos) |pos| {
            const args = command[pos..];
            const resolved = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ alias_value, args }) catch return command;
            return resolved;
        } else {
            const resolved = self.allocator.dupe(u8, alias_value) catch return command;
            return resolved;
        }
    }

    return command;
}

pub fn expandVariables(self: *Shell, input: []const u8) ![]const u8 {
    // Simple variable expansion - replace $VAR with variable value
    var result = try std.ArrayList(u8).initCapacity(self.allocator, input.len);
    defer result.deinit(self.allocator);

    var i: usize = 0;

    // Tilde expansion at start of input
    if (input.len > 0 and input[0] == '~') {
        if (input.len == 1 or input[1] == '/') {
            const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch "";
            defer if (home.len > 0) self.allocator.free(home);
            try result.appendSlice(self.allocator, home);
            i = 1; // skip the ~
        }
    }

    while (i < input.len) {
        if (input[i] == '$' and i + 1 < input.len) {
            // Found variable expansion
            i += 1; // skip $

            // Handle special single-character variables first
            if (i < input.len and input[i] == '?') {
                var exit_code_buf: [8]u8 = undefined;
                const exit_code_str = std.fmt.bufPrint(&exit_code_buf, "{d}", .{self.last_exit_code}) catch "0";
                try result.appendSlice(self.allocator, exit_code_str);
                i += 1; // consume the ?
                continue;
            }

            // Check for $((arithmetic)) first
            if (i + 1 < input.len and input[i] == '(' and input[i+1] == '(') {
                i += 2; // skip ((
                const expr_start = i;

                // Find matching ))
                var paren_count: u32 = 2;
                while (i < input.len and paren_count > 0) {
                    if (input[i] == '(') {
                        paren_count += 1;
                    } else if (input[i] == ')') {
                        paren_count -= 1;
                        if (paren_count == 0) break;
                    }
                    i += 1;
                }

                if (paren_count == 0) {
                    const expr = input[expr_start..i-1];
                    i += 1; // consume final ) (first one was consumed in loop)

                    // Evaluate arithmetic expression
                    const arith_result = try self.evaluateArithmetic(expr);
                    var buf: [32]u8 = undefined;
                    const result_str = std.fmt.bufPrint(&buf, "{d}", .{arith_result}) catch "0";
                    try result.appendSlice(self.allocator, result_str);
                    continue;
                }
            }

            // Handle command substitution $(command)
            if (i < input.len and input[i] == '(') {
                i += 1; // skip (
                const cmd_start = i;

                // Find matching closing paren
                var paren_count: u32 = 1;
                while (i < input.len and paren_count > 0) {
                    switch (input[i]) {
                        '(' => paren_count += 1,
                        ')' => paren_count -= 1,
                        else => {},
                    }
                    if (paren_count > 0) i += 1;
                }

                if (paren_count == 0) {
                    const command = input[cmd_start..i];
                    i += 1; // consume )

                    // Execute command and capture output
                    const cmd_output = self.executeCommandAndCapture(command) catch "";
                    try result.appendSlice(self.allocator, std.mem.trimRight(u8, cmd_output, "\n\r"));
                    continue;
                } else {
                    // Unmatched parens, treat as regular text
                    try result.append(self.allocator, '$');
                    try result.append(self.allocator, '(');
                    i = cmd_start;
                    continue;
                }
            }

            // Handle ${VAR} and ${VAR:-default} syntax
            if (i < input.len and input[i] == '{') {
                i += 1; // skip {
                const name_start = i;

                // Find end of variable name or modifier
                while (i < input.len and input[i] != '}' and input[i] != ':' and input[i] != '-' and input[i] != '+' and input[i] != '?') {
                    i += 1;
                }

                const var_name = input[name_start..i];

                // Check for modifier
                var modifier: u8 = 0;
                var has_colon = false;
                var default_value: []const u8 = "";

                if (i < input.len and input[i] == ':') {
                    has_colon = true;
                    i += 1;
                }

                if (i < input.len and (input[i] == '-' or input[i] == '+' or input[i] == '?')) {
                    modifier = input[i];
                    i += 1;

                    // Find the default/alternate value up to closing }
                    const val_start = i;
                    var brace_depth: u32 = 1;
                    while (i < input.len and brace_depth > 0) {
                        if (input[i] == '{') brace_depth += 1;
                        if (input[i] == '}') brace_depth -= 1;
                        if (brace_depth > 0) i += 1;
                    }
                    default_value = input[val_start..i];
                }

                // Skip closing }
                if (i < input.len and input[i] == '}') i += 1;

                // Look up variable value
                var var_value: ?[]const u8 = null;
                var owned_value: ?[]const u8 = null;
                defer if (owned_value) |v| self.allocator.free(v);

                if (self.variables.get(var_name)) |value| {
                    var_value = value;
                } else {
                    const env_value = std.process.getEnvVarOwned(self.allocator, var_name) catch null;
                    if (env_value) |val| {
                        owned_value = val;
                        var_value = val;
                    }
                }

                // Apply modifier
                const is_set = var_value != null;
                const is_empty = if (var_value) |v| v.len == 0 else true;
                const use_default = if (has_colon) !is_set or is_empty else !is_set;

                switch (modifier) {
                    '-' => {
                        // ${VAR:-default} or ${VAR-default}
                        if (use_default) {
                            // Recursively expand the default value
                            const expanded_default = try self.expandVariables(default_value);
                            defer self.allocator.free(expanded_default);
                            try result.appendSlice(self.allocator, expanded_default);
                        } else if (var_value) |v| {
                            try result.appendSlice(self.allocator, v);
                        }
                    },
                    '+' => {
                        // ${VAR:+alternate} or ${VAR+alternate}
                        if (!use_default) {
                            const expanded_alt = try self.expandVariables(default_value);
                            defer self.allocator.free(expanded_alt);
                            try result.appendSlice(self.allocator, expanded_alt);
                        }
                    },
                    '?' => {
                        // ${VAR:?error} or ${VAR?error}
                        if (use_default) {
                            try self.stdout().print("zish: {s}: {s}\n", .{ var_name, if (default_value.len > 0) default_value else "parameter not set" });
                            return error.ParameterNotSet;
                        } else if (var_value) |v| {
                            try result.appendSlice(self.allocator, v);
                        }
                    },
                    else => {
                        // No modifier, just ${VAR}
                        if (var_value) |v| {
                            try result.appendSlice(self.allocator, v);
                        }
                    },
                }
            } else {
                // Simple $VAR without braces
                const name_start = i;
                // Find end of variable name (alphanumeric + underscore)
                while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_')) {
                    i += 1;
                }

                if (i > name_start) {
                    const var_name = input[name_start..i];

                    // Look up variable
                    if (self.variables.get(var_name)) |value| {
                        try result.appendSlice(self.allocator, value);
                    } else {
                        // Try environment variable
                        const env_value = std.process.getEnvVarOwned(self.allocator, var_name) catch null;
                        if (env_value) |val| {
                            defer self.allocator.free(val);
                            try result.appendSlice(self.allocator, val);
                        }
                        // If no variable found, don't expand (leave empty)
                    }
                } else {
                    // Just a lone $, keep it
                    try result.append(self.allocator, '$');
                }
            }
        } else if (input[i] == '`') {
            // Handle backtick command substitution
            i += 1; // skip `
            const cmd_start = i;

            // Find matching closing backtick
            while (i < input.len and input[i] != '`') {
                i += 1;
            }

            if (i < input.len) {
                const command = input[cmd_start..i];
                i += 1; // consume closing `

                // Execute command and capture output
                const cmd_output = self.executeCommandAndCapture(command) catch "";
                try result.appendSlice(self.allocator, std.mem.trimRight(u8, cmd_output, "\n\r"));
            } else {
                // Unmatched backtick, treat as regular text
                try result.append(self.allocator, '`');
                i = cmd_start;
            }
        } else {
            try result.append(self.allocator, input[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(self.allocator);
}

fn evaluateArithmetic(self: *Shell, expr: []const u8) !i64 {
    var trimmed = std.mem.trim(u8, expr, " \t\n\r");
    if (trimmed.len == 0) return 0;

    // check for operators (left-to-right, lowest to highest precedence)
    for ([_]u8{'+', '-', '*', '/'}) |op| {
        if (std.mem.lastIndexOfScalar(u8, trimmed, op)) |op_pos| {
            if (op_pos > 0 and op_pos < trimmed.len - 1) {
                const left = try self.evaluateArithmetic(trimmed[0..op_pos]);
                const right = try self.evaluateArithmetic(trimmed[op_pos+1..]);
                return switch (op) {
                    '+' => left + right,
                    '-' => left - right,
                    '*' => left * right,
                    '/' => if (right != 0) @divTrunc(left, right) else 0,
                    else => 0,
                };
            }
        }
    }

    // try to parse as number
    if (std.fmt.parseInt(i64, trimmed, 10)) |num| {
        return num;
    } else |_| {
        // try as variable
        if (self.variables.get(trimmed)) |val| {
            return std.fmt.parseInt(i64, val, 10) catch 0;
        }
        // unknown variable defaults to 0
        return 0;
    }
}

fn executeCommandAndCapture(self: *Shell, command: []const u8) ![]const u8 {
    // Execute a command and capture its output
    // For now, implement simple built-in commands

    const trimmed_cmd = std.mem.trim(u8, command, " \t\n\r");

    if (std.mem.eql(u8, trimmed_cmd, "pwd")) {
        var buf: [4096]u8 = undefined;
        const cwd = std.posix.getcwd(&buf) catch return self.allocator.dupe(u8, "");
        return self.allocator.dupe(u8, cwd);
    } else if (std.mem.eql(u8, trimmed_cmd, "date")) {
        // Simple date implementation - just return a placeholder
        return self.allocator.dupe(u8, "Wed Oct 16 10:00:00 UTC 2025");
    } else if (std.mem.startsWith(u8, trimmed_cmd, "echo ")) {
        const msg = trimmed_cmd[5..];
        return self.allocator.dupe(u8, msg);
    } else {
        // For other commands, try to execute them externally and capture output
        return self.executeExternalAndCapture(trimmed_cmd) catch self.allocator.dupe(u8, "");
    }
}

fn executeExternalAndCapture(self: *Shell, command: []const u8) ![]const u8 {
    // Execute external command and capture output
    const result = try std.process.Child.run(.{
        .allocator = self.allocator,
        .argv = &[_][]const u8{ "/bin/sh", "-c", command },
        .max_output_bytes = 4096,
    });
    defer self.allocator.free(result.stderr);

    return result.stdout; // caller owns this memory
}

fn executeCommandInternal(self: *Shell, command: []const u8) !u8 {
    // Try parsing with new parser first for pipes/redirects/logical operators
    var cmd_parser = parser.Parser.init(command, self.allocator) catch {
        // Parser init failed, use legacy path
        return self.executeCommandLegacy(command);
    };
    defer cmd_parser.deinit();

    const ast_root = cmd_parser.parse() catch {
        // Parsing failed, fall back to legacy implementation
        return self.executeCommandLegacy(command);
    };

    // Successfully parsed, evaluate AST
    return eval.evaluateAst(self, ast_root);
}

fn executeCommandLegacy(self: *Shell, command: []const u8) !u8 {
    // Handle variable assignments (VAR=value) first
    if (std.mem.indexOfScalar(u8, command, '=')) |eq_pos| {
        const prefix = command[0..eq_pos];
        if (std.mem.indexOfScalar(u8, prefix, ' ') == null) {
            const name = prefix;
            const value = command[eq_pos + 1 ..];

            // Validate variable name
            for (name) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '_') {
                    break; // Not valid, treat as command
                }
            } else {
                // Valid assignment
                const name_copy = try self.allocator.dupe(u8, name);
                const value_copy = try self.allocator.dupe(u8, value);

                if (self.variables.get(name_copy)) |old_value| {
                    self.allocator.free(old_value);
                }

                try self.variables.put(name_copy, value_copy);
                return 0;
            }
        }
    }

    // Tokenize command
    var lex = try lexer.Lexer.init(command);
    var tokens = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
    defer {
        for (tokens.items) |token_str| {
            self.allocator.free(token_str);
        }
        tokens.deinit(self.allocator);
    }

    while (true) {
        const token = try lex.nextToken();
        if (token.ty == .Eof) break;
        if (token.ty == .Word or token.ty == .String) {
            const owned_token = try self.allocator.dupe(u8, token.value);
            tokens.append(self.allocator, owned_token) catch {
                self.allocator.free(owned_token);
                return 1;
            };
        }
    }

    if (tokens.items.len == 0) return 0;

    // Expand variables and globs for each token
    var args = try std.ArrayList([]const u8).initCapacity(self.allocator, tokens.items.len * 2);
    defer {
        for (args.items) |arg| {
            var is_original = false;
            for (tokens.items) |tok| {
                if (arg.ptr == tok.ptr) {
                    is_original = true;
                    break;
                }
            }
            if (!is_original) self.allocator.free(arg);
        }
        args.deinit(self.allocator);
    }

    for (tokens.items) |token_val| {
        // Expand variables first
        const var_expanded = try self.expandVariables(token_val);
        defer if (var_expanded.ptr != token_val.ptr) self.allocator.free(var_expanded);

        // Check for glob patterns
        const has_glob = for (var_expanded) |c| {
            if (c == '*' or c == '?' or c == '[') break true;
        } else false;

        if (has_glob) {
            const glob_results = glob.expandGlob(self.allocator, var_expanded) catch {
                const copy = try self.allocator.dupe(u8, var_expanded);
                try args.append(self.allocator, copy);
                continue;
            };
            defer self.allocator.free(glob_results);

            if (glob_results.len == 0) {
                const copy = try self.allocator.dupe(u8, var_expanded);
                try args.append(self.allocator, copy);
            } else {
                for (glob_results) |match| {
                    try args.append(self.allocator, match);
                }
            }
        } else {
            const copy = try self.allocator.dupe(u8, var_expanded);
            try args.append(self.allocator, copy);
        }
    }

    if (args.items.len == 0) return 0;

    const cmd_name = args.items[0];

    // Handle builtins
    if (std.mem.eql(u8, cmd_name, "exit")) {
        self.running = false;
        return 0;
    }

    if (std.mem.eql(u8, cmd_name, "echo")) {
        for (args.items[1..], 0..) |arg, i| {
            if (i > 0) try self.stdout().writeByte(' ');
            try self.stdout().writeAll(arg);
        }
        try self.stdout().writeByte('\n');
        return 0;
    }

    if (std.mem.eql(u8, cmd_name, "pwd")) {
        var buf: [4096]u8 = undefined;
        const cwd = try std.posix.getcwd(&buf);
        try self.stdout().print("{s}\n", .{cwd});
        return 0;
    }

    if (std.mem.eql(u8, cmd_name, "vimode")) {
        self.vim_mode_enabled = !self.vim_mode_enabled;
        if (self.vim_mode_enabled) {
            try self.stdout().writeAll("Vi mode enabled\n");
            self.vim_mode = .insert;
        } else {
            try self.stdout().writeAll("Vi mode disabled (Emacs-like editing)\n");
        }
        return 0;
    }

    if (std.mem.eql(u8, cmd_name, "cd")) {
        const path = if (args.items.len > 1) args.items[1] else blk: {
            const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch {
                try self.stdout().writeAll("cd: could not get HOME\n");
                return 1;
            };
            defer self.allocator.free(home);
            break :blk try self.allocator.dupe(u8, home);
        };
        defer if (args.items.len == 1) self.allocator.free(path);

        std.posix.chdir(path) catch |err| {
            try self.stdout().print("cd: {s}: {}\n", .{ path, err });
            return 1;
        };
        return 0;
    }

    if (std.mem.eql(u8, cmd_name, "history")) {
        if (self.history) |h| {
            const stats = h.getStats();
            try self.stdout().print("history: {} entries ({} unique)\n", .{ stats.total, stats.unique });

            var count: usize = 0;
            var i = h.entries.items.len;
            while (i > 0 and count < 10) {
                i -= 1;
                count += 1;
                const entry = h.entries.items[i];
                const cmd = h.getCommand(entry);
                try self.stdout().print("  {}: {s} (exit: {})\n", .{ count, cmd, entry.exit_code });
            }
        } else {
            try self.stdout().writeAll("history not available\n");
        }
        return 0;
    }

    if (std.mem.eql(u8, cmd_name, "search") and args.items.len > 1) {
        if (self.history) |h| {
            const query = args.items[1];
            const matches = try h.fuzzySearch(query, self.allocator);
            defer self.allocator.free(matches);

            try self.stdout().print("fuzzy search results for '{s}':\n", .{query});
            for (matches[0..@min(matches.len, 10)]) |match| {
                const entry = h.entries.items[match.entry_index];
                const cmd_str = h.getCommand(entry);
                try self.stdout().print("  {}: {s}\n", .{ @as(u32, @intFromFloat(match.score)), cmd_str });
            }
        } else {
            try self.stdout().writeAll("history not available\n");
        }
        return 0;
    }

    // Execute external command
    // restore terminal to normal mode so child can handle signals properly
    const is_tty = std.posix.isatty(std.posix.STDIN_FILENO);
    if (is_tty) {
        self.disableRawMode();
    }
    defer if (is_tty) {
        self.enableRawMode() catch {};
    };

    var child = std.process.Child.init(args.items, self.allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.stdin_behavior = .Inherit;

    const env_map = try std.process.getEnvMap(self.allocator);
    child.env_map = &env_map;

    // ignore SIGINT in shell while child runs (child will receive it)
    var old_sigint: std.posix.Sigaction = undefined;
    const ignore_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &ignore_action, &old_sigint);
    defer std.posix.sigaction(std.posix.SIG.INT, &old_sigint, null);

    _ = child.spawn() catch |err| {
        try self.stdout().print("zish: {s}: {}\n", .{ cmd_name, err });
        return 127;
    };

    const term = child.wait() catch |err| {
        try self.stdout().print("zish: wait failed: {}\n", .{err});
        return 1;
    };

    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn executeExternal(self: *Shell, command: []const u8) !u8 {
    // tokenize command
    var lex = try lexer.Lexer.init(command);
    var tokens = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
    defer {
        // free all allocated token strings
        for (tokens.items) |token_str| {
            self.allocator.free(token_str);
        }
        tokens.deinit(self.allocator);
    }

    while (true) {
        const token = try lex.nextToken();
        if (token.ty == .Eof) break;
        if (token.ty == .Word or token.ty == .String) {
            // allocate separate storage for each token to avoid buffer reuse issues
            const owned_token = try self.allocator.dupe(u8, token.value);
            try tokens.append(self.allocator, owned_token);
        }
    }

    if (tokens.items.len == 0) return 1;

    // prepare args for exec with glob expansion
    var args = try std.ArrayList([]const u8).initCapacity(self.allocator, tokens.items.len);
    defer {
        for (args.items) |arg| {
            // Only free if it was allocated by glob expansion (not in tokens)
            var is_original = false;
            for (tokens.items) |tok| {
                if (arg.ptr == tok.ptr) {
                    is_original = true;
                    break;
                }
            }
            if (!is_original) self.allocator.free(arg);
        }
        args.deinit(self.allocator);
    }

    for (tokens.items) |token_val| {
        // Check if this looks like a glob pattern
        const has_glob = for (token_val) |c| {
            if (c == '*' or c == '?' or c == '[') break true;
        } else false;

        if (has_glob) {
            // Expand glob pattern
            const glob_results = glob.expandGlob(self.allocator, token_val) catch {
                // If glob fails, use literal
                try args.append(self.allocator, token_val);
                continue;
            };
            defer self.allocator.free(glob_results);

            if (glob_results.len == 0) {
                // No matches, use literal pattern
                try args.append(self.allocator, token_val);
            } else {
                // Add all glob matches
                for (glob_results) |match| {
                    try args.append(self.allocator, match);
                }
            }
        } else {
            try args.append(self.allocator, token_val);
        }
    }

    // execute with PATH resolution
    // restore terminal to normal mode so child can handle signals properly
    const is_tty = std.posix.isatty(std.posix.STDIN_FILENO);
    if (is_tty) {
        self.disableRawMode();
    }
    defer if (is_tty) {
        self.enableRawMode() catch {};
    };

    var child = std.process.Child.init(args.items, self.allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.stdin_behavior = .Inherit;

    // inherit full environment from parent
    child.env_map = null; // null means inherit all from parent

    // ignore SIGINT in shell while child runs (child will receive it)
    var old_sigint: std.posix.Sigaction = undefined;
    const ignore_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &ignore_action, &old_sigint);
    defer std.posix.sigaction(std.posix.SIG.INT, &old_sigint, null);

    const term = child.spawnAndWait() catch |err| switch (err) {
        error.FileNotFound => {
            try self.stdout().print("zish: {s}: command not found\n", .{args.items[0]});
            return 127;
        },
        else => return err,
    };
    return switch (term) {
        .Exited => |code| code,
        .Signal => |sig| @as(u8, @intCast(sig + 128)),
        .Stopped => |sig| @as(u8, @intCast(sig + 128)),
        .Unknown => |code| @as(u8, @intCast(code)),
    };
}
