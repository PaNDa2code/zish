// secure_executor.zig - capability-based sandboxed execution

const std = @import("std");
const types = @import("types.zig");
const ast = @import("ast.zig");
const env = @import("environment.zig");

// execution result with security context
pub const exitstatus = struct {
    code: u8,
    signal: ?u32,
    terminated_by_policy: bool = false,
};

// sandboxed executor with capability restrictions
pub const secureexecutor = struct {
    arena: std.heap.arenaallocator,
    environment: *env.securenvironment,
    execution_caps: std.enumset(secure.executioncapability),
    command_whitelist: []const []const u8,
    max_execution_time: u64, // nanoseconds

    const self = @this();
    const max_execution_time_default = 30 * std.time.ns_per_s; // 30 seconds

    pub fn init(
        allocator: std.mem.allocator,
        environment: *env.securenvironment,
        execution_caps: std.enumset(secure.executioncapability),
    ) !*self {
        var arena = std.heap.arenaallocator.init(allocator);

        const executor = try arena.allocator().create(self);
        executor.* = .{
            .arena = arena,
            .environment = environment,
            .execution_caps = execution_caps,
            .command_whitelist = &default_safe_commands,
            .max_execution_time = max_execution_time_default,
        };

        return executor;
    }

    pub fn deinit(self: *self) void {
        self.arena.deinit();
    }

    // main evaluation entry point with security checks
    pub fn evaluate(self: *self, node: *const ast.astnode) !exitstatus {
        return switch (node.node_type) {
            .command => self.evaluatecommand(node),
            .list => self.evaluatelist(node),
            .if_statement => self.evaluateif(node),
            .while_loop => self.evaluatewhile(node),
            .until_loop => self.evaluateuntil(node),
            .for_loop => self.evaluatefor(node),
            .subshell => self.evaluatesubshell(node),
            else => exitstatus{ .code = 0, .signal = null },
        };
    }

    fn evaluatecommand(self: *self, node: *const ast.astnode) !exitstatus {
        if (node.children.len == 0) return error.emptycommand;

        const cmd_name = node.children[0].value;

        // security: validate command name
        try secure.validateshellsafe(cmd_name);

        // check if it's a builtin command
        if (self.isbuiltin(cmd_name)) {
            return self.executebuiltin(cmd_name, node.children[1..]);
        }

        // check capability for external execution
        if (!self.execution_caps.contains(.processspawn)) {
            std.debug.print("command execution not allowed: insufficient capability\n", .{});
            return exitstatus{ .code = 126, .signal = null, .terminated_by_policy = true };
        }

        // whitelist check for external commands
        if (!self.iscommandallowed(cmd_name)) {
            std.debug.print("command not in whitelist: {s}\n", .{cmd_name});
            return exitstatus{ .code = 127, .signal = null, .terminated_by_policy = true };
        }

        // for now, simulate external execution (would use proper sandboxing in production)
        std.debug.print("would execute external command: {s} (not implemented)\n", .{cmd_name});
        return exitstatus{ .code = 0, .signal = null };
    }

    fn evaluatelist(self: *self, node: *const ast.astnode) !exitstatus {
        var last_status = exitstatus{ .code = 0, .signal = null };

        for (node.children) |child| {
            last_status = try self.evaluate(child);
            self.environment.setexitstatus(@as(i32, last_status.code));

            // stop execution if terminated by security policy
            if (last_status.terminated_by_policy) break;
        }

        return last_status;
    }

    fn evaluateif(self: *self, node: *const ast.astnode) !exitstatus {
        if (node.children.len < 2) return error.invalidsyntax;

        // evaluate condition
        const condition = try self.evaluate(node.children[0]);

        if (condition.code == 0) {
            // condition true - execute then branch
            return self.evaluate(node.children[1]);
        } else if (node.children.len > 2) {
            // condition false - execute else branch if present
            return self.evaluate(node.children[2]);
        }

        return exitstatus{ .code = 0, .signal = null };
    }

    fn evaluatewhile(self: *self, node: *const ast.astnode) !exitstatus {
        if (node.children.len != 2) return error.invalidsyntax;

        var last_status = exitstatus{ .code = 0, .signal = null };
        var iterations: u32 = 0;
        const max_iterations = 1000; // prevent infinite loops

        while (iterations < max_iterations) {
            // evaluate condition
            const condition = try self.evaluate(node.children[0]);
            if (condition.code != 0) break;

            // execute body
            last_status = try self.evaluate(node.children[1]);

            if (last_status.terminated_by_policy) break;

            iterations = try secure.checkedadd(u32, iterations, 1);
        }

        if (iterations >= max_iterations) {
            std.debug.print("while loop terminated: iteration limit reached\n", .{});
            return exitstatus{ .code = 1, .signal = null, .terminated_by_policy = true };
        }

        return last_status;
    }

    fn evaluateuntil(self: *self, node: *const ast.astnode) !exitstatus {
        if (node.children.len != 2) return error.invalidsyntax;

        var last_status = exitstatus{ .code = 0, .signal = null };
        var iterations: u32 = 0;
        const max_iterations = 1000;

        while (iterations < max_iterations) {
            // evaluate condition (until is opposite of while)
            const condition = try self.evaluate(node.children[0]);
            if (condition.code == 0) break;

            // execute body
            last_status = try self.evaluate(node.children[1]);

            if (last_status.terminated_by_policy) break;

            iterations = try secure.checkedadd(u32, iterations, 1);
        }

        if (iterations >= max_iterations) {
            std.debug.print("until loop terminated: iteration limit reached\n", .{});
            return exitstatus{ .code = 1, .signal = null, .terminated_by_policy = true };
        }

        return last_status;
    }

    fn evaluatefor(self: *self, node: *const ast.astnode) !exitstatus {
        if (node.children.len < 3) return error.invalidsyntax;

        const variable = node.children[0];
        const body = node.children[node.children.len - 1];
        const values = node.children[1 .. node.children.len - 1];

        var last_status = exitstatus{ .code = 0, .signal = null };

        // iteration limit for security
        if (values.len > secure.max_args_count) {
            return exitstatus{ .code = 1, .signal = null, .terminated_by_policy = true };
        }

        for (values) |value| {
            // set loop variable
            try self.environment.set(variable.value, value.value);

            // execute body
            last_status = try self.evaluate(body);

            if (last_status.terminated_by_policy) break;
        }

        return last_status;
    }

    fn evaluatesubshell(self: *self, node: *const ast.astnode) !exitstatus {
        // subshells would normally fork - for now just evaluate in current context
        if (node.children.len == 0) return error.emptysubshell;
        return self.evaluate(node.children[0]);
    }

    // builtin command implementations with security focus
    fn isbuiltin(self: *self, cmd_name: []const u8) bool {
        _ = self;
        const builtins = [_][]const u8{
            "echo", "pwd", "cd", "exit", "export", "unset", "true", "false",
        };

        for (builtins) |builtin| {
            if (std.crypto.utils.timingsafeeql(u8, cmd_name, builtin)) return true;
        }
        return false;
    }

    fn executebuiltin(self: *self, cmd_name: []const u8, args: []const *const ast.astnode) !exitstatus {
        if (std.mem.eql(u8, cmd_name, "echo")) {
            return self.builtinecho(args);
        } else if (std.mem.eql(u8, cmd_name, "pwd")) {
            return self.builtinpwd(args);
        } else if (std.mem.eql(u8, cmd_name, "cd")) {
            return self.builtincd(args);
        } else if (std.mem.eql(u8, cmd_name, "exit")) {
            return self.builtinexit(args);
        } else if (std.mem.eql(u8, cmd_name, "export")) {
            return self.builtinexport(args);
        } else if (std.mem.eql(u8, cmd_name, "unset")) {
            return self.builtinunset(args);
        } else if (std.mem.eql(u8, cmd_name, "true")) {
            return exitstatus{ .code = 0, .signal = null };
        } else if (std.mem.eql(u8, cmd_name, "false")) {
            return exitstatus{ .code = 1, .signal = null };
        }

        return error.unknownbuiltin;
    }

    fn builtinecho(self: *self, args: []const *const ast.astnode) !exitstatus {
        _ = self;

        for (args, 0..) |arg, i| {
            if (i > 0) std.debug.print(" ", .{});

            // security: validate output
            try secure.validateshellsafe(arg.value);
            std.debug.print("{s}", .{arg.value});
        }
        std.debug.print("\n", .{});

        return exitstatus{ .code = 0, .signal = null };
    }

    fn builtinpwd(self: *self, args: []const *const ast.astnode) !exitstatus {
        _ = args;
        std.debug.print("{s}\n", .{self.environment.getcurrentdir()});
        return exitstatus{ .code = 0, .signal = null };
    }

    fn builtincd(self: *self, args: []const *const ast.astnode) !exitstatus {
        const target_path = if (args.len > 0)
            args[0].value
        else
            self.environment.get("home") orelse "/";

        self.environment.setcurrentdir(target_path) catch {
            std.debug.print("cd: {s}: no such file or directory\n", .{target_path});
            return exitstatus{ .code = 1, .signal = null };
        };

        return exitstatus{ .code = 0, .signal = null };
    }

    fn builtinexit(self: *self, args: []const *const ast.astnode) !exitstatus {
        _ = self;

        const exit_code: u8 = if (args.len > 0 and args[0].value.len > 0) blk: {
            break :blk std.fmt.parseint(u8, args[0].value, 10) catch 1;
        } else 0;

        std.process.exit(exit_code);
    }

    fn builtinexport(self: *self, args: []const *const ast.astnode) !exitstatus {
        for (args) |arg| {
            const var_assignment = arg.value;

            // security: validate assignment
            try secure.validateshellsafe(var_assignment);

            if (std.mem.indexofscalar(u8, var_assignment, '=')) |eq_pos| {
                const name = var_assignment[0..eq_pos];
                const value = var_assignment[eq_pos + 1..];

                // additional validation for exported variables
                if (name.len == 0 or value.len > secure.max_env_value_length) {
                    return exitstatus{ .code = 1, .signal = null };
                }

                try self.environment.set(name, value);
            } else {
                std.debug.print("export: {s}: not a valid identifier\n", .{var_assignment});
                return exitstatus{ .code = 1, .signal = null };
            }
        }

        return exitstatus{ .code = 0, .signal = null };
    }

    fn builtinunset(self: *self, args: []const *const ast.astnode) !exitstatus {
        for (args) |arg| {
            try secure.validateshellsafe(arg.value);
            _ = self.environment.unset(arg.value);
        }
        return exitstatus{ .code = 0, .signal = null };
    }

    // security: command whitelist
    fn iscommandallowed(self: *self, cmd_name: []const u8) bool {
        for (self.command_whitelist) |allowed_cmd| {
            if (std.crypto.utils.timingsafeeql(u8, cmd_name, allowed_cmd)) {
                return true;
            }
        }
        return false;
    }
};

// default safe command whitelist
const default_safe_commands = [_][]const u8{
    "cat", "ls", "grep", "wc", "sort", "head", "tail", "cut", "tr",
    "date", "whoami", "id", "uname",
    // note: no potentially dangerous commands like rm, chmod, su, etc.
};

// compile-time security checks
comptime {
    // ensure we don't accidentally include dangerous commands
    for (default_safe_commands) |cmd| {
        if (std.mem.eql(u8, cmd, "rm") or
            std.mem.eql(u8, cmd, "rmdir") or
            std.mem.eql(u8, cmd, "chmod") or
            std.mem.eql(u8, cmd, "chown") or
            std.mem.eql(u8, cmd, "su") or
            std.mem.eql(u8, cmd, "sudo")) {
            @compileerror("dangerous command in whitelist: " ++ cmd);
        }
    }
}