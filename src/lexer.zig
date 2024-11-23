// lexer.zig

const std = @import("std");

/// Token types covering all shell syntax elements
pub const TokenType = enum {
    // Basic elements
    Whitespace,
    Word,
    Integer,
    String,

    // Variables and expansions
    Dollar,
    ParameterExpansion, // ${...}
    CommandSubstitution, // $(...) or `...`
    ArithmeticExpansion, // $((...)
    ProcessSubstitution, // <(...) or >(...)

    // Redirection
    RedirectInput, // <
    RedirectOutput, // >
    RedirectAppend, // >>
    RedirectHereDoc, // <<
    RedirectHereString, // <<<
    RedirectInputOutput, // <>
    RedirectFd, // >&, <&

    // Pipes and background
    Pipe, // |
    PipeAnd, // |&
    Background, // &

    // Control structures
    If,
    Then,
    Else,
    Elif,
    Fi,
    Case,
    Esac,
    For,
    While,
    Until,
    Do,
    Done,
    In,
    Select,
    Function,
    Time,

    // Logical operators
    And, // &&
    Or, // ||
    Not, // !

    // Grouping
    LeftParen, // (
    RightParen, // )
    LeftBrace, // {
    RightBrace, // }
    LeftBracket, // [
    RightBracket, // ]
    DoubleLeftBracket, // [[
    DoubleRightBracket, // ]]

    // Assignment
    Equals, // =
    PlusEquals, // +=
    MinusEquals, // -=
    TimesEquals, // *=
    DivideEquals, // /=
    ModEquals, // %=

    // Special characters
    Semicolon, // ;
    DoubleSemicolon, // ;;
    Backslash, // \
    Quote, // '
    DoubleQuote, // "
    Backquote, // `

    // Miscellaneous
    Shebang, // #!
    Comment, // #
    NewLine, // \n
    Unknown,
    Eof,
};

/// Lexer errors that can occur during tokenization
pub const LexError = error{
    UnterminatedString,
    UnterminatedCommandSubstitution,
    UnterminatedParameterExpansion,
    UnterminatedArithmeticExpansion,
    UnterminatedProcessSubstitution,
    UnterminatedHereDoc,
    InvalidCharacter,
    UnexpectedEof,
    OutOfMemory,
};

/// Token structure representing a single lexical unit
pub const Token = struct {
    ty: TokenType,
    value: []const u8,
    line: usize,
    column: usize,

    /// Check if token matches a keyword
    pub fn isKeyword(self: Token, keyword: []const u8) bool {
        return std.mem.eql(u8, self.value, keyword);
    }

    /// Check if token is an operator
    pub fn isOperator(self: Token) bool {
        return switch (self.ty) {
            .And, .Or, .Not, .Pipe, .PipeAnd, .PlusEquals, .MinusEquals, .TimesEquals, .DivideEquals, .ModEquals => true,
            else => false,
        };
    }

    /// Check if token is a redirection operator
    pub fn isRedirect(self: Token) bool {
        return switch (self.ty) {
            .RedirectInput, .RedirectOutput, .RedirectAppend, .RedirectHereDoc, .RedirectHereString, .RedirectInputOutput, .RedirectFd => true,
            else => false,
        };
    }
};

