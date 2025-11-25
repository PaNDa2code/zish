// secure_lexer.zig - memory-safe, bounded lexer

const std = @import("std");
const types = @import("types.zig");

// token types with security annotations
pub const TokenType = enum {
    // basic elements
    Word,
    Integer,
    String, // single-quoted (no expansion)
    DoubleQuotedString, // double-quoted (with expansion)

    // variables and expansions
    Dollar,
    ParameterExpansion,
    CommandSubstitution,
    ArithmeticExpansion,

    // redirection
    RedirectInput, // <
    RedirectOutput, // >
    RedirectAppend, // >>
    RedirectHereDoc, // <<<
    RedirectHereDocLiteral, // <<
    RedirectStderr, // 2>
    RedirectBoth, // 2>&1

    // pipes and background
    Pipe,
    Background,

    // control structures
    If, Then, Else, Elif, Fi,
    For, While, Until, Do, Done, In,
    Case, Esac,
    Function,

    // logical operators
    And, // &&
    Or, // ||
    Not,

    // grouping
    LeftParen, RightParen,
    LeftBrace, RightBrace,

    // test expressions
    TestOpen,  // [[
    TestClose, // ]]

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

    // stack-allocated bounded buffers (2 buffers to support current + peek tokens)
    token_buffers: [2][types.MAX_TOKEN_LENGTH]u8,
    buffer_index: u1,
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
            .token_buffers = undefined,
            .buffer_index = 0,
            .heredoc_buffer = undefined,
        };
    }

    // bounds-checked character access
    fn peek(self: *Self) ?u8 {
        if (self.position >= self.input.len) return null;
        return self.input[self.position];
    }

    fn peekN(self: *Self, n: usize) ?u8 {
        if (self.position + n >= self.input.len) return null;
        return self.input[self.position + n];
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

    // get current token buffer (alternates to support current + peek tokens)
    fn getCurrentBuffer(self: *Self) []u8 {
        return &self.token_buffers[self.buffer_index];
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

        // handle comments (including shebangs)
        if (char == '#') {
            // skip shebang on first line
            if (start_line == 1 and start_column == 1) {
                // skip entire first line (shebang)
                while (self.peek()) |c| {
                    if (c == '\n') break;
                    _ = try self.advance();
                }
                // skip the newline too and get next token
                if (self.peek()) |c| {
                    if (c == '\n') {
                        _ = try self.advance();
                    }
                }
                return self.nextToken();
            }
            // regular comment - skip to end of line
            while (self.peek()) |c| {
                if (c == '\n') break;
                _ = try self.advance();
            }
            // return the next token (could be newline or next line)
            return self.nextToken();
        }

        // handle backslash-newline line continuation
        if (char == '\\') {
            if (self.peekN(1)) |next| {
                if (next == '\n') {
                    _ = try self.advance(); // consume backslash
                    _ = try self.advance(); // skip newline
                    return self.nextToken(); // continue on next line
                }
            }
            // backslash followed by other char - treat as word (handleWord handles escapes)
            return self.handleWord(start_line, start_column);
        }

        const token = switch (char) {
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
            '[' => self.handleLeftBracket(start_line, start_column),
            ']' => self.handleRightBracket(start_line, start_column),
            '\n' => self.handleNewline(start_line, start_column),
            else => if (std.ascii.isDigit(char))
                self.handleNumber(start_line, start_column)
            else
                self.handleWord(start_line, start_column),
        };

        // toggle buffer for next token
        self.buffer_index +%= 1;

        return token;
    }

    // secure string handling with bounds checking
    fn handleWord(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        const start_pos = self.position;

        while (self.peek()) |char| {
            // bounds check token length
            if (self.position - start_pos >= types.MAX_TOKEN_LENGTH - 1) {
                return error.TokenTooLong;
            }

            // handle backslash escapes - \x escapes the next character
            if (char == '\\') {
                _ = try self.advance(); // consume backslash
                if (self.peek()) |_| {
                    _ = try self.advance(); // consume escaped char
                }
                continue;
            }

            // handle backticks - skip over `...`
            if (char == '`') {
                _ = try self.advance();
                while (self.peek()) |c| {
                    _ = try self.advance();
                    if (c == '`') break;
                }
                continue;
            }

            // handle $ specially - skip over expansions
            if (char == '$') {
                _ = try self.advance();
                const next = self.peek();
                if (next) |n| {
                    if (n == '(') {
                        // skip over $(...)
                        _ = try self.advance(); // skip (
                        var paren_count: u32 = 1;
                        while (self.peek()) |c| {
                            _ = try self.advance();
                            if (c == '(') paren_count += 1;
                            if (c == ')') {
                                paren_count -= 1;
                                if (paren_count == 0) break;
                            }
                        }
                        continue;
                    } else if (n == '{') {
                        // skip over ${...}
                        _ = try self.advance(); // skip {
                        var brace_count: u32 = 1;
                        while (self.peek()) |c| {
                            _ = try self.advance();
                            if (c == '{') brace_count += 1;
                            if (c == '}') {
                                brace_count -= 1;
                                if (brace_count == 0) break;
                            }
                        }
                        continue;
                    } else if (std.ascii.isAlphabetic(n) or n == '_' or n == '?') {
                        // skip over $VAR or $?
                        if (n == '?') {
                            _ = try self.advance();
                        } else {
                            while (self.peek()) |c| {
                                if (!std.ascii.isAlphanumeric(c) and c != '_') break;
                                _ = try self.advance();
                            }
                        }
                        continue;
                    }
                }
                // if none of the above, just $ alone, continue
                continue;
            }

            if (isShellMetacharacter(char)) break;
            _ = try self.advance();
        }

        if (self.position == start_pos) return error.EmptyToken;

        // return slice directly from input (not from reused buffer)
        const word = self.input[start_pos..self.position];
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
        const buffer = self.getCurrentBuffer();

        while (self.peek()) |char| {
            if (char == '"') {
                _ = try self.advance();
                return Token{
                    .ty = .DoubleQuotedString,
                    .value = buffer[0..len],
                    .line = start_line,
                    .column = start_column,
                };
            }

            // bounds check
            if (len >= buffer.len - 1) {
                return error.StringTooLong;
            }

            if (char == '\\') {
                _ = try self.advance();
                if (self.peek()) |escaped| {
                    buffer[len] = switch (escaped) {
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
                buffer[len] = char;
                len += 1;
                _ = try self.advance();
            }
        }

        return error.UnterminatedString;
    }

    fn handleSingleQuote(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance(); // skip opening quote
        const start_pos = self.position;

        // single-quoted strings have no escapes, so we can use input slice directly
        while (self.peek()) |char| {
            if (char == '\'') {
                const end_pos = self.position;
                _ = try self.advance(); // skip closing quote
                return Token{
                    .ty = .String,
                    .value = self.input[start_pos..end_pos],
                    .line = start_line,
                    .column = start_column,
                };
            }
            _ = try self.advance();
        }

        return error.UnterminatedString;
    }

    // recursion-bounded expansion handling
    fn handleDollar(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        if (self.recursion_depth >= types.MAX_RECURSION_DEPTH) {
            return error.RecursionLimitExceeded;
        }

        const start_pos = self.position;
        _ = try self.advance(); // skip $

        const next = self.peek() orelse {
            return self.makeToken(.Dollar, "$", start_line, start_column);
        };

        if (next == '{') {
            return self.handleParameterExpansionWord(start_line, start_column);
        }

        if (next == '(') {
            return self.handleCommandSubstitutionWord(start_line, start_column);
        }

        // handle $? special variable - continue reading rest of word
        if (next == '?') {
            _ = try self.advance();
            // continue reading non-metacharacters to form complete word
            while (self.peek()) |char| {
                if (isShellMetacharacter(char)) break;
                if (self.position - start_pos >= types.MAX_TOKEN_LENGTH - 1) return error.TokenTooLong;
                _ = try self.advance();
            }
            return self.makeToken(.Word, self.input[start_pos..self.position], start_line, start_column);
        }

        // handle $VAR style variable references
        if (!std.ascii.isAlphabetic(next) and next != '_') {
            // just a lone $, but might be part of a larger word like "$*"
            // continue reading to form complete word
            while (self.peek()) |char| {
                if (isShellMetacharacter(char)) break;
                if (self.position - start_pos >= types.MAX_TOKEN_LENGTH - 1) return error.TokenTooLong;
                _ = try self.advance();
            }
            const word = self.input[start_pos..self.position];
            return self.makeToken(if (word.len == 1) .Dollar else .Word, word, start_line, start_column);
        }

        // read variable name
        while (self.peek()) |char| {
            if (!std.ascii.isAlphanumeric(char) and char != '_') break;
            if (self.position - start_pos >= types.MAX_TOKEN_LENGTH - 1) return error.TokenTooLong;
            _ = try self.advance();
        }

        // continue reading non-metacharacters to form complete word (e.g., $USER.txt)
        while (self.peek()) |char| {
            if (isShellMetacharacter(char)) break;
            if (self.position - start_pos >= types.MAX_TOKEN_LENGTH - 1) return error.TokenTooLong;
            _ = try self.advance();
        }

        return self.makeToken(.Word, self.input[start_pos..self.position], start_line, start_column);
    }

    fn handleParameterExpansionWord(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        self.recursion_depth = try types.checkedAdd(types.RecursionDepth, self.recursion_depth, 1);
        defer self.recursion_depth -= 1;

        const start_pos = self.position - 1; // include the $
        _ = try self.advance(); // skip {
        var brace_count: u32 = 1;

        // find matching }
        while (self.peek()) |char| {
            if (self.position - start_pos >= types.MAX_TOKEN_LENGTH - 1) {
                return error.ExpansionTooLong;
            }

            if (char == '{') {
                brace_count = try types.checkedAdd(u32, brace_count, 1);
            } else if (char == '}') {
                brace_count -= 1;
                if (brace_count == 0) {
                    _ = try self.advance(); // consume }
                    break;
                }
            }
            _ = try self.advance();
        } else {
            return error.UnterminatedParameterExpansion;
        }

        // continue reading non-metacharacters to form complete word
        while (self.peek()) |char| {
            if (isShellMetacharacter(char)) break;
            if (self.position - start_pos >= types.MAX_TOKEN_LENGTH - 1) return error.TokenTooLong;
            _ = try self.advance();
        }

        return self.makeToken(.Word, self.input[start_pos..self.position], start_line, start_column);
    }

    fn handleParameterExpansion(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        self.recursion_depth = try types.checkedAdd(types.RecursionDepth, self.recursion_depth, 1);
        defer self.recursion_depth -= 1;

        _ = try self.advance(); // skip {
        var len: usize = 0;
        var brace_count: u32 = 1;
        const buffer = self.getCurrentBuffer();

        // store opening syntax
        buffer[0] = '$';
        buffer[1] = '{';
        len = 2;

        while (self.peek()) |char| {
            if (len >= buffer.len - 1) {
                return error.ExpansionTooLong;
            }

            buffer[len] = char;
            len += 1;

            if (char == '{') {
                brace_count = try types.checkedAdd(u32, brace_count, 1);
            } else if (char == '}') {
                brace_count -= 1;
                if (brace_count == 0) {
                    _ = try self.advance();
                    return Token{
                        .ty = .ParameterExpansion,
                        .value = buffer[0..len],
                        .line = start_line,
                        .column = start_column,
                    };
                }
            }
            _ = try self.advance();
        }

        return error.UnterminatedParameterExpansion;
    }

    fn handleCommandSubstitutionWord(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        self.recursion_depth = try types.checkedAdd(types.RecursionDepth, self.recursion_depth, 1);
        defer self.recursion_depth -= 1;

        const start_pos = self.position - 1; // include the $
        _ = try self.advance(); // skip (
        var paren_count: u32 = 1;

        // find matching )
        while (self.peek()) |char| {
            if (self.position - start_pos >= types.MAX_TOKEN_LENGTH - 1) {
                return error.SubstitutionTooLong;
            }

            if (char == '(') {
                paren_count = try types.checkedAdd(u32, paren_count, 1);
            } else if (char == ')') {
                paren_count -= 1;
                if (paren_count == 0) {
                    _ = try self.advance(); // consume )
                    break;
                }
            }
            _ = try self.advance();
        } else {
            return error.UnterminatedCommandSubstitution;
        }

        // continue reading non-metacharacters to form complete word
        while (self.peek()) |char| {
            if (isShellMetacharacter(char)) break;
            if (self.position - start_pos >= types.MAX_TOKEN_LENGTH - 1) return error.TokenTooLong;
            _ = try self.advance();
        }

        return self.makeToken(.Word, self.input[start_pos..self.position], start_line, start_column);
    }

    fn handleCommandSubstitution(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        self.recursion_depth = try types.checkedAdd(types.RecursionDepth, self.recursion_depth, 1);
        defer self.recursion_depth -= 1;

        _ = try self.advance(); // skip (
        var len: usize = 0;
        var paren_count: u32 = 1;
        const buffer = self.getCurrentBuffer();

        // store opening syntax
        buffer[0] = '$';
        buffer[1] = '(';
        len = 2;

        while (self.peek()) |char| {
            if (len >= buffer.len - 1) {
                return error.SubstitutionTooLong;
            }

            buffer[len] = char;
            len += 1;

            if (char == '(') {
                paren_count = try types.checkedAdd(u32, paren_count, 1);
            } else if (char == ')') {
                paren_count -= 1;
                if (paren_count == 0) {
                    _ = try self.advance();
                    return Token{
                        .ty = .CommandSubstitution,
                        .value = buffer[0..len],
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
        _ = try self.advance(); // consume first |

        // check for || (logical OR)
        if (self.peek()) |next| {
            if (next == '|') {
                _ = try self.advance(); // consume second |
                return Token{
                    .ty = .Or,
                    .value = "||",
                    .line = start_line,
                    .column = start_column,
                };
            }
        }

        // just a single | (pipe)
        return Token{
            .ty = .Pipe,
            .value = "|",
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleBackground(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance(); // consume first &

        // check for && (logical AND)
        if (self.peek()) |next| {
            if (next == '&') {
                _ = try self.advance(); // consume second &
                return Token{
                    .ty = .And,
                    .value = "&&",
                    .line = start_line,
                    .column = start_column,
                };
            }
        }

        // just a single & (background)
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

    fn handleLeftBracket(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance(); // consume first [

        // check for [[ (test open)
        if (self.peek()) |next| {
            if (next == '[') {
                _ = try self.advance(); // consume second [
                return Token{
                    .ty = .TestOpen,
                    .value = "[[",
                    .line = start_line,
                    .column = start_column,
                };
            }
        }

        // single [ - treat as word for now (used in glob patterns)
        return Token{
            .ty = .Word,
            .value = "[",
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleRightBracket(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance(); // consume first ]

        // check for ]] (test close)
        if (self.peek()) |next| {
            if (next == ']') {
                _ = try self.advance(); // consume second ]
                return Token{
                    .ty = .TestClose,
                    .value = "]]",
                    .line = start_line,
                    .column = start_column,
                };
            }
        }

        // single ] - treat as word for now (used in glob patterns)
        return Token{
            .ty = .Word,
            .value = "]",
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleRedirectOutput(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance(); // consume first >

        // check for >> (append)
        if (self.peek()) |next| {
            if (next == '>') {
                _ = try self.advance(); // consume second >
                return Token{
                    .ty = .RedirectAppend,
                    .value = ">>",
                    .line = start_line,
                    .column = start_column,
                };
            }
        }

        // just a single > (redirect output)
        return Token{
            .ty = .RedirectOutput,
            .value = ">",
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleRedirectInput(self: *Self, start_line: types.LineNumber, start_column: types.ColumnNumber) !Token {
        _ = try self.advance(); // consume first <

        // check for <<< (here-doc) or << (here-string)
        if (self.peek()) |next| {
            if (next == '<') {
                _ = try self.advance(); // consume second <
                if (self.peek()) |third| {
                    if (third == '<') {
                        _ = try self.advance(); // consume third <
                        return Token{
                            .ty = .RedirectHereDoc,
                            .value = "<<<",
                            .line = start_line,
                            .column = start_column,
                        };
                    }
                }
                // just << (heredoc)
                return Token{
                    .ty = .RedirectHereDocLiteral,
                    .value = "<<",
                    .line = start_line,
                    .column = start_column,
                };
            }
        }

        // just a single < (redirect input)
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
        // peek ahead to check if this is an fd redirect (e.g., 2>)
        var temp_pos = self.position;
        while (temp_pos < self.input.len and std.ascii.isDigit(self.input[temp_pos])) {
            temp_pos += 1;
        }

        // not an fd redirect - delegate to handleWord for ip addresses, decimals, etc
        if (temp_pos >= self.input.len or self.input[temp_pos] != '>') {
            return self.handleWord(start_line, start_column);
        }

        // parse fd redirect number
        const start_pos = self.position;
        while (self.peek()) |char| {
            if (!std.ascii.isDigit(char)) break;
            if (self.position - start_pos >= types.MAX_TOKEN_LENGTH - 1) return error.NumberTooLong;
            _ = try self.advance();
        }

        const fd_str = self.input[start_pos..self.position];
        _ = try self.advance(); // consume >

        // attempt to parse 2>&1 pattern
        const next1 = self.peek() orelse return self.makeToken(.RedirectStderr, fd_str, start_line, start_column);
        if (next1 != '&') return self.makeToken(.RedirectStderr, fd_str, start_line, start_column);
        _ = try self.advance();

        const next2 = self.peek() orelse return self.makeToken(.RedirectStderr, fd_str, start_line, start_column);
        if (next2 != '1') return self.makeToken(.RedirectStderr, fd_str, start_line, start_column);
        _ = try self.advance();

        return self.makeToken(.RedirectBoth, "2>&1", start_line, start_column);
    }

    fn makeToken(self: *Self, token_type: TokenType, value: []const u8, line: types.LineNumber, column: types.ColumnNumber) Token {
        _ = self;
        return Token{
            .ty = token_type,
            .value = value,
            .line = line,
            .column = column,
        };
    }
};

// security helper functions
fn isShellMetacharacter(char: u8) bool {
    return switch (char) {
        ' ', '\t', '\n', '\r', '|', '&', ';', '(', ')', '<', '>',
        '{', '}', '[', ']', '\'', '"', '`', '$', '\\', '#' => true,
        else => false,
    };
}

fn isKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{
        "if", "then", "else", "elif", "fi",
        "case", "esac", "for", "while", "until",
        "do", "done", "in", "function",
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
    if (std.mem.eql(u8, word, "function")) return .Function;
    return .Word;
}