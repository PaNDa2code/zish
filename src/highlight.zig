// highlight.zig - Shell syntax highlighting for zish
// Based on Justine Tunney's llamafile shell highlighter design

const std = @import("std");
const keywords = @import("keywords.zig");

// ANSI color codes
pub const HI_RESET = "\x1b[0m";
pub const HI_STRING = "\x1b[32m"; // green
pub const HI_VAR = "\x1b[36m"; // cyan
pub const HI_KEYWORD = "\x1b[35m"; // magenta
pub const HI_BUILTIN = "\x1b[34m"; // blue
pub const HI_COMMENT = "\x1b[90m"; // gray
pub const HI_ESCAPE = "\x1b[33m"; // yellow
pub const HI_BOLD = "\x1b[1m";
pub const HI_UNBOLD = "\x1b[22m";

const State = enum {
    normal,
    word,
    quote,
    dquote,
    dquote_var,
    dquote_var2,
    dquote_curl,
    dquote_backslash,
    tick,
    tick_backslash,
    var_start,
    var2,
    curl,
    curl_backslash,
    comment,
    lt,
    lt_lt,
    lt_lt_name,
    lt_lt_qname,
    heredoc_bol,
    heredoc,
    heredoc_var,
    heredoc_var2,
    heredoc_curl,
    backslash,
};

