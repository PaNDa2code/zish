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

// A table-driven lexer.
// In this approach, we define a table that maps characters to their
// corresponding token types and functions to handle the respective token types.

const CharacterHandler = struct {
    ty: TokenType,
    handler: fn (*Lexer) Token,
};

const character_handlers: [256]CharacterHandler = initCharacterHandlers();

pub fn initCharacterHandlers() [256]CharacterHandler {
    var table: [256]CharacterHandler = undefined;
    for (table) |*item| {
        item.* = CharacterHandler{ .ty = TokenType.Unknown, .handler = handleUnknown };
    }

    // Handle whitespace
    table[' '.ord()] = CharacterHandler{ .ty = TokenType.Whitespace, .handler = handleWhitespace };
    table['\t'.ord()] = CharacterHandler{ .ty = TokenType.Whitespace, .handler = handleWhitespace };
    table['\n'.ord()] = CharacterHandler{ .ty = TokenType.Whitespace, .handler = handleWhitespace };
    table['\r'.ord()] = CharacterHandler{ .ty = TokenType.Whitespace, .handler = handleWhitespace };

    for (std.ascii.digit) |digit| {
        table[digit.ord()] = CharacterHandler{ .ty = TokenType.Integer, .handler = handleInteger };
    }

    for (std.ascii.alpha) |alpha| {
        table[alpha.ord()] = CharacterHandler{ .ty = TokenType.Identifier, .handler = handleIdentifier };
    }

    // Handle single-character tokens
    table['('.ord()] = CharacterHandler{ .ty = TokenType.LeftParen, .handler = handleSingleCharToken };
    table[')'.ord()] = CharacterHandler{ .ty = TokenType.RightParen, .handler = handleSingleCharToken };
    table['['.ord()] = CharacterHandler{ .ty = TokenType.LeftBracket, .handler = handleSingleCharToken };
    table[']'.ord()] = CharacterHandler{ .ty = TokenType.RightBracket, .handler = handleSingleCharToken };
    table['{'.ord()] = CharacterHandler{ .ty = TokenType.LeftBrace, .handler = handleSingleCharToken };
    table['}'.ord()] = CharacterHandler{ .ty = TokenType.RightBrace, .handler = handleSingleCharToken };
    table[';'.ord()] = CharacterHandler{ .ty = TokenType.Semicolon, .handler = handleSingleCharToken };
    table['|'.ord()] = CharacterHandler{ .ty = TokenType.Pipe, .handler = handleSingleCharToken };
    table['<'.ord()] = CharacterHandler{ .ty = TokenType.LessThan, .handler = handleSingleCharToken };
    table['>'.ord()] = CharacterHandler{ .ty = TokenType.GreaterThan, .handler = handleSingleCharToken };
    table['&'.ord()] = CharacterHandler{ .ty = TokenType.And, .handler = handleDoubleCharToken };
    table['|'.ord()] = CharacterHandler{ .ty = TokenType.Or, .handler = handleDoubleCharToken };
    table['$'.ord()] = CharacterHandler{ .ty = TokenType.Dollar, .handler = handleDollar };
    table['`'.ord()] = CharacterHandler{ .ty = TokenType.Backquote, .handler = handleBackquote };
    table['\''.ord()] = CharacterHandler{ .ty = TokenType.Quote, .handler = handleQuote };
    table['"'.ord()] = CharacterHandler{ .ty = TokenType.DoubleQuote, .handler = handleDoubleQuote };
    table['='.ord()] = CharacterHandler{ .ty = TokenType.Equals, .handler = handleSingleCharToken };
    table['#'.ord()] = CharacterHandler{ .ty = TokenType.Comment, .handler = handleComment };

    

    return table;
}

fn handleUnknown(lexer: *Lexer) Token {
    const startPos = lexer.position;
    const tokenValue = advance(lexer);
    return Token{
        .ty = TokenType.Unknown,
        .value = tokenValue,
        .line = lexer.line,
        .column = startPos - lexer.column + 1,
    };
}

fn handleWhitespace(lexer: *Lexer) Token {
    const startPos = lexer.position;
    const tokenValue = advanceWhile(lexer, std.ascii.isSpace);
    return Token{
        .ty = TokenType.Whitespace,
        .value = tokenValue,
        .line = lexer.line,
        .column = startPos - lexer.column + 1,
    };
}

fn handleInteger(lexer: *Lexer) Token {
    const startPos = lexer.position;
    const tokenValue = advanceWhile(lexer, std.ascii.isDigit);
    return Token{
        .ty = TokenType.Integer,
        .value = tokenValue,
        .line = lexer.line,
        .column = startPos - lexer.column + 1,
    };
}

fn handleIdentifier(lexer: *Lexer) Token {
    const startPos = lexer.position;
    const tokenValue = advanceWhile(lexer, std.ascii.isAlnum);
    return Token{
        .ty = TokenType.Identifier,
        .value = tokenValue,
        .line = lexer.line,
        .column = startPos - lexer.column + 1,
    };
}

