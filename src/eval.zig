// eval.zig - AST evaluation for zish
const std = @import("std");
const ast = @import("ast.zig");
const glob = @import("glob.zig");
const Shell = @import("Shell.zig");

pub fn evaluateAst(shell: *Shell, node: *const ast.AstNode) anyerror!u8 {
    return switch (node.node_type) {
        .command => evaluateCommand(shell, node),
        .pipeline => evaluatePipeline(shell, node),
        .logical_and => evaluateLogicalAnd(shell, node),
        .logical_or => evaluateLogicalOr(shell, node),
        .redirect => evaluateRedirect(shell, node),
        .list => evaluateList(shell, node),
        .assignment => evaluateAssignment(shell, node),
        .if_statement => evaluateIf(shell, node),
        .while_loop => evaluateWhile(shell, node),
        .until_loop => evaluateUntil(shell, node),
        .for_loop => evaluateFor(shell, node),
        .subshell => evaluateSubshell(shell, node),
        .test_expression => evaluateTest(shell, node),
        .function_def => evaluateFunctionDef(shell, node),
        else => {
            try shell.stdout().writeAll("unsupported AST node type\n");
            return 1;
        },
    };
}

pub fn evaluateCommand(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len == 0) return 1;

    const cmd_name = node.children[0].value;

    // expand glob patterns in arguments
    var expanded_args = try std.ArrayList([]const u8).initCapacity(shell.allocator, 16);
    defer {
        for (expanded_args.items) |arg| shell.allocator.free(arg);
        expanded_args.deinit(shell.allocator);
    }

    try expanded_args.append(shell.allocator, try shell.allocator.dupe(u8, cmd_name));

    for (node.children[1..]) |arg_node| {
        const arg = arg_node.value;

        // First expand variables (skip for single-quoted strings)
        const var_expanded = if (arg_node.node_type == .string)
            try shell.allocator.dupe(u8, arg)
        else
            try shell.expandVariables(arg);
        defer shell.allocator.free(var_expanded);

        // Then expand globs
        const glob_results = try glob.expandGlob(shell.allocator, var_expanded);
        defer glob.freeGlobResults(shell.allocator, glob_results);

        if (glob_results.len == 0) {
            try expanded_args.append(shell.allocator, try shell.allocator.dupe(u8, var_expanded));
        } else {
            for (glob_results) |match| {
                try expanded_args.append(shell.allocator, try shell.allocator.dupe(u8, match));
            }
        }
    }

    // check builtins
    if (std.mem.eql(u8, cmd_name, "exit")) {
        shell.running = false;
        if (expanded_args.items.len > 1) {
            const exit_code = std.fmt.parseInt(u8, expanded_args.items[1], 10) catch 1;
            std.process.exit(exit_code);
        }
        std.process.exit(0);
    }

    if (std.mem.eql(u8, cmd_name, "echo")) {
        for (expanded_args.items[1..], 0..) |arg, i| {
            if (i > 0) try shell.stdout().writeByte(' ');
            try shell.stdout().writeAll(arg);
        }
        try shell.stdout().writeByte('\n');
        return 0;
    }

    if (std.mem.eql(u8, cmd_name, "pwd")) {
        var buf: [4096]u8 = undefined;
        const cwd = try std.posix.getcwd(&buf);
        try shell.stdout().print("{s}\n", .{cwd});
        return 0;
    }

    // `..` builtin: go up one directory
    if (std.mem.eql(u8, cmd_name, "..")) {
        var cwd_buf: [4096]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch "";
        std.posix.chdir("..") catch {
            try shell.stdout().writeAll("..: cannot go up\n");
            return 1;
        };
        if (cwd.len > 0) try setShellVar(shell, "OLDPWD", cwd);
        return 0;
    }

    // `...` builtin: go up two directories
    if (std.mem.eql(u8, cmd_name, "...")) {
        var cwd_buf: [4096]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch "";
        std.posix.chdir("../..") catch {
            try shell.stdout().writeAll("...: cannot go up\n");
            return 1;
        };
        if (cwd.len > 0) try setShellVar(shell, "OLDPWD", cwd);
        return 0;
    }

    // `-` builtin: go to previous directory
    if (std.mem.eql(u8, cmd_name, "-")) {
        // check shell variables first, then environment
        const oldpwd = if (shell.variables.get("OLDPWD")) |v|
            try shell.allocator.dupe(u8, v)
        else
            std.process.getEnvVarOwned(shell.allocator, "OLDPWD") catch {
                try shell.stdout().writeAll("-: OLDPWD not set\n");
                return 1;
            };
        defer shell.allocator.free(oldpwd);

        // save current dir
        var cwd_buf: [4096]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch {
            try shell.stdout().writeAll("-: could not get current directory\n");
            return 1;
        };

        std.posix.chdir(oldpwd) catch {
            try shell.stdout().print("-: {s}: no such file or directory\n", .{oldpwd});
            return 1;
        };

        // update OLDPWD to where we were
        try setShellVar(shell, "OLDPWD", cwd);
        try shell.stdout().print("{s}\n", .{oldpwd});
        return 0;
    }

    if (std.mem.eql(u8, cmd_name, "cd")) {
        // save current directory to OLDPWD
        var cwd_buf: [4096]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch "";

        const path = if (expanded_args.items.len > 1) blk: {
            const arg = expanded_args.items[1];
            // handle cd -
            if (std.mem.eql(u8, arg, "-")) {
                const oldpwd = if (shell.variables.get("OLDPWD")) |v|
                    try shell.allocator.dupe(u8, v)
                else
                    std.process.getEnvVarOwned(shell.allocator, "OLDPWD") catch {
                        try shell.stdout().writeAll("cd: OLDPWD not set\n");
                        return 1;
                    };
                break :blk oldpwd;
            }
            break :blk try shell.allocator.dupe(u8, arg);
        } else blk: {
            const home = std.process.getEnvVarOwned(shell.allocator, "HOME") catch {
                try shell.stdout().writeAll("cd: could not get HOME\n");
                return 1;
            };
            break :blk home;
        };
        defer shell.allocator.free(path);

        std.posix.chdir(path) catch {
            try shell.stdout().print("cd: {s}: no such file or directory\n", .{path});
            return 1;
        };

        // set OLDPWD after successful cd
        if (cwd.len > 0) {
            try setShellVar(shell, "OLDPWD", cwd);
        }

        // print new dir if we used cd -
        if (expanded_args.items.len > 1 and std.mem.eql(u8, expanded_args.items[1], "-")) {
            try shell.stdout().print("{s}\n", .{path});
        }
        return 0;
    }

    if (std.mem.eql(u8, cmd_name, "true")) {
        return 0;
    }

    if (std.mem.eql(u8, cmd_name, "false")) {
        return 1;
    }

    if (std.mem.eql(u8, cmd_name, "export")) {
        for (expanded_args.items[1..]) |arg| {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
                const name = arg[0..eq_pos];
                const value = arg[eq_pos + 1 ..];

                const name_copy = try shell.allocator.dupe(u8, name);
                const value_copy = try shell.allocator.dupe(u8, value);

                if (shell.variables.get(name_copy)) |old_value| {
                    shell.allocator.free(old_value);
                }

                try shell.variables.put(name_copy, value_copy);
            } else {
                try shell.stdout().print("export: {s}: not a valid identifier\n", .{arg});
                return 1;
            }
        }
        return 0;
    }

    // local - same as variable assignment (simplified, no true scope)
    if (std.mem.eql(u8, cmd_name, "local")) {
        for (expanded_args.items[1..]) |arg| {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
                const name = arg[0..eq_pos];
                const value = arg[eq_pos + 1 ..];
                try setShellVar(shell, name, value);
            } else {
                // local var without value - initialize to empty
                try setShellVar(shell, arg, "");
            }
        }
        return 0;
    }

    if (std.mem.eql(u8, cmd_name, "unset")) {
        for (expanded_args.items[1..]) |arg| {
            if (shell.variables.fetchRemove(arg)) |kv| {
                shell.allocator.free(kv.key);
                shell.allocator.free(kv.value);
            }
        }
        return 0;
    }

    if (std.mem.eql(u8, cmd_name, "set")) {
        // set option [on|off]
        if (expanded_args.items.len < 2) {
            try shell.stdout().writeAll("usage: set <option> [on|off]\n");
            try shell.stdout().writeAll("options: git_prompt\n");
            return 1;
        }
        const option = expanded_args.items[1];
        const value = if (expanded_args.items.len > 2) expanded_args.items[2] else "on";
        const enabled = std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");

        if (std.mem.eql(u8, option, "git_prompt")) {
            shell.show_git_info = enabled;
        } else if (std.mem.eql(u8, option, "vim")) {
            shell.vim_mode_enabled = enabled;
        } else {
            try shell.stdout().print("set: unknown option: {s}\n", .{option});
            return 1;
        }
        return 0;
    }

    if (std.mem.eql(u8, cmd_name, "history")) {
        const h = shell.history orelse {
            try shell.stdout().writeAll("history: not available\n");
            return 1;
        };

        // print all history entries
        for (h.entries.items, 1..) |entry, i| {
            const cmd = h.getCommand(entry);
            try shell.stdout().print("{d}  {s}\n", .{ i, cmd });
        }
        return 0;
    }

    if (std.mem.eql(u8, cmd_name, "chpw")) {
        const crypto_mod = @import("crypto.zig");

        // check for flags
        if (expanded_args.items.len > 1) {
            const arg = expanded_args.items[1];
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                // show help
                try shell.stdout().writeAll("usage:\n");
                try shell.stdout().writeAll("  chpw           set password (prompts securely)\n");
                try shell.stdout().writeAll("  chpw -r        remove password protection\n");
                try shell.stdout().writeAll("  chpw -s        show password status\n");
                try shell.stdout().writeAll("  chpw -h        show this help\n");
                return 0;
            } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--remove")) {
                // remove password protection
                if (!crypto_mod.isPasswordModeEnabled(shell.allocator)) {
                    try shell.stdout().writeAll("password protection not enabled\n");
                    return 0;
                }

                // check if history is available
                if (shell.history) |h| {
                    // generate new random key
                    var new_key: [32]u8 = undefined;
                    std.crypto.random.bytes(&new_key);

                    // re-encrypt history with new key
                    try h.reEncryptWithKey(new_key);

                    // save the new key to disk
                    try crypto_mod.saveKeyDirect(new_key);
                }

                // disable password mode
                try crypto_mod.disablePasswordMode(shell.allocator);

                try shell.stdout().writeAll("password protection removed\n");
                return 0;
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--status")) {
                // show status
                if (crypto_mod.isPasswordModeEnabled(shell.allocator)) {
                    try shell.stdout().writeAll("password protection: enabled\n");
                } else {
                    try shell.stdout().writeAll("password protection: disabled\n");
                }
                return 0;
            } else {
                try shell.stdout().writeAll("error: don't pass password as argument (security risk)\n");
                try shell.stdout().writeAll("usage:\n");
                try shell.stdout().writeAll("  chpw           set password (prompts securely)\n");
                try shell.stdout().writeAll("  chpw -r        remove password protection\n");
                try shell.stdout().writeAll("  chpw -s        show password status\n");
                return 1;
            }
        }

        // check if already password protected
        const already_protected = crypto_mod.isPasswordModeEnabled(shell.allocator);
        const log_mod = @import("history_log.zig");

        // if already protected, need old password to decrypt existing history atomically
        var old_entries: ?[]log_mod.EntryData = null;
        defer {
            if (old_entries) |entries| {
                for (entries) |entry| {
                    shell.allocator.free(entry.command);
                }
                shell.allocator.free(entries);
            }
        }

        if (already_protected) {
            const old_password = try crypto_mod.promptPassword(shell.allocator, "current password: ");
            defer shell.allocator.free(old_password);

            if (old_password.len == 0) {
                try shell.stdout().writeAll("password cannot be empty\n");
                return 1;
            }

            // derive old key and read all history entries from disk
            const old_key = try crypto_mod.deriveKeyFromPassword(old_password, shell.allocator);

            // validate old password by reading entries
            old_entries = log_mod.readAllWithKey(shell.allocator, old_key) catch |err| {
                if (err == error.AuthenticationFailed) {
                    try shell.stdout().writeAll("wrong password\n");
                    return 1;
                }
                return err;
            };

            if (old_entries.?.len == 0) {
                try shell.stdout().writeAll("warning: no history entries found (wrong password?)\n");
            }
        }

        // prompt for new password
        const new_password = try crypto_mod.promptPassword(shell.allocator, "new password: ");
        defer shell.allocator.free(new_password);

        if (new_password.len == 0) {
            try shell.stdout().writeAll("password cannot be empty\n");
            return 1;
        }

        // confirm password
        const confirm_password = try crypto_mod.promptPassword(shell.allocator, "confirm password: ");
        defer shell.allocator.free(confirm_password);

        if (!std.mem.eql(u8, new_password, confirm_password)) {
            try shell.stdout().writeAll("passwords don't match\n");
            return 1;
        }

        // derive new key
        const new_key = try crypto_mod.deriveKeyFromPassword(new_password, shell.allocator);

        // check if history is available
        if (shell.history) |h| {
            // if we have old entries from disk, merge them into history first
            if (old_entries) |entries| {
                for (entries) |entry| {
                    h.mergeEntry(entry) catch {};
                }
            }

            // re-encrypt all history with new key
            try h.reEncryptWithKey(new_key);
        }

        // enable password mode
        try crypto_mod.enablePasswordMode(shell.allocator);

        if (already_protected) {
            try shell.stdout().writeAll("password updated\n");
        } else {
            try shell.stdout().writeAll("password protection enabled\n");
        }

        return 0;
    }

    // check if it's a function call
    if (shell.functions.get(cmd_name)) |_| {
        // call function with remaining arguments
        return callFunction(shell, cmd_name, expanded_args.items[1..]) catch |err| {
            if (err == error.FunctionNotFound) {
                // shouldn't happen since we just checked, but handle anyway
            }
            return 1;
        };
    }

    // external command
    // restore terminal to normal mode so child can handle signals properly
    // only do this if stdin is a tty
    const is_tty = std.posix.isatty(std.posix.STDIN_FILENO);
    if (is_tty) {
        shell.disableRawMode();
    }
    defer if (is_tty) {
        shell.enableRawMode() catch {};
    };

    var child = std.process.Child.init(expanded_args.items, shell.allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.stdin_behavior = .Inherit;

    // ignore SIGINT in shell while child runs (child will receive it)
    var old_sigint: std.posix.Sigaction = undefined;
    const ignore_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &ignore_action, &old_sigint);
    defer std.posix.sigaction(std.posix.SIG.INT, &old_sigint, null);

    const term = child.spawnAndWait() catch {
        try shell.stdout().print("zish: {s}: command not found\n", .{cmd_name});
        return 127;
    };

    return switch (term) {
        .Exited => |code| code,
        .Signal => |sig| @truncate(128 + sig),
        else => 127,
    };
}

