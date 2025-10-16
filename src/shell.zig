// shell.zig - zish interactive shell

const std = @import("std");
const types = @import("types.zig");
const lexer = @import("lexer.zig");
const history = @import("simple_history.zig");

const VimMode = enum {
    insert,
    normal,
};

const EscapeAction = enum {
    continue_loop,
    set_position,
    switch_to_normal,
};

const EscapeResult = struct {
    action: EscapeAction,
    new_pos: usize = 0,
};

// ansi color codes for zsh-like colorful prompt
const Colors = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";

    // vim mode indicators
    const insert_mode = "\x1b[33m";     // yellow
    const normal_mode = "\x1b[31m";     // red

    // prompt elements
    const userhost = "\x1b[32m";        // green for user@host
    const path = "\x1b[36m";            // turquoise/cyan for all paths
    const default_color = "\x1b[39m";   // default terminal color
};

pub const Shell = struct {
    allocator: std.mem.Allocator,
    running: bool,
    hist: ?*history.History, // make optional for now
    vim_mode: VimMode,
    cursor_pos: usize,
    history_index: i32,
    current_command: []u8,
    current_command_len: usize,
    original_termios: ?std.posix.termios = null,
    aliases: std.StringHashMap([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const shell = try allocator.create(Self);

        // try to initialize history, but don't fail if it doesn't work
        const hist = history.History.init(allocator, null) catch null;

        // allocate buffer for current command editing
        const cmd_buffer = try allocator.alloc(u8, types.MAX_COMMAND_LENGTH);

        shell.* = .{
            .allocator = allocator,
            .running = false,
            .hist = hist,
            .vim_mode = .insert,
            .cursor_pos = 0,
            .history_index = -1,
            .current_command = cmd_buffer,
            .current_command_len = 0,
            .original_termios = null,
            .aliases = std.StringHashMap([]const u8).init(allocator),
        };

        // set terminal to raw mode for proper input handling
        try shell.enableRawMode();

        // load aliases from ~/.zishrc
        shell.loadAliases() catch {}; // don't fail if no config file

        return shell;
    }

    fn printFancyPrompt(self: *Self) !void {
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
        const mode_color = switch (self.vim_mode) {
            .insert => Colors.insert_mode,
            .normal => Colors.normal_mode,
        };
        const mode_indicator = switch (self.vim_mode) {
            .insert => "I",
            .normal => "N",
        };

        // mild colorful prompt: [mode] user@host ~/path $
        std.debug.print("{s}[{s}{s}{s}]{s} {s}{s}@{s}{s} {s}{s}{s} {s}${s} ", .{
            Colors.bold,
            mode_color, mode_indicator, Colors.reset,
            Colors.reset,
            Colors.userhost, user, hostname, Colors.reset,
            Colors.path, display_path, Colors.reset,
            Colors.default_color, Colors.reset,
        });
    }

    fn readInputWithVim(self: *Self, buf: *[types.MAX_COMMAND_LENGTH]u8) !?[]const u8 {
        const stdin = std.fs.File{ .handle = 0 };
        var pos: usize = 0;
        self.cursor_pos = 0;

        while (pos < buf.len - 1) {
            const bytes_read = stdin.read(buf[pos..pos + 1]) catch |err| {
                std.debug.print("input error: {}\n", .{err});
                self.running = false;
                return null;
            };

            if (bytes_read == 0) {
                self.running = false;
                return null;
            }

            const char = buf[pos];

            // handle escape sequences
            if (char == 27) {
                const escape_result = try self.handleEscapeSequence(&stdin, buf, pos);
                switch (escape_result.action) {
                    .continue_loop => continue,
                    .set_position => {
                        pos = escape_result.new_pos;
                        continue;
                    },
                    .switch_to_normal => {
                        self.vim_mode = .normal;
                        std.debug.print("\r", .{});
                        try self.printFancyPrompt();
                        if (pos > 0) {
                            std.debug.print("{s}", .{buf[0..pos]});
                        }
                        continue;
                    },
                }
            }

            switch (self.vim_mode) {
                .insert => {
                    if (char == '\n') {
                        // move to next line when user presses enter
                        std.debug.print("\n", .{});
                        buf[pos] = 0; // null terminate
                        const input = std.mem.trim(u8, buf[0..pos], " \t\n\r");
                        return input;
                    } else if (char == 3) { // ctrl+c in insert mode - switch to normal mode
                        self.vim_mode = .normal;
                        std.debug.print("\r", .{});
                        try self.printFancyPrompt();
                        if (pos > 0) {
                            std.debug.print("{s}", .{buf[0..pos]});
                        }
                        continue;
                    } else if (char == '\t') {
                        // handle tab completion
                        const completion_result = try self.handleTabCompletion(buf, pos);
                        if (completion_result) |new_text| {
                            defer self.allocator.free(new_text);
                            // clear current line and show completion
                            std.debug.print("\r", .{});
                            try self.printFancyPrompt();
                            std.debug.print("{s}", .{new_text});
                            // update buffer with completion
                            const copy_len = @min(new_text.len, buf.len - 1);
                            @memcpy(buf[0..copy_len], new_text[0..copy_len]);
                            pos = copy_len;
                        }
                    } else if (char == 8 or char == 127) { // backspace
                        if (pos > 0) {
                            pos -= 1;
                            // move cursor back, print space to erase character, move cursor back again
                            std.debug.print("\x08 \x08", .{});
                        }
                    } else if (char >= 32 and char <= 126) {
                        // echo printable characters (since we disabled terminal echo)
                        std.debug.print("{c}", .{char});
                        pos += 1;
                    } else {
                        // ignore control characters
                        continue;
                    }
                },
                .normal => {
                    switch (char) {
                        'i' => {
                            self.vim_mode = .insert;
                            // show mode change
                            std.debug.print("\r", .{});
                            try self.printFancyPrompt();
                            // re-display current input
                            if (pos > 0) {
                                std.debug.print("{s}", .{buf[0..pos]});
                            }
                        },
                        3 => { // ctrl+c in normal mode - just clear line, never exit
                            std.debug.print("\n", .{});
                            pos = 0;
                            self.history_index = -1; // reset history navigation
                            try self.printFancyPrompt();
                        },
                        '\n' => {
                            buf[pos] = 0; // null terminate
                            const input = std.mem.trim(u8, buf[0..pos], " \t\n\r");
                            // return to insert mode for next command
                            self.vim_mode = .insert;
                            return input;
                        },
                        // ignore other characters in normal mode
                        else => {},
                    }
                },
            }
        }

        return error.InputTooLong;
    }

    pub fn handleTabCompletion(self: *Self, buf: *[types.MAX_COMMAND_LENGTH]u8, pos: usize) !?[]const u8 {
        if (pos == 0) return null;

        const current_input = buf[0..pos];

        // simple completion logic
        if (std.mem.indexOf(u8, current_input, " ")) |_| {
            // if there's a space, complete file/directory names
            return try self.completeFilePath(current_input);
        } else {
            // if no space, complete command names
            return try self.completeCommand(current_input);
        }
    }

    fn completeCommand(self: *Self, input: []const u8) !?[]const u8 {
        const builtin_commands = [_][]const u8{
            "pwd", "echo", "cd", "exit", "history", "search"
        };

        // check if input matches any builtin command prefix
        for (builtin_commands) |cmd| {
            if (std.mem.startsWith(u8, cmd, input)) {
                // return completed command
                return try self.allocator.dupe(u8, cmd);
            }
        }

        // TODO: could also complete external commands from PATH
        return null;
    }

    fn completeFilePath(self: *Self, input: []const u8) !?[]const u8 {
        // find the last space to get the file argument
        if (std.mem.lastIndexOf(u8, input, " ")) |last_space| {
            const file_part = input[last_space + 1..];
            const command_part = input[0..last_space + 1];

            // determine if we should only complete directories
            const only_dirs = std.mem.startsWith(u8, input, "cd ");

            // simple file completion - look for files in current directory that match prefix
            var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch return null;
            defer dir.close();

            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (std.mem.startsWith(u8, entry.name, file_part)) {
                    // if only_dirs is true, skip files
                    if (only_dirs and entry.kind != .directory) continue;

                    // found a match, complete it
                    const completed = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}{s}",
                        .{ command_part, entry.name }
                    );
                    return completed;
                }
            }
        }

        return null;
    }

    fn handleShiftTab(self: *Self, buf: *[types.MAX_COMMAND_LENGTH]u8, pos: usize) !void {
        if (pos == 0) return;

        const current_input = buf[0..pos];
        std.debug.print("\n{s}--- available completions ---{s}\n", .{ Colors.bold, Colors.reset });

        if (std.mem.indexOf(u8, current_input, " ")) |_| {
            // show file completions
            try self.showFileCompletions(current_input);
        } else {
            // show command completions
            try self.showCommandCompletions(current_input);
        }

        std.debug.print("{s}-------------------------------{s}\n", .{ Colors.bold, Colors.reset });
        try self.printFancyPrompt();
        std.debug.print("{s}", .{current_input});
    }

    fn showCommandCompletions(self: *Self, input: []const u8) !void {
        _ = self;
        const builtin_commands = [_][]const u8{
            "pwd", "echo", "cd", "exit", "history", "search"
        };

        for (builtin_commands) |cmd| {
            if (std.mem.startsWith(u8, cmd, input)) {
                std.debug.print("  {s}{s}{s}\n", .{ Colors.userhost, cmd, Colors.reset });
            }
        }
    }

    fn showFileCompletions(self: *Self, input: []const u8) !void {
        _ = self;
        if (std.mem.lastIndexOf(u8, input, " ")) |last_space| {
            const file_part = input[last_space + 1..];

            // determine if we should only show directories
            const only_dirs = std.mem.startsWith(u8, input, "cd ");

            var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch return;
            defer dir.close();

            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (std.mem.startsWith(u8, entry.name, file_part)) {
                    // if only_dirs is true, skip files
                    if (only_dirs and entry.kind != .directory) continue;

                    const file_color = switch (entry.kind) {
                        .directory => Colors.path,  // turquoise for directories
                        .file => Colors.default_color,  // default color for files
                        else => Colors.default_color,
                    };
                    const suffix = if (entry.kind == .directory) "/" else "";
                    std.debug.print("  {s}{s}{s}{s}\n", .{ file_color, entry.name, suffix, Colors.reset });
                }
            }
        }
    }

    fn handleUpArrow(self: *Self, buf: *[types.MAX_COMMAND_LENGTH]u8, current_pos: usize) !usize {
        if (self.hist) |h| {
            if (h.entries.items.len == 0) return current_pos;

            // save current command if we're starting history navigation
            if (self.history_index == -1) {
                @memcpy(self.current_command[0..current_pos], buf[0..current_pos]);
                self.current_command_len = current_pos;
                self.history_index = @intCast(h.entries.items.len);
            }

            // move up in history
            if (self.history_index > 0) {
                self.history_index -= 1;
                const history_cmd = h.entries.items[@intCast(self.history_index)].command;

                // clear current line and show history command
                std.debug.print("\r", .{});
                try self.printFancyPrompt();
                std.debug.print("{s}", .{history_cmd});

                // update buffer
                const copy_len = @min(history_cmd.len, buf.len - 1);
                @memcpy(buf[0..copy_len], history_cmd[0..copy_len]);
                return copy_len;
            }
        }
        return current_pos;
    }

    fn handleDownArrow(self: *Self, buf: *[types.MAX_COMMAND_LENGTH]u8, current_pos: usize) !usize {
        if (self.hist) |h| {
            if (self.history_index == -1) return current_pos; // not in history mode

            // move down in history
            self.history_index += 1;

            if (self.history_index >= @as(i32, @intCast(h.entries.items.len))) {
                // restore original command
                self.history_index = -1;
                const original_len = self.current_command_len;

                // clear current line and show original command
                std.debug.print("\r", .{});
                try self.printFancyPrompt();
                std.debug.print("{s}", .{self.current_command[0..original_len]});

                // update buffer
                const copy_len = @min(original_len, buf.len - 1);
                @memcpy(buf[0..copy_len], self.current_command[0..copy_len]);
                return copy_len;
            } else {
                // show history command
                const history_cmd = h.entries.items[@intCast(self.history_index)].command;

                // clear current line and show history command
                std.debug.print("\r", .{});
                try self.printFancyPrompt();
                std.debug.print("{s}", .{history_cmd});

                // update buffer
                const copy_len = @min(history_cmd.len, buf.len - 1);
                @memcpy(buf[0..copy_len], history_cmd[0..copy_len]);
                return copy_len;
            }
        }
        return current_pos;
    }

    fn jumpWordForward(self: *Self, buf: *[types.MAX_COMMAND_LENGTH]u8, current_pos: usize) usize {
        var pos = current_pos;
        const input_len = self.findInputEnd(buf);

        // skip current word
        while (pos < input_len and !isWhitespace(buf[pos])) {
            pos += 1;
        }
        // skip whitespace
        while (pos < input_len and isWhitespace(buf[pos])) {
            pos += 1;
        }

        return pos;
    }

    fn jumpWordBackward(self: *Self, buf: *[types.MAX_COMMAND_LENGTH]u8, current_pos: usize) usize {
        _ = self;
        if (current_pos == 0) return 0;

        var pos = current_pos - 1;

        // skip whitespace
        while (pos > 0 and isWhitespace(buf[pos])) {
            pos -= 1;
        }
        // skip to beginning of word
        while (pos > 0 and !isWhitespace(buf[pos - 1])) {
            pos -= 1;
        }

        return pos;
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t';
    }

    fn redrawLine(self: *Self, buf: *[types.MAX_COMMAND_LENGTH]u8, cursor_pos: usize) !void {
        const input_len = self.findInputEnd(buf);

        // clear current line and redraw prompt + input
        std.debug.print("\r", .{});
        try self.printFancyPrompt();

        if (input_len > 0) {
            std.debug.print("{s}", .{buf[0..input_len]});
        }

        // position cursor at the right place
        if (cursor_pos < input_len) {
            const back_chars = input_len - cursor_pos;
            for (0..back_chars) |_| {
                std.debug.print("\x1b[D", .{}); // move cursor left
            }
        }
    }

    fn handleEscapeSequence(self: *Self, stdin: *const std.fs.File, buf: *[types.MAX_COMMAND_LENGTH]u8, pos: usize) !EscapeResult {
        // read '['
        var temp_buf: [1]u8 = undefined;
        const second_byte = stdin.read(&temp_buf) catch return EscapeResult{ .action = .switch_to_normal };
        if (second_byte == 0 or temp_buf[0] != '[') {
            return EscapeResult{ .action = .switch_to_normal };
        }

        // read the command byte
        const third_byte = stdin.read(&temp_buf) catch return EscapeResult{ .action = .continue_loop };
        if (third_byte == 0) return EscapeResult{ .action = .continue_loop };

        return switch (temp_buf[0]) {
            'Z' => blk: {
                if (self.vim_mode == .insert) {
                    try self.handleShiftTab(buf, pos);
                }
                break :blk EscapeResult{ .action = .continue_loop };
            },
            'A' => blk: {
                if (self.vim_mode == .insert) {
                    const new_pos = try self.handleUpArrow(buf, pos);
                    break :blk EscapeResult{ .action = .set_position, .new_pos = new_pos };
                }
                break :blk EscapeResult{ .action = .continue_loop };
            },
            'B' => blk: {
                if (self.vim_mode == .insert) {
                    const new_pos = try self.handleDownArrow(buf, pos);
                    break :blk EscapeResult{ .action = .set_position, .new_pos = new_pos };
                }
                break :blk EscapeResult{ .action = .continue_loop };
            },
            'C', 'D' => EscapeResult{ .action = .continue_loop }, // ignore basic arrows for now
            '1' => try self.handleCtrlArrows(stdin, buf, pos),
            else => EscapeResult{ .action = .continue_loop },
        };
    }

    fn handleCtrlArrows(self: *Self, stdin: *const std.fs.File, buf: *[types.MAX_COMMAND_LENGTH]u8, pos: usize) !EscapeResult {
        var temp_buf: [1]u8 = undefined;

        // expect ';'
        const semicolon = stdin.read(&temp_buf) catch return EscapeResult{ .action = .continue_loop };
        if (semicolon == 0 or temp_buf[0] != ';') return EscapeResult{ .action = .continue_loop };

        // expect '5'
        const five = stdin.read(&temp_buf) catch return EscapeResult{ .action = .continue_loop };
        if (five == 0 or temp_buf[0] != '5') return EscapeResult{ .action = .continue_loop };

        // read direction
        const direction = stdin.read(&temp_buf) catch return EscapeResult{ .action = .continue_loop };
        if (direction == 0) return EscapeResult{ .action = .continue_loop };

        if (self.vim_mode != .insert) return EscapeResult{ .action = .continue_loop };

        return switch (temp_buf[0]) {
            'C' => blk: { // ctrl+right
                const new_pos = self.jumpWordForward(buf, pos);
                try self.redrawLine(buf, new_pos);
                break :blk EscapeResult{ .action = .set_position, .new_pos = new_pos };
            },
            'D' => blk: { // ctrl+left
                const new_pos = self.jumpWordBackward(buf, pos);
                try self.redrawLine(buf, new_pos);
                break :blk EscapeResult{ .action = .set_position, .new_pos = new_pos };
            },
            'A' => blk: { // ctrl+up - beginning of line
                try self.redrawLine(buf, 0);
                break :blk EscapeResult{ .action = .set_position, .new_pos = 0 };
            },
            'B' => blk: { // ctrl+down - end of line
                const new_pos = self.findInputEnd(buf);
                try self.redrawLine(buf, new_pos);
                break :blk EscapeResult{ .action = .set_position, .new_pos = new_pos };
            },
            else => EscapeResult{ .action = .continue_loop },
        };
    }

    fn findInputEnd(self: *Self, buf: *[types.MAX_COMMAND_LENGTH]u8) usize {
        _ = self;
        var end_pos: usize = 0;
        while (end_pos < buf.len and buf[end_pos] != 0) {
            end_pos += 1;
        }
        return end_pos;
    }

    pub fn deinit(self: *Self) void {
        // restore terminal mode before cleanup
        self.disableRawMode();

        // cleanup aliases
        var it = self.aliases.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.aliases.deinit();

        if (self.hist) |h| h.deinit();
        self.allocator.free(self.current_command);
        self.allocator.destroy(self);
    }

    fn enableRawMode(self: *Self) !void {
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

    fn disableRawMode(self: *Self) void {
        if (self.original_termios) |original| {
            const stdin_fd = std.posix.STDIN_FILENO;
            std.posix.tcsetattr(stdin_fd, .NOW, original) catch {};
        }
    }

    fn loadAliases(self: *Self) !void {
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
                    var value = std.mem.trim(u8, alias_def[eq_pos + 1..], " \t");

                    // remove quotes if present
                    if (value.len >= 2 and value[0] == '\'' and value[value.len-1] == '\'') {
                        value = value[1..value.len-1];
                    } else if (value.len >= 2 and value[0] == '"' and value[value.len-1] == '"') {
                        value = value[1..value.len-1];
                    }

                    // store alias (make copies)
                    const name_copy = try self.allocator.dupe(u8, name);
                    const value_copy = try self.allocator.dupe(u8, value);
                    try self.aliases.put(name_copy, value_copy);
                }
            }
        }
    }

    pub fn run(self: *Self) !void {
        self.running = true;

        // don't print version on startup

        var buf: [types.MAX_COMMAND_LENGTH]u8 = undefined;

        while (self.running) {
            // fancy prompt with user@hostname and current directory
            try self.printFancyPrompt();

            // enhanced input handling with vim mode support
            const input_result = try self.readInputWithVim(&buf);
            if (input_result) |input| {
                if (input.len > 0) {
                    const exit_code = try self.executeCommand(input);
                    // add to history if available
                    if (self.hist) |h| {
                        h.addCommand(input, exit_code) catch {};
                    }
                    // reset history navigation
                    self.history_index = -1;
                } else {
                    // empty command - just print newline to move cursor
                    std.debug.print("\n", .{});
                }
            }
        }
    }

    pub fn executeCommand(self: *Self, command: []const u8) !u8 {
        // check if command starts with an alias
        const resolved_command = self.resolveAlias(command);
        defer if (!std.mem.eql(u8, resolved_command, command)) self.allocator.free(resolved_command);


        return try self.executeCommandInternal(resolved_command);
    }

    fn resolveAlias(self: *Self, command: []const u8) []const u8 {
        // find first word (command name)
        const space_pos = std.mem.indexOf(u8, command, " ");
        const cmd_name = if (space_pos) |pos| command[0..pos] else command;

        // check if it's an alias
        if (self.aliases.get(cmd_name)) |alias_value| {
            // replace the command name with the alias value
            if (space_pos) |pos| {
                const args = command[pos..];
                const resolved = std.fmt.allocPrint(self.allocator, "{s}{s}", .{alias_value, args}) catch return command;
                return resolved;
            } else {
                const resolved = self.allocator.dupe(u8, alias_value) catch return command;
                return resolved;
            }
        }

        return command;
    }

    fn executeCommandInternal(self: *Self, command: []const u8) !u8 {
        // handle builtins
        if (std.mem.eql(u8, command, "exit")) {
            self.running = false;
            return 0;
        }

        if (std.mem.startsWith(u8, command, "echo ")) {
            const msg = command[5..];
            std.debug.print("{s}\n", .{msg});
            return 0;
        }

        if (std.mem.eql(u8, command, "pwd")) {
            var buf: [4096]u8 = undefined;
            const cwd = try std.posix.getcwd(&buf);
            std.debug.print("{s}\n", .{cwd});
            return 0;
        }

        if (std.mem.startsWith(u8, command, "cd ")) {
            var path = std.mem.trim(u8, command[3..], " ");

            // expand tilde to home directory
            var expanded_path_buf: [4096]u8 = undefined;
            var final_path: []const u8 = path;

            if (std.mem.startsWith(u8, path, "~")) {
                const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch {
                    std.debug.print("cd: ~: could not get HOME directory\n", .{});
                    return 1;
                };
                defer self.allocator.free(home);

                if (std.mem.eql(u8, path, "~")) {
                    final_path = std.fmt.bufPrint(&expanded_path_buf, "{s}", .{home}) catch {
                        std.debug.print("cd: path too long\n", .{});
                        return 1;
                    };
                } else if (std.mem.startsWith(u8, path, "~/")) {
                    final_path = std.fmt.bufPrint(&expanded_path_buf, "{s}{s}", .{ home, path[1..] }) catch {
                        std.debug.print("cd: path too long\n", .{});
                        return 1;
                    };
                }
            }

            std.posix.chdir(final_path) catch |err| {
                std.debug.print("cd: {s}: {}\n", .{final_path, err});
                return 1;
            };
            return 0;
        }

        if (std.mem.eql(u8, command, "history")) {
            if (self.hist) |h| {
                const stats = h.getStats();
                std.debug.print("history: {} entries ({} unique)\n", .{stats.total, stats.unique});

                // show recent commands
                var count: usize = 0;
                var i = h.entries.items.len;
                while (i > 0 and count < 10) {
                    i -= 1;
                    count += 1;
                    const entry = h.entries.items[i];
                    std.debug.print("  {}: {s} (exit: {})\n", .{count, entry.command, entry.exit_code});
                }
            } else {
                std.debug.print("history not available\n", .{});
            }
            return 0;
        }

        if (std.mem.startsWith(u8, command, "search ")) {
            if (self.hist) |h| {
                const query = command[7..];
                const matches = try h.fuzzySearch(query, self.allocator);
                defer self.allocator.free(matches);

                std.debug.print("fuzzy search results for '{s}':\n", .{query});
                for (matches[0..@min(matches.len, 10)]) |match| {
                    std.debug.print("  {}: {s}\n", .{@as(u32, @intFromFloat(match.score)), match.entry.command});
                }
            } else {
                std.debug.print("history not available\n", .{});
            }
            return 0;
        }

        // try to execute external command
        return try self.executeExternal(command);
    }

    fn executeExternal(self: *Self, command: []const u8) !u8 {
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
                std.debug.print("zish: {s}: command not found\n", .{args.items[0]});
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
};