fn handleSingleCharToken(lexer: *Lexer) Token {
    const startPos = lexer.position;
    const tokenValue = advance(lexer);
    const tokenType = character_handlers[tokenValue.ord()].ty;
    return Token{
        .ty = tokenType,
        .value = tokenValue,
        .line = lexer.line,
        .column = startPos - lexer.column + 1,
    };
}

fn handleDoubleCharToken(lexer: *Lexer) Token {
    const startPos = lexer.position;
    const firstChar = lexer.input[lexer.position];
    advance(lexer);
    const secondChar = lexer.input[lexer.position];

    const tokenType = if (firstChar == secondChar) character_handlers[firstChar.ord()].ty else TokenType.Unknown;
    const tokenValue = tokenType != TokenType.Unknown ? advance(lexer) : firstChar;

    return Token{
        .ty = tokenType,
        .value = tokenValue,
        .line = lexer.line,
        .column = startPos - lexer.column + 1,
    };
}


fn handleDollar(lexer: *Lexer) Token {
    const startPos = lexer.position;
    advance(lexer); // consume '$'

    if (lexer.position < lexer.input.len) {
        const nextChar = lexer.input[lexer.position];

        if (nextChar == '{') {
            advance(lexer); // consume '{'
            return Token{
                .ty = TokenType.ParameterExpansion,
                .value = "{}",
                .line = lexer.line,
                .column = startPos - lexer.column + 1,
            };
        } else if (nextChar == '(') {
            advance(lexer); // consume '('

            if (lexer.position < lexer.input.len && lexer.input[lexer.position] == '(') {
                advance(lexer); // consume second '('
                return Token{
                    .ty = TokenType.ArithmeticExpansion,
                    .value = "$((",
                    .line = lexer.line,
                    .column = startPos - lexer.column + 1,
                };
            } else {
                return Token{
                    .ty = TokenType.CommandSubstitution,
                    .value = "$(",
                    .line = lexer.line,
                    .column = startPos - lexer.column + 1,
                };
            }
        }
    }

    return Token{
        .ty = TokenType.Dollar,
        .value = "$",
        .line = lexer.line,
        .column = startPos - lexer.column + 1,
    };
}


fn handleBackquote(lexer: *Lexer) Token {
    const startPos = lexer.position;
    advance(lexer); // consume '`'
    
    const tokenValue = advanceWhile(lexer, |ch| ch != '`');
    
    if (lexer.position < lexer.input.len && lexer.input[lexer.position] == '`') {
        advance(lexer); // consume closing '`'
    }

    return Token{
        .ty = TokenType.CommandSubstitution,
        .value = tokenValue,
        .line = lexer.line,
        .column = startPos - lexer.column + 1,
    };
}

fn handleQuote(lexer: *Lexer) Token {
    const startPos = lexer.position;
    advance(lexer); // consume single quote
    
    const tokenValue = advanceWhile(lexer, |ch| ch != '\'');
    
    if (lexer.position < lexer.input.len && lexer.input[lexer.position] == '\'') {
        advance(lexer); // consume closing single quote
    }

    return Token{
        .ty = TokenType.String,
        .value = tokenValue,
        .line = lexer.line,
        .column = startPos - lexer.column + 1,
    };
}

fn handleDoubleQuote(lexer: *Lexer) Token {
    const startPos = lexer.position;
    advance(lexer); // consume double quote

    const tokenValue = advanceWhile(lexer, |ch| ch != '"' && (ch != '\\' || (lexer.position + 1 < lexer.input.len && lexer.input[lexer.position + 1] != '"')));

    // Handle escaped double quotes and other escape sequences within the double-quoted string
    while (lexer.position < lexer.input.len && lexer.input[lexer.position] != '"') {
        if (lexer.input[lexer.position] == '\\') {
            advance(lexer); // consume backslash
        }
        advance(lexer); // consume escaped character
    }

    if (lexer.position < lexer.input.len && lexer.input[lexer.position] == '"') {
        advance(lexer); // consume closing double quote
    }

    return Token{
        .ty = TokenType.String,
        .value = tokenValue,
        .line = lexer.line,
        .column = startPos - lexer.column + 1,
    };
}

fn handleComment(lexer: *Lexer) Token {
    const startPos = lexer.position;
    advance(lexer); // consume '#'
    const tokenValue = advanceWhile(lexer, |ch| ch != '\n');

    return Token{
        .ty = TokenType.Comment,
        .value = tokenValue,
        .line = lexer.line,
        .column = startPos - lexer.column + 1,
    };
}

pub fn nextToken(lexer: *Lexer) Token {
    while (lexer.position < lexer.input.len) {
        const char = lexer.input[lexer.position];
        const handler = character_handlers[char.ord()];
        return handler.handler(lexer);
    }

    return Token{ .ty = TokenType.Eof, .value = "", .line = lexer.line, .column = lexer.column };
}