pub fn evaluatePipeline(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len < 2) return 1;

    const num_commands = node.children.len;
    const pipes = try shell.allocator.alloc([2]std.posix.fd_t, num_commands - 1);
    defer shell.allocator.free(pipes);

    // initialize to invalid fd for safe cleanup on error
    for (pipes) |*pipe_fds| {
        pipe_fds.*[0] = -1;
        pipe_fds.*[1] = -1;
    }

    // cleanup pipes on error (fork failure, etc)
    errdefer {
        for (pipes) |pipe_fds| {
            if (pipe_fds[0] != -1) std.posix.close(pipe_fds[0]);
            if (pipe_fds[1] != -1) std.posix.close(pipe_fds[1]);
        }
    }

    for (pipes) |*pipe_fds| {
        pipe_fds.* = try std.posix.pipe();
    }

    var pids = try shell.allocator.alloc(std.posix.pid_t, num_commands);
    defer shell.allocator.free(pids);

    for (node.children, 0..) |child, i| {
        const pid = try std.posix.fork();
        if (pid == 0) {
            if (i > 0) {
                try std.posix.dup2(pipes[i - 1][0], std.posix.STDIN_FILENO);
            }
            if (i < num_commands - 1) {
                try std.posix.dup2(pipes[i][1], std.posix.STDOUT_FILENO);
            }
            for (pipes) |pipe_fds| {
                std.posix.close(pipe_fds[0]);
                std.posix.close(pipe_fds[1]);
            }
            const status = evaluateAst(shell, child) catch 127;
            shell.stdout().flush() catch {};
            std.process.exit(status);
        } else {
            pids[i] = pid;
        }
    }

    for (pipes) |pipe_fds| {
        std.posix.close(pipe_fds[0]);
        std.posix.close(pipe_fds[1]);
    }

    // ignore SIGINT in shell while waiting for pipeline (children will receive it)
    var old_sigint: std.posix.Sigaction = undefined;
    const ignore_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &ignore_action, &old_sigint);
    defer std.posix.sigaction(std.posix.SIG.INT, &old_sigint, null);

    var last_status: u8 = 0;
    for (pids) |pid| {
        const result = std.posix.waitpid(pid, 0);
        if (std.posix.W.IFEXITED(result.status)) {
            last_status = std.posix.W.EXITSTATUS(result.status);
        } else if (std.posix.W.IFSIGNALED(result.status)) {
            last_status = @truncate(128 + std.posix.W.TERMSIG(result.status));
        } else {
            last_status = 127;
        }
    }

    return last_status;
}

