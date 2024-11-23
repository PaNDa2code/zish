// ast.zig
// abstract syntax tree
const std = @import("std");

pub const NodeType = enum {
    // Commands
    Command,
    Pipeline,
    List,
    Subshell,

    // Control structures
    If,
    While,
    Until,
    For,
    Case,

    // Functions
    FunctionDef,

    // Redirections
    Redirect,
    HereDoc,

    // Variables and expansions
    Assignment,
    ParameterExpansion,
    CommandSubstitution,
    ArithmeticExpansion,

    // Words and literals
    Word,
    String,
    Number,
};

pub const RedirectType = enum {
    Input, // <
    Output, // >
    Append, // >>
    HereDoc, // <<
    HereString, // <<<
    InputOutput, // <>
    DupInput, // <&
    DupOutput, // >&
};

pub const Node = struct {
    type: NodeType,
    value: ?[]const u8 = null,
    children: std.ArrayList(*Node),
    redirects: std.ArrayList(*RedirectNode),
    line: usize,
    column: usize,

    pub fn init(allocator: std.mem.Allocator, node_type: NodeType, value: ?[]const u8, line: usize, column: usize) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .type = node_type,
            .value = value,
            .children = std.ArrayList(*Node).init(allocator),
            .redirects = std.ArrayList(*RedirectNode).init(allocator),
            .line = line,
            .column = column,
        };
        return node;
    }

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        for (self.children.items) |child| {
            child.deinit(allocator);
        }
        for (self.redirects.items) |redirect| {
            redirect.deinit(allocator);
        }
        self.children.deinit();
        self.redirects.deinit();
        allocator.destroy(self);
    }
};

pub const RedirectNode = struct {
    type: RedirectType,
    fd: ?i32,
    target: *Node,
    here_doc_content: ?[]const u8,
    line: usize,
    column: usize,

    pub fn init(allocator: std.mem.Allocator, redirect_type: RedirectType, fd: ?i32, target: *Node, line: usize, column: usize) !*RedirectNode {
        const node = try allocator.create(RedirectNode);
        node.* = .{
            .type = redirect_type,
            .fd = fd,
            .target = target,
            .here_doc_content = null,
            .line = line,
            .column = column,
        };
        return node;
    }

    pub fn deinit(self: *RedirectNode, allocator: std.mem.Allocator) void {
        self.target.deinit(allocator);
        allocator.destroy(self);
    }
};
