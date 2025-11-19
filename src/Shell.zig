const Shell = @This();

const std = @import("std");
const types = @import("types.zig");
const lexer = @import("lexer.zig");
const hist = @import("history.zig");
const tty = @import("tty.zig");

const VimMode = enum {
    insert,
    normal,
};

const WordBoundary = enum {
    word,
    WORD,
    word_end,
    WORD_end,
};

const HistoryDirection = enum {
    up,
    down,
};

const SearchDirection = enum {
    forward,
    backward,
};

const MoveCursorAction = union(enum) {
    to_line_start,
    to_line_end,

    to_word_boundary: WordBoundary,

    relative: isize,
    absolute: usize,
};

const DeleteAction = union(enum) {
    to_line_end,
    char_under_cursor,
    char_at: usize,
};

const YenkAction = union(enum) {
    line,
    selection: struct { start: usize, end: usize },
};

const PasteAction = enum {
    after_cursor,
    before_cursor,
};

const InsertAtPosition = enum {
    cursor,
    after_cursor,
    line_start,
    line_end,
};

const VimModeAction = union(enum) {
    toggle_enabled,
    toggle_mode,
    set_mode: VimMode,
};

const Action = union(enum) {
    none,
    cancel,
    exit_shell,
    execute_command,
    redraw_line,
    clear_screen,
    vim_mode: VimModeAction,
    input_char: u8,
    backspace,
    delete: DeleteAction,
    tap_complete,
    move_cursor: MoveCursorAction,
    history_nav: HistoryDirection,
    enter_search_mode: SearchDirection,
    exit_search_mode: bool, // true execute search, flase cancel
    yank: YenkAction,
    paste: PasteAction,
    insert_at_position: InsertAtPosition,
    undo,
};

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
current_command: []u8,
current_command_len: usize,
original_termios: ?std.posix.termios = null,
aliases: std.StringHashMap([]const u8),
variables: std.StringHashMap([]const u8),
last_exit_code: u8 = 0,

// vim clipboard for yank/paste operations
clipboard: []u8,
clipboard_len: usize = 0,
// search state
search_mode: bool = false,
search_buffer: []u8,
search_len: usize = 0,

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

    const writer_buffer = try allocator.alloc(u8, types.MAX_COMMAND_LENGTH + types.MAX_PROMET_LENGHT);

    shell.* = .{
        .allocator = allocator,
        .running = false,
        .history = history,
        .vim_mode = .insert,
        .vim_mode_enabled = true,
        .cursor_pos = 0,
        .history_index = -1,
        .current_command = cmd_buffer,
        .current_command_len = 0,
        .original_termios = null,
        .aliases = std.StringHashMap([]const u8).init(allocator),
        .variables = std.StringHashMap([]const u8).init(allocator),
        .clipboard = clipboard_buffer,
        .clipboard_len = 0,
        .search_mode = false,
        .search_buffer = search_buffer,
        .search_len = 0,
        .stdout_writer = .init(.stdout(), writer_buffer),
    };

    // set terminal to raw mode for proper input handling
    try shell.enableRawMode();

    // load aliases from ~/.zishrc
    shell.loadAliases() catch {}; // don't fail if no config file

    return shell;
}

pub fn deinit(self: *Shell) void {
    // restore terminal mode before cleanup
    self.disableRawMode();

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

    if (self.history) |h| h.deinit();
    self.allocator.free(self.current_command);
    self.allocator.free(self.clipboard);
    self.allocator.free(self.search_buffer);
    self.allocator.free(self.stdout().buffer);
    self.allocator.destroy(self);
}

pub fn run(self: *Shell) !void {
    self.running = true;

    try self.printFancyPrompt();
    try self.stdout().flush();

    var last_action: Action = .none;

    while (self.running) {
        try self.log(last_action);
        last_action = try self.readNextAction();
        try self.handleAction(last_action);
        try self.stdout().flush();
    }
}

inline fn stdout(self: *Shell) *std.Io.Writer {
    return &self.stdout_writer.interface;
}

fn ctrlKey(comptime char_code: u8) u8 {
    // The standard way to calculate the control code is by masking the upper bits.
    // Bitwise AND with 0x1F (which is 0b00011111) clears the 6th and 7th bits.
    return char_code & 0x1F;
}

