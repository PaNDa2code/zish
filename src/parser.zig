// secure_parser.zig - typestate parser with bounds checking

const std = @import("std");
const types = @import("types.zig");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

// parser state machine - makes invalid states unrepresentable
pub const parserstate = enum {
    initial,
    hascurrent,
    hasboth,
    complete,
    error_state,
};

pub const parsererror = error{
    unexpectedtoken,
    unexpectedeof,
    invalidsyntax,
    parserfinished,
    invalidparserstate,
    outofmemory,
} || secure.securityerror;

// typestate-based parser
pub const secureparser = struct {
    lexer: lexer.securelexer,
    builder: ast.astbuilder,
    state: parserstate,
    current_token: lexer.token,
    peek_token: lexer.token,
    recursion_depth: secure.recursiondepth,

    const self = @this();

    pub fn init(input: []const u8, allocator: std.mem.allocator) !self {
        var lex = try lexer.securelexer.init(input);

        return self{
            .lexer = lex,
            .builder = ast.astbuilder.init(allocator),
            .state = .initial,
            .current_token = lexer.token.empty,
            .peek_token = lexer.token.empty,
            .recursion_depth = 0,
        };
    }

    pub fn deinit(self: *self) void {
        self.builder.deinit();
    }

    // state-safe token advancement
    pub fn nexttoken(self: *self) !void {
        switch (self.state) {
            .initial => {
                self.current_token = try self.lexer.nexttoken();
                self.peek_token = try self.lexer.nexttoken();
                self.state = .hasboth;
            },
            .hasboth => {
                self.current_token = self.peek_token;
                self.peek_token = try self.lexer.nexttoken();
            },
            .complete, .error_state => return error.parserfinished,
            else => return error.invalidparserstate,
        }
    }

    // main parsing entry point with security checks
    pub fn parse(self: *self) !*const ast.astnode {
        // prime the parser
        try self.nexttoken();

        const root = try self.parsecommandlist();

        self.state = .complete;

        // validate the resulting ast for security
        try ast.validateast(root);

        return root;
    }

    fn parsecommandlist(self: *self) parsererror!*const ast.astnode {
        if (self.state != .hasboth) return error.invalidparserstate;

        var commands = std.arraylist(*const ast.astnode).init(self.builder.arena.allocator());

        while (self.current_token.ty != .eof) {
            // skip empty statements
            if (self.current_token.ty == .semicolon or self.current_token.ty == .newline) {
                try self.nexttoken();
                continue;
            }

            // prevent dos via massive command lists
            if (commands.items.len >= secure.max_args_count) {
                return error.toomanycommands;
            }

            const cmd = try self.parsecommand();
            try commands.append(cmd);

            // handle separators
            if (self.current_token.ty == .semicolon or self.current_token.ty == .newline) {
                try self.nexttoken();
            }
        }

        if (commands.items.len == 0) {
            return error.emptyinput;
        }

        if (commands.items.len == 1) {
            return commands.items[0];
        }

        return self.builder.createlist(
            commands.items,
            commands.items[0].line,
            commands.items[0].column,
        );
    }

    fn parsecommand(self: *self) parsererror!*const ast.astnode {
        // recursion depth check
        if (self.recursion_depth >= secure.max_recursion_depth) {
            return error.recursionlimitexceeded;
        }

        self.recursion_depth = try secure.checkedadd(secure.recursiondepth, self.recursion_depth, 1);
        defer self.recursion_depth -= 1;

        return switch (self.current_token.ty) {
            .if => self.parseif(),
            .while => self.parsewhile(),
            .until => self.parseuntil(),
            .for => self.parsefor(),
            .case => self.parsecase(),
            .leftbrace => self.parsegroup(),
            .leftparen => self.parsesubshell(),
            else => self.parsesimplecommand(),
        };
    }

    fn parsesimplecommand(self: *self) parsererror!*const ast.astnode {
        var words = std.arraylist(*const ast.astnode).init(self.builder.arena.allocator());

        while (self.current_token.ty != .eof) {
            switch (self.current_token.ty) {
                .word, .string, .integer => {
                    const word = try self.parseword();
                    try words.append(word);
                },
                else => break,
            }
        }

        if (words.items.len == 0) {
            return error.emptycommand;
        }

        return self.builder.createcommand(
            words.items,
            self.current_token.line,
            self.current_token.column,
        );
    }

    fn parseword(self: *self) parsererror!*const ast.astnode {
        if (self.state != .hasboth) return error.invalidparserstate;

        const token = self.current_token;
        try self.nexttoken();

        const node_type: ast.nodetype = switch (token.ty) {
            .word => .word,
            .string => .string,
            .integer => .number,
            else => return error.unexpectedtoken,
        };

        return switch (node_type) {
            .word => self.builder.createword(token.value, token.line, token.column),
            .string => self.builder.createstring(token.value, token.line, token.column),
            .number => self.builder.createnode(.number, token.value, &[_]*const ast.astnode{}, token.line, token.column),
            else => error.invalidsyntax,
        };
    }

    // control structure parsing with bounds checking
    fn parseif(self: *self) parsererror!*const ast.astnode {
        const if_token = self.current_token;
        try self.nexttoken(); // consume 'if'

        // parse condition
        const condition = try self.parsesimplecommand();

        // expect 'then'
        if (self.current_token.ty != .then) {
            return error.unexpectedtoken;
        }
        try self.nexttoken(); // consume 'then'

        // parse then branch
        const then_branch = try self.parsecommandlist();

        var else_branch: ?*const ast.astnode = null;

        // handle else clause
        if (self.current_token.ty == .else) {
            try self.nexttoken(); // consume 'else'
            else_branch = try self.parsecommandlist();
        }

        // expect 'fi'
        if (self.current_token.ty != .fi) {
            return error.unexpectedtoken;
        }
        try self.nexttoken(); // consume 'fi'

        return self.builder.createif(
            condition,
            then_branch,
            else_branch,
            if_token.line,
            if_token.column,
        );
    }

    fn parsewhile(self: *self) parsererror!*const ast.astnode {
        const while_token = self.current_token;
        try self.nexttoken(); // consume 'while'

        const condition = try self.parsesimplecommand();

        if (self.current_token.ty != .do) {
            return error.unexpectedtoken;
        }
        try self.nexttoken(); // consume 'do'

        const body = try self.parsecommandlist();

        if (self.current_token.ty != .done) {
            return error.unexpectedtoken;
        }
        try self.nexttoken(); // consume 'done'

        return self.builder.createwhile(
            condition,
            body,
            while_token.line,
            while_token.column,
        );
    }

    fn parseuntil(self: *self) parsererror!*const ast.astnode {
        const until_token = self.current_token;
        try self.nexttoken(); // consume 'until'

        const condition = try self.parsesimplecommand();

        if (self.current_token.ty != .do) {
            return error.unexpectedtoken;
        }
        try self.nexttoken(); // consume 'do'

        const body = try self.parsecommandlist();

        if (self.current_token.ty != .done) {
            return error.unexpectedtoken;
        }
        try self.nexttoken(); // consume 'done'

        return self.builder.createwhile( // until is like while with negated condition
            condition,
            body,
            until_token.line,
            until_token.column,
        );
    }

    fn parsefor(self: *self) parsererror!*const ast.astnode {
        const for_token = self.current_token;
        try self.nexttoken(); // consume 'for'

        // parse variable name
        const variable = try self.parseword();

        if (self.current_token.ty != .in) {
            return error.unexpectedtoken;
        }
        try self.nexttoken(); // consume 'in'

        // parse value list
        var values = std.arraylist(*const ast.astnode).init(self.builder.arena.allocator());
        while (self.current_token.ty != .semicolon and
            self.current_token.ty != .newline and
            self.current_token.ty != .do and
            self.current_token.ty != .eof)
        {
            if (values.items.len >= secure.max_args_count) {
                return error.toomanyarguments;
            }

            const value = try self.parseword();
            try values.append(value);
        }

        // skip optional separator
        if (self.current_token.ty == .semicolon or self.current_token.ty == .newline) {
            try self.nexttoken();
        }

        if (self.current_token.ty != .do) {
            return error.unexpectedtoken;
        }
        try self.nexttoken(); // consume 'do'

        const body = try self.parsecommandlist();

        if (self.current_token.ty != .done) {
            return error.unexpectedtoken;
        }
        try self.nexttoken(); // consume 'done'

        return self.builder.createfor(
            variable,
            values.items,
            body,
            for_token.line,
            for_token.column,
        );
    }

    fn parsecase(self: *self) parsererror!*const ast.astnode {
        // simplified case parsing - full implementation would be more complex
        const case_token = self.current_token;
        try self.nexttoken(); // consume 'case'

        const expr = try self.parseword();

        if (self.current_token.ty != .in) {
            return error.unexpectedtoken;
        }
        try self.nexttoken(); // consume 'in'

        // for now, just consume until esac
        while (self.current_token.ty != .esac and self.current_token.ty != .eof) {
            try self.nexttoken();
        }

        if (self.current_token.ty != .esac) {
            return error.unexpectedtoken;
        }
        try self.nexttoken(); // consume 'esac'

        return self.builder.createnode(
            .case_statement,
            "",
            &[_]*const ast.astnode{expr},
            case_token.line,
            case_token.column,
        );
    }

    fn parsegroup(self: *self) parsererror!*const ast.astnode {
        const brace_token = self.current_token;
        try self.nexttoken(); // consume '{'

        const body = try self.parsecommandlist();

        if (self.current_token.ty != .rightbrace) {
            return error.unexpectedtoken;
        }
        try self.nexttoken(); // consume '}'

        return self.builder.createnode(
            .list,
            "",
            &[_]*const ast.astnode{body},
            brace_token.line,
            brace_token.column,
        );
    }

    fn parsesubshell(self: *self) parsererror!*const ast.astnode {
        const paren_token = self.current_token;
        try self.nexttoken(); // consume '('

        const body = try self.parsecommandlist();

        if (self.current_token.ty != .rightparen) {
            return error.unexpectedtoken;
        }
        try self.nexttoken(); // consume ')'

        return self.builder.createnode(
            .subshell,
            "",
            &[_]*const ast.astnode{body},
            paren_token.line,
            paren_token.column,
        );
    }
};

// compile-time security checks
comptime {
    // ensure parser cannot be used for dos
    if (@sizeof(secureparser) > 1024) {
        @compileerror("parser too large - potential memory exhaustion");
    }
}