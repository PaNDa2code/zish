// secure_ast.zig - immutable ast with arena allocation

const std = @import("std");
const secure = @import("secure_types.zig");

// immutable node types
pub const nodetype = enum {
    command,
    pipeline,
    list,
    subshell,
    if_statement,
    while_loop,
    until_loop,
    for_loop,
    case_statement,
    function_def,
    assignment,
    word,
    string,
    number,
};

// immutable ast node - no cleanup needed, arena handles lifetime
pub const astnode = struct {
    node_type: nodetype,
    value: []const u8,  // slice into arena memory
    children: []const *const astnode,  // const pointers to const data
    line: secure.linenumber,
    column: secure.columnnumber,

    // const empty node for safe defaults
    pub const empty = astnode{
        .node_type = .word,
        .value = "",
        .children = &[_]*const astnode{},
        .line = 0,
        .column = 0,
    };

    pub fn iscommand(self: *const astnode) bool {
        return self.node_type == .command;
    }

    pub fn iscontrol(self: *const astnode) bool {
        return switch (self.node_type) {
            .if_statement, .while_loop, .until_loop, .for_loop, .case_statement => true,
            else => false,
        };
    }

    // safe child access with bounds checking
    pub fn getchild(self: *const astnode, index: usize) ?*const astnode {
        if (index >= self.children.len) return null;
        return self.children[index];
    }

    pub fn childcount(self: *const astnode) usize {
        return self.children.len;
    }
};

// typestate-based ast builder with security guarantees
pub const astbuilder = struct {
    arena: std.heap.arenaallocator,
    depth: secure.recursiondepth,
    node_count: u32,  // prevent ast explosion

    const max_nodes = 1024;  // prevent dos via massive asts
    const self = @this();

    pub fn init(parent_allocator: std.mem.allocator) self {
        return self{
            .arena = std.heap.arenaallocator.init(parent_allocator),
            .depth = 0,
            .node_count = 0,
        };
    }

    pub fn deinit(self: *self) void {
        // arena cleanup handles everything - no double-free possible
        self.arena.deinit();
    }

    pub fn createnode(
        self: *self,
        node_type: nodetype,
        value: []const u8,
        children: []const *const astnode,
        line: secure.linenumber,
        column: secure.columnnumber,
    ) !*const astnode {
        // prevent ast explosion attacks
        if (self.node_count >= max_nodes) {
            return error.asttoocomplex;
        }

        // prevent stack overflow in traversal
        if (self.depth >= secure.max_parse_depth) {
            return error.parsetoodeeop;
        }

        const allocator = self.arena.allocator();

        // bounds check children array
        if (children.len > secure.max_args_count) {
            return error.toomanychildren;
        }

        const node = try allocator.create(astnode);
        node.* = astnode{
            .node_type = node_type,
            .value = try allocator.dupe(u8, value),  // copy into arena
            .children = try allocator.dupe(*const astnode, children),  // copy array
            .line = line,
            .column = column,
        };

        self.node_count = try secure.checkedadd(u32, self.node_count, 1);
        return node;
    }

    pub fn createword(self: *self, value: []const u8, line: secure.linenumber, column: secure.columnnumber) !*const astnode {
        try secure.validateshellsafe(value);
        return self.createnode(.word, value, &[_]*const astnode{}, line, column);
    }

    pub fn createstring(self: *self, value: []const u8, line: secure.linenumber, column: secure.columnnumber) !*const astnode {
        return self.createnode(.string, value, &[_]*const astnode{}, line, column);
    }

    pub fn createcommand(self: *self, words: []const *const astnode, line: secure.linenumber, column: secure.columnnumber) !*const astnode {
        if (words.len == 0) return error.emptycommand;
        return self.createnode(.command, "", words, line, column);
    }

    pub fn createif(self: *self, condition: *const astnode, then_branch: *const astnode, else_branch: ?*const astnode, line: secure.linenumber, column: secure.columnnumber) !*const astnode {
        self.depth = try secure.checkedadd(secure.recursiondepth, self.depth, 1);
        defer self.depth -= 1;

        var children_buf: [3]*const astnode = undefined;
        var child_count: usize = 2;

        children_buf[0] = condition;
        children_buf[1] = then_branch;

        if (else_branch) |else_node| {
            children_buf[2] = else_node;
            child_count = 3;
        }

        return self.createnode(.if_statement, "", children_buf[0..child_count], line, column);
    }

    pub fn createwhile(self: *self, condition: *const astnode, body: *const astnode, line: secure.linenumber, column: secure.columnnumber) !*const astnode {
        self.depth = try secure.checkedadd(secure.recursiondepth, self.depth, 1);
        defer self.depth -= 1;

        const children = [_]*const astnode{ condition, body };
        return self.createnode(.while_loop, "", &children, line, column);
    }

    pub fn createfor(self: *self, variable: *const astnode, values: []const *const astnode, body: *const astnode, line: secure.linenumber, column: secure.columnnumber) !*const astnode {
        self.depth = try secure.checkedadd(secure.recursiondepth, self.depth, 1);
        defer self.depth -= 1;

        const allocator = self.arena.allocator();

        // create children array: [variable, value1, value2, ..., body]
        var children = try allocator.alloc(*const astnode, values.len + 2);
        children[0] = variable;
        std.mem.copy(*const astnode, children[1..values.len + 1], values);
        children[children.len - 1] = body;

        return self.createnode(.for_loop, "", children, line, column);
    }

    pub fn createpipeline(self: *self, commands: []const *const astnode, line: secure.linenumber, column: secure.columnnumber) !*const astnode {
        if (commands.len < 2) return error.invalidpipeline;
        return self.createnode(.pipeline, "", commands, line, column);
    }

    pub fn createlist(self: *self, commands: []const *const astnode, line: secure.linenumber, column: secure.columnnumber) !*const astnode {
        return self.createnode(.list, "", commands, line, column);
    }

    // secure ast traversal with stack overflow protection
    pub fn traverse(node: *const astnode, visitor: *const astvisitor, depth: secure.recursiondepth) !void {
        if (depth >= secure.max_parse_depth) {
            return error.traversaltooDeep;
        }

        try visitor.visit(node);

        for (node.children) |child| {
            try traverse(child, visitor, depth + 1);
        }
    }
};

// visitor pattern for safe ast traversal
pub const astvisitor = struct {
    visit_fn: *const fn (node: *const astnode) anyerror!void,

    pub fn visit(self: *const astvisitor, node: *const astnode) !void {
        return self.visit_fn(node);
    }
};

// security-focused ast validation
pub fn validateast(root: *const astnode) !void {
    const validator = astvisitor{
        .visit_fn = validatenode,
    };

    try astbuilder.traverse(root, &validator, 0);
}

fn validatenode(node: *const astnode) !void {
    // validate node structure
    switch (node.node_type) {
        .command => {
            if (node.children.len == 0) return error.emptycommand;
            // first child must be a word (command name)
            if (node.children[0].node_type != .word and node.children[0].node_type != .string) {
                return error.invalidcommandname;
            }
        },
        .if_statement => {
            if (node.children.len < 2) return error.invalidif;
        },
        .while_loop, .until_loop => {
            if (node.children.len != 2) return error.invalidloop;
        },
        .for_loop => {
            if (node.children.len < 3) return error.invalidfor;
        },
        .pipeline => {
            if (node.children.len < 2) return error.invalidpipeline;
        },
        else => {},
    }

    // validate value content for security
    try secure.validateshellsafe(node.value);
}

// compile-time security checks
comptime {
    if (@sizeof(astnode) > 64) {
        @compileerror("ast node too large - potential memory exhaustion");
    }
}