pub fn evaluateLogicalAnd(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len != 2) return 1;

    const left_status = try evaluateAst(shell, node.children[0]);
    if (left_status == 0) {
        return evaluateAst(shell, node.children[1]);
    }
    return left_status;
}

pub fn evaluateLogicalOr(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len != 2) return 1;

    const left_status = try evaluateAst(shell, node.children[0]);
    if (left_status != 0) {
        return evaluateAst(shell, node.children[1]);
    }
    return left_status;
}

pub fn evaluateRedirect(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len != 2) return 1;

    const command = node.children[0];
    const target = node.children[1];
    const redirect_type = node.value;

    const expanded_target = if (target.node_type == .string)
        try shell.allocator.dupe(u8, target.value)
    else
        try shell.expandVariables(target.value);
    defer shell.allocator.free(expanded_target);

    const stdin_backup = try std.posix.dup(std.posix.STDIN_FILENO);
    const stdout_backup = try std.posix.dup(std.posix.STDOUT_FILENO);
    const stderr_backup = try std.posix.dup(std.posix.STDERR_FILENO);
    defer {
        std.posix.dup2(stdin_backup, std.posix.STDIN_FILENO) catch {};
        std.posix.dup2(stdout_backup, std.posix.STDOUT_FILENO) catch {};
        std.posix.dup2(stderr_backup, std.posix.STDERR_FILENO) catch {};
        std.posix.close(stdin_backup);
        std.posix.close(stdout_backup);
        std.posix.close(stderr_backup);
    }

    if (std.mem.eql(u8, redirect_type, ">")) {
        const file = try std.fs.cwd().createFile(expanded_target, .{ .truncate = true });
        defer file.close();
        try std.posix.dup2(file.handle, std.posix.STDOUT_FILENO);
    } else if (std.mem.eql(u8, redirect_type, ">>")) {
        const file = try std.fs.cwd().openFile(expanded_target, .{ .mode = .write_only });
        defer file.close();
        try file.seekFromEnd(0);
        try std.posix.dup2(file.handle, std.posix.STDOUT_FILENO);
    } else if (std.mem.eql(u8, redirect_type, "<")) {
        const file = try std.fs.cwd().openFile(expanded_target, .{ .mode = .read_only });
        defer file.close();
        try std.posix.dup2(file.handle, std.posix.STDIN_FILENO);
    } else if (std.mem.eql(u8, redirect_type, "2>")) {
        const file = try std.fs.cwd().createFile(expanded_target, .{ .truncate = true });
        defer file.close();
        try std.posix.dup2(file.handle, std.posix.STDERR_FILENO);
    } else if (std.mem.eql(u8, redirect_type, "2>&1")) {
        try std.posix.dup2(std.posix.STDOUT_FILENO, std.posix.STDERR_FILENO);
    }

    return evaluateAst(shell, command);
}

