// evaluator.zig

const std = @import("std");
const ast = @import("ast.zig");
const Environment = @import("environment.zig").Environment;

pub const EvalError = error{
    CommandNotFound,
    ExecutionFailed,
    RedirectionFailed,
    SubshellFailed,
    InvalidSyntax,
    OutOfMemory,
};

pub const ExitStatus = struct {
    code: u8,
    signal: ?u32,
};

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    env: *Environment,
    last_exit_status: ExitStatus,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const evaluator = try allocator.create(Self);
        evaluator.* = .{
            .allocator = allocator,
            .env = try Environment.init(allocator),
            .last_exit_status = .{ .code = 0, .signal = null },
        };
        return evaluator;
    }

    pub fn deinit(self: *Self) void {
        self.env.deinit();
        self.allocator.destroy(self);
    }

    pub fn evaluate(self: *Self, node: *ast.Node) !ExitStatus {
        return switch (node.type) {
            .Command => self.evaluateCommand(node),
            .Pipeline => self.evaluatePipeline(node),
            .List => self.evaluateList(node),
            .Subshell => self.evaluateSubshell(node),
            .If => self.evaluateIf(node),
            .While => self.evaluateWhile(node),
            .Until => self.evaluateUntil(node),
            .For => self.evaluateFor(node),
            .Case => self.evaluateCase(node),
            .FunctionDef => self.evaluateFunction(node),
            else => error.InvalidSyntax,
        };
    }

    fn evaluateCommand(self: *Self, node: *ast.Node) !ExitStatus {
        // First apply any redirections
        const saved_fds = try self.applyRedirects(node.redirects.items);
        defer self.restoreFds(saved_fds);

        // Get command name and arguments
        if (node.children.items.len == 0) return error.InvalidSyntax;

        const cmd_name = node.children.items[0].value orelse return error.InvalidSyntax;

        // Check for builtin commands
        if (self.isBuiltin(cmd_name)) {
            return self.executeBuiltin(cmd_name, node.children.items[1..]);
        }

        // Prepare arguments
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        for (node.children.items) |child| {
            try args.append(child.value orelse return error.InvalidSyntax);
        }

        // Execute external command
        return self.executeExternal(args.items);
    }

    fn executeExternal(self: *Self, args: []const []const u8) !ExitStatus {
        const child_pid = try std.os.fork();
        if (child_pid == 0) {
            // Child process
            const err = std.os.execvpeZ(
                args[0],
                args,
                self.env.getEnvp(),
            );
            std.debug.warn("exec failed: {}\n", .{err});
            std.os.exit(127);
        }

        // Parent process
        const wait_result = try std.os.waitpid(child_pid, 0);
        return ExitStatus{
            .code = @truncate(u8, wait_result.status >> 8),
            .signal = if (std.os.system.WIFSIGNALED(wait_result.status))
                std.os.system.WTERMSIG(wait_result.status)
            else
                null,
        };
    }
};
