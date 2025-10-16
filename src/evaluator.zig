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
        var args = std.ArrayListUnmanaged([]const u8){};
        defer args.deinit(self.allocator);

        for (node.children.items) |child| {
            try args.append(self.allocator, child.value orelse return error.InvalidSyntax);
        }

        // Execute external command
        return self.executeExternal(args.items);
    }

    // Evaluator executeExternal function
    fn executeExternal(self: *Self, args: []const []const u8) !ExitStatus {
        // For now, just return success - external command execution will be implemented later
        _ = self;
        _ = args;
        std.debug.print("External command execution not yet implemented\n", .{});
        return ExitStatus{ .code = 0, .signal = null };
    }

    fn evaluatePipeline(self: *Self, node: *ast.Node) !ExitStatus {
        // TODO: Implement pipeline execution
        _ = node;
        _ = self;
        return ExitStatus{ .code = 0, .signal = null };
    }

    fn evaluateList(self: *Self, node: *ast.Node) EvalError!ExitStatus {
        var last_status = ExitStatus{ .code = 0, .signal = null };

        for (node.children.items) |child| {
            last_status = self.evaluate(child) catch |err| {
                return err;
            };
            self.env.setExitStatus(@as(i32, last_status.code));
        }

        return last_status;
    }

    fn evaluateSubshell(self: *Self, node: *ast.Node) !ExitStatus {
        // TODO: Implement subshell execution with fork
        _ = node;
        _ = self;
        return ExitStatus{ .code = 0, .signal = null };
    }

    fn evaluateIf(self: *Self, node: *ast.Node) EvalError!ExitStatus {
        if (node.children.items.len < 2) return error.InvalidSyntax;

        // Evaluate condition
        const condition_status = self.evaluate(node.children.items[0]) catch |err| {
            return err;
        };

        if (condition_status.code == 0) {
            // Condition is true, execute then branch
            return self.evaluate(node.children.items[1]) catch |err| {
                return err;
            };
        } else if (node.children.items.len > 2) {
            // Execute else branch if present
            return self.evaluate(node.children.items[2]) catch |err| {
                return err;
            };
        }

        return ExitStatus{ .code = 0, .signal = null };
    }

    fn evaluateWhile(self: *Self, node: *ast.Node) EvalError!ExitStatus {
        if (node.children.items.len != 2) return error.InvalidSyntax;

        var last_status = ExitStatus{ .code = 0, .signal = null };

        while (true) {
            // Evaluate condition
            const condition_status = self.evaluate(node.children.items[0]) catch |err| {
                return err;
            };
            if (condition_status.code != 0) break;

            // Execute body
            last_status = self.evaluate(node.children.items[1]) catch |err| {
                return err;
            };
        }

        return last_status;
    }

    fn evaluateUntil(self: *Self, node: *ast.Node) EvalError!ExitStatus {
        if (node.children.items.len != 2) return error.InvalidSyntax;

        var last_status = ExitStatus{ .code = 0, .signal = null };

        while (true) {
            // Evaluate condition
            const condition_status = self.evaluate(node.children.items[0]) catch |err| {
                return err;
            };
            if (condition_status.code == 0) break;

            // Execute body
            last_status = self.evaluate(node.children.items[1]) catch |err| {
                return err;
            };
        }

        return last_status;
    }

    fn evaluateFor(self: *Self, node: *ast.Node) !ExitStatus {
        // TODO: Implement for loop evaluation
        _ = node;
        _ = self;
        return ExitStatus{ .code = 0, .signal = null };
    }

    fn evaluateCase(self: *Self, node: *ast.Node) !ExitStatus {
        // TODO: Implement case statement evaluation
        _ = node;
        _ = self;
        return ExitStatus{ .code = 0, .signal = null };
    }

    fn evaluateFunction(self: *Self, node: *ast.Node) !ExitStatus {
        // TODO: Implement function definition
        _ = node;
        _ = self;
        return ExitStatus{ .code = 0, .signal = null };
    }

    fn applyRedirects(self: *Self, redirects: []const *ast.RedirectNode) ![]i32 {
        // TODO: Implement redirection handling
        _ = redirects;
        _ = self;
        return &[_]i32{};
    }

    fn restoreFds(self: *Self, saved_fds: []i32) void {
        // TODO: Implement file descriptor restoration
        _ = saved_fds;
        _ = self;
    }

    fn isBuiltin(self: *Self, cmd_name: []const u8) bool {
        _ = self;
        const builtins = [_][]const u8{
            "cd", "pwd", "echo", "exit", "export", "unset", "set", "source", "."
        };

        for (builtins) |builtin| {
            if (std.mem.eql(u8, cmd_name, builtin)) return true;
        }

        return false;
    }

    fn executeBuiltin(self: *Self, cmd_name: []const u8, args: []*ast.Node) !ExitStatus {
        if (std.mem.eql(u8, cmd_name, "cd")) {
            return self.builtinCd(args);
        } else if (std.mem.eql(u8, cmd_name, "pwd")) {
            return self.builtinPwd(args);
        } else if (std.mem.eql(u8, cmd_name, "echo")) {
            return self.builtinEcho(args);
        } else if (std.mem.eql(u8, cmd_name, "exit")) {
            return self.builtinExit(args);
        } else if (std.mem.eql(u8, cmd_name, "export")) {
            return self.builtinExport(args);
        } else if (std.mem.eql(u8, cmd_name, "unset")) {
            return self.builtinUnset(args);
        }

        return error.CommandNotFound;
    }

    fn builtinCd(self: *Self, args: []*ast.Node) !ExitStatus {
        const path = if (args.len > 0)
            args[0].value orelse "~"
        else
            self.env.get("HOME") orelse "~";

        // Handle ~ expansion
        const target_path = if (std.mem.eql(u8, path, "~"))
            self.env.get("HOME") orelse "/"
        else
            path;

        self.env.setCurrentDir(target_path) catch {
            std.debug.print("cd: {s}: No such file or directory\n", .{target_path});
            return ExitStatus{ .code = 1, .signal = null };
        };

        return ExitStatus{ .code = 0, .signal = null };
    }

    fn builtinPwd(self: *Self, args: []*ast.Node) !ExitStatus {
        _ = args;
        std.debug.print("{s}\n", .{self.env.getCurrentDir()});
        return ExitStatus{ .code = 0, .signal = null };
    }

    fn builtinEcho(self: *Self, args: []*ast.Node) !ExitStatus {
        _ = self;
        for (args, 0..) |arg, i| {
            if (i > 0) std.debug.print(" ", .{});
            std.debug.print("{s}", .{arg.value orelse ""});
        }
        std.debug.print("\n", .{});
        return ExitStatus{ .code = 0, .signal = null };
    }

    fn builtinExit(self: *Self, args: []*ast.Node) !ExitStatus {
        _ = self;
        const exit_code: u8 = if (args.len > 0 and args[0].value != null) blk: {
            break :blk std.fmt.parseInt(u8, args[0].value.?, 10) catch 1;
        } else 0;

        std.process.exit(exit_code);
    }

    fn builtinExport(self: *Self, args: []*ast.Node) !ExitStatus {
        for (args) |arg| {
            if (arg.value) |var_assignment| {
                // Look for '=' to split name and value
                if (std.mem.indexOfScalar(u8, var_assignment, '=')) |eq_pos| {
                    const name = var_assignment[0..eq_pos];
                    const value = var_assignment[eq_pos + 1..];
                    try self.env.set(name, value);
                } else {
                    // Just mark existing variable for export (TODO: Implement export flag)
                    std.debug.print("export: {s} (marking for export not implemented)\n", .{var_assignment});
                }
            }
        }
        return ExitStatus{ .code = 0, .signal = null };
    }

    fn builtinUnset(self: *Self, args: []*ast.Node) !ExitStatus {
        for (args) |arg| {
            if (arg.value) |var_name| {
                _ = self.env.unset(var_name);
            }
        }
        return ExitStatus{ .code = 0, .signal = null };
    }
};