pub fn evaluateList(shell: *Shell, node: *const ast.AstNode) !u8 {
    var last_status: u8 = 0;
    for (node.children) |child| {
        last_status = try evaluateAst(shell, child);
        shell.last_exit_code = last_status;
    }
    return last_status;
}

pub fn evaluateAssignment(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len != 2) return 1;

    const name = node.children[0].value;
    const value = node.children[1].value;

    // expand value BEFORE removing old variable (in case value references the variable being assigned)
    const expanded_value = try shell.expandVariables(value);
    defer shell.allocator.free(expanded_value);
    const value_copy = try shell.allocator.dupe(u8, expanded_value);

    // now remove old variable after expansion is complete
    if (shell.variables.fetchRemove(name)) |kv| {
        shell.allocator.free(kv.key);
        shell.allocator.free(kv.value);
    }

    const name_copy = try shell.allocator.dupe(u8, name);
    try shell.variables.put(name_copy, value_copy);
    return 0;
}

pub fn evaluateIf(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len < 2) return 1;

    const condition = try evaluateAst(shell, node.children[0]);

    if (condition == 0) {
        return evaluateAst(shell, node.children[1]);
    } else if (node.children.len > 2) {
        return evaluateAst(shell, node.children[2]);
    }

    return 0;
}

pub fn evaluateWhile(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len != 2) return 1;

    var last_status: u8 = 0;
    var iterations: u32 = 0;
    const max_iterations: u32 = 10000;

    while (iterations < max_iterations) {
        const condition = try evaluateAst(shell, node.children[0]);
        if (condition != 0) break;

        last_status = try evaluateAst(shell, node.children[1]);
        iterations += 1;
    }

    if (iterations >= max_iterations) {
        try shell.stdout().writeAll("while: iteration limit reached\n");
        return 1;
    }

    return last_status;
}

