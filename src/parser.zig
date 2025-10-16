// parser.zig - typestate parser with bounds checking

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
} || types.SecurityError;

// typestate-based parser
pub const Parser = struct {
    lexer: lexer.Lexer,
    builder: ast.AstBuilder,
    state: parserstate,
    current_token: lexer.token,
    peek_token: lexer.token,
    recursion_depth: types.RecursionDepth,

    const Self = @This();

    pub fn init(input: []const u8, allocator: std.mem.allocator) !Self {
        var lex = try lexer.Lexer.init(input);

        return Self{
            .lexer = lex,
            .builder = ast.AstBuilder.init(allocator),
            .state = .initial,
            .current_token = lexer.token.empty,
            .peek_token = lexer.token.empty,
            .recursion_depth = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.builder.deinit();
    }

    // state-safe token advancement
    pub fn nexttoken(self: *Self) !void {
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
    pub fn parse(self: *Self) !*const ast.AstNode {
        // prime the parser
        try self.nexttoken();

        const root = try self.parsecommandlist();

        self.state = .complete;

        // validate the resulting ast for security
        try ast.validateast(root);

        return root;
    }

    fn parsecommandlist(self: *Self) parsererror!*const ast.AstNode {
        if (self.state != .hasboth) return error.invalidparserstate;

        var commands = std.arraylist(*const ast.AstNode).init(self.builder.arena.allocator());

        while (self.current_token.ty != .eof) {
            // skip empty statements
            if (self.current_token.ty == .semicolon or self.current_token.ty == .newline) {
                try self.nexttoken();
                continue;
            }

            // prevent dos via massive command lists
            if (commands.items.len >= types.MAX_ARGS_COUNT) {
                return error.toomanycommands;
            }

            const cmd = try self.parsepipeline();
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

    fn parsepipeline(self: *Self) parsererror!*const ast.AstNode {
        var pipeline_commands = std.arraylist(*const ast.AstNode).init(self.builder.arena.allocator());

        // Parse first command
        const first_cmd = try self.parsecommand();
        try pipeline_commands.append(first_cmd);

        // Parse additional commands connected by pipes
        while (self.current_token.ty == .Pipe) {
            try self.nexttoken(); // consume pipe token

            if (pipeline_commands.items.len >= types.MAX_ARGS_COUNT) {
                return error.toomanypipelinecommands;
            }

            const next_cmd = try self.parsecommand();
            try pipeline_commands.append(next_cmd);
        }

        // If we only have one command, return it directly
        if (pipeline_commands.items.len == 1) {
            return pipeline_commands.items[0];
        }

        // Create pipeline node
        return self.builder.createpipeline(
            pipeline_commands.items,
            pipeline_commands.items[0].line,
            pipeline_commands.items[0].column,
        );
    }

    fn parsecommand(self: *Self) parsererror!*const ast.AstNode {
        // recursion depth check
        if (self.recursion_depth >= types.MAX_RECURSION_DEPTH) {
            return error.recursionlimitexceeded;
        }

        self.recursion_depth = try types.checkedAdd(types.RecursionDepth, self.recursion_depth, 1);
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

    fn parsesimplecommand(self: *Self) parsererror!*const ast.AstNode {
        var words = std.arraylist(*const ast.AstNode).init(self.builder.arena.allocator());

        while (self.current_token.ty != .eof) {
            switch (self.current_token.ty) {
                .word => {
                    // Check if this word is an assignment (contains =)
                    if (std.mem.indexOfScalar(u8, self.current_token.value, '=')) |eq_pos| {
                        // This is an assignment like VAR=value
                        const token = self.current_token;
                        try self.nexttoken();

                        const name = token.value[0..eq_pos];
                        const value = token.value[eq_pos + 1..];

                        // Create assignment node
                        return self.builder.createassignment(name, value, token.line, token.column);
                    } else {
                        // Regular word
                        const word = try self.parseword();
                        try words.append(word);
                    }
                },
                .string, .integer => {
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

    fn parseword(self: *Self) parsererror!*const ast.AstNode {
        if (self.state != .hasboth) return error.invalidparserstate;

        const token = self.current_token;
        try self.nexttoken();

        const node_type: ast.NodeType = switch (token.ty) {
            .word => .word,
            .string => .string,
            .integer => .number,
            else => return error.unexpectedtoken,
        };

        return switch (node_type) {
            .word => self.builder.createword(token.value, token.line, token.column),
            .string => self.builder.createstring(token.value, token.line, token.column),
            .number => self.builder.createnode(.number, token.value, &[_]*const ast.AstNode{}, token.line, token.column),
            else => error.invalidsyntax,
        };
    }

    // control structure parsing with bounds checking
    fn parseif(self: *Self) parsererror!*const ast.AstNode {
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

        var else_branch: ?*const ast.AstNode = null;

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

    fn parsewhile(self: *Self) parsererror!*const ast.AstNode {
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

    fn parseuntil(self: *Self) parsererror!*const ast.AstNode {
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

    fn parsefor(self: *Self) parsererror!*const ast.AstNode {
        const for_token = self.current_token;
        try self.nexttoken(); // consume 'for'

        // parse variable name
        const variable = try self.parseword();

        if (self.current_token.ty != .in) {
            return error.unexpectedtoken;
        }
        try self.nexttoken(); // consume 'in'

        // parse value list
        var values = std.arraylist(*const ast.AstNode).init(self.builder.arena.allocator());
        while (self.current_token.ty != .semicolon and
            self.current_token.ty != .newline and
            self.current_token.ty != .do and
            self.current_token.ty != .eof)
        {
            if (values.items.len >= types.MAX_ARGS_COUNT) {
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

    fn parsecase(self: *Self) parsererror!*const ast.AstNode {
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
            &[_]*const ast.AstNode{expr},
            case_token.line,
            case_token.column,
        );
    }

    fn parsegroup(self: *Self) parsererror!*const ast.AstNode {
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
            &[_]*const ast.AstNode{body},
            brace_token.line,
            brace_token.column,
        );
    }

    fn parsesubshell(self: *Self) parsererror!*const ast.AstNode {
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
            &[_]*const ast.AstNode{body},
            paren_token.line,
            paren_token.column,
        );
    }
};

// compile-time security checks
comptime {
    // ensure parser cannot be used for dos
    if (@sizeOf(Parser) > 1024) {
        @compileError("parser too large - potential memory exhaustion");
    }
}