// shell.zig - zish interactive shell

const std = @import("std");
const types = @import("types.zig");
const lexer = @import("lexer.zig");
const history = @import("history.zig");
const tty = @import("tty.zig");

const VimMode = enum {
    insert,
    normal,
};

const EscapeAction = enum {
    continue_loop,
    set_position,
    toggle_vim_mode,
};

const EscapeResult = union(EscapeAction) {
    continue_loop,
    set_position: usize,
    toggle_vim_mode,
};

// ansi color codes for zsh-like colorful prompt
const Colors = struct {
    const default_color = tty.Color.reset;
    const path = tty.Color.cyan;
    const userhost = tty.Color.green;
    const normal_mode = tty.Color.red;
    const insert_mode = tty.Color.yellow;
};

// Control character constants for better readability
const CTRL_C = 3;
const CTRL_T = 20;
const CTRL_L = 12;
const ESC = 27;
const BACKSPACE = 8;
const DELETE = 127;

pub const Shell = struct {
    allocator: std.mem.Allocator,
    running: bool,
    hist: ?*history.History, // make optional for now
    vim_mode: VimMode,
    vim_mode_enabled: bool = true, // toggleable vim mode
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

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const shell = try allocator.create(Self);

        // try to initialize history, but don't fail if it doesn't work
        const hist = history.History.init(allocator, null) catch null;

        // allocate buffer for current command editing
        const cmd_buffer = try allocator.alloc(u8, types.MAX_COMMAND_LENGTH);
        const clipboard_buffer = try allocator.alloc(u8, types.MAX_COMMAND_LENGTH);
        const search_buffer = try allocator.alloc(u8, 256); // search queries are usually short

        const writer_buffer = try allocator.alloc(u8, types.MAX_COMMAND_LENGTH + types.MAX_PROMET_LENGHT);

        shell.* = .{
            .allocator = allocator,
            .running = false,
            .hist = hist,
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

    inline fn stdout(self: *Self) *std.Io.Writer {
        return &self.stdout_writer.interface;
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

    fn readInputWithVim(self: *Self, buf: *[types.MAX_COMMAND_LENGTH]u8) !?[]const u8 {
        const stdin = std.fs.File.stdin();
        var pos: usize = 0;
        self.cursor_pos = 0;

        while (pos < buf.len - 1) {
            const bytes_read = stdin.read(buf[pos .. pos + 1]) catch |err| {
                try self.stdout().print("input error: {}\n", .{err});
                self.running = false;
                return null;
            };

            defer self.stdout().flush() catch unreachable;

            if (bytes_read == 0) {
                self.running = false;
                return null;
            }

            const char = buf[pos];

            // handle escape sequences
            if (char == ESC) {
                const escape_result = try self.handleEscapeSequence(&stdin, buf, pos);
                switch (escape_result) {
                    .continue_loop => continue,
                    .set_position => |p| {
                        pos = p;
                        continue;
                    },
                    .toggle_vim_mode => {
                        self.vim_mode = if (self.vim_mode == .normal) .insert else .normal;
                        try self.stdout().writeByte('\r');
                        try self.printFancyPrompt();
                        if (pos > 0) {
                            try self.stdout().writeAll(buf[0..pos]);
                        }
                        continue;
                    },
                }
            }

            // handle search mode
            if (self.search_mode) {
                switch (char) {
                    '\n' => {
                        // execute search
                        self.search_mode = false;
                        try self.stdout().writeByte('\r');
                        try self.printFancyPrompt();
                        // perform history search with search_buffer
                        if (self.search_len > 0 and self.hist != null) {
                            const search_term = self.search_buffer[0..self.search_len];
                            const match_list = self.hist.?.fuzzySearch(search_term, self.allocator) catch continue;
                            defer self.allocator.free(match_list);
                            if (match_list.len > 0) {
                                const entry_idx = match_list[0].entry_index;
                                const entry = self.hist.?.entries.items[entry_idx];
                                const cmd = self.hist.?.getCommand(entry);
                                const copy_len = @min(cmd.len, buf.len - 1);
                                @memcpy(buf[0..copy_len], cmd[0..copy_len]);
                                pos = copy_len;
                                try self.stdout().writeAll(buf[0..pos]);
                                self.cursor_pos = pos;
                            }
                        }
                        continue;
                    },
                    ESC => {
                        // escape - cancel search
                        self.search_mode = false;
                        self.search_len = 0;
                        try self.stdout().writeByte('\r');
                        try self.printFancyPrompt();
                        if (pos > 0) {
                            try self.stdout().writeAll(buf[0..pos]);
                        }
                        continue;
                    },
                    8, 127 => {
                        // backspace in search
                        if (self.search_len > 0) {
                            self.search_len -= 1;
                            try self.stdout().writeAll("\x08 \x08");
                        }
                    },
                    32...126 => {
                        // add character to search buffer
                        if (self.search_len < self.search_buffer.len - 1) {
                            self.search_buffer[self.search_len] = char;
                            self.search_len += 1;
                            try self.stdout().writeByte(char);
                        }
                    },
                    else => {
                        continue;
                    },
                }
            }

            // Check if vim mode is enabled, if not treat everything as insert mode
            const effective_vim_mode = if (self.vim_mode_enabled) self.vim_mode else .insert;

            switch (effective_vim_mode) {
                .insert => {
                    switch (char) {
                        '\n' => {
                            // move to next line when user presses enter
                            try self.stdout().writeByte('\n');
                            buf[pos] = 0; // null terminate
                            const input = std.mem.trim(u8, buf[0..pos], " \t\n\r");
                            return input;
                        },
                        CTRL_C => {
                            // ctrl+c - clear line and start fresh
                            try self.stdout().writeByte('\n');
                            pos = 0;
                            self.cursor_pos = 0;
                            self.history_index = -1; // reset history navigation
                            // Always start in insert mode for new line
                            self.vim_mode = .insert;
                            try self.printFancyPrompt();
                            continue;
                        },
                        CTRL_T => {
                            // Ctrl+T - toggle vim/emacs mode
                            self.vim_mode_enabled = !self.vim_mode_enabled;
                            if (self.vim_mode_enabled) {
                                self.vim_mode = .insert; // Reset to insert when enabling vim mode
                            }
                            // show mode change
                            try self.stdout().writeByte('\r');
                            try self.printFancyPrompt();
                            // re-display current input
                            if (pos > 0) {
                                try self.stdout().writeAll(buf[0..pos]);
                            }
                            continue;
                        },
                        CTRL_L => {
                            try self.stdout().writeAll("\x1b[2J\x1b[H");
                            try self.printFancyPrompt();
                            if (pos > 0) {
                                try self.stdout().writeAll(buf[0..pos]);
                            }
                            continue;
                        },
                        '\t' => {
                            // handle tab completion
                            const new_text = try self.handleTabCompletion(buf, pos) orelse continue;
                            defer self.allocator.free(new_text);
                            // clear current line and show completion
                            try self.stdout().writeByte('\r');
                            try self.printFancyPrompt();
                            try self.stdout().writeAll(new_text);
                            // update buffer with completion
                            const copy_len = @min(new_text.len, buf.len - 1);
                            @memcpy(buf[0..copy_len], new_text[0..copy_len]);
                            pos = copy_len;
                        },
                        8, 127 => {
                            // backspace
                            if (pos > 0) {
                                pos -= 1;
                                // move cursor back, print space to erase character, move cursor back again
                                try self.stdout().writeAll("\x08 \x08");
                            }
                        },
                        32...126 => {
                            // echo printable characters (since we disabled terminal echo)
                            @branchHint(.likely);
                            try self.stdout().writeByte(char);
                            pos += 1;
                        },
                        else => {
                            // ignore control characters
                            continue;
                        },
                    }
                },
                .normal => {
                    switch (char) {
                        'h' => { // move cursor left
                            if (self.cursor_pos > 0) {
                                self.cursor_pos -= 1;
                                try self.stdout().writeAll("\x1B[D"); // move cursor left
                            }
                        },
                        'j' => { // move to previous command in history
                            const result = try self.handleDownArrow(buf, pos);
                            pos = result;
                            self.cursor_pos = pos;
                            try self.redrawLine(buf, self.cursor_pos);
                        },
                        'k' => { // move to next command in history
                            const result = try self.handleUpArrow(buf, pos);
                            pos = result;
                            self.cursor_pos = pos;
                            try self.redrawLine(buf, self.cursor_pos);
                        },
                        'l' => { // move cursor right
                            const input_end = self.findInputEnd(buf);
                            if (self.cursor_pos < input_end and self.cursor_pos < pos) {
                                self.cursor_pos += 1;
                                try self.stdout().writeAll("\x1B[C"); // move cursor right
                            }
                        },
                        '0' => { // move to beginning of line
                            try self.stdout().writeByte('\r');
                            try self.printFancyPrompt();
                            self.cursor_pos = 0;
                        },
                        '$' => { // move to end of line
                            const input_end = self.findInputEnd(buf);
                            const move_amount = input_end - self.cursor_pos;
                            if (move_amount > 0) {
                                for (0..move_amount) |_| {
                                    try self.stdout().writeAll("\x1B[C");
                                }
                                self.cursor_pos = input_end;
                            }
                        },
                        'w' => { // move forward one word
                            const new_pos = self.jumpWordForward(buf, self.cursor_pos);
                            const move_amount = new_pos - self.cursor_pos;
                            if (move_amount > 0) {
                                try self.stdout().print("\x1B[{d}C", .{move_amount});
                                self.cursor_pos = new_pos;
                            }
                        },
                        'b' => { // move backward one word
                            const new_pos = self.jumpWordBackward(buf, self.cursor_pos);
                            const move_amount = self.cursor_pos - new_pos;
                            if (move_amount > 0) {
                                try self.stdout().print("\x1B[{d}D", .{move_amount});
                                self.cursor_pos = new_pos;
                            }
                        },
                        'B' => {
                            const new_pos = self.jumpWordBackward(buf, self.cursor_pos);
                            const move_amount = self.cursor_pos - new_pos;
                            if (move_amount > 0) {
                                try self.stdout().print("\x1B[{d}D", .{move_amount});
                                self.cursor_pos = new_pos;
                            }
                        },
                        'i' => {
                            self.vim_mode = .insert;
                            // show mode change
                            try self.stdout().writeByte('\r');
                            try self.printFancyPrompt();
                            // re-display current input
                            if (pos > 0) {
                                try self.stdout().writeAll(buf[0..pos]);
                            }
                        },
                        'e' => { // move to end of word (vim standard)
                            const new_pos = self.jumpWordEndForward(buf, self.cursor_pos);
                            const move_amount = new_pos - self.cursor_pos;
                            if (move_amount > 0) {
                                try self.stdout().print("\x1B[{d}C", .{move_amount});
                                self.cursor_pos = new_pos;
                            }
                        },
                        'E' => { // move to end of WORD (vim standard)
                            const new_pos = self.jumpWORDEndForward(buf, self.cursor_pos);
                            const move_amount = new_pos - self.cursor_pos;
                            if (move_amount > 0) {
                                try self.stdout().print("\x1B[{d}C", .{move_amount});
                                self.cursor_pos = new_pos;
                            }
                        },
                        CTRL_T => { // Ctrl+T - toggle vim/emacs mode
                            self.vim_mode_enabled = !self.vim_mode_enabled;
                            if (self.vim_mode_enabled) {
                                self.vim_mode = .insert; // Reset to insert when enabling vim mode
                            }
                            // show mode change
                            try self.stdout().writeByte('\r');
                            try self.printFancyPrompt();
                            // re-display current input
                            if (pos > 0) {
                                try self.stdout().writeAll(buf[0..pos]);
                            }
                        },
                        'a' => { // append after cursor
                            if (self.cursor_pos < pos) {
                                self.cursor_pos += 1;
                                try self.stdout().writeAll("\x1B[C");
                            }
                            self.vim_mode = .insert;
                        },
                        'A' => { // append at end of line
                            const input_end = self.findInputEnd(buf);
                            const move_amount = input_end - self.cursor_pos;
                            if (move_amount > 0) {
                                for (0..move_amount) |_| {
                                    try self.stdout().writeAll("\x1B[C");
                                }
                                self.cursor_pos = input_end;
                            }
                            self.vim_mode = .insert;
                        },
                        'I' => { // insert at beginning of line
                            try self.stdout().writeByte('\r');
                            try self.printFancyPrompt();
                            self.cursor_pos = 0;
                            self.vim_mode = .insert;
                        },
                        'x' => { // delete character under cursor
                            if (self.cursor_pos < pos and pos > 0) {
                                // shift everything left
                                for (self.cursor_pos..pos - 1) |i| {
                                    buf[i] = buf[i + 1];
                                }
                                pos -= 1;
                                try self.redrawLine(buf, self.cursor_pos);
                            }
                        },
                        'X' => { // delete character before cursor
                            if (self.cursor_pos > 0) {
                                self.cursor_pos -= 1;
                                // shift everything left
                                for (self.cursor_pos..pos - 1) |i| {
                                    buf[i] = buf[i + 1];
                                }
                                pos -= 1;
                                try self.redrawLine(buf, self.cursor_pos);
                            }
                        },
                        'D' => { // delete from cursor to end of line
                            if (self.cursor_pos < pos) {
                                // copy to clipboard
                                const delete_len = pos - self.cursor_pos;
                                @memcpy(self.clipboard[0..delete_len], buf[self.cursor_pos..pos]);
                                self.clipboard_len = delete_len;
                                // clear from cursor to end
                                pos = self.cursor_pos;
                                try self.redrawLine(buf, self.cursor_pos);
                            }
                        },
                        'C' => { // change from cursor to end of line (delete and enter insert mode)
                            if (self.cursor_pos < pos) {
                                // copy to clipboard
                                const delete_len = pos - self.cursor_pos;
                                @memcpy(self.clipboard[0..delete_len], buf[self.cursor_pos..pos]);
                                self.clipboard_len = delete_len;
                                // clear from cursor to end
                                pos = self.cursor_pos;
                                try self.redrawLine(buf, self.cursor_pos);
                            }
                            self.vim_mode = .insert;
                        },
                        'y' => { // yank commands (need to handle yy, yw, etc.)
                            // For now, just implement yy (yank line)
                            @memcpy(self.clipboard[0..pos], buf[0..pos]);
                            self.clipboard_len = pos;
                        },
                        'p' => { // paste after cursor
                            if (self.clipboard_len > 0 and pos + self.clipboard_len < buf.len - 1) {
                                // shift everything right to make room
                                var i: usize = pos;
                                while (i > self.cursor_pos) {
                                    i -= 1;
                                    buf[i + self.clipboard_len] = buf[i];
                                }
                                // insert clipboard content
                                @memcpy(buf[self.cursor_pos .. self.cursor_pos + self.clipboard_len], self.clipboard[0..self.clipboard_len]);
                                pos += self.clipboard_len;
                                try self.redrawLine(buf, self.cursor_pos);
                            }
                        },
                        'P' => { // paste before cursor
                            if (self.clipboard_len > 0 and pos + self.clipboard_len < buf.len - 1 and self.cursor_pos > 0) {
                                self.cursor_pos -= 1;
                                // shift everything right to make room
                                var i: usize = pos;
                                while (i > self.cursor_pos) {
                                    i -= 1;
                                    buf[i + self.clipboard_len] = buf[i];
                                }
                                // insert clipboard content
                                @memcpy(buf[self.cursor_pos .. self.cursor_pos + self.clipboard_len], self.clipboard[0..self.clipboard_len]);
                                pos += self.clipboard_len;
                                try self.redrawLine(buf, self.cursor_pos);
                            }
                        },
                        'u' => { // undo (simplified - just clear line)
                            pos = 0;
                            self.cursor_pos = 0;
                            try self.stdout().writeByte('\r');
                            try self.printFancyPrompt();
                        },
                        '/' => { // forward search
                            try self.stdout().writeByte('/');
                            self.search_mode = true;
                            self.search_len = 0;
                        },
                        '?' => { // backward search
                            try self.stdout().writeByte('?');
                            self.search_mode = true;
                            self.search_len = 0;
                        },
                        'n' => { // next search result (simplified - just use j for now)
                            const result = try self.handleDownArrow(buf, pos);
                            pos = result;
                            try self.redrawLine(buf, self.cursor_pos);
                        },
                        'N' => { // previous search result (simplified - just use k for now)
                            const result = try self.handleUpArrow(buf, pos);
                            pos = result;
                            try self.redrawLine(buf, self.cursor_pos);
                        },
                        CTRL_C => { // ctrl+c in normal mode - clear line and return to insert
                            try self.stdout().writeByte('\n');
                            pos = 0;
                            self.cursor_pos = 0;
                            self.history_index = -1; // reset history navigation
                            // Always start new line in insert mode
                            self.vim_mode = .insert;
                            try self.printFancyPrompt();
                        },
                        '\n' => {
                            try self.stdout().writeByte('\n');
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
        const builtin_commands = [_][]const u8{ "pwd", "echo", "cd", "exit", "history", "search", "vimode" };

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

    const PathInfo = struct {
        dir_path: []const u8,
        search_prefix: []const u8,
        is_tilde: bool,
        is_absolute: bool,
    };

    fn parsePathForCompletion(file_part: []const u8) PathInfo {
        if (std.mem.startsWith(u8, file_part, "~/")) {
            const home = std.posix.getenv("HOME") orelse "/home";
            return PathInfo{
                .dir_path = home,
                .search_prefix = file_part[2..],
                .is_tilde = true,
                .is_absolute = false,
            };
        } else if (std.mem.startsWith(u8, file_part, "/")) {
            if (std.mem.lastIndexOf(u8, file_part, "/")) |last_slash| {
                const dir_path = if (last_slash == 0) "/" else file_part[0..last_slash];
                const search_prefix = file_part[last_slash + 1 ..];
                return PathInfo{
                    .dir_path = dir_path,
                    .search_prefix = search_prefix,
                    .is_tilde = false,
                    .is_absolute = true,
                };
            }
        }

        return PathInfo{
            .dir_path = ".",
            .search_prefix = file_part,
            .is_tilde = false,
            .is_absolute = false,
        };
    }

    fn completeFilePath(self: *Self, input: []const u8) !?[]const u8 {
        if (std.mem.lastIndexOf(u8, input, " ")) |last_space| {
            const file_part = input[last_space + 1 ..];
            const command_part = input[0 .. last_space + 1];
            const only_dirs = std.mem.startsWith(u8, input, "cd ");

            const path_info = parsePathForCompletion(file_part);
            var dir = std.fs.cwd().openDir(path_info.dir_path, .{ .iterate = true }) catch return null;
            defer dir.close();

            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (std.mem.startsWith(u8, entry.name, path_info.search_prefix)) {
                    if (only_dirs and entry.kind != .directory) continue;

                    const completed = if (path_info.is_tilde)
                        try std.fmt.allocPrint(self.allocator, "{s}~/{s}", .{ command_part, entry.name })
                    else if (path_info.is_absolute)
                        try std.fmt.allocPrint(self.allocator, "{s}{s}/{s}", .{ command_part, path_info.dir_path, entry.name })
                    else
                        try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ command_part, entry.name });

                    return completed;
                }
            }
        }

        return null;
    }

    fn handleShiftTab(self: *Self, buf: *[types.MAX_COMMAND_LENGTH]u8, pos: usize) !void {
        if (pos == 0) return;

        const current_input = buf[0..pos];
        try self.stdout().print("\n{f}--- available completions ---{f}\n", .{ tty.Style.bold, tty.Color.reset });

        if (std.mem.indexOf(u8, current_input, " ")) |_| {
            // show file completions
            try self.showFileCompletions(current_input);
        } else {
            // show command completions
            try self.showCommandCompletions(current_input);
        }

        try self.stdout().print("{f}-------------------------------{f}\n", .{ tty.Style.bold, tty.Color.reset });
        try self.printFancyPrompt();
        try self.stdout().writeAll(current_input);
    }

    fn showCommandCompletions(self: *Self, input: []const u8) !void {
        const builtin_commands = [_][]const u8{ "pwd", "echo", "cd", "exit", "history", "search", "vimode" };

        for (builtin_commands) |cmd| {
            if (std.mem.startsWith(u8, cmd, input)) {
                try self.stdout().print("  {f}{s}{f}\n", .{ Colors.userhost, cmd, tty.Color.reset });
            }
        }
    }

    fn showFileCompletions(self: *Self, input: []const u8) !void {
        if (std.mem.lastIndexOf(u8, input, " ")) |last_space| {
            const file_part = input[last_space + 1 ..];
            const only_dirs = std.mem.startsWith(u8, input, "cd ");

            const path_info = parsePathForCompletion(file_part);
            var dir = std.fs.cwd().openDir(path_info.dir_path, .{ .iterate = true }) catch return;
            defer dir.close();

            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (std.mem.startsWith(u8, entry.name, path_info.search_prefix)) {
                    if (only_dirs and entry.kind != .directory) continue;

                    const file_color = switch (entry.kind) {
                        .directory => Colors.path,
                        .file => Colors.default_color,
                        else => Colors.default_color,
                    };
                    const suffix = if (entry.kind == .directory) "/" else "";
                    try self.stdout().print("  {f}{s}{s}{f}\n", .{ file_color, entry.name, suffix, tty.Color.reset });
                }
            }
        }
    }

    fn handleUpArrow(self: *Self, buf: *[types.MAX_COMMAND_LENGTH]u8, current_pos: usize) !usize {
        const h = self.hist orelse return current_pos;

        // save current command if we're starting history navigation
        if (self.history_index == -1) {
            @memcpy(self.current_command[0..current_pos], buf[0..current_pos]);
            self.current_command_len = current_pos;
            self.history_index = @intCast(h.entries.items.len);
        }
        if (self.history_index > 0) {
            self.history_index -= 1;
            const entry = h.entries.items[@intCast(self.history_index)];
            const history_cmd = h.getCommand(entry);

            // update buffer
            const copy_len = @min(history_cmd.len, buf.len - 1);
            @memcpy(buf[0..copy_len], history_cmd[0..copy_len]);
            return copy_len;
        }

        return current_pos;
    }

    fn handleDownArrow(self: *Self, buf: *[types.MAX_COMMAND_LENGTH]u8, current_pos: usize) !usize {
        const h = self.hist orelse return current_pos;
        if (self.history_index == -1) return current_pos;

        self.history_index += 1;

        if (self.history_index >= @as(i32, @intCast(h.entries.items.len))) {
            self.history_index = -1;
            const original_len = self.current_command_len;

            // update buffer
            const copy_len = @min(original_len, buf.len - 1);
            @memcpy(buf[0..copy_len], self.current_command[0..copy_len]);
            return copy_len;
        }

        const entry = h.entries.items[@intCast(self.history_index)];
        const history_cmd = h.getCommand(entry);

        // update buffer
        const copy_len = @min(history_cmd.len, buf.len - 1);
        @memcpy(buf[0..copy_len], history_cmd[0..copy_len]);
        return copy_len;
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

    fn jumpWordEndForward(self: *Self, buf: *[types.MAX_COMMAND_LENGTH]u8, current_pos: usize) usize {
        return self.jumpEndForwardImpl(buf, current_pos, isWordChar);
    }

    fn jumpWORDEndForward(self: *Self, buf: *[types.MAX_COMMAND_LENGTH]u8, current_pos: usize) usize {
        return self.jumpEndForwardImpl(buf, current_pos, isNonWhitespace);
    }

    fn jumpEndForwardImpl(self: *Self, buf: *[types.MAX_COMMAND_LENGTH]u8, current_pos: usize, isCharFn: fn (u8) bool) usize {
        var pos = current_pos;
        const input_len = self.findInputEnd(buf);

        if (pos >= input_len) return pos;

        // if we're on whitespace, skip it first
        while (pos < input_len and isWhitespace(buf[pos])) {
            pos += 1;
        }

        // move to end of current word/WORD
        while (pos < input_len and isCharFn(buf[pos])) {
            pos += 1;
        }

        // move back one to be ON the last character
        if (pos > current_pos) {
            pos -= 1;
        }

        return pos;
    }

    fn isWordChar(c: u8) bool {
        return !isWhitespace(c);
    }

    fn isNonWhitespace(c: u8) bool {
        return !isWhitespace(c);
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t';
    }

    // Helper functions for cursor movement to reduce code duplication
    fn moveCursorRight(self: *Self, count: usize) void {
        for (0..count) |_| {
            try self.stdout().writeAll("\x1B[C");
        }
        self.cursor_pos += count;
    }

    fn moveCursorLeft(self: *Self, count: usize) void {
        for (0..count) |_| {
            try self.stdout().writeAll("\x1B[D");
        }
        if (self.cursor_pos >= count) {
            self.cursor_pos -= count;
        } else {
            self.cursor_pos = 0;
        }
    }

    fn redrawLine(self: *Self, buf: *[types.MAX_COMMAND_LENGTH]u8, cursor_pos: usize) !void {
        const input_len = @min(self.findInputEnd(buf), cursor_pos);

        // clear current line and redraw prompt + input
        try self.stdout().writeAll("\r\x1b[2K");
        try self.printFancyPrompt();

        if (input_len > 0) {
            try self.stdout().writeAll(buf[0..input_len]);
        }

        // position cursor at the right place
        if (cursor_pos < input_len) {
            const back_chars = input_len - cursor_pos;
            try self.stdout().print("\x1b[{d}D", .{back_chars});
        }
    }

    fn handleEscapeSequence(
        self: *Self,
        stdin: *const std.fs.File,
        buf: *[types.MAX_COMMAND_LENGTH]u8,
        pos: usize,
    ) !EscapeResult {
        var temp_buf: [2]u8 = undefined;

        // If there is an ESC sequence, the terminal emulator will have already piped
        // all the sequence bytes into stdin. If not, the read will return 0 bytes,
        // indicating this is a normal ESC key press.

        // Set stdin to non-blocking mode to check if there's more data
        const flags = std.posix.fcntl(stdin.handle, std.posix.F.GETFL, 0) catch 0;
        _ = std.posix.fcntl(stdin.handle, std.posix.F.SETFL, flags | 0o4000) catch {}; // O_NONBLOCK = 0o4000 on Linux

        const readed_bytes = stdin.read(&temp_buf) catch 0;

        // Restore blocking mode
        _ = std.posix.fcntl(stdin.handle, std.posix.F.SETFL, flags) catch {};

        if (readed_bytes == 0 or temp_buf[0] != '[') {
            return if (self.vim_mode_enabled)
                .toggle_vim_mode
            else
                .continue_loop;
        }

        // read the command byte
        if (readed_bytes == 1) return .continue_loop;

        return switch (temp_buf[1]) {
            'Z' => blk: {
                if (self.vim_mode == .insert) {
                    try self.handleShiftTab(buf, pos);
                }
                break :blk .continue_loop;
            },
            'A' => blk: {
                if (self.vim_mode == .insert) {
                    const new_pos = try self.handleUpArrow(buf, pos);
                    try self.redrawLine(buf, new_pos);
                    break :blk .{ .set_position = new_pos };
                }
                break :blk .continue_loop;
            },
            'B' => blk: {
                if (self.vim_mode == .insert) {
                    const new_pos = try self.handleDownArrow(buf, pos);
                    try self.redrawLine(buf, new_pos);
                    break :blk .{ .set_position = new_pos };
                }
                break :blk .continue_loop;
            },
            'C', 'D' => .continue_loop, // ignore basic arrows for now
            '1' => try self.handleCtrlArrows(stdin, buf, pos),
            else => .continue_loop,
        };
    }

    fn handleCtrlArrows(self: *Self, stdin: *const std.fs.File, buf: *[types.MAX_COMMAND_LENGTH]u8, pos: usize) !EscapeResult {
        var temp_buf: [1]u8 = undefined;

        // expect ';'
        const semicolon = stdin.read(&temp_buf) catch return EscapeResult.continue_loop;
        if (semicolon == 0 or temp_buf[0] != ';') return EscapeResult.continue_loop;

        // expect '5'
        const five = stdin.read(&temp_buf) catch return EscapeResult.continue_loop;
        if (five == 0 or temp_buf[0] != '5') return EscapeResult.continue_loop;

        // read direction
        const direction = stdin.read(&temp_buf) catch return EscapeResult.continue_loop;
        if (direction == 0) return EscapeResult.continue_loop;

        if (self.vim_mode != .insert) return EscapeResult.continue_loop;

        return switch (temp_buf[0]) {
            'C' => blk: { // ctrl+right
                const new_pos = self.jumpWordForward(buf, pos);
                try self.redrawLine(buf, new_pos);
                break :blk EscapeResult{ .set_position = new_pos };
            },
            'D' => blk: { // ctrl+left
                const new_pos = self.jumpWordBackward(buf, pos);
                try self.redrawLine(buf, new_pos);
                break :blk EscapeResult{ .set_position = new_pos };
            },
            'A' => blk: { // ctrl+up - beginning of line
                try self.redrawLine(buf, 0);
                break :blk EscapeResult{ .set_position = 0 };
            },
            'B' => blk: { // ctrl+down - end of line
                const new_pos = self.findInputEnd(buf);
                try self.redrawLine(buf, new_pos);
                break :blk EscapeResult{ .set_position = new_pos };
            },
            else => EscapeResult.continue_loop,
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

        // cleanup variables
        var var_it = self.variables.iterator();
        while (var_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.variables.deinit();

        if (self.hist) |h| h.deinit();
        self.allocator.free(self.current_command);
        self.allocator.free(self.clipboard);
        self.allocator.free(self.search_buffer);
        self.allocator.free(self.stdout().buffer);
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

    pub fn run(self: *Self) !void {
        self.running = true;

        // don't print version on startup

        var buf: [types.MAX_COMMAND_LENGTH]u8 = undefined;

        // Print initial prompt
        try self.printFancyPrompt();
        try self.stdout().flush();

        while (self.running) {
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
                }
                // For both empty and non-empty commands, print new prompt
                if (self.running) {
                    try self.printFancyPrompt();
                }
                self.stdout().flush() catch unreachable;
            }
        }
    }

    pub fn executeCommand(self: *Self, command: []const u8) !u8 {
        // check if command starts with an alias
        const resolved_command = self.resolveAlias(command);
        defer if (!std.mem.eql(u8, resolved_command, command)) self.allocator.free(resolved_command);

        const exit_code = try self.executeCommandInternal(resolved_command);
        self.last_exit_code = exit_code;
        return exit_code;
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
                const resolved = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ alias_value, args }) catch return command;
                return resolved;
            } else {
                const resolved = self.allocator.dupe(u8, alias_value) catch return command;
                return resolved;
            }
        }

        return command;
    }

    fn expandVariables(self: *Self, input: []const u8) ![]const u8 {
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

    fn executeCommandAndCapture(self: *Self, command: []const u8) ![]const u8 {
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

    fn executeExternalAndCapture(self: *Self, command: []const u8) ![]const u8 {
        // Execute external command and capture output
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "/bin/sh", "-c", command },
            .max_output_bytes = 4096,
        });
        defer self.allocator.free(result.stderr);

        return result.stdout; // caller owns this memory
    }

    fn executeCommandInternal(self: *Self, command: []const u8) !u8 {

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
            if (self.hist) |h| {
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
            if (self.hist) |h| {
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
};