pub fn evaluateUntil(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len != 2) return 1;

    var last_status: u8 = 0;
    var iterations: u32 = 0;
    const max_iterations: u32 = 10000;

    while (iterations < max_iterations) {
        const condition = try evaluateAst(shell, node.children[0]);
        if (condition == 0) break;

        last_status = try evaluateAst(shell, node.children[1]);
        iterations += 1;
    }

    if (iterations >= max_iterations) {
        try shell.stdout().writeAll("until: iteration limit reached\n");
        return 1;
    }

    return last_status;
}

pub fn evaluateFor(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len < 3) return 1;

    const variable = node.children[0];
    const body = node.children[node.children.len - 1];
    const values = node.children[1 .. node.children.len - 1];

    var last_status: u8 = 0;

    for (values) |value_node| {
        const var_expanded = if (value_node.node_type == .string)
            try shell.allocator.dupe(u8, value_node.value)
        else
            try shell.expandVariables(value_node.value);
        defer shell.allocator.free(var_expanded);

        const glob_results = try glob.expandGlob(shell.allocator, var_expanded);
        defer glob.freeGlobResults(shell.allocator, glob_results);

        const items_to_iterate = if (glob_results.len == 0)
            &[_][]const u8{var_expanded}
        else
            glob_results;

        for (items_to_iterate) |item| {
            if (shell.variables.fetchRemove(variable.value)) |kv| {
                shell.allocator.free(kv.key);
                shell.allocator.free(kv.value);
            }

            const name_copy = try shell.allocator.dupe(u8, variable.value);
            const value_copy = try shell.allocator.dupe(u8, item);
            try shell.variables.put(name_copy, value_copy);

            last_status = try evaluateAst(shell, body);
        }
    }

    return last_status;
}

