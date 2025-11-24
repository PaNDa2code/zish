// expand.zig - Variable and tilde expansion for zish
const std = @import("std");

/// Expand variables and tilde in input string
pub fn expandVariables(
    allocator: std.mem.Allocator,
    input: []const u8,
    variables: std.StringHashMap([]const u8),
    last_exit_code: u8,
    captureCommand: ?*const fn ([]const u8) anyerror![]const u8,
) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len);
    defer result.deinit(allocator);

    var i: usize = 0;

    // Tilde expansion at start
    if (input.len > 0 and input[0] == '~') {
        if (input.len == 1 or input[1] == '/') {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch "";
            defer if (home.len > 0) allocator.free(home);
            try result.appendSlice(allocator, home);
            i = 1;
        }
    }

    while (i < input.len) {
        if (input[i] == '$' and i + 1 < input.len) {
            i += 1;

            // Handle $?
            if (i < input.len and input[i] == '?') {
                var exit_code_buf: [8]u8 = undefined;
                const exit_code_str = std.fmt.bufPrint(&exit_code_buf, "{d}", .{last_exit_code}) catch "0";
                try result.appendSlice(allocator, exit_code_str);
                i += 1;
                continue;
            }

            // check for $((arithmetic))
            if (i + 1 < input.len and input[i] == '(' and input[i+1] == '(') {
                i += 2;
                const expr_start = i;

                var paren_count: u32 = 2;
                while (i < input.len and paren_count > 0) {
                    if (input[i] == '(') {
                        paren_count += 1;
                    } else if (input[i] == ')') {
                        paren_count -= 1;
                        if (paren_count == 0) break;
                    }
                    i += 1;
                }

                if (paren_count == 0) {
                    const expr = input[expr_start..i-1];
                    i += 2;
                    const arith_result = try evaluateArithmetic(
                        allocator,
                        expr,
                        variables
                    );
                    var buf: [32]u8 = undefined;
                    const result_str = std.fmt.bufPrint(
                        &buf,
                        "{d}",
                        .{arith_result}
                    ) catch "0";
                    try result.appendSlice(allocator, result_str);
                    continue;
                }
            }

            // check for $(command)
            if (i < input.len and input[i] == '(' and captureCommand != null) {
                i += 1;
                const cmd_start = i;

                var paren_count: u32 = 1;
                while (i < input.len and paren_count > 0) {
                    if (input[i] == '(') paren_count += 1;
                    if (input[i] == ')') paren_count -= 1;
                    if (paren_count > 0) i += 1;
                }

                if (paren_count == 0) {
                    const command = input[cmd_start..i];
                    i += 1;
                    const cmd_output = captureCommand.?(command) catch "";
                    try result.appendSlice(allocator, std.mem.trimRight(u8, cmd_output, "\n\r"));
                    continue;
                }

                try result.append(allocator, '$');
                try result.append(allocator, '(');
                i = cmd_start;
                continue;
            }

            // Handle $VAR
            const name_start = i;
            while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_')) {
                i += 1;
            }

            if (i > name_start) {
                const var_name = input[name_start..i];

                if (variables.get(var_name)) |value| {
                    try result.appendSlice(allocator, value);
                } else {
                    const env_value = std.process.getEnvVarOwned(allocator, var_name) catch null;
                    if (env_value) |val| {
                        defer allocator.free(val);
                        try result.appendSlice(allocator, val);
                    }
                }
            } else {
                try result.append(allocator, '$');
            }
        } else if (input[i] == '`') {
            // Backtick command substitution
            i += 1;
            const cmd_start = i;

            while (i < input.len and input[i] != '`') {
                i += 1;
            }

            if (i < input.len and captureCommand != null) {
                const command = input[cmd_start..i];
                i += 1;
                const cmd_output = captureCommand.?(command) catch "";
                try result.appendSlice(allocator, std.mem.trimRight(u8, cmd_output, "\n\r"));
            } else {
                try result.append(allocator, '`');
                i = cmd_start;
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

fn evaluateArithmetic(
    allocator: std.mem.Allocator,
    expr: []const u8,
    variables: std.StringHashMap([]const u8)
) !i64 {
    var trimmed = std.mem.trim(u8, expr, " \t\n\r");
    if (trimmed.len == 0) return 0;

    // check for operators (left-to-right, low to high precedence)
    for ([_]u8{'+', '-', '*', '/'}) |op| {
        if (std.mem.lastIndexOfScalar(u8, trimmed, op)) |op_pos| {
            if (op_pos > 0 and op_pos < trimmed.len - 1) {
                const left = try evaluateArithmetic(allocator, trimmed[0..op_pos], variables);
                const right = try evaluateArithmetic(allocator, trimmed[op_pos+1..], variables);
                return switch (op) {
                    '+' => left + right,
                    '-' => left - right,
                    '*' => left * right,
                    '/' => if (right != 0) @divTrunc(left, right) else 0,
                    else => 0,
                };
            }
        }
    }

    // try to parse as number
    if (std.fmt.parseInt(i64, trimmed, 10)) |num| {
        return num;
    } else |_| {
        // try as variable
        if (variables.get(trimmed)) |val| {
            return std.fmt.parseInt(i64, val, 10) catch 0;
        }
        // unknown variable defaults to 0
        return 0;
    }
}
