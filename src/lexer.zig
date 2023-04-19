// lexer.zig
// lexer.zig: Contains the lexer implementation to tokenize the input script.

const std = @import("std");

pub const TokenType = enum {
    Whitespace,
    Identifier,
    Integer,
    String,
    // Variables and expansions
    Dollar,
    ParameterExpansion,
    CommandSubstitution,
    ArithmeticExpansion,
    // Redirection
    RedirectInput,
    RedirectOutput,
    RedirectAppend,
    RedirectInputOutput,
    RedirectFd,
    // Pipes and background processes
    Pipe,
    Background,
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
    // Logical operators
    And,
    Or,
    Not,
    // Braces and brackets
    LeftParenthesis,
    RightParenthesis,
    LeftBrace,
    RightBrace,
    LeftBracket,
    RightBracket,
    DoubleLeftBracket,
    DoubleRightBracket,
    // Assignment
    Equals,
    // Special characters
    Semicolon,
    Backslash,
    Quote,
    DoubleQuote,
    Backquote,
    // Miscellaneous
    Shebang,
    Comment,
    // Eof
    Eof,
};

pub const Token = struct {
    ty: TokenType,
    value: []const u8,
    line: usize,
    column: usize,
};

pub fn tokenToString(token: *const Token) ![:0]const u8 {
    var buffer = try std.Buffer.initSize(std.heap.page_allocator, 0);
    defer buffer.deinit();

    try buffer.print("Token {{ .ty = {}, .value = \"{}\", .line = {}, .column = {} }}", .{
        token.ty,
        token.value,
        token.line,
        token.column,
    });

    return buffer.toOwnedSlice();
}

pub const Lexer = struct {
    input: []const u8,
    position: usize,
    line: usize,
    column: usize,
};

pub fn init(input: []const u8) Lexer {
    return Lexer{
        .input = input,
        .position = 0,
        .line = 1,
        .column = 1,
    };
}


pub fn nextToken(lexer: *Lexer) Token {
    while (lexer.position < lexer.input.len) {
        const char = lexer.input[lexer.position];

        switch (char) {
            // Whitespace handling
            ' ', '\t', '\n', '\r' => {
                const startPos = lexer.position;
                const tokenValue = advanceWhile(lexer, std.ascii.isSpace);
                return Token{
                    .ty = TokenType.Whitespace,
                    .value = tokenValue,
                    .line = lexer.line,
                    .column = startPos - lexer.column + 1,
                };
            },
            '0'...'9' => {
                const startPos = lexer.position;
                const tokenValue = advanceWhile(lexer, std.ascii.isDigit);
                return Token{
                    .ty = TokenType.Integer,
                    .value = tokenValue,
                    .line = lexer.line,
                    .column = startPos - lexer.column + 1,
                };
            },
            'a'...'z', 'A'...'Z', '_' => {
                // Identifier handling
            },
            '\'' => {
                // Single-quoted string handling
            },
            '"' => {
                // Double-quoted string handling
            },
            '$' => {
                // Variable and expansion handling
            },
            '|' => {
                // Pipe handling
            },
            '&' => {
                // Background process or logical AND handling
            },
            '>' => {
                // Redirection handling
            },
            '<' => {
                // Input redirection handling
            },
            ';' => {
                // Semicolon handling
            },
            // Other cases for different characters and token types
            else => {
                // Handle unknown characters
            },
        }
        // Add more cases for different characters and token types
        else => {
            // Handle unknown characters
            const tokenValue = advance(lexer);
            return Token{
                .ty = TokenType.Unknown,
                .value = tokenValue,
                .line = lexer.line,
                .column = lexer.position - lexer.column,
            };
        },
    }
}

return Token{ .ty = TokenType.Eof, .value = "", .line = lexer.line, .column = lexer.column };
}

fn advanceWhile(lexer: *Lexer, pred: fn (u8) bool) []const u8 {
    const start = lexer.position;
    while (lexer.position < lexer.input.len and pred(lexer.input[lexer.position])) {
        if (lexer.input[lexer.position] == '\n') {
            lexer.line += 1;
            lexer.column = 0;
        } else {
            lexer.column += 1;
        }
        lexer.position += 1;
    }
    return lexer.input[start..lexer.position];
}

fn advance(lexer: *Lexer) []const u8 {
    const start = lexer.position;
    if (lexer.input[lexer.position] == '\n') {
        lexer.line += 1;
        lexer.column = 0;
    } else {
        lexer.column += 1;
    }
    lexer.position += 1;
    return lexer.input[start..lexer.position];
}