/// Lexer state and methods
pub const Lexer = struct {
    input: []const u8,
    position: usize,
    line: usize,
    column: usize,
    allocator: std.mem.Allocator,
    here_doc_delimiter: ?[]const u8,

    const Self = @This();

    /// Initialize a new lexer
    pub fn init(allocator: std.mem.Allocator, input: []const u8) Self {
        return Self{
            .input = input,
            .position = 0,
            .line = 1,
            .column = 1,
            .allocator = allocator,
            .here_doc_delimiter = null,
        };
    }

    /// Clean up lexer resources
    pub fn deinit(self: *Self) void {
        if (self.here_doc_delimiter) |delim| {
            self.allocator.free(delim);
        }
    }

    /// Look at current character without advancing
    fn peek(self: *Self) ?u8 {
        if (self.position >= self.input.len) return null;
        return self.input[self.position];
    }

    /// Look at next character without advancing
    fn peekNext(self: *Self) ?u8 {
        if (self.position + 1 >= self.input.len) return null;
        return self.input[self.position + 1];
    }

    /// Advance position and return current character
    fn advance(self: *Self) ?u8 {
        if (self.position >= self.input.len) return null;
        const char = self.input[self.position];
        self.position += 1;

        if (char == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }

        return char;
    }

    /// Skip whitespace characters
    fn skipWhitespace(self: *Self) void {
        while (self.peek()) |char| {
            if (!std.ascii.isWhitespace(char)) break;
            _ = self.advance();
        }
    }

    /// Get next token from input
    pub fn nextToken(self: *Self) !Token {
        // Skip whitespace unless at start of line (important for here-docs)
        if (self.column != 1) {
            self.skipWhitespace();
        }

        // const start_pos = self.position;
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
            '#' => self.handleComment(),
            '$' => self.handleDollar(),
            '\'' => self.handleSingleQuote(),
            '"' => self.handleDoubleQuote(),
            '`' => self.handleBackquote(),
            '>' => self.handleRedirectOutput(),
            '<' => self.handleRedirectInput(),
            '|' => self.handlePipe(),
            '&' => self.handleBackground(),
            ';' => self.handleSemicolon(),
            '(' => self.handleLeftParen(),
            ')' => self.handleRightParen(),
            '{' => self.handleLeftBrace(),
            '}' => self.handleRightBrace(),
            '[' => self.handleLeftBracket(),
            ']' => self.handleRightBracket(),
            '=' => self.handleEquals(),
            '\\' => self.handleBackslash(),
            '!' => self.handleNot(),
            '\n' => self.handleNewline(),
            else => if (std.ascii.isDigit(char))
                self.handleNumber()
            else
                self.handleWord(),
        };
    }

    /// Handle shell comments
    fn handleComment(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance(); // Skip #

        // Check for shebang at start of file
        if (start_pos == 0 and self.peek() == '!') {
            _ = self.advance();
            while (self.peek()) |char| {
                if (char == '\n') break;
                _ = self.advance();
            }
            return Token{
                .ty = .Shebang,
                .value = self.input[start_pos..self.position],
                .line = start_line,
                .column = start_column,
            };
        }

        // Regular comment
        while (self.peek()) |char| {
            if (char == '\n') break;
            _ = self.advance();
        }

        return Token{
            .ty = .Comment,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    /// Handle variable expansions and command substitutions
    fn handleDollar(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance(); // Skip $

        // If no next character, return simple dollar token
        const next = self.peek() orelse {
            return makeToken(self, .Dollar, start_pos, start_line, start_column);
        };

        return switch (next) {
            '{' => self.handleParameterExpansion(start_pos, start_line, start_column),
            '(' => self.handleDollarExpansion(start_pos, start_line, start_column),
            else => makeToken(self, .Dollar, start_pos, start_line, start_column),
        };
    }

    // Handles $(...) and $((...)) expansions
    fn handleDollarExpansion(self: *Self, start_pos: usize, start_line: usize, start_column: usize) !Token {
        _ = self.advance(); // Skip (

        // Check for $(( which indicates arithmetic expansion
        if (self.peek() == '(') {
            return self.handleArithmeticExpansion(start_pos, start_line, start_column);
        }

        // Otherwise it's a command substitution $(...)
        return self.handleCommandSubstitution(start_pos, start_line, start_column);
    }

    fn handleParameterExpansion(self: *Self, start_pos: usize, start_line: usize, start_column: usize) !Token {
        _ = self.advance();

        var brace_count: usize = 1;
        while (self.peek()) |char| {
            if (char == '{') {
                brace_count += 1;
            } else if (char == '}') {
                brace_count -= 1;
                if (brace_count == 0) {
                    _ = self.advance();
                    break;
                }
            }
            _ = self.advance();
        }

        if (brace_count != 0) {
            return error.UnterminatedParameterExpansion;
        }

        return Token{
            .ty = .ParameterExpansion,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleCommandSubstitution(self: *Self, start_pos: usize, start_line: usize, start_column: usize) !Token {
        var paren_count: usize = 1;

        while (self.peek()) |char| {
            _ = self.advance();
            paren_count += @intFromBool(char == '(');
            paren_count -= @intFromBool(char == ')');
            if (paren_count == 0) break;
        }

        if (paren_count != 0) {
            return error.UnterminatedCommandSubstitution;
        }

        return makeToken(self, .CommandSubstitution, start_pos, start_line, start_column);
    }

    fn handleArithmeticExpansion(self: *Self, start_pos: usize, start_line: usize, start_column: usize) !Token {
        _ = self.advance(); // Skip second (
        var paren_count: usize = 2;

        while (self.peek()) |char| {
            _ = self.advance();
            paren_count += @intFromBool(char == '(');
            paren_count -= @intFromBool(char == ')');
            if (paren_count == 0) break;
        }

        if (paren_count != 0) {
            return error.UnterminatedArithmeticExpansion;
        }

        return makeToken(self, .ArithmeticExpansion, start_pos, start_line, start_column);
    }

    // Helper to create a token
    inline fn makeToken(self: *Self, ty: TokenType, start_pos: usize, start_line: usize, start_column: usize) Token {
        return Token{
            .ty = ty,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    /// Handle single-quoted strings
    fn handleSingleQuote(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance(); // Skip opening quote

        while (self.peek()) |char| {
            if (char == '\'') {
                _ = self.advance();
                return Token{
                    .ty = .String,
                    .value = self.input[start_pos..self.position],
                    .line = start_line,
                    .column = start_column,
                };
            }
            _ = self.advance();
        }

        return error.UnterminatedString;
    }

    /// Handle double-quoted strings
    fn handleDoubleQuote(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance(); // Skip opening quote

        while (self.peek()) |char| {
            if (char == '\\') {
                _ = self.advance();
                if (self.peek()) |_| {
                    _ = self.advance();
                }
                continue;
            }
            if (char == '"') {
                _ = self.advance();
                return Token{
                    .ty = .String,
                    .value = self.input[start_pos..self.position],
                    .line = start_line,
                    .column = start_column,
                };
            }
            _ = self.advance();
        }

        return error.UnterminatedString;
    }

    /// Handle backtick command substitution
    fn handleBackquote(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance(); // Skip opening backtick

        while (self.peek()) |char| {
            if (char == '\\') {
                _ = self.advance();
                if (self.peek()) |_| {
                    _ = self.advance();
                }
                continue;
            }
            if (char == '`') {
                _ = self.advance();
                return Token{
                    .ty = .CommandSubstitution,
                    .value = self.input[start_pos..self.position],
                    .line = start_line,
                    .column = start_column,
                };
            }
            _ = self.advance();
        }

        return error.UnterminatedCommandSubstitution;
    }

    /// Handle output redirection operators
    fn handleRedirectOutput(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance(); // Skip >

        // Use peek() without capturing the value
        if (self.peek()) |_| {
            switch (self.peek().?) {
                '>' => {
                    _ = self.advance();
                    return Token{
                        .ty = .RedirectAppend,
                        .value = self.input[start_pos..self.position],
                        .line = start_line,
                        .column = start_column,
                    };
                },
                '&' => {
                    _ = self.advance();
                    return Token{
                        .ty = .RedirectFd,
                        .value = self.input[start_pos..self.position],
                        .line = start_line,
                        .column = start_column,
                    };
                },
                else => {},
            }
        }

        return Token{
            .ty = .RedirectOutput,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    /// Handle input redirection operators
    fn handleRedirectInput(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance(); // Skip

        // Change this part:
        if (self.peek()) |_| { // Changed from |next| to |_|
            switch (self.peek().?) { // Access the value directly
                '<' => {
                    _ = self.advance();
                    if (self.peek() == '<') {
                        _ = self.advance();
                        return Token{
                            .ty = .RedirectHereString,
                            .value = self.input[start_pos..self.position],
                            .line = start_line,
                            .column = start_column,
                        };
                    }
                    return Token{
                        .ty = .RedirectHereDoc,
                        .value = self.input[start_pos..self.position],
                        .line = start_line,
                        .column = start_column,
                    };
                },
                '&' => {
                    _ = self.advance();
                    return Token{
                        .ty = .RedirectFd,
                        .value = self.input[start_pos..self.position],
                        .line = start_line,
                        .column = start_column,
                    };
                },
                '>' => {
                    _ = self.advance();
                    return Token{
                        .ty = .RedirectInputOutput,
                        .value = self.input[start_pos..self.position],
                        .line = start_line,
                        .column = start_column,
                    };
                },
                else => {},
            }
        }

        return Token{
            .ty = .RedirectInput,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    /// Handle pipe operators
    fn handlePipe(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance(); // Skip |

        if (self.peek()) |next| {
            switch (next) {
                '|' => {
                    _ = self.advance();
                    return Token{
                        .ty = .Or,
                        .value = self.input[start_pos..self.position],
                        .line = start_line,
                        .column = start_column,
                    };
                },
                '&' => {
                    _ = self.advance();
                    return Token{
                        .ty = .PipeAnd,
                        .value = self.input[start_pos..self.position],
                        .line = start_line,
                        .column = start_column,
                    };
                },
                else => {},
            }
        }

        return Token{
            .ty = .Pipe,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    /// Handle background and logical AND operators
    fn handleBackground(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance(); // Skip &

        if (self.peek()) |next| {
            if (next == '&') {
                _ = self.advance();
                return Token{
                    .ty = .And,
                    .value = self.input[start_pos..self.position],
                    .line = start_line,
                    .column = start_column,
                };
            }
        }

        return Token{
            .ty = .Background,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    /// Handle semicolon operators
    fn handleSemicolon(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance(); // Skip ;

        if (self.peek()) |next| {
            if (next == ';') {
                _ = self.advance();
                return Token{
                    .ty = .DoubleSemicolon,
                    .value = self.input[start_pos..self.position],
                    .line = start_line,
                    .column = start_column,
                };
            }
        }

        return Token{
            .ty = .Semicolon,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    /// Handle parentheses and subshells
    fn handleLeftParen(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance();

        return Token{
            .ty = .LeftParen,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleRightParen(self: *Self) !Token {
        const start_line = self.line;
        const start_column = self.column;
        const start_pos = self.position;

        _ = self.advance();

        return Token{
            .ty = .RightParen,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    /// Handle braces for command grouping
    fn handleLeftBrace(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance();

        return Token{
            .ty = .LeftBrace,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleRightBrace(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance();

        return Token{
            .ty = .RightBrace,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    /// Handle test brackets
    fn handleLeftBracket(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance();

        if (self.peek()) |next| {
            if (next == '[') {
                _ = self.advance();
                return Token{
                    .ty = .DoubleLeftBracket,
                    .value = self.input[start_pos..self.position],
                    .line = start_line,
                    .column = start_column,
                };
            }
        }

        return Token{
            .ty = .LeftBracket,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    fn handleRightBracket(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance();

        if (self.peek()) |next| {
            if (next == ']') {
                _ = self.advance();
                return Token{
                    .ty = .DoubleRightBracket,
                    .value = self.input[start_pos..self.position],
                    .line = start_line,
                    .column = start_column,
                };
            }
        }

        return Token{
            .ty = .RightBracket,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    /// Handle assignment operators
    fn handleEquals(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance(); // Skip =

        return Token{
            .ty = .Equals,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    /// Handle escape sequences
    fn handleBackslash(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance();
        if (self.peek()) |_| {
            _ = self.advance();
        }

        return Token{
            .ty = .Backslash,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    /// Handle logical NOT operator
    fn handleNot(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance();

        return Token{
            .ty = .Not,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    /// Handle newlines
    fn handleNewline(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        _ = self.advance();

        return Token{
            .ty = .NewLine,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    /// Handle numeric literals
    fn handleNumber(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        while (self.peek()) |char| {
            if (!std.ascii.isDigit(char)) break;
            _ = self.advance();
        }

        return Token{
            .ty = .Integer,
            .value = self.input[start_pos..self.position],
            .line = start_line,
            .column = start_column,
        };
    }

    /// Handle shell words and keywords
    fn handleWord(self: *Self) !Token {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        while (self.peek()) |char| {
            if (isShellMetacharacter(char)) break;
            _ = self.advance();
        }

        const word = self.input[start_pos..self.position];
        const token_type = if (isKeyword(word)) keywordToTokenType(word) else .Word;

        return Token{
            .ty = token_type,
            .value = word,
            .line = start_line,
            .column = start_column,
        };
    }

    /// Check if character is a shell metacharacter
    fn isShellMetacharacter(char: u8) bool {
        return switch (char) {
            ' ',
            '\t',
            '\n',
            '\r', // whitespace
            '|',
            '&',
            ';',
            '(',
            ')',
            '<',
            '>', // operators
            '[',
            ']',
            '{',
            '}', // grouping
            '\'',
            '"',
            '`', // quotes
            '$',
            '\\', // special
            '#', // comment
            '=', // assignment
            => true,
            else => false,
        };
    }

    /// Check if word is a shell keyword
    fn isKeyword(word: []const u8) bool {
        const keywords = [_][]const u8{
            "if",     "then", "else", "elif",     "fi",
            "case",   "esac", "for",  "while",    "until",
            "do",     "done", "in",   "function", "time",
            "select",
        };

        for (keywords) |keyword| {
            if (std.mem.eql(u8, word, keyword)) return true;
        }
        return false;
    }

    /// Convert keyword to corresponding token type
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
        if (std.mem.eql(u8, word, "time")) return .Time;
        if (std.mem.eql(u8, word, "select")) return .Select;
        return .Word;
    }

    /// Handle heredoc content
    fn handleHereDoc(self: *Self, delimiter: []const u8) !Token {
        const start_line = self.line;
        const start_column = self.column;

        var content = std.ArrayList(u8).init(self.allocator);
        defer content.deinit();

        var line_start = true;
        while (self.peek()) |char| {
            if (line_start) {
                // Check if we've reached the delimiter
                const remaining = self.input[self.position..];
                if (std.mem.startsWith(u8, remaining, delimiter)) {
                    const delim_end = self.position + delimiter.len;
                    if (delim_end >= self.input.len or
                        self.input[delim_end] == '\n' or
                        self.input[delim_end] == '\r')
                    {
                        break;
                    }
                }
            }

            try content.append(char);
            _ = self.advance();
            line_start = (char == '\n');
        }

        // Skip the delimiter
        self.position += delimiter.len;
        if (self.peek()) |char| {
            if (char == '\r') _ = self.advance();
            if (self.peek() == '\n') _ = self.advance();
        }

        const token_value = try self.allocator.dupe(u8, content.items);
        return Token{
            .ty = .String,
            .value = token_value,
            .line = start_line,
            .column = start_column,
        };
    }

    /// Process potential operator or word characters
    fn handleOperatorOrWord(self: *Self) !Token {
        const start_line = self.line;
        const start_column = self.column;

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        while (self.peek()) |char| {
            if (isShellMetacharacter(char)) break;
            try buf.append(char);
            _ = self.advance();
        }

        const word = buf.items;
        const token_type = blk: {
            if (word.len == 0) break :blk .Unknown;
            if (isKeyword(word)) break :blk keywordToTokenType(word);
            break :blk .Word;
        };

        return Token{
            .ty = token_type,
            .value = try self.allocator.dupe(u8, word),
            .line = start_line,
            .column = start_column,
        };
    }

    /// Process a full quoted string including escape sequences
    fn processQuotedString(self: *Self, delimiter: u8) ![]u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        while (self.peek()) |char| {
            if (char == delimiter) {
                _ = self.advance();
                break;
            }

            if (char == '\\' and delimiter == '"') {
                _ = self.advance();
                if (self.peek()) |next| {
                    switch (next) {
                        '\\', '"', '$', '`' => {
                            try buf.append(next);
                            _ = self.advance();
                        },
                        'n' => {
                            try buf.append('\n');
                            _ = self.advance();
                        },
                        't' => {
                            try buf.append('\t');
                            _ = self.advance();
                        },
                        else => {
                            try buf.append('\\');
                            try buf.append(next);
                            _ = self.advance();
                        },
                    }
                }
                continue;
            }

            try buf.append(char);
            _ = self.advance();
        }

        return buf.toOwnedSlice();
    }

    /// Process a parameter expansion ${...}
    fn processParameterExpansion(self: *Self) ![]u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        var brace_count: usize = 1;
        while (self.peek()) |char| {
            if (char == '{') {
                brace_count += 1;
            } else if (char == '}') {
                brace_count -= 1;
                if (brace_count == 0) {
                    _ = self.advance();
                    break;
                }
            }
            try buf.append(char);
            _ = self.advance();
        }

        if (brace_count != 0) return error.UnterminatedParameterExpansion;
        return buf.toOwnedSlice();
    }

    /// Get version information and token stats
    pub const version = struct {
        pub const major = 0;
        pub const minor = 1;
        pub const patch = 0;
        pub const git_revision = "unknown";

        pub fn format(
            _: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try writer.print("zish lexer v{d}.{d}.{d}-{s}", .{
                major, minor, patch, git_revision,
            });
        }
    };
};

test "basic lexer functionality" {
    const allocator = std.testing.allocator;

    // Test simple command
    {
        const input = "ls -la";
        var lexer = Lexer.init(allocator, input);
        defer lexer.deinit();

        const token1 = try lexer.nextToken();
        try std.testing.expectEqual(TokenType.Word, token1.ty);
        try std.testing.expectEqualStrings("ls", token1.value);

        const token2 = try lexer.nextToken();
        try std.testing.expectEqual(TokenType.Word, token2.ty);
        try std.testing.expectEqualStrings("-la", token2.value);

        const token3 = try lexer.nextToken();
        try std.testing.expectEqual(TokenType.Eof, token3.ty);
    }

    // Test pipe and redirection
    {
        const input = "echo hello | grep o > output.txt";
        var lexer = Lexer.init(allocator, input);
        defer lexer.deinit();

        const tokens = [_]TokenType{
            .Word,           .Word, .Pipe, .Word, .Word,
            .RedirectOutput, .Word, .Eof,
        };

        for (tokens) |expected_type| {
            const token = try lexer.nextToken();
            try std.testing.expectEqual(expected_type, token.ty);
        }
    }

    // Test variable expansion
    {
        const input = "echo $HOME ${PATH} $(pwd)";
        var lexer = Lexer.init(allocator, input);
        defer lexer.deinit();

        const tokens = [_]TokenType{
            .Word,               .Dollar,              .Word,
            .ParameterExpansion, .CommandSubstitution, .Eof,
        };

        for (tokens) |expected_type| {
            const token = try lexer.nextToken();
            try std.testing.expectEqual(expected_type, token.ty);
        }
    }
}

// Export the main components
pub const LexerToken = Token;
pub const LexerTokenType = TokenType;
pub const LexerErrors = LexError;
