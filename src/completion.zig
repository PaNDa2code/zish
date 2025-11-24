// completion.zig - Tab completion logic for zish
const std = @import("std");

pub const WordResult = struct {
    word: []const u8,
    start: usize,
    end: usize,
};

pub const CycleDirection = enum {
    forward,
    backward,
};

/// Extract word at cursor position from command string
pub fn extractWordAtCursor(cmd: []const u8, cursor_pos: usize) ?WordResult {
    if (cmd.len == 0) return null;

    var start = cursor_pos;
    var end = cursor_pos;

    // find start of word
    while (start > 0 and cmd[start - 1] != ' ') {
        start -= 1;
    }

    // find end of word
    while (end < cmd.len and cmd[end] != ' ') {
        end += 1;
    }

    if (start == end) return null;

    return WordResult{
        .word = cmd[start..end],
        .start = start,
        .end = end,
    };
}

/// Find completions for a pattern in a directory
pub fn findCompletions(
    allocator: std.mem.Allocator,
    search_dir: []const u8,
    pattern: []const u8,
) !std.ArrayList([]const u8) {
    var matches = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    errdefer {
        for (matches.items) |match| {
            allocator.free(match);
        }
        matches.deinit(allocator);
    }

    const dir = std.fs.cwd().openDir(search_dir, .{ .iterate = true }) catch return matches;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, pattern)) {
            const full_name = if (entry.kind == .directory)
                try std.fmt.allocPrint(allocator, "{s}/", .{entry.name})
            else
                try allocator.dupe(u8, entry.name);
            try matches.append(allocator, full_name);
        }
    }

    return matches;
}

/// Parse word to get search directory and pattern
pub fn parseWordForCompletion(word: []const u8) struct { dir: []const u8, pattern: []const u8 } {
    const search_dir: []const u8 = if (std.mem.lastIndexOf(u8, word, "/")) |last_slash| blk: {
        if (last_slash == 0) {
            break :blk "/";
        } else {
            break :blk word[0..last_slash];
        }
    } else ".";

    const pattern = if (std.mem.lastIndexOf(u8, word, "/")) |last_slash|
        word[last_slash + 1 ..]
    else
        word;

    return .{ .dir = search_dir, .pattern = pattern };
}

/// Calculate column layout for completion display
pub fn calculateColumnLayout(
    matches: []const []const u8,
    term_width: usize,
) struct { cols: usize, col_width: usize } {
    // find max match length
    var max_len: usize = 0;
    for (matches) |match| {
        if (match.len > max_len) max_len = match.len;
    }

    const col_width = max_len + 2; // padding
    const cols = @max(1, term_width / col_width);

    return .{ .cols = cols, .col_width = col_width };
}
