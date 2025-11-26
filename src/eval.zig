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
        .case_statement => evaluateCase(shell, node),
        else => {
            try shell.stdout().writeAll("unsupported AST node type\n");
            return 1;
        },
    };
}

// Fast path for [ and test builtins - uses stack buffers to avoid allocations
fn evaluateTestBuiltinFast(shell: *Shell, node: *const ast.AstNode) !u8 {
    const is_bracket = node.children[0].value.len == 1 and node.children[0].value[0] == '[';

    // Stack-allocated buffers for expanded arguments (max 8 args, 256 bytes each)
    var arg_buffers: [8][256]u8 = undefined;
    var arg_slices: [8][]const u8 = undefined;
    var arg_count: usize = 0;

    // Skip command name ([ or test) and closing ] if present
    const start_idx: usize = 1;
    var end_idx = node.children.len;

    // For [ command, check for closing ]
    if (is_bracket and end_idx > start_idx) {
        const last = node.children[end_idx - 1].value;
        if (last.len == 1 and last[0] == ']') {
            end_idx -= 1;
        } else {
            try shell.stdout().writeAll("[: missing ]\n");
            return 2;
        }
    }

    // Expand arguments into stack buffers
    for (node.children[start_idx..end_idx]) |arg_node| {
        if (arg_count >= 8) break; // max args

        const arg = arg_node.value;
        const dest = &arg_buffers[arg_count];

        // Fast variable expansion into stack buffer
        const expanded_len = try expandVariableFast(shell, arg, dest);
        arg_slices[arg_count] = dest[0..expanded_len];
        arg_count += 1;
    }

    // Evaluate test expression with stack-allocated args
    const result = evaluateTestExpr(arg_slices[0..arg_count]);
    return if (result) 0 else 1;
}

// Fast variable expansion that writes to a provided buffer (no allocation)
fn expandVariableFast(shell: *Shell, input: []const u8, dest: *[256]u8) !usize {
    // Fast path: no variables
    if (std.mem.indexOfScalar(u8, input, '$') == null) {
        const len = @min(input.len, 256);
        @memcpy(dest[0..len], input[0..len]);
        return len;
    }

    var out_pos: usize = 0;
    var i: usize = 0;

    while (i < input.len and out_pos < 256) {
        if (input[i] == '$' and i + 1 < input.len) {
            i += 1;

            // Handle $? (exit code)
            if (input[i] == '?') {
                const exit_str = std.fmt.bufPrint(dest[out_pos..], "{d}", .{shell.last_exit_code}) catch break;
                out_pos += exit_str.len;
                i += 1;
                continue;
            }

            // Handle $((expr))
            if (i + 1 < input.len and input[i] == '(' and input[i + 1] == '(') {
                i += 2;
                const expr_start = i;
                var paren_count: u32 = 2;
                while (i < input.len and paren_count > 0) {
                    if (input[i] == '(') paren_count += 1;
                    if (input[i] == ')') paren_count -= 1;
                    if (paren_count > 0) i += 1;
                }
                if (paren_count == 0 and i > 0) {
                    const expr = input[expr_start .. i - 1];
                    i += 1; // skip final )
                    const arith_result = try shell.evaluateArithmetic(expr);
                    const result_str = std.fmt.bufPrint(dest[out_pos..], "{d}", .{arith_result}) catch break;
                    out_pos += result_str.len;
                    continue;
                }
            }

            // Simple $VAR
            const name_start = i;
            while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_')) {
                i += 1;
            }

            if (i > name_start) {
                const var_name = input[name_start..i];
                // Look up in shell variables first, then env
                if (shell.variables.get(var_name)) |value| {
                    const copy_len = @min(value.len, 256 - out_pos);
                    @memcpy(dest[out_pos..][0..copy_len], value[0..copy_len]);
                    out_pos += copy_len;
                } else if (std.posix.getenv(var_name)) |value| {
                    const copy_len = @min(value.len, 256 - out_pos);
                    @memcpy(dest[out_pos..][0..copy_len], value[0..copy_len]);
                    out_pos += copy_len;
                }
            } else {
                // Lone $
                if (out_pos < 256) {
                    dest[out_pos] = '$';
                    out_pos += 1;
                }
            }
        } else {
            dest[out_pos] = input[i];
            out_pos += 1;
            i += 1;
        }
    }

    return out_pos;
}