const CTRL_C = ctrlKey('c');
const CTRL_T = ctrlKey('t');
const CTRL_L = ctrlKey('l');
const CTRL_D = ctrlKey('d');

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

    // mild colorful prompt: [mode] user@host ~/path $
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
            self.current_command_len = 0;
            self.cursor_pos = 0;
            self.history_index = -1;
            self.vim_mode = .insert; // Always return to insert mode
            try self.stdout().writeByte('\n');
            try self.printFancyPrompt();
        },

        .exit_shell => {
            self.running = false;
            try self.stdout().writeByte('\n');
        },

        .input_char => |char| {
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
                if (self.cursor_pos == self.current_command_len) {
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
                self.vim_mode = .insert;

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
                .set_mode => |mode| self.vim_mode = mode,
                .toggle_enabled => {
                    self.vim_mode_enabled = !self.vim_mode_enabled;
                },
                .toggle_mode => {
                    self.vim_mode = if (self.vim_mode == .normal) .insert else .normal;
                },
            }
            return self.redrawLine();
        },

        .tap_complete => {
            // TODO
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
                .after_cursor => self.cursor_pos,
                .before_cursor => if (self.cursor_pos > 0) self.cursor_pos - 1 else 0,
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
            try self.redrawLine();
        },

        .undo => {
            self.current_command_len = 0;
            self.cursor_pos = 0;
            try self.redrawLine();
        },
    }
}

fn handleCursorMovement(self: *Shell, move_action: MoveCursorAction) !void {
    const old_pos = self.cursor_pos;
    const max_pos = self.current_command_len;

    // Calculate new position (clamped to valid range)
    const new_pos = switch (move_action) {
        .relative => |steps| blk: {
            const new = @as(isize, @intCast(self.cursor_pos)) + steps;
            break :blk @as(usize, @intCast(@max(0, @min(new, @as(isize, @intCast(max_pos))))));
        },
        .absolute => |pos| @min(pos, max_pos),
        .to_line_start => 0,
        .to_line_end => max_pos,
        .to_word_boundary => 0,
    };

    if (new_pos == old_pos) return;

    self.cursor_pos = new_pos;

    const steps = if (new_pos > old_pos)
        new_pos - old_pos
    else
        old_pos - new_pos;

    if (new_pos > old_pos) {
        // right
        try self.stdout().print("\x1b[{d}C", .{steps});
    } else {
        // left
        try self.stdout().print("\x1b[{d}D", .{steps});
    }
}

fn readNextAction(self: *Shell) !Action {
    var temp_buf: [1]u8 = undefined;
    const count = try std.fs.File.stdin().read(temp_buf[0..]);
    const char = temp_buf[0];

    if (count == 0) return .none;

    if (self.search_mode) {
        return self.getSearchModeAction(char);
    }

    // Check if vim mode is enabled, if not treat everything as insert mode
    if (self.vim_mode_enabled) {
        return self.getCharVimModeAction(char);
    } else {
        return insertModeAction(char);
    }
}

fn getCharVimModeAction(self: *Shell, char: u8) !Action {
    return if (char == '\x1b')
        escapeSequenceAction()
    else switch (self.vim_mode) {
        .normal => normalModeAction(char),
        .insert => insertModeAction(char),
    };
}

fn insertModeAction(char: u8) Action {
    return switch (char) {
        '\n' => .execute_command,
        CTRL_C => .cancel,
        CTRL_T => .{ .vim_mode = .toggle_enabled },
        CTRL_L => .clear_screen,
        CTRL_D => .exit_shell,
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
        'w' => .{ .move_cursor = .{ .to_word_boundary = .word } },
        'b' => .{ .move_cursor = .{ .to_word_boundary = .word } },
        'e' => .{ .move_cursor = .{ .to_word_boundary = .word_end } },
        'E' => .{ .move_cursor = .{ .to_word_boundary = .WORD_end } },

        'j' => .{ .history_nav = .down },
        'k' => .{ .history_nav = .up },

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
    const flags = std.posix.fcntl(stdin.handle, std.posix.F.GETFL, 0) catch 0;
    _ = std.posix.fcntl(stdin.handle, std.posix.F.SETFL, flags | 0o4000) catch {}; // O_NONBLOCK

    const bytes_read = stdin.read(&temp_buf) catch 0;

    // Restore blocking mode
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
        'Z' => .tap_complete, // Shift+Tab (for completion list)
        'H' => .{ .move_cursor = .to_line_start }, // Home key
        'F' => .{ .move_cursor = .to_line_end }, // End key
        '1' => try handleExtendedEscapeSequence(), // Ctrl+arrows, etc.
        '3' => blk: {
            // Delete key (ESC[3~)
            if (bytes_read >= 3 and temp_buf[2] == '~') {
                break :blk .{ .delete = .char_under_cursor };
            }
            break :blk .none;
        },
        else => .none,
    };
}

