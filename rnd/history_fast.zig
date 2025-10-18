// history_fast.zig - ultra-fast history system with advanced search
// designed for microsecond-level response times

const std = @import("std");
const types = @import("types.zig");
const strings = @import("strings.zig");
const simd = @import("simd.zig");

// Compact history entry optimized for cache efficiency
const HistoryEntry = packed struct {
    // Pack into 64 bytes (cache line) for optimal performance
    command_hash: u64, // 8 bytes
    command_offset: u32, // 4 bytes - offset into string pool
    command_len: u16, // 2 bytes
    frequency: u16, // 2 bytes - usage frequency
    timestamp: u32, // 4 bytes - unix timestamp (compressed)
    exit_code: u8, // 1 byte
    session_id: u8, // 1 byte
    flags: u8, // 1 byte - various flags
    _padding: [39]u8 = [_]u8{0} ** 39, // 39 bytes padding to 64 bytes

    const SUCCESSFUL_FLAG = 1;
    const BOOKMARKED_FLAG = 2;

    pub fn isSuccessful(self: HistoryEntry) bool {
        return (self.flags & SUCCESSFUL_FLAG) != 0;
    }

    pub fn isBookmarked(self: HistoryEntry) bool {
        return (self.flags & BOOKMARKED_FLAG) != 0;
    }
};

// Fast fuzzy match result
const FuzzyMatch = struct {
    entry_index: u32,
    score: f32,
    match_positions: [8]u16, // positions of matched characters

    fn lessThan(_: void, a: FuzzyMatch, b: FuzzyMatch) bool {
        return a.score > b.score;
    }
};