pub fn evaluateCommand(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len == 0) return 1;

    // Fast path for test builtin - avoid allocations in tight loops
    const raw_cmd = node.children[0].value;
    if ((raw_cmd.len == 1 and raw_cmd[0] == '[') or std.mem.eql(u8, raw_cmd, "test")) {
        return evaluateTestBuiltinFast(shell, node);
    }

    // expand command name (for ~/path/to/cmd)
    const cmd_name = try shell.expandVariables(raw_cmd);
    defer shell.allocator.free(cmd_name);

    // alias expansion - substitute alias value for command name
    // but prevent infinite recursion for self-referencing aliases like "alias ls='ls --color=auto'"
    if (shell.aliases.get(cmd_name)) |alias_value| {
        // check if alias value starts with the same command (self-reference)
        const first_word_end = std.mem.indexOfScalar(u8, alias_value, ' ') orelse alias_value.len;
        const first_word = alias_value[0..first_word_end];

        // skip expansion if alias is self-referencing (e.g., ls -> ls --color=auto)
        if (!std.mem.eql(u8, first_word, cmd_name)) {
            // build new command: alias_value + remaining args
            var new_cmd = std.ArrayListUnmanaged(u8){};
            defer new_cmd.deinit(shell.allocator);

            try new_cmd.appendSlice(shell.allocator, alias_value);

            // append remaining arguments
            for (node.children[1..]) |arg_node| {
                try new_cmd.append(shell.allocator, ' ');
                try new_cmd.appendSlice(shell.allocator, arg_node.value);
            }

            // recursively execute the expanded command
            return shell.executeCommand(new_cmd.items);
        }
        // for self-referencing aliases, we'll add the extra args below
    }

    // get extra args from self-referencing alias (e.g., "--color=auto" from "ls --color=auto")
    const alias_extra_args = if (shell.aliases.get(cmd_name)) |alias_value| blk: {
        const first_word_end = std.mem.indexOfScalar(u8, alias_value, ' ') orelse alias_value.len;
        const first_word = alias_value[0..first_word_end];
        if (std.mem.eql(u8, first_word, cmd_name) and first_word_end < alias_value.len) {
            break :blk alias_value[first_word_end + 1 ..]; // args after first space
        }
        break :blk @as([]const u8, "");
    } else "";

    // expand glob patterns in arguments
    var expanded_args = try std.ArrayList([]const u8).initCapacity(shell.allocator, 16);
    defer {
        for (expanded_args.items) |arg| shell.allocator.free(arg);
        expanded_args.deinit(shell.allocator);
    }

    try expanded_args.append(shell.allocator, try shell.allocator.dupe(u8, cmd_name));

    // insert alias extra args (e.g., "--color=auto")
    if (alias_extra_args.len > 0) {
        var iter = std.mem.splitScalar(u8, alias_extra_args, ' ');
        while (iter.next()) |arg| {
            if (arg.len > 0) {
                try expanded_args.append(shell.allocator, try shell.allocator.dupe(u8, arg));
            }
        }
    }

    for (node.children[1..]) |arg_node| {
        const arg = arg_node.value;

        // First expand variables (skip for single-quoted strings)
        const var_expanded = if (arg_node.node_type == .string)
            try shell.allocator.dupe(u8, arg)
        else
            try shell.expandVariables(arg);
        defer shell.allocator.free(var_expanded);

        // Then expand globs (only if pattern contains glob chars)
        if (glob.hasGlobChars(var_expanded)) {
            const glob_results = try glob.expandGlob(shell.allocator, var_expanded);
            defer glob.freeGlobResults(shell.allocator, glob_results);

            if (glob_results.len == 0) {
                try expanded_args.append(shell.allocator, try shell.allocator.dupe(u8, var_expanded));
            } else {
                for (glob_results) |match| {
                    try expanded_args.append(shell.allocator, try shell.allocator.dupe(u8, match));
                }
            }
        } else {
            try expanded_args.append(shell.allocator, try shell.allocator.dupe(u8, var_expanded));
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
        var interpret_escapes = false;
        var print_newline = true;
        var arg_start: usize = 1;

        // parse flags
        while (arg_start < expanded_args.items.len) {
            const arg = expanded_args.items[arg_start];
            if (arg.len >= 2 and arg[0] == '-') {
                var valid_flag = true;
                var has_e = false;
                var has_n = false;
                for (arg[1..]) |c| {
                    switch (c) {
                        'e' => has_e = true,
                        'n' => has_n = true,
                        'E' => {}, // disable escapes (default)
                        else => {
                            valid_flag = false;
                            break;
                        },
                    }
                }
                if (valid_flag) {
                    if (has_e) interpret_escapes = true;
                    if (has_n) print_newline = false;
                    arg_start += 1;
                    continue;
                }
            }
            break;
        }

        for (expanded_args.items[arg_start..], 0..) |arg, i| {
            if (i > 0) try shell.stdout().writeByte(' ');
            if (interpret_escapes) {
                try writeEscaped(shell.stdout(), arg);
            } else {
                try shell.stdout().writeAll(arg);
            }
        }
        if (print_newline) try shell.stdout().writeByte('\n');
        return 0;
    }

    // test builtin and [ alias
    if (std.mem.eql(u8, cmd_name, "test") or std.mem.eql(u8, cmd_name, "[")) {
        var test_args = expanded_args.items[1..];
        // if [ command, check for closing ]
        if (std.mem.eql(u8, cmd_name, "[")) {
            if (test_args.len == 0 or !std.mem.eql(u8, test_args[test_args.len - 1], "]")) {
                try shell.stdout().writeAll("[: missing ]\n");
                return 2;
            }
            test_args = test_args[0 .. test_args.len - 1];
        }
        const result = evaluateTestExpr(test_args);
        return if (result) 0 else 1;
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
        // set -- arg1 arg2 ... sets positional parameters
        if (expanded_args.items.len >= 2 and std.mem.eql(u8, expanded_args.items[1], "--")) {
            // clear existing positional parameters
            var i: usize = 1;
            while (i <= 99) : (i += 1) {
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch break;
                if (shell.variables.fetchRemove(num_str)) |kv| {
                    shell.allocator.free(kv.key);
                    shell.allocator.free(kv.value);
                } else break;
            }
            // set new positional parameters
            for (expanded_args.items[2..], 1..) |arg, idx| {
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{idx}) catch continue;
                try setShellVar(shell, num_str, arg);
            }
            // set $# (number of arguments)
            var count_buf: [16]u8 = undefined;
            const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{expanded_args.items.len - 2}) catch "0";
            try setShellVar(shell, "#", count_str);
            return 0;
        }
        // set option [on|off]
        if (expanded_args.items.len < 2) {
            try shell.stdout().writeAll("usage: set <option> [on|off] or set -- args...\n");
            try shell.stdout().writeAll("options: git_prompt, vim\n");
            return 0;
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

    // continue and break builtins - return special values to be handled by loops
    if (std.mem.eql(u8, cmd_name, "continue")) {
        return 253; // special value for continue
    }
    if (std.mem.eql(u8, cmd_name, "break")) {
        return 254; // special value for break
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

    // use cached path lookup for faster execution
    if (shell.lookupCommand(cmd_name)) |full_path| {
        // free original and replace with duped cached path
        shell.allocator.free(expanded_args.items[0]);
        expanded_args.items[0] = shell.allocator.dupe(u8, full_path) catch cmd_name;
    }

    // direct fork/exec for performance
    const pid = std.posix.fork() catch {
        try shell.stdout().print("zish: fork failed\n", .{});
        return 1;
    };

    if (pid == 0) {
        // child process - exec the command
        // build null-terminated argv on stack
        var argv_buf: [256]?[*:0]const u8 = undefined;
        for (expanded_args.items, 0..) |arg, i| {
            argv_buf[i] = @ptrCast(arg.ptr);
        }
        argv_buf[expanded_args.items.len] = null;
        const argv = argv_buf[0..expanded_args.items.len :null];

        std.posix.execvpeZ(argv[0].?, argv, @ptrCast(std.os.environ.ptr)) catch {
            // exec failed - exit (parent will report error)
            std.posix.exit(127);
        };
    }

    // parent - ignore SIGINT while child runs
    var old_sigint: std.posix.Sigaction = undefined;
    const ignore_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &ignore_action, &old_sigint);
    defer std.posix.sigaction(std.posix.SIG.INT, &old_sigint, null);

    // wait for child
    const result = std.posix.waitpid(pid, 0);
    if (std.posix.W.IFEXITED(result.status)) {
        const code = std.posix.W.EXITSTATUS(result.status);
        if (code == 127) {
            try shell.stdout().print("zish: {s}: command not found\n", .{cmd_name});
        }
        return code;
    } else if (std.posix.W.IFSIGNALED(result.status)) {
        return @truncate(128 + std.posix.W.TERMSIG(result.status));
    }
    return 127;
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

    for (pipes) |*pipe_fds| {
        pipe_fds.* = try std.posix.pipe();
    }

    var pids = try shell.allocator.alloc(std.posix.pid_t, num_commands);
    defer shell.allocator.free(pids);

    // initialize pids to 0 so we can track which children were forked
    for (pids) |*pid| {
        pid.* = 0;
    }

    // cleanup pipes and kill already-forked children on error
    errdefer {
        for (pipes) |pipe_fds| {
            if (pipe_fds[0] != -1) std.posix.close(pipe_fds[0]);
            if (pipe_fds[1] != -1) std.posix.close(pipe_fds[1]);
        }
        // kill and reap any children that were already forked
        for (pids) |pid| {
            if (pid != 0) {
                std.posix.kill(pid, std.posix.SIG.TERM) catch {};
                _ = std.posix.waitpid(pid, 0);
            }
        }
    }

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
        // create file if doesn't exist, don't truncate if exists
        const file = try std.fs.cwd().createFile(expanded_target, .{ .truncate = false });
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
    } else if (std.mem.eql(u8, redirect_type, "<<<")) {
        // here string: create pipe, write string, connect to stdin
        const pipe_fds = try std.posix.pipe();
        defer std.posix.close(pipe_fds[0]);

        // write string to write end of pipe
        const content_with_newline = try std.fmt.allocPrint(shell.allocator, "{s}\n", .{expanded_target});
        defer shell.allocator.free(content_with_newline);
        _ = try std.posix.write(pipe_fds[1], content_with_newline);
        std.posix.close(pipe_fds[1]);

        // connect read end to stdin
        try std.posix.dup2(pipe_fds[0], std.posix.STDIN_FILENO);
    }

    return evaluateAst(shell, command);
}