pub fn evaluateSubshell(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len == 0) return 1;
    return evaluateAst(shell, node.children[0]);
}

pub fn evaluateTest(shell: *Shell, node: *const ast.AstNode) !u8 {
    // expand variables in children
    var args = try std.ArrayList([]const u8).initCapacity(shell.allocator, 16);
    defer {
        for (args.items) |arg| shell.allocator.free(arg);
        args.deinit(shell.allocator);
    }

    for (node.children) |child| {
        const expanded = try shell.expandVariables(child.value);
        try args.append(shell.allocator, expanded);
    }

    const result = evaluateTestExpr(args.items);
    return if (result) 0 else 1;
}

fn evaluateTestExpr(args: []const []const u8) bool {
    if (args.len == 0) return false;

    var i: usize = 0;
    var negate = false;

    // check for negation
    if (args.len > 0 and std.mem.eql(u8, args[0], "!")) {
        negate = true;
        i = 1;
    }

    if (i >= args.len) return negate;

    const result = evaluateTestPrimary(args[i..]);
    return if (negate) !result else result;
}

fn evaluateTestPrimary(args: []const []const u8) bool {
    if (args.len == 0) return false;

    const first = args[0];

    // unary file tests: -x, -f, -d, -e, -r, -w, -s
    if (first.len == 2 and first[0] == '-' and args.len >= 2) {
        const path = args[1];
        const fs = std.fs;

        return switch (first[1]) {
            'e' => blk: {
                // file exists
                fs.cwd().access(path, .{}) catch break :blk false;
                break :blk true;
            },
            'f' => blk: {
                // regular file
                const stat = fs.cwd().statFile(path) catch break :blk false;
                break :blk stat.kind == .file;
            },
            'd' => blk: {
                // directory
                const stat = fs.cwd().statFile(path) catch break :blk false;
                break :blk stat.kind == .directory;
            },
            'r' => blk: {
                // readable
                fs.cwd().access(path, .{ .mode = .read_only }) catch break :blk false;
                break :blk true;
            },
            'w' => blk: {
                // writable
                fs.cwd().access(path, .{ .mode = .write_only }) catch break :blk false;
                break :blk true;
            },
            'x' => blk: {
                // executable - check if file exists and has execute permission
                const file = fs.cwd().openFile(path, .{}) catch break :blk false;
                defer file.close();
                const stat = file.stat() catch break :blk false;
                // check execute bit for owner
                break :blk (stat.mode & 0o100) != 0;
            },
            's' => blk: {
                // file exists and has size > 0
                const stat = fs.cwd().statFile(path) catch break :blk false;
                break :blk stat.size > 0;
            },
            'z' => blk: {
                // string is empty (unary on second arg)
                break :blk args[1].len == 0;
            },
            'n' => blk: {
                // string is non-empty
                break :blk args[1].len > 0;
            },
            else => false,
        };
    }

    // binary operators: ==, !=, -eq, -ne, -lt, -gt, -le, -ge
    if (args.len >= 3) {
        const left = args[0];
        const op = args[1];
        const right = args[2];

        if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "=")) {
            return std.mem.eql(u8, left, right);
        } else if (std.mem.eql(u8, op, "!=")) {
            return !std.mem.eql(u8, left, right);
        } else if (std.mem.eql(u8, op, "-eq")) {
            const l = std.fmt.parseInt(i64, left, 10) catch return false;
            const r = std.fmt.parseInt(i64, right, 10) catch return false;
            return l == r;
        } else if (std.mem.eql(u8, op, "-ne")) {
            const l = std.fmt.parseInt(i64, left, 10) catch return false;
            const r = std.fmt.parseInt(i64, right, 10) catch return false;
            return l != r;
        } else if (std.mem.eql(u8, op, "-lt")) {
            const l = std.fmt.parseInt(i64, left, 10) catch return false;
            const r = std.fmt.parseInt(i64, right, 10) catch return false;
            return l < r;
        } else if (std.mem.eql(u8, op, "-gt")) {
            const l = std.fmt.parseInt(i64, left, 10) catch return false;
            const r = std.fmt.parseInt(i64, right, 10) catch return false;
            return l > r;
        } else if (std.mem.eql(u8, op, "-le")) {
            const l = std.fmt.parseInt(i64, left, 10) catch return false;
            const r = std.fmt.parseInt(i64, right, 10) catch return false;
            return l <= r;
        } else if (std.mem.eql(u8, op, "-ge")) {
            const l = std.fmt.parseInt(i64, left, 10) catch return false;
            const r = std.fmt.parseInt(i64, right, 10) catch return false;
            return l >= r;
        }
    }

    // single arg: non-empty string is true
    return first.len > 0;
}