fn handleExtendedEscapeSequence() !Action {
    const stdin = std.fs.File.stdin();
    var temp_buf: [3]u8 = undefined;

    const semicolon_read = stdin.read(temp_buf[0..1]) catch return .none;
    if (semicolon_read == 0 or temp_buf[0] != ';') return .none;

    const modifier_read = stdin.read(temp_buf[0..1]) catch return .none;
    if (modifier_read == 0 or temp_buf[0] != '5') return .none;

    const direction_read = stdin.read(temp_buf[0..1]) catch return .none;
    if (direction_read == 0) return .none;

    return switch (temp_buf[0]) {
        'C' => .{ .move_cursor = .{ .to_word_boundary = .word } },
        'D' => .{ .move_cursor = .{ .to_word_boundary = .word } },
        'A' => .{ .move_cursor = .to_line_start },
        'B' => .{ .move_cursor = .to_line_end },
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

fn enableRawMode(self: *Shell) !void {
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
}

fn disableRawMode(self: *Shell) void {
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
                // Push current input buffer into current_command (our "staging area")
                // This is already done when typing, so current_command_len should be up to date
                self.history_index = @intCast(h.entries.items.len);
            }

            // Move up in history
            if (self.history_index > 0) {
                self.history_index -= 1;
                try self.loadHistoryEntry(h);
            }
        },
        .down => {
            // Can't go down if not in history navigation
            if (self.history_index == -1) return;

            self.history_index += 1;

            // Reached the end - restore original command
            if (self.history_index >= @as(i32, @intCast(h.entries.items.len))) {
                self.history_index = -1;
                // current_command still has the original, just reset cursor
                self.cursor_pos = self.current_command_len;
            } else {
                // Load next history entry
                try self.loadHistoryEntry(h);
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

fn redrawLine(self: *Shell) !void {
    // Clear current line
    try self.stdout().writeAll("\r\x1b[2K");

    // Redraw prompt
    try self.printFancyPrompt();

    // Write current command buffer
    if (self.current_command_len > 0) {
        try self.stdout().writeAll(self.current_command[0..self.current_command_len]);
    }

    // Position cursor correctly
    if (self.cursor_pos < self.current_command_len) {
        const back_chars = self.current_command_len - self.cursor_pos;
        try self.stdout().print("\x1b[{d}D", .{back_chars});
    }

    try self.stdout().flush();
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

    // parse aliases line by line
    var lines = std.mem.splitSequence(u8, contents, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");

        // skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

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
    // check if command starts with an alias
    const resolved_command = self.resolveAlias(command);
    defer if (!std.mem.eql(u8, resolved_command, command)) self.allocator.free(resolved_command);

    const exit_code = try self.executeCommandInternal(resolved_command);
    self.last_exit_code = exit_code;
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

fn expandVariables(self: *Shell, input: []const u8) ![]const u8 {
    // Simple variable expansion - replace $VAR with variable value
    var result = try std.ArrayList(u8).initCapacity(self.allocator, input.len);
    defer result.deinit(self.allocator);

    var i: usize = 0;
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

    // Expand variables in command first (but not for assignments)
    var expanded_command: []const u8 = command;
    var should_free_expanded = false;

    // Don't expand variables in assignment statements
    if (std.mem.indexOfScalar(u8, command, '=')) |eq_pos| {
        const prefix = command[0..eq_pos];
        if (std.mem.indexOfScalar(u8, prefix, ' ') == null) {
            // This is an assignment, don't expand variables
        } else {
            // This has = but isn't an assignment, expand variables
            expanded_command = try self.expandVariables(command);
            should_free_expanded = true;
        }
    } else {
        // No = sign, expand variables
        expanded_command = try self.expandVariables(command);
        should_free_expanded = true;
    }

    defer if (should_free_expanded) self.allocator.free(expanded_command);

    // handle variable assignments (VAR=value)
    if (std.mem.indexOfScalar(u8, command, '=')) |eq_pos| {
        // Check if this looks like an assignment (no spaces before =)
        const prefix = command[0..eq_pos];
        if (std.mem.indexOfScalar(u8, prefix, ' ') == null) {
            // This is a variable assignment
            const name = prefix;
            const value = command[eq_pos + 1 ..];

            // Simple validation - variable name should only contain alphanumeric and underscore
            for (name) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '_') {
                    break; // Not a valid variable name, treat as command
                }
            } else {
                // Valid variable name - store in shell variables (for now)
                const name_copy = self.allocator.dupe(u8, name) catch {
                    try self.stdout().writeAll("zish: assignment failed: out of memory\n");
                    return 1;
                };
                const value_copy = self.allocator.dupe(u8, value) catch {
                    self.allocator.free(name_copy);
                    try self.stdout().writeAll("zish: assignment failed: out of memory\n");
                    return 1;
                };

                // Free existing value if it exists
                if (self.variables.get(name_copy)) |old_value| {
                    self.allocator.free(old_value);
                }

                self.variables.put(name_copy, value_copy) catch {
                    self.allocator.free(name_copy);
                    self.allocator.free(value_copy);
                    try self.stdout().writeAll("zish: assignment failed: out of memory\n");
                    return 1;
                };
                return 0;
            }
        }
    }

    // handle builtins
    if (std.mem.eql(u8, expanded_command, "exit")) {
        self.running = false;
        return 0;
    }

    if (std.mem.startsWith(u8, expanded_command, "echo ")) {
        const msg = expanded_command[5..];
        try self.stdout().print("{s}\n", .{msg});
        return 0;
    }

    if (std.mem.eql(u8, expanded_command, "pwd")) {
        var buf: [4096]u8 = undefined;
        const cwd = try std.posix.getcwd(&buf);
        try self.stdout().print("{s}\n", .{cwd});
        return 0;
    }

    if (std.mem.eql(u8, expanded_command, "vimode")) {
        self.vim_mode_enabled = !self.vim_mode_enabled;
        if (self.vim_mode_enabled) {
            try self.stdout().writeAll("Vi mode enabled\n");
            self.vim_mode = .insert; // Reset to insert mode when enabling
        } else {
            try self.stdout().writeAll("Vi mode disabled (Emacs-like editing)\n");
        }
        return 0;
    }

    if (std.mem.startsWith(u8, expanded_command, "cd ")) {
        var path = std.mem.trim(u8, expanded_command[3..], " ");

        // expand tilde to home directory
        var expanded_path_buf: [4096]u8 = undefined;
        var final_path: []const u8 = path;

        if (std.mem.startsWith(u8, path, "~")) {
            const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch {
                try self.stdout().writeAll("cd: ~: could not get HOME directory\n");
                return 1;
            };
            defer self.allocator.free(home);

            if (std.mem.eql(u8, path, "~")) {
                final_path = std.fmt.bufPrint(&expanded_path_buf, "{s}", .{home}) catch {
                    try self.stdout().writeAll("cd: path too long\n");
                    return 1;
                };
            } else if (std.mem.startsWith(u8, path, "~/")) {
                final_path = std.fmt.bufPrint(&expanded_path_buf, "{s}{s}", .{ home, path[1..] }) catch {
                    try self.stdout().writeAll("cd: path too long\n");
                    return 1;
                };
            }
        }

        std.posix.chdir(final_path) catch |err| {
            try self.stdout().print("cd: {s}: {}\n", .{ final_path, err });
            return 1;
        };
        return 0;
    }

    if (std.mem.eql(u8, command, "history")) {
        if (self.history) |h| {
            const stats = h.getStats();
            try self.stdout().print("history: {} entries ({} unique)\n", .{ stats.total, stats.unique });

            // show recent commands
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

    if (std.mem.startsWith(u8, command, "search ")) {
        if (self.history) |h| {
            const query = command[7..];
            const matches = try h.fuzzySearch(query, self.allocator);
            defer self.allocator.free(matches);

            try self.stdout().print("fuzzy search results for '{s}':\n", .{query});
            for (matches[0..@min(matches.len, 10)]) |match| {
                const entry = h.entries.items[match.entry_index];
                const cmd = h.getCommand(entry);
                try self.stdout().print("  {}: {s}\n", .{ @as(u32, @intFromFloat(match.score)), cmd });
            }
        } else {
            try self.stdout().writeAll("history not available\n");
        }
        return 0;
    }

    // try to execute external command
    return try self.executeExternal(expanded_command);
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
        if (token.ty == .Word) {
            // allocate separate storage for each token to avoid buffer reuse issues
            const owned_token = try self.allocator.dupe(u8, token.value);
            try tokens.append(self.allocator, owned_token);
        }
    }

    if (tokens.items.len == 0) return 1;

    // prepare args for exec
    var args = try std.ArrayList([]const u8).initCapacity(self.allocator, tokens.items.len);
    defer args.deinit(self.allocator);

    for (tokens.items) |token_val| {
        try args.append(self.allocator, token_val);
    }

    // execute with PATH resolution
    var child = std.process.Child.init(args.items, self.allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.stdin_behavior = .Inherit;

    // inherit full environment from parent
    child.env_map = null; // null means inherit all from parent

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
