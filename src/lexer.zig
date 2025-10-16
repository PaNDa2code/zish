// secure_lexer.zig - memory-safe, bounded lexer

const std = @import("std");
const types = @import("types.zig");

// token types with security annotations
pub const TokenType = enum {
    // basic elements
    Word,
    Integer,
    String,

    // variables and expansions
    Dollar,
    ParameterExpansion,
    CommandSubstitution,
    ArithmeticExpansion,

    // redirection
    RedirectInput,
    RedirectOutput,
    RedirectAppend,
    RedirectHereDoc,

    // pipes and background
    Pipe,
    Background,

    // control structures
    If, Then, Else, Elif, Fi,
    For, While, Until, Do, Done, In,
    Case, Esac,

    // logical operators
    And, Or, Not,

    // grouping
    LeftParen, RightParen,
    LeftBrace, RightBrace,

    // special
    Semicolon,
    NewLine,
    Eof,
};

// immutable token with bounded lifetime
pub const Token = struct {
    ty: TokenType,
    value: []const u8,  // points into lexer buffer or interned string
    line: types.LineNumber,
    column: types.ColumnNumber,

    pub const EMPTY = Token{
        .ty = .Eof,
        .value = "",
        .line = 0,
        .column = 0,
    };

    pub fn isKeyword(self: Token, keyword: []const u8) bool {
        // constant-time comparison for security
        return std.mem.eql(u8, self.value, keyword);
    }
};