pub fn evaluateList(shell: *Shell, node: *const ast.AstNode) !u8 {
    var last_status: u8 = 0;
    for (node.children) |child| {
        last_status = try evaluateAst(shell, child);
        shell.last_exit_code = last_status;
        // propagate break/continue signals up
        if (last_status == 253 or last_status == 254) return last_status;
    }
    return last_status;
}

pub fn evaluateAssignment(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len != 2) return 1;

    const name = node.children[0].value;
    const value = node.children[1].value;

    // Fast path for pure arithmetic assignments like i=$((i+1))
    if (value.len >= 5 and std.mem.startsWith(u8, value, "$((") and value[value.len - 2] == ')' and value[value.len - 1] == ')') {
        const expr = value[3 .. value.len - 2];
        const arith_result = shell.evaluateArithmetic(expr) catch 0;

        // Format result into stack buffer
        var result_buf: [32]u8 = undefined;
        const result_str = std.fmt.bufPrint(&result_buf, "{d}", .{arith_result}) catch return 1;

        // Try to update existing variable in-place, reusing buffer if possible
        if (shell.variables.getPtr(name)) |value_ptr| {
            const old_value = value_ptr.*;
            // Reuse existing buffer if it can hold the new value (avoid alloc/free)
            if (result_str.len <= old_value.len) {
                // Copy into existing buffer - this is a u8 slice, need to cast for write
                const writable: [*]u8 = @ptrCast(@constCast(old_value.ptr));
                @memcpy(writable[0..result_str.len], result_str);
                // Update slice length by replacing with trimmed slice
                value_ptr.* = writable[0..result_str.len];
            } else {
                // Need larger buffer - free and allocate
                shell.allocator.free(old_value);
                value_ptr.* = try shell.allocator.dupe(u8, result_str);
            }
            return 0;
        }

        // New variable - need to allocate name and value
        const name_copy = try shell.allocator.dupe(u8, name);
        const value_copy = try shell.allocator.dupe(u8, result_str);
        try shell.variables.put(name_copy, value_copy);
        return 0;
    }

    // expand value BEFORE removing old variable (in case value references the variable being assigned)
    const expanded_value = try shell.expandVariables(value);
    defer shell.allocator.free(expanded_value);

    // Try to update existing variable in-place (reuse key)
    if (shell.variables.getPtr(name)) |value_ptr| {
        shell.allocator.free(value_ptr.*);
        value_ptr.* = try shell.allocator.dupe(u8, expanded_value);
        return 0;
    }

    // New variable - allocate name and value
    const name_copy = try shell.allocator.dupe(u8, name);
    const value_copy = try shell.allocator.dupe(u8, expanded_value);
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
        if (last_status == 254) break; // break
        if (last_status == 253) { // continue
            last_status = 0;
            iterations += 1;
            continue;
        }
        iterations += 1;
    }

    if (iterations >= max_iterations) {
        try shell.stdout().writeAll("while: iteration limit reached\n");
        return 1;
    }

    return if (last_status == 254) 0 else last_status;
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
        if (last_status == 254) break; // break
        if (last_status == 253) { // continue
            last_status = 0;
            iterations += 1;
            continue;
        }
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
    var should_break = false;

    outer: for (values) |value_node| {
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
            if (last_status == 254) { // break
                should_break = true;
                break :outer;
            }
            if (last_status == 253) { // continue
                last_status = 0;
                continue;
            }
        }
    }

    return if (should_break) 0 else last_status;
}

