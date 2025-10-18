// simple_history.zig - basic history without complex features

const std = @import("std");

const HistoryEntry = struct {
    command: []const u8,
    exit_code: u8,
};

pub const History = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(HistoryEntry),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, _: ?[]const u8) !*Self {
        const history = try allocator.create(Self);
        history.* = .{
            .allocator = allocator,
            .entries = try std.ArrayList(HistoryEntry).initCapacity(allocator, 100),
        };
        return history;
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.command);
        }
        self.entries.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn addCommand(self: *Self, command: []const u8, exit_code: u8) !void {
        if (command.len == 0) return;

        const cmd_copy = try self.allocator.dupe(u8, command);
        try self.entries.append(self.allocator, .{
            .command = cmd_copy,
            .exit_code = exit_code,
        });

        // keep only last 100 entries
        if (self.entries.items.len > 100) {
            const removed = self.entries.orderedRemove(0);
            self.allocator.free(removed.command);
        }
    }

    pub fn getStats(self: *Self) struct { total: usize, unique: usize } {
        return .{
            .total = self.entries.items.len,
            .unique = self.entries.items.len, // simplified
        };
    }

    pub fn fuzzySearch(self: *Self, query: []const u8, allocator: std.mem.Allocator) ![]FuzzyMatch {
        var matches = try std.ArrayList(FuzzyMatch).initCapacity(allocator, 10);

        for (self.entries.items) |entry| {
            if (std.mem.indexOf(u8, entry.command, query)) |_| {
                try matches.append(allocator, .{
                    .entry = &entry,
                    .score = 1.0,
                });
            }
        }

        return matches.toOwnedSlice(allocator);
    }
};

pub const FuzzyMatch = struct {
    entry: *const HistoryEntry,
    score: f32,
};