pub const Highlighter = struct {
    allocator: std.mem.Allocator,
    state: State = .normal,
    word_buf: std.ArrayList(u8),
    heredoc_delim: std.ArrayList(u8),
    curl_depth: u32 = 0,
    heredoc_idx: usize = 0,
    pending_heredoc: bool = false,
    indented_heredoc: bool = false,
    no_interpolation: bool = false,
    last_char: u8 = 0,

    pub fn init(allocator: std.mem.Allocator) !Highlighter {
        return .{
            .allocator = allocator,
            .word_buf = try std.ArrayList(u8).initCapacity(allocator, 256),
            .heredoc_delim = try std.ArrayList(u8).initCapacity(allocator, 64),
        };
    }

    pub fn deinit(self: *Highlighter) void {
        self.word_buf.deinit(self.allocator);
        self.heredoc_delim.deinit(self.allocator);
    }

    pub fn reset(self: *Highlighter) void {
        self.state = .normal;
        self.word_buf.clearRetainingCapacity();
        self.heredoc_delim.clearRetainingCapacity();
        self.curl_depth = 0;
        self.heredoc_idx = 0;
        self.pending_heredoc = false;
        self.indented_heredoc = false;
        self.no_interpolation = false;
        self.last_char = 0;
    }

    pub fn highlight(self: *Highlighter, input: []const u8, output: *std.ArrayList(u8)) !void {
        self.reset();
        for (input) |c| {
            try self.feed(c, output);
            self.last_char = c;
        }
        try self.flush(output);
    }

    fn feed(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        switch (self.state) {
            .normal => try self.handleNormal(c, r),
            .word => try self.handleWord(c, r),
            .quote => try self.handleQuote(c, r),
            .dquote => try self.handleDquote(c, r),
            .dquote_var => try self.handleDquoteVar(c, r),
            .dquote_var2 => try self.handleDquoteVar2(c, r),
            .dquote_curl => try self.handleDquoteCurl(c, r),
            .dquote_backslash => try self.handleDquoteBackslash(c, r),
            .tick => try self.handleTick(c, r),
            .tick_backslash => try self.handleTickBackslash(c, r),
            .var_start => try self.handleVarStart(c, r),
            .var2 => try self.handleVar2(c, r),
            .curl => try self.handleCurl(c, r),
            .curl_backslash => try self.handleCurlBackslash(c, r),
            .comment => try self.handleComment(c, r),
            .lt => try self.handleLt(c, r),
            .lt_lt => try self.handleLtLt(c, r),
            .lt_lt_name => try self.handleLtLtName(c, r),
            .lt_lt_qname => try self.handleLtLtQname(c, r),
            .heredoc_bol => try self.handleHeredocBol(c, r),
            .heredoc => try self.handleHeredoc(c, r),
            .heredoc_var => try self.handleHeredocVar(c, r),
            .heredoc_var2 => try self.handleHeredocVar2(c, r),
            .heredoc_curl => try self.handleHeredocCurl(c, r),
            .backslash => try self.handleBackslash(c, r),
        }
    }

    fn handleNormal(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        if (std.ascii.isAlphabetic(c) or c == '_') {
            self.state = .word;
            try self.word_buf.append(a, c);
        } else if (c == '\'') {
            self.state = .quote;
            try r.appendSlice(a, HI_STRING);
            try r.append(a, c);
        } else if (c == '\\') {
            self.state = .backslash;
            try r.appendSlice(a, HI_ESCAPE);
            try r.append(a, c);
        } else if (c == '"') {
            self.state = .dquote;
            try r.appendSlice(a, HI_STRING);
            try r.append(a, c);
        } else if (c == '`') {
            self.state = .tick;
            try r.appendSlice(a, HI_STRING);
            try r.append(a, c);
        } else if (c == '$') {
            self.state = .var_start;
            try r.append(a, c);
        } else if (c == '<') {
            self.state = .lt;
            try r.append(a, c);
        } else if (c == '#' and (self.last_char == 0 or std.ascii.isWhitespace(self.last_char))) {
            try r.appendSlice(a, HI_COMMENT);
            try r.append(a, c);
            self.state = .comment;
        } else if (c == '\n') {
            try r.append(a, c);
            if (self.pending_heredoc) {
                try r.appendSlice(a, HI_STRING);
                self.pending_heredoc = false;
                self.state = .heredoc_bol;
                self.heredoc_idx = 0;
            }
        } else {
            try r.append(a, c);
        }
    }

    fn handleBackslash(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        try r.append(a, c);
        try r.appendSlice(a, HI_RESET);
        self.state = .normal;
    }

    fn handleWord(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            try self.word_buf.append(a, c);
        } else {
            try self.flushWord(r);
            self.state = .normal;
            try self.handleNormal(c, r);
        }
    }

    fn flushWord(self: *Highlighter, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        const word = self.word_buf.items;
        if (keywords.isKeyword(word)) {
            try r.appendSlice(a, HI_KEYWORD);
            try r.appendSlice(a, word);
            try r.appendSlice(a, HI_RESET);
        } else if (keywords.isBuiltin(word)) {
            try r.appendSlice(a, HI_BUILTIN);
            try r.appendSlice(a, word);
            try r.appendSlice(a, HI_RESET);
        } else {
            try r.appendSlice(a, word);
        }
        self.word_buf.clearRetainingCapacity();
    }

    fn handleQuote(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        try r.append(a, c);
        if (c == '\'') {
            try r.appendSlice(a, HI_RESET);
            self.state = .normal;
        }
    }

    fn handleDquote(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        if (c == '"') {
            try r.append(a, c);
            try r.appendSlice(a, HI_RESET);
            self.state = .normal;
        } else if (c == '\\') {
            try r.append(a, c);
            self.state = .dquote_backslash;
        } else if (c == '$') {
            self.state = .dquote_var;
        } else {
            try r.append(a, c);
        }
    }

    fn handleDquoteBackslash(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        try r.append(self.allocator, c);
        self.state = .dquote;
    }

    fn handleDquoteVar(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        if (isSpecialVar(c)) {
            try r.appendSlice(a, HI_BOLD);
            try r.append(a, '$');
            try r.append(a, c);
            try r.appendSlice(a, HI_UNBOLD);
            self.state = .dquote;
        } else if (c == '{') {
            try r.appendSlice(a, HI_BOLD);
            try r.appendSlice(a, "${");
            self.state = .dquote_curl;
            self.curl_depth = 1;
        } else if (c == '(') {
            try r.appendSlice(a, "$(");
            self.state = .dquote_var2;
        } else {
            try r.appendSlice(a, HI_BOLD);
            try r.append(a, '$');
            self.state = .dquote_var2;
            try self.handleDquoteVar2(c, r);
        }
    }

    fn handleDquoteVar2(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            try r.append(a, c);
        } else {
            try r.appendSlice(a, HI_UNBOLD);
            self.state = .dquote;
            try self.handleDquote(c, r);
        }
    }

    fn handleDquoteCurl(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        if (c == '{') {
            try r.append(a, c);
            self.curl_depth += 1;
        } else if (c == '}') {
            try r.append(a, c);
            self.curl_depth -= 1;
            if (self.curl_depth == 0) {
                try r.appendSlice(a, HI_UNBOLD);
                self.state = .dquote;
            }
        } else {
            try r.append(a, c);
        }
    }

    fn handleTick(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        try r.append(a, c);
        if (c == '`') {
            try r.appendSlice(a, HI_RESET);
            self.state = .normal;
        } else if (c == '\\') {
            self.state = .tick_backslash;
        }
    }

    fn handleTickBackslash(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        try r.append(self.allocator, c);
        self.state = .tick;
    }

    fn handleVarStart(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        if (isSpecialVar(c)) {
            try r.appendSlice(a, HI_VAR);
            try r.append(a, c);
            try r.appendSlice(a, HI_RESET);
            self.state = .normal;
        } else if (c == '{') {
            try r.append(a, c);
            try r.appendSlice(a, HI_VAR);
            self.state = .curl;
            self.curl_depth = 1;
        } else if (std.ascii.isAlphabetic(c) or c == '_') {
            try r.appendSlice(a, HI_VAR);
            try r.append(a, c);
            self.state = .var2;
        } else {
            self.state = .normal;
            try self.handleNormal(c, r);
        }
    }

    fn handleVar2(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            try r.append(a, c);
        } else {
            try r.appendSlice(a, HI_RESET);
            self.state = .normal;
            try self.handleNormal(c, r);
        }
    }

    fn handleCurl(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        if (c == '\\') {
            self.state = .curl_backslash;
            try r.appendSlice(a, HI_RESET);
            try r.appendSlice(a, HI_ESCAPE);
            try r.append(a, c);
        } else if (c == '{') {
            try r.appendSlice(a, HI_RESET);
            try r.append(a, c);
            try r.appendSlice(a, HI_VAR);
            self.curl_depth += 1;
        } else if (c == '}') {
            try r.appendSlice(a, HI_RESET);
            try r.append(a, c);
            self.curl_depth -= 1;
            if (self.curl_depth == 0) {
                self.state = .normal;
            }
        } else if (isPunct(c)) {
            try r.appendSlice(a, HI_RESET);
            try r.append(a, c);
        } else {
            try r.append(a, c);
        }
    }

    fn handleCurlBackslash(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        try r.append(a, c);
        try r.appendSlice(a, HI_RESET);
        self.state = .curl;
    }

    fn handleComment(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        try r.append(a, c);
        if (c == '\n') {
            try r.appendSlice(a, HI_RESET);
            self.state = .normal;
        }
    }

    fn handleLt(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        if (c == '<') {
            try r.append(self.allocator, c);
            self.state = .lt_lt;
            self.heredoc_delim.clearRetainingCapacity();
            self.pending_heredoc = false;
            self.indented_heredoc = false;
            self.no_interpolation = false;
        } else {
            self.state = .normal;
            try self.handleNormal(c, r);
        }
    }

    fn handleLtLt(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        if (c == '-') {
            self.indented_heredoc = true;
            try r.append(a, c);
        } else if (c == '\\') {
            try r.append(a, c);
        } else if (c == '\'') {
            self.state = .lt_lt_qname;
            try r.appendSlice(a, HI_STRING);
            try r.append(a, c);
            self.no_interpolation = true;
        } else if (std.ascii.isAlphabetic(c) or c == '_') {
            self.state = .lt_lt_name;
            try self.heredoc_delim.append(a, c);
            try r.append(a, c);
        } else if (std.ascii.isWhitespace(c) and c != '\n') {
            try r.append(a, c);
        } else {
            self.state = .normal;
            try self.handleNormal(c, r);
        }
    }

    fn handleLtLtName(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            try self.heredoc_delim.append(a, c);
            try r.append(a, c);
        } else if (c == '\n') {
            try r.append(a, c);
            try r.appendSlice(a, HI_STRING);
            self.state = .heredoc_bol;
        } else {
            self.pending_heredoc = true;
            self.state = .normal;
            try self.handleNormal(c, r);
        }
    }

    fn handleLtLtQname(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        try r.append(a, c);
        if (c == '\'') {
            try r.appendSlice(a, HI_RESET);
            self.pending_heredoc = true;
            self.state = .normal;
        } else {
            try self.heredoc_delim.append(a, c);
        }
    }

    fn handleHeredocBol(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        try r.append(a, c);
        if (c == '\n') {
            if (self.heredoc_idx == self.heredoc_delim.items.len) {
                self.state = .normal;
                try r.appendSlice(a, HI_RESET);
            }
            self.heredoc_idx = 0;
        } else if (c == '\t' and self.indented_heredoc) {
            // skip tabs in indented heredocs
        } else if (self.heredoc_idx < self.heredoc_delim.items.len and
            self.heredoc_delim.items[self.heredoc_idx] == c)
        {
            self.heredoc_idx += 1;
        } else {
            self.state = .heredoc;
            self.heredoc_idx = 0;
        }
    }

    fn handleHeredoc(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        if (c == '\n') {
            try r.append(a, c);
            self.state = .heredoc_bol;
        } else if (c == '$' and !self.no_interpolation) {
            self.state = .heredoc_var;
        } else {
            try r.append(a, c);
        }
    }

    fn handleHeredocVar(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        if (isSpecialVar(c)) {
            try r.appendSlice(a, HI_BOLD);
            try r.append(a, '$');
            try r.append(a, c);
            try r.appendSlice(a, HI_UNBOLD);
            self.state = .heredoc;
        } else if (c == '{') {
            try r.appendSlice(a, HI_BOLD);
            try r.appendSlice(a, "${");
            self.state = .heredoc_curl;
            self.curl_depth = 1;
        } else if (std.ascii.isAlphabetic(c) or c == '_') {
            try r.appendSlice(a, HI_BOLD);
            try r.append(a, '$');
            try r.append(a, c);
            self.state = .heredoc_var2;
        } else {
            try r.append(a, '$');
            self.state = .heredoc;
            try self.handleHeredoc(c, r);
        }
    }

    fn handleHeredocVar2(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            try r.append(a, c);
        } else {
            try r.appendSlice(a, HI_UNBOLD);
            self.state = .heredoc;
            try self.handleHeredoc(c, r);
        }
    }

    fn handleHeredocCurl(self: *Highlighter, c: u8, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        if (c == '{') {
            try r.append(a, c);
            self.curl_depth += 1;
        } else if (c == '}') {
            try r.append(a, c);
            self.curl_depth -= 1;
            if (self.curl_depth == 0) {
                try r.appendSlice(a, HI_UNBOLD);
                self.state = .heredoc;
            }
        } else {
            try r.append(a, c);
        }
    }

    fn flush(self: *Highlighter, r: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        switch (self.state) {
            .word => try self.flushWord(r),
            .dquote_var, .heredoc_var => {
                try r.append(a, '$');
                try r.appendSlice(a, HI_RESET);
            },
            .var2, .curl, .curl_backslash, .tick, .tick_backslash,
            .quote, .dquote, .dquote_var2, .dquote_curl,
            .dquote_backslash, .comment, .heredoc_bol, .heredoc,
            .heredoc_var2, .heredoc_curl, .lt_lt_qname, .backslash => {
                try r.appendSlice(a, HI_RESET);
            },
            else => {},
        }
    }
};

fn isSpecialVar(c: u8) bool {
    return c == '!' or c == '#' or c == '$' or c == '*' or
        c == '-' or c == '?' or c == '@' or c == '\\' or c == '^';
}

fn isPunct(c: u8) bool {
    return switch (c) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*',
        '+', ',', '-', '.', '/', ':', ';', '<', '=', '>',
        '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|',
        '}', '~' => true,
        else => false,
    };
}
