// parser.zig

const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const Token = lexer.LexerToken;
const TokenType = lexer.LexerTokenType;
const LexError = lexer.LexerErrors;

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidSyntax,
    OutOfMemory,
};

pub const Parser = struct {
    lexer: *lexer.Lexer,
    allocator: std.mem.Allocator,
    current_token: ?Token,
    peek_token: ?Token,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, lex: *lexer.Lexer) !Self {
        var parser = Self{
            .lexer = lex,
            .allocator = allocator,
            .current_token = null,
            .peek_token = null,
        };
        // Prime the parser with first two tokens
        _ = try parser.nextToken();
        _ = try parser.nextToken();
        return parser;
    }

    pub fn deinit(self: *Self) void {
        _ = self; // TODO:Mark as used until we implement cleanup
    }

    fn nextToken(self: *Self) !?Token {
        self.current_token = self.peek_token;
        self.peek_token = try self.lexer.nextToken();
        return self.current_token;
    }

    pub fn parse(self: *Self) !*ast.Node {
        var nodes = std.ArrayList(*ast.Node).init(self.allocator);
        defer nodes.deinit();

        while (self.current_token != null and self.current_token.?.ty != .Eof) {
            const node = try self.parseCommand();
            try nodes.append(node);

            if (self.current_token) |token| {
                switch (token.ty) {
                    .Semicolon, .NewLine => _ = try self.nextToken(),
                    else => {},
                }
            }
        }

        // If we only have one command, return it directly
        if (nodes.items.len == 1) {
            return nodes.items[0];
        }

        // Otherwise, create a List node
        const list = try ast.Node.init(
            self.allocator,
            .List,
            null,
            if (nodes.items.len > 0) nodes.items[0].line else 1,
            if (nodes.items.len > 0) nodes.items[0].column else 1,
        );

        try list.children.appendSlice(nodes.items);
        return list;
    }

    fn parseCommand(self: *Self) !*ast.Node {
        const token = self.current_token orelse return error.UnexpectedEof;

        return switch (token.ty) {
            .If => self.parseIf(),
            .While => self.parseWhile(),
            .Until => self.parseUntil(),
            .For => self.parseFor(),
            .Case => self.parseCase(),
            .Function => self.parseFunction(),
            .LeftBrace => self.parseGroup(),
            .LeftParen => self.parseSubshell(),
            else => self.parseSimpleCommand(),
        };
    }

    fn parseSimpleCommand(self: *Self) !*ast.Node {
        const start_token = self.current_token orelse return error.UnexpectedEof;

        var cmd = try ast.Node.init(
            self.allocator,
            .Command,
            null,
            start_token.line,
            start_token.column,
        );
        errdefer cmd.deinit(self.allocator);

        // Parse assignments that precede the command
        while (self.current_token) |token| {
            if (token.ty == .Word) {
                const peek = self.peek_token orelse return error.UnexpectedEof;
                if (peek.ty == .Equals) {
                    const assign = try self.parseAssignment();
                    try cmd.children.append(assign);
                    continue;
                }
            }
            break;
        }

        // Parse command words
        while (self.current_token) |token| {
            switch (token.ty) {
                .Word, .String, .Integer => {
                    const word = try self.parseWord();
                    try cmd.children.append(word);
                },
                .RedirectInput, .RedirectOutput, .RedirectAppend, .RedirectHereDoc, .RedirectHereString => {
                    const redirect = try self.parseRedirect();
                    try cmd.redirects.append(redirect);
                },
                else => break,
            }
        }

        if (cmd.children.items.len == 0 and cmd.redirects.items.len == 0) {
            return error.InvalidSyntax;
        }

        return cmd;
    }

    // Implement other parsing methods...

    fn parseWord(self: *Self) !*ast.Node {
        const token = self.current_token orelse return error.UnexpectedEof;

        const word = try ast.Node.init(
            self.allocator,
            .Word,
            token.value,
            token.line,
            token.column,
        );

        _ = try self.nextToken();
        return word;
    }

    fn parseRedirect(self: *Self) !*ast.RedirectNode {
        const token = self.current_token orelse return error.UnexpectedEof;

        const redirect_type: ast.RedirectType = switch (token.ty) {
            .RedirectInput => .Input,
            .RedirectOutput => .Output,
            .RedirectAppend => .Append,
            .RedirectHereDoc => .HereDoc,
            .RedirectHereString => .HereString,
            else => return error.InvalidSyntax,
        };

        _ = try self.nextToken();

        const target = try self.parseWord();

        return ast.RedirectNode.init(
            self.allocator,
            redirect_type,
            null,
            target,
            token.line,
            token.column,
        );
    }
};