fn setShellVar(shell: *Shell, name: []const u8, value: []const u8) !void {
    const value_copy = try shell.allocator.dupe(u8, value);
    errdefer shell.allocator.free(value_copy);

    // check if key exists
    if (shell.variables.getKey(name)) |existing_key| {
        // key exists, just update value
        if (try shell.variables.fetchPut(existing_key, value_copy)) |old| {
            shell.allocator.free(old.value);
        }
    } else {
        // new key, need to dupe it
        const name_copy = try shell.allocator.dupe(u8, name);
        try shell.variables.put(name_copy, value_copy);
    }
}

pub fn evaluateFunctionDef(shell: *Shell, node: *const ast.AstNode) !u8 {
    // node.value = function name, node.children[0] = body
    if (node.children.len == 0) return 1;

    const func_name = node.value;
    const body = node.children[0];

    // serialize body to string (simple approach - just value for now)
    var body_buf = std.ArrayListUnmanaged(u8){};
    defer body_buf.deinit(shell.allocator);

    try serializeAst(shell.allocator, &body_buf, body);

    // store function
    const name_copy = try shell.allocator.dupe(u8, func_name);
    errdefer shell.allocator.free(name_copy);
    const body_copy = try body_buf.toOwnedSlice(shell.allocator);

    if (try shell.functions.fetchPut(name_copy, body_copy)) |old| {
        // free old value but not key (fetchPut reuses key slot)
        shell.allocator.free(name_copy); // we don't need the new key copy
        shell.allocator.free(old.value);
    }

    return 0;
}