pub fn evaluateSubshell(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len == 0) return 1;
    return evaluateAst(shell, node.children[0]);
}

pub fn evaluateCase(shell: *Shell, node: *const ast.AstNode) !u8 {
    // case structure: children[0] = expr, children[1..] = case_items
    if (node.children.len < 1) return 1;

    // expand the expression being matched
    const expr_value = try shell.expandVariables(node.children[0].value);
    defer shell.allocator.free(expr_value);

    // iterate through case items (children[1..])
    for (node.children[1..]) |case_item| {
        if (case_item.node_type != .case_item) continue;

        // patterns are stored in case_item.value, separated by '|'
        const patterns = case_item.value;
        var pattern_iter = std.mem.splitScalar(u8, patterns, '|');

        while (pattern_iter.next()) |pattern| {
            // expand variables in pattern
            const expanded_pattern = try shell.expandVariables(pattern);
            defer shell.allocator.free(expanded_pattern);

            // check if pattern matches
            if (glob.matchGlob(expanded_pattern, expr_value)) {
                // execute the body (case_item.children[0])
                if (case_item.children.len > 0) {
                    return evaluateAst(shell, case_item.children[0]);
                }
                return 0;
            }
        }
    }

    // no pattern matched
    return 0;
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
            'e', 'a' => blk: {
                // file exists (-e or -a)
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

// helper for echo -e escape sequences
fn writeEscaped(writer: anytype, input: []const u8) !void {
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            switch (next) {
                'n' => {
                    try writer.writeByte('\n');
                    i += 2;
                },
                't' => {
                    try writer.writeByte('\t');
                    i += 2;
                },
                'r' => {
                    try writer.writeByte('\r');
                    i += 2;
                },
                '\\' => {
                    try writer.writeByte('\\');
                    i += 2;
                },
                'a' => {
                    try writer.writeByte(0x07); // bell
                    i += 2;
                },
                'b' => {
                    try writer.writeByte(0x08); // backspace
                    i += 2;
                },
                'e' => {
                    try writer.writeByte(0x1b); // escape
                    i += 2;
                },
                'f' => {
                    try writer.writeByte(0x0c); // form feed
                    i += 2;
                },
                'v' => {
                    try writer.writeByte(0x0b); // vertical tab
                    i += 2;
                },
                '0' => {
                    // octal escape \0nnn
                    var val: u8 = 0;
                    var j: usize = i + 2;
                    var digits: usize = 0;
                    while (j < input.len and digits < 3) {
                        const c = input[j];
                        if (c >= '0' and c <= '7') {
                            val = val * 8 + (c - '0');
                            j += 1;
                            digits += 1;
                        } else break;
                    }
                    try writer.writeByte(val);
                    i = j;
                },
                'x' => {
                    // hex escape \xHH
                    if (i + 3 < input.len) {
                        const hex = input[i + 2 .. i + 4];
                        if (std.fmt.parseInt(u8, hex, 16)) |val| {
                            try writer.writeByte(val);
                            i += 4;
                            continue;
                        } else |_| {}
                    }
                    try writer.writeByte(input[i]);
                    i += 1;
                },
                else => {
                    try writer.writeByte(input[i]);
                    i += 1;
                },
            }
        } else {
            try writer.writeByte(input[i]);
            i += 1;
        }
    }
}
