// brace.zig - Brace expansion for zish
const std = @import("std");

pub fn expandBraces(allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
    // check if input contains braces
    const open = std.mem.indexOf(u8, input, "{") orelse {
        // no braces, return single result
        const result = try allocator.alloc([]const u8, 1);
        result[0] = try allocator.dupe(u8, input);
        return result;
    };

    const close = std.mem.indexOfPos(u8, input, open, "}") orelse {
        // malformed, return as-is
        const result = try allocator.alloc([]const u8, 1);
        result[0] = try allocator.dupe(u8, input);
        return result;
    };

    const prefix = input[0..open];
    const suffix = input[close + 1 ..];
    const brace_content = input[open + 1 .. close];

    // check for range expansion {n..m}
    if (std.mem.indexOf(u8, brace_content, "..")) |dot_pos| {
        return expandRange(allocator, prefix, suffix, brace_content, dot_pos);
    }

    // check for list expansion {a,b,c}
    if (std.mem.indexOf(u8, brace_content, ",")) |_| {
        return expandList(allocator, prefix, suffix, brace_content);
    }

    // no expansion pattern found, return as-is
    const result = try allocator.alloc([]const u8, 1);
    result[0] = try allocator.dupe(u8, input);
    return result;
}

fn expandRange(allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8, content: []const u8, dot_pos: usize) ![][]const u8 {
    const start_str = content[0..dot_pos];
    const end_str = content[dot_pos + 2 ..];

    // try numeric range
    const start_num = std.fmt.parseInt(i32, start_str, 10) catch {
        // not numeric, try character range
        if (start_str.len == 1 and end_str.len == 1) {
            return expandCharRange(allocator, prefix, suffix, start_str[0], end_str[0]);
        }
        // invalid range, return as-is
        const result = try allocator.alloc([]const u8, 1);
        const full = try std.fmt.allocPrint(allocator, "{s}{{{s}}}{s}", .{ prefix, content, suffix });
        result[0] = full;
        return result;
    };

    const end_num = std.fmt.parseInt(i32, end_str, 10) catch {
        // invalid range, return as-is
        const result = try allocator.alloc([]const u8, 1);
        const full = try std.fmt.allocPrint(allocator, "{s}{{{s}}}{s}", .{ prefix, content, suffix });
        result[0] = full;
        return result;
    };

    // calculate range
    const count = @abs(end_num - start_num) + 1;
    const step: i32 = if (start_num <= end_num) 1 else -1;

    var results = try allocator.alloc([]const u8, @intCast(count));
    var current = start_num;
    var i: usize = 0;

    while (i < count) : (i += 1) {
        results[i] = try std.fmt.allocPrint(allocator, "{s}{d}{s}", .{ prefix, current, suffix });
        current += step;
    }

    return results;
}

fn expandCharRange(allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8, start: u8, end: u8) ![][]const u8 {
    const count = if (start <= end) end - start + 1 else start - end + 1;
    const step: i8 = if (start <= end) 1 else -1;

    var results = try allocator.alloc([]const u8, count);
    var current: i16 = start;
    var i: usize = 0;

    while (i < count) : (i += 1) {
        results[i] = try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ prefix, @as(u8, @intCast(current)), suffix });
        current += step;
    }

    return results;
}

fn expandList(allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8, content: []const u8) ![][]const u8 {
    // split by comma
    var items = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    defer items.deinit(allocator);

    var start: usize = 0;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == ',') {
            try items.append(allocator, content[start..i]);
            start = i + 1;
        }
    }
    // add last item
    try items.append(allocator, content[start..]);

    var results = try allocator.alloc([]const u8, items.items.len);
    for (items.items, 0..) |item, idx| {
        results[idx] = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, item, suffix });
    }

    return results;
}

pub fn freeBraceResults(allocator: std.mem.Allocator, results: [][]const u8) void {
    for (results) |result| {
        allocator.free(result);
    }
    allocator.free(results);
}