fn serializeAst(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), node: *const ast.AstNode) !void {
    switch (node.node_type) {
        .command => {
            for (node.children, 0..) |child, i| {
                if (i > 0) try buf.append(allocator, ' ');
                try buf.appendSlice(allocator, child.value);
            }
        },
        .list => {
            for (node.children, 0..) |child, i| {
                if (i > 0) try buf.appendSlice(allocator, "; ");
                try serializeAst(allocator, buf, child);
            }
        },
        .pipeline => {
            for (node.children, 0..) |child, i| {
                if (i > 0) try buf.appendSlice(allocator, " | ");
                try serializeAst(allocator, buf, child);
            }
        },
        .logical_and => {
            if (node.children.len >= 2) {
                try serializeAst(allocator, buf, node.children[0]);
                try buf.appendSlice(allocator, " && ");
                try serializeAst(allocator, buf, node.children[1]);
            }
        },
        .logical_or => {
            if (node.children.len >= 2) {
                try serializeAst(allocator, buf, node.children[0]);
                try buf.appendSlice(allocator, " || ");
                try serializeAst(allocator, buf, node.children[1]);
            }
        },
        .test_expression => {
            try buf.appendSlice(allocator, "[[ ");
            try buf.appendSlice(allocator, node.value);
            try buf.appendSlice(allocator, " ]]");
        },
        else => {
            try buf.appendSlice(allocator, node.value);
        },
    }
}

pub fn callFunction(shell: *Shell, name: []const u8, args: []const []const u8) !u8 {
    const body = shell.functions.get(name) orelse return error.FunctionNotFound;

    // set positional parameters $1, $2, etc.
    for (args, 1..) |arg, i| {
        var num_buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch continue;
        try setShellVar(shell, num_str, arg);
    }

    // execute function body
    const result = shell.executeCommand(body) catch |err| {
        // clear positional parameters
        for (args, 1..) |_, i| {
            var num_buf: [16]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch continue;
            _ = shell.variables.fetchRemove(num_str);
        }
        return err;
    };

    // clear positional parameters
    for (args, 1..) |_, i| {
        var num_buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch continue;
        if (shell.variables.fetchRemove(num_str)) |kv| {
            shell.allocator.free(kv.key);
            shell.allocator.free(kv.value);
        }
    }

    return result;
}