// High-performance history manager
pub const FastHistory = struct {
    allocator: std.mem.Allocator,

    // Separate arrays for cache-friendly access
    entries: []HistoryEntry,
    entry_count: u32,
    max_entries: u32,

    // String pool for commands (reduces memory fragmentation)
    string_pool: []u8,
    string_pool_used: u32,
    string_pool_capacity: u32,

    // Hash table for O(1) duplicate detection
    hash_to_index: std.AutoHashMap(u64, u32),

    // Frequency-based ranking cache
    frequent_commands: [64]u32, // indices of most frequent commands
    frequent_count: u8,

    // Search cache for repeated queries
    search_cache: std.StringHashMap([]FuzzyMatch),
    cache_allocator: std.heap.ArenaAllocator,

    const Self = @This();
    const DEFAULT_MAX_ENTRIES = 50000;
    const STRING_POOL_SIZE = 2 * 1024 * 1024; // 2MB string pool

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const history = try allocator.create(Self);

        // Pre-allocate everything for maximum performance
        const entries = try allocator.alloc(HistoryEntry, DEFAULT_MAX_ENTRIES);
        const string_pool = try allocator.alloc(u8, STRING_POOL_SIZE);

        history.* = .{
            .allocator = allocator,
            .entries = entries,
            .entry_count = 0,
            .max_entries = DEFAULT_MAX_ENTRIES,
            .string_pool = string_pool,
            .string_pool_used = 0,
            .string_pool_capacity = STRING_POOL_SIZE,
            .hash_to_index = std.AutoHashMap(u64, u32).init(allocator),
            .frequent_commands = [_]u32{0} ** 64,
            .frequent_count = 0,
            .search_cache = std.StringHashMap([]FuzzyMatch).init(allocator),
            .cache_allocator = std.heap.ArenaAllocator.init(allocator),
        };

        try history.hash_to_index.ensureTotalCapacity(DEFAULT_MAX_ENTRIES);

        return history;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.string_pool);
        self.hash_to_index.deinit();
        self.search_cache.deinit();
        self.cache_allocator.deinit();
        self.allocator.destroy(self);
    }

    pub fn addCommand(self: *Self, command: []const u8, exit_code: u8) !void {
        if (command.len == 0 or command.len > types.MAX_COMMAND_LENGTH) return;

        const command_hash = simd.hashString(command);

        // Check for duplicate
        if (self.hash_to_index.get(command_hash)) |existing_index| {
            // Update frequency and move to end
            self.entries[existing_index].frequency += 1;
            self.entries[existing_index].timestamp = @intCast(std.time.timestamp());
            self.updateFrequentCommands(existing_index);
            self.invalidateSearchCache();
            return;
        }

        // Check if we have space
        if (self.entry_count >= self.max_entries) {
            try self.evictOldest();
        }

        if (self.string_pool_used + command.len >= self.string_pool_capacity) {
            try self.compactStringPool();
        }

        // Add new entry
        const command_offset = self.string_pool_used;
        @memcpy(self.string_pool[command_offset..command_offset + command.len], command);
        self.string_pool_used += @intCast(command.len);

        const entry_index = self.entry_count;
        self.entries[entry_index] = HistoryEntry{
            .command_hash = command_hash,
            .command_offset = @intCast(command_offset),
            .command_len = @intCast(command.len),
            .frequency = 1,
            .timestamp = @intCast(std.time.timestamp()),
            .exit_code = exit_code,
            .session_id = 1,
            .flags = if (exit_code == 0) HistoryEntry.SUCCESSFUL_FLAG else 0,
        };

        try self.hash_to_index.put(command_hash, entry_index);
        self.entry_count += 1;

        self.updateFrequentCommands(entry_index);
        self.invalidateSearchCache();
    }

    pub fn fuzzySearch(self: *Self, query: []const u8, allocator: std.mem.Allocator) ![]FuzzyMatch {
        if (query.len == 0) return &[_]FuzzyMatch{};

        // Check cache first
        if (self.search_cache.get(query)) |cached_results| {
            const results = try allocator.dupe(FuzzyMatch, cached_results);
            return results;
        }

        // Perform fuzzy search
        var matches = try std.ArrayList(FuzzyMatch).initCapacity(allocator, 100);
        defer matches.deinit();

        // Search through entries
        for (0..self.entry_count) |i| {
            const entry = self.entries[i];
            const command = self.getCommandText(entry);

            if (const score = self.calculateFuzzyScore(query, command, i)) |match_score| {
                try matches.append(FuzzyMatch{
                    .entry_index = @intCast(i),
                    .score = match_score.score,
                    .match_positions = match_score.positions,
                });
            }
        }

        // Sort by score (descending)
        std.sort.pdq(FuzzyMatch, matches.items, {}, FuzzyMatch.lessThan);

        // Cache results (top 50)
        const cache_size = @min(matches.items.len, 50);
        const cache_results = try self.cache_allocator.allocator().dupe(FuzzyMatch, matches.items[0..cache_size]);
        try self.search_cache.put(query, cache_results);

        return try allocator.dupe(FuzzyMatch, matches.items);
    }

    pub fn getEntry(self: *Self, match: FuzzyMatch) HistoryEntry {
        return self.entries[match.entry_index];
    }

    pub fn getCommandText(self: *Self, entry: HistoryEntry) []const u8 {
        const start = entry.command_offset;
        const end = start + entry.command_len;
        return self.string_pool[start..end];
    }

    pub fn getStats(self: *Self) struct { total: usize, unique: usize } {
        return .{ .total = self.entry_count, .unique = self.entry_count };
    }

    // High-performance fuzzy matching algorithm
    fn calculateFuzzyScore(self: *Self, query: []const u8, text: []const u8, entry_index: usize) ?struct { score: f32, positions: [8]u16 } {
        if (query.len > 8) return null; // Limit query length for performance

        var positions: [8]u16 = [_]u16{0} ** 8;
        var query_pos: usize = 0;
        var text_pos: usize = 0;
        var matches: u8 = 0;
        var consecutive_matches: u8 = 0;
        var max_consecutive: u8 = 0;

        // Boyer-Moore-style search with SIMD acceleration
        while (query_pos < query.len and text_pos < text.len) {
            const query_char = std.ascii.toLower(query[query_pos]);

            // Find next occurrence of query character
            const remaining_text = text[text_pos..];
            const char_pos = simd.findCharacter(remaining_text, query_char) orelse
                simd.findCharacter(remaining_text, std.ascii.toUpper(query_char));

            if (char_pos) |pos| {
                positions[matches] = @intCast(text_pos + pos);
                text_pos += pos + 1;
                query_pos += 1;
                matches += 1;

                // Track consecutive matches
                if (matches > 1 and positions[matches - 1] == positions[matches - 2] + 1) {
                    consecutive_matches += 1;
                } else {
                    max_consecutive = @max(max_consecutive, consecutive_matches);
                    consecutive_matches = 1;
                }
            } else {
                break;
            }
        }

        if (matches == 0) return null;

        max_consecutive = @max(max_consecutive, consecutive_matches);

        // Calculate score based on multiple factors
        var score: f32 = 0.0;

        // Base score: percentage of query matched
        score += (@as(f32, @floatFromInt(matches)) / @as(f32, @floatFromInt(query.len))) * 100.0;

        // Bonus for consecutive matches
        score += @as(f32, @floatFromInt(max_consecutive)) * 10.0;

        // Bonus for exact prefix match
        if (matches > 0 and positions[0] == 0) {
            score += 20.0;
        }

        // Bonus for frequency (popular commands)
        const entry = self.entries[entry_index];
        score += @min(@as(f32, @floatFromInt(entry.frequency)) * 2.0, 20.0);

        // Bonus for recent usage
        const now = std.time.timestamp();
        const age_hours = @max(1, @divFloor(now - entry.timestamp, 3600));
        score += @max(0.0, 10.0 - @log10(@as(f32, @floatFromInt(age_hours))));

        // Bonus for successful commands
        if (entry.isSuccessful()) {
            score += 5.0;
        }

        return .{ .score = score, .positions = positions };
    }

    fn updateFrequentCommands(self: *Self, entry_index: u32) void {
        const entry = self.entries[entry_index];

        // Insert into sorted frequency list
        var insert_pos: usize = 0;
        while (insert_pos < self.frequent_count) {
            const other_entry = self.entries[self.frequent_commands[insert_pos]];
            if (entry.frequency > other_entry.frequency) break;
            insert_pos += 1;
        }

        // Shift and insert
        if (insert_pos < self.frequent_commands.len) {
            const move_count = @min(self.frequent_count - insert_pos, self.frequent_commands.len - insert_pos - 1);
            if (move_count > 0) {
                std.mem.copyBackwards(u32,
                    self.frequent_commands[insert_pos + 1..insert_pos + 1 + move_count],
                    self.frequent_commands[insert_pos..insert_pos + move_count]);
            }

            self.frequent_commands[insert_pos] = entry_index;
            self.frequent_count = @min(self.frequent_count + 1, self.frequent_commands.len);
        }
    }

    fn evictOldest(self: *Self) !void {
        // Find oldest entry by timestamp
        var oldest_index: u32 = 0;
        var oldest_timestamp = self.entries[0].timestamp;

        for (1..self.entry_count) |i| {
            if (self.entries[i].timestamp < oldest_timestamp) {
                oldest_timestamp = self.entries[i].timestamp;
                oldest_index = @intCast(i);
            }
        }

        // Remove from hash table
        _ = self.hash_to_index.remove(self.entries[oldest_index].command_hash);

        // Shift entries down
        if (oldest_index < self.entry_count - 1) {
            std.mem.copy(HistoryEntry,
                self.entries[oldest_index..self.entry_count - 1],
                self.entries[oldest_index + 1..self.entry_count]);
        }

        self.entry_count -= 1;
        self.invalidateSearchCache();
    }

    fn compactStringPool(self: *Self) !void {
        // Rebuild string pool by copying active strings
        var new_pool = try self.allocator.alloc(u8, self.string_pool_capacity);
        defer self.allocator.free(self.string_pool);

        var new_offset: u32 = 0;
        for (0..self.entry_count) |i| {
            const entry = &self.entries[i];
            const command_text = self.string_pool[entry.command_offset..entry.command_offset + entry.command_len];

            @memcpy(new_pool[new_offset..new_offset + entry.command_len], command_text);
            entry.command_offset = new_offset;
            new_offset += entry.command_len;
        }

        self.string_pool = new_pool;
        self.string_pool_used = new_offset;
    }

    fn invalidateSearchCache(self: *Self) void {
        _ = self.cache_allocator.reset(.retain_capacity);
        self.search_cache.clearRetainingCapacity();
    }
};