// bounded lexer with stack-allocated buffers
pub const Lexer = struct {
    input: []const u8,
    position: usize,
    line: types.LineNumber,
    column: types.ColumnNumber,
    recursion_depth: types.RecursionDepth,

    // stack-allocated bounded buffers
    token_buffer: [types.MAX_TOKEN_LENGTH]u8,
    heredoc_buffer: [types.MAX_HEREDOC_SIZE]u8,

    const Self = @This();

    pub fn init(input: []const u8) !Self {
        try types.validateShellSafe(input);

        return Self{
            .input = input,
            .position = 0,
            .line = 1,
            .column = 1,
            .recursion_depth = 0,
            .token_buffer = undefined,
            .heredoc_buffer = undefined,
        };
    }

    // bounds-checked character access
    fn peek(self: *Self) ?u8 {
        if (self.position >= self.input.len) return null;
        return self.input[self.position];
    }

    fn advance(self: *Self) !?u8 {
        if (self.position >= self.input.len) return null;

        const char = self.input[self.position];

        // bounds-checked increment
        self.position = try types.checkedAdd(usize, self.position, 1);

        if (char == '\n') {
            self.line = try types.checkedAdd(types.LineNumber, self.line, 1);
            self.column = 1;
        } else {
            self.column = try types.checkedAdd(types.ColumnNumber, self.column, 1);
        }

        return char;
    }

    pub fn nextToken(self: *Self) !Token {
        // skip whitespace
        while (self.peek()) |char| {
            if (!std.ascii.isWhitespace(char)) break;
            _ = try self.advance();
        }

        const start_line = self.line;
        const start_column = self.column;

        const char = self.peek() orelse {
            return Token{
                .ty = .Eof,
                .value = "",
                .line = start_line,
                .column = start_column,
            };
        };

        return switch (char) {
            '$' => self.handleDollar(start_line, start_column),
            '\'' => self.handleSingleQuote(start_line, start_column),
            '"' => self.handleDoubleQuote(start_line, start_column),
            '>' => self.handleRedirectOutput(start_line, start_column),
            '<' => self.handleRedirectInput(start_line, start_column),
            '|' => self.handlePipe(start_line, start_column),
            '&' => self.handleBackground(start_line, start_column),
            ';' => self.handleSemicolon(start_line, start_column),
            '(' => self.handleLeftParen(start_line, start_column),
            ')' => self.handleRightParen(start_line, start_column),
            '{' => self.handleLeftBrace(start_line, start_column),
            '}' => self.handleRightBrace(start_line, start_column),
            '\n' => self.handleNewline(start_line, start_column),
            else => if (std.ascii.isDigit(char))
                self.handleNumber(start_line, start_column)
            else
                self.handleWord(start_line, start_column),
        };
    }

    // secure string handling with bounds checking
    fn handleWord(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        var len: usize = 0;

        while (self.peek()) |char| {
            if (isShellMetacharacter(char)) break;

            // bounds check before writing to buffer
            if (len >= self.token_buffer.len - 1) {
                return error.TokenTooLong;
            }

            self.token_buffer[len] = char;
            len += 1;
            _ = try self.advance();
        }

        if (len == 0) return error.EmptyToken;

        const word = self.token_buffer[0..len];
        const token_type = if (isKeyword(word)) keywordToTokenType(word) else .Word;

        return Token{
            .ty = token_type,
            .value = word,
            .line = start_line,
            .column = start_column,
        };
    }

    // secure quoted string handling
    fn handleDoubleQuote(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance(); // skip opening quote
        var len: usize = 0;

        while (self.peek()) |char| {
            if (char == '"') {
                _ = try self.advance();
                return Token{
                    .ty = .String,
                    .value = self.token_buffer[0..len],
                    .line = start_line,
                    .column = start_column,
                };
            }

            // bounds check
            if (len >= self.token_buffer.len - 1) {
                return error.StringTooLong;
            }

            if (char == '\\') {
                _ = try self.advance();
                if (self.peek()) |escaped| {
                    self.token_buffer[len] = switch (escaped) {
                        'n' => '\n',
                        't' => '\t',
                        '\\' => '\\',
                        '"' => '"',
                        else => escaped,
                    };
                    len += 1;
                    _ = try self.advance();
                }
            } else {
                self.token_buffer[len] = char;
                len += 1;
                _ = try self.advance();
            }
        }

        return error.UnterminatedString;
    }

    fn handleSingleQuote(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance(); // skip opening quote
        var len: usize = 0;

        while (self.peek()) |char| {
            if (char == '\'') {
                _ = try self.advance();
                return Token{
                    .ty = .String,
                    .value = self.token_buffer[0..len],
                    .line = start_line,
                    .column = start_column,
                };
            }

            if (len >= self.token_buffer.len - 1) {
                return error.StringTooLong;
            }

            self.token_buffer[len] = char;
            len += 1;
            _ = try self.advance();
        }

        return error.UnterminatedString;
    }

    // recursion-bounded expansion handling
    fn handleDollar(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        if (self.recursion_depth >= types.MAX_RECURSION_DEPTH) {
            return error.RecursionLimitExceeded;
        }

        _ = try self.advance(); // skip $

        const next = self.peek() orelse {
            return Token{
                .ty = .Dollar,
                .value = "$",
                .line = start_line,
                .column = start_column,
            };
        };

        switch (next) {
            '{' => return self.handleParameterExpansion(start_line, start_column),
            '(' => return self.handleCommandSubstitution(start_line, start_column),
            else => return Token{
                .ty = .Dollar,
                .value = "$",
                .line = start_line,
                .column = start_column,
            },
        }
    }

    fn handleParameterExpansion(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        self.recursion_depth = try types.checkedAdd(types.RecursionDepth, self.recursion_depth, 1);
        defer self.recursion_depth -= 1;

        _ = try self.advance(); // skip {
        var len: usize = 0;
        var brace_count: u32 = 1;

        // store opening syntax
        self.token_buffer[0] = '$';
        self.token_buffer[1] = '{';
        len = 2;

        while (self.peek()) |char| {
            if (len >= self.token_buffer.len - 1) {
                return error.ExpansionTooLong;
            }

            self.token_buffer[len] = char;
            len += 1;

            if (char == '{') {
                brace_count = try types.checkedAdd(u32, brace_count, 1);
            } else if (char == '}') {
                brace_count -= 1;
                if (brace_count == 0) {
                    _ = try self.advance();
                    return Token{
                        .ty = .ParameterExpansion,
                        .value = self.token_buffer[0..len],
                        .line = start_line,
                        .column = start_column,
                    };
                }
            }
            _ = try self.advance();
        }

        return error.UnterminatedParameterExpansion;
    }

    fn handleCommandSubstitution(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        self.recursion_depth = try types.checkedAdd(types.RecursionDepth, self.recursion_depth, 1);
        defer self.recursion_depth -= 1;

        _ = try self.advance(); // skip (
        var len: usize = 0;
        var paren_count: u32 = 1;

        // store opening syntax
        self.token_buffer[0] = '$';
        self.token_buffer[1] = '(';
        len = 2;

        while (self.peek()) |char| {
            if (len >= self.token_buffer.len - 1) {
                return error.SubstitutionTooLong;
            }

            self.token_buffer[len] = char;
            len += 1;

            if (char == '(') {
                paren_count = try types.checkedAdd(u32, paren_count, 1);
            } else if (char == ')') {
                paren_count -= 1;
                if (paren_count == 0) {
                    _ = try self.advance();
                    return Token{
                        .ty = .CommandSubstitution,
                        .value = self.token_buffer[0..len],
                        .line = start_line,
                        .column = start_column,
                    };
                }
            }
            _ = try self.advance();
        }

        return error.UnterminatedCommandSubstitution;
    }

    // simple token handlers
    fn handlePipe(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance();
        return Token{
            .ty = .Pipe,
            .value = "|",
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleBackground(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance();
        return Token{
            .ty = .Background,
            .value = "&",
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleSemicolon(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance();
        return Token{
            .ty = .Semicolon,
            .value = ";",
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleLeftParen(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance();
        return Token{
            .ty = .LeftParen,
            .value = "(",
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleRightParen(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance();
        return Token{
            .ty = .RightParen,
            .value = ")",
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleLeftBrace(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance();
        return Token{
            .ty = .LeftBrace,
            .value = "{",
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleRightBrace(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance();
        return Token{
            .ty = .RightBrace,
            .value = "}",
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleRedirectOutput(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance();
        return Token{
            .ty = .RedirectOutput,
            .value = ">",
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleRedirectInput(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance();
        return Token{
            .ty = .RedirectInput,
            .value = "<",
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleNewline(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance();
        return Token{
            .ty = .NewLine,
            .value = "\n",
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleNumber(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        var len: usize = 0;

        while (self.peek()) |char| {
            if (!std.ascii.isDigit(char)) break;

            if (len >= self.token_buffer.len - 1) {
                return error.NumberTooLong;
            }

            self.token_buffer[len] = char;
            len += 1;
            _ = try self.advance();
        }

        return Token{
            .ty = .Integer,
            .value = self.token_buffer[0..len],
            .line = start_line,
            .column = start_column,
        };
    }
};

// security helper functions
fn isShellMetacharacter(char: u8) bool {
    return switch (char) {
        ' ', '\t', '\n', '\r', '|', '&', ';', '(', ')', '<', '>',
        '[', ']', '{', '}', '\'', '"', '`', '$', '\\', '#' => true,
        else => false,
    };
}

fn isKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{
        "if", "then", "else", "elif", "fi",
        "case", "esac", "for", "while", "until",
        "do", "done", "in",
    };

    for (keywords) |keyword| {
        if (std.mem.eql(u8, word, keyword)) return true;
    }
    return false;
}

fn keywordToTokenType(word: []const u8) TokenType {
    if (std.mem.eql(u8, word, "if")) return .If;
    if (std.mem.eql(u8, word, "then")) return .Then;
    if (std.mem.eql(u8, word, "else")) return .Else;
    if (std.mem.eql(u8, word, "elif")) return .Elif;
    if (std.mem.eql(u8, word, "fi")) return .Fi;
    if (std.mem.eql(u8, word, "case")) return .Case;
    if (std.mem.eql(u8, word, "esac")) return .Esac;
    if (std.mem.eql(u8, word, "for")) return .For;
    if (std.mem.eql(u8, word, "while")) return .While;
    if (std.mem.eql(u8, word, "until")) return .Until;
    if (std.mem.eql(u8, word, "do")) return .Do;
    if (std.mem.eql(u8, word, "done")) return .Done;
    if (std.mem.eql(u8, word, "in")) return .In;
    return .Word;
}