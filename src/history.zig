// history.zig - smart history system with fuzzy search and shared multi-instance support

const std = @import("std");
const types = @import("types.zig");

// history entry with metadata
const HistoryEntry = struct {
    command: []const u8,
    timestamp: i64,
    exit_code: u8,
    frequency: u32, // how often this exact command was used
    session_id: u32, // which shell instance created this

    pub fn init(allocator: std.mem.Allocator, cmd: []const u8, exit_code: u8, session_id: u32) !*HistoryEntry {
        const entry = try allocator.create(HistoryEntry);
        entry.* = .{
            .command = try allocator.dupe(u8, cmd),
            .timestamp = std.time.timestamp(),
            .exit_code = exit_code,
            .frequency = 1,
            .session_id = session_id,
        };
        return entry;
    }

    pub fn deinit(self: *HistoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        allocator.destroy(self);
    }
};

// fuzzy match result with score
const FuzzyMatch = struct {
    entry: *HistoryEntry,
    score: f32,

    fn lessThan(_: void, a: FuzzyMatch, b: FuzzyMatch) bool {
        // higher scores first, then more recent, then more frequent
        if (a.score != b.score) return a.score > b.score;
        if (a.entry.timestamp != b.entry.timestamp) return a.entry.timestamp > b.entry.timestamp;
        return a.entry.frequency > b.entry.frequency;
    }
};

// smart history manager with multi-instance support
pub const History = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(*HistoryEntry),
    command_map: std.AutoHashMap(u64, *HistoryEntry),
    history_file: []const u8,
    lock_file: []const u8,
    max_entries: usize,
    current_position: isize, // for up/down navigation, -1 means at prompt
    search_query: []u8,
    search_buffer: [256]u8,
    session_id: u32,
    last_sync: i64, // last time we synced with other instances

    const Self = @This();
    const DEFAULT_MAX_ENTRIES = 10000;

    pub fn init(allocator: std.mem.Allocator, history_file_path: ?[]const u8) !*Self {
        const history = try allocator.create(Self);

        const hist_path = if (history_file_path) |path|
            try allocator.dupe(u8, path)
        else
            try std.fmt.allocPrint(allocator, "{s}/.zish_history", .{std.posix.getenv("HOME") orelse "."});

        const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{hist_path});

        // generate unique session id
        const session_id: u32 = @intCast(@as(u64, @bitCast(std.time.microTimestamp())) & 0xFFFFFFFF);

        history.* = .{
            .allocator = allocator,
            .entries = std.ArrayList(*HistoryEntry).init(allocator),
            .command_map = std.AutoHashMap(u64, *HistoryEntry).init(allocator),
            .history_file = hist_path,
            .lock_file = lock_path,
            .max_entries = DEFAULT_MAX_ENTRIES,
            .current_position = -1,
            .search_query = &[_]u8{},
            .search_buffer = undefined,
            .session_id = session_id,
            .last_sync = 0,
        };

        try history.loadFromFile();
        return history;
    }

    pub fn deinit(self: *Self) void {
        // save to file before cleanup
        self.saveToFile() catch {};

        // cleanup entries
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit();
        self.command_map.deinit();

        self.allocator.free(self.history_file);
        self.allocator.free(self.lock_file);
        self.allocator.destroy(self);
    }

    // add command to history with deduplication and immediate sync to other instances
    pub fn addCommand(self: *Self, command: []const u8, exit_code: u8) !void {
        if (command.len == 0 or command[0] == ' ') return; // ignore empty and space-prefixed

        // sync with other instances first to get latest state
        try self.syncFromOtherInstances();

        const command_hash = std.hash_map.hashString(command);

        // check if we already have this exact command
        if (self.command_map.get(command_hash)) |existing| {
            // update existing entry - move to front, update frequency and timestamp
            existing.timestamp = std.time.timestamp();
            existing.exit_code = exit_code;
            existing.frequency += 1;
            existing.session_id = self.session_id; // update to current session

            // move to end of list (most recent)
            for (self.entries.items, 0..) |entry, i| {
                if (entry == existing) {
                    _ = self.entries.orderedRemove(i);
                    try self.entries.append(existing);
                    break;
                }
            }
        } else {
            // new command
            const entry = try HistoryEntry.init(self.allocator, command, exit_code, self.session_id);
            try self.entries.append(entry);
            try self.command_map.put(command_hash, entry);

            // trim if too many entries
            if (self.entries.items.len > self.max_entries) {
                const oldest = self.entries.orderedRemove(0);
                const oldest_hash = std.hash_map.hashString(oldest.command);
                _ = self.command_map.remove(oldest_hash);
                oldest.deinit(self.allocator);
            }
        }

        self.current_position = -1; // reset position after new command

        // immediately append to shared file for other instances
        try self.appendToSharedFile(command, exit_code);
    }

    // sync history from other shell instances (non-blocking)
    pub fn syncFromOtherInstances(self: *Self) !void {
        const now = std.time.timestamp();

        // only sync every few seconds to avoid constant file I/O
        if (now - self.last_sync < 2) return;

        // try to get file stats to see if it changed
        const file_stat = std.fs.cwd().statFile(self.history_file) catch return;

        // if file is newer than our last sync, reload it
        if (file_stat.mtime > @as(u64, @intCast(self.last_sync)) * 1_000_000_000) {
            try self.incrementalLoad();
            self.last_sync = now;
        }
    }

    // append single command to shared file (atomic operation)
    fn appendToSharedFile(self: *Self, command: []const u8, exit_code: u8) !void {
        // use file locking to prevent corruption from multiple instances
        const lock_acquired = try self.tryAcquireLock();
        if (!lock_acquired) return; // skip if can't get lock quickly

        defer self.releaseLock() catch {};

        const file = std.fs.cwd().openFile(self.history_file, .{ .mode = .write_only }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.cwd().createFile(self.history_file, .{}),
            else => return err,
        };
        defer file.close();

        try file.seekToEnd();

        // format: timestamp:session_id:exit_code:command
        const timestamp = std.time.timestamp();
        try file.writer().print("{}:{}:{}:{s}\n", .{ timestamp, self.session_id, exit_code, command });
    }

    // load only new entries since last sync
    fn incrementalLoad(self: *Self) !void {
        const file = std.fs.cwd().openFile(self.history_file, .{}) catch return;
        defer file.close();

        var buf_reader = std.io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();

        var line_buf: [types.MAX_COMMAND_LENGTH + 64]u8 = undefined; // extra space for metadata
        while (try in_stream.readUntilDelimiterOrEof(line_buf[0..], '\n')) |line| {
            try self.parseLine(line);
        }
    }

    fn parseLine(self: *Self, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\n\r");
        if (trimmed.len == 0) return;

        // try to parse new format: timestamp:session_id:exit_code:command
        var parts = std.mem.split(u8, trimmed, ":");
        const timestamp_str = parts.next() orelse return;
        const session_str = parts.next() orelse {
            // old format - just the command
            try self.addHistoryEntry(trimmed, 0, 0, 0);
            return;
        };
        const exit_code_str = parts.next() orelse return;
        const command = parts.rest();

        const timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch return;
        const session_id = std.fmt.parseInt(u32, session_str, 10) catch return;
        const exit_code = std.fmt.parseInt(u8, exit_code_str, 10) catch return;

        // only add if it's newer than what we have and not from current session
        if (session_id != self.session_id and timestamp > self.last_sync - 10) {
            try self.addHistoryEntry(command, exit_code, session_id, timestamp);
        }
    }

    fn addHistoryEntry(self: *Self, command: []const u8, exit_code: u8, session_id: u32, timestamp: i64) !void {
        const command_hash = std.hash_map.hashString(command);

        // check if we already have this exact command
        if (self.command_map.get(command_hash)) |existing| {
            // update if this is more recent
            if (timestamp > existing.timestamp) {
                existing.timestamp = timestamp;
                existing.exit_code = exit_code;
                existing.frequency += 1;
                if (session_id != 0) existing.session_id = session_id;
            }
        } else {
            // new command
            const entry = try self.allocator.create(HistoryEntry);
            entry.* = .{
                .command = try self.allocator.dupe(u8, command),
                .timestamp = if (timestamp > 0) timestamp else std.time.timestamp(),
                .exit_code = exit_code,
                .frequency = 1,
                .session_id = if (session_id > 0) session_id else self.session_id,
            };
            try self.entries.append(entry);
            try self.command_map.put(command_hash, entry);
        }
    }

    // non-blocking lock acquisition
    fn tryAcquireLock(self: *Self) !bool {
        const lock_file = std.fs.cwd().createFile(self.lock_file, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => return false, // another instance has the lock
            else => return err,
        };
        lock_file.close();
        return true;
    }

    fn releaseLock(self: *Self) !void {
        std.fs.cwd().deleteFile(self.lock_file) catch {};
    }

    // fuzzy search with scoring based on fzf algorithm
    pub fn fuzzySearch(self: *Self, query: []const u8, allocator: std.mem.Allocator) ![]FuzzyMatch {
        if (query.len == 0) {
            // no query - return recent commands
            var matches = std.ArrayList(FuzzyMatch).init(allocator);
            var i = self.entries.items.len;
            while (i > 0 and matches.items.len < 20) {
                i -= 1;
                try matches.append(.{
                    .entry = self.entries.items[i],
                    .score = 1.0,
                });
            }
            return matches.toOwnedSlice();
        }

        var matches = std.ArrayList(FuzzyMatch).init(allocator);

        for (self.entries.items) |entry| {
            if (fuzzyMatchScore(entry.command, query)) |s| {
                // boost score based on frequency and recency
                const freq_boost = std.math.log2(@as(f32, @floatFromInt(entry.frequency + 1))) * 0.1;
                const recency_boost = if (std.time.timestamp() - entry.timestamp < 3600) @as(f32, 0.2) else 0.0;
                const success_boost = if (entry.exit_code == 0) @as(f32, 0.1) else 0.0;

                try matches.append(.{
                    .entry = entry,
                    .score = s + freq_boost + recency_boost + success_boost,
                });
            }
        }

        // sort by score
        std.mem.sort(FuzzyMatch, matches.items, {}, FuzzyMatch.lessThan);

        return matches.toOwnedSlice();
    }

    // prefix search for up/down arrows (like your ^[[A/B bindings)
    pub fn prefixSearch(self: *Self, prefix: []const u8, direction: enum { up, down }) ?*HistoryEntry {
        if (prefix.len == 0) {
            // no prefix - simple chronological navigation
            return self.navigateHistory(direction);
        }

        const start_pos = if (self.current_position == -1)
            @as(isize, @intCast(self.entries.items.len))
        else
            self.current_position;

        var i = start_pos;

        while (true) {
            switch (direction) {
                .up => {
                    i -= 1;
                    if (i < 0) return null;
                },
                .down => {
                    i += 1;
                    if (i >= @as(isize, @intCast(self.entries.items.len))) return null;
                },
            }

            const entry = self.entries.items[@intCast(i)];
            if (std.mem.startsWith(u8, entry.command, prefix)) {
                self.current_position = i;
                return entry;
            }
        }
    }

    fn navigateHistory(self: *Self, direction: enum { up, down }) ?*HistoryEntry {
        switch (direction) {
            .up => {
                if (self.current_position == -1) {
                    self.current_position = @as(isize, @intCast(self.entries.items.len)) - 1;
                } else {
                    self.current_position -= 1;
                }

                if (self.current_position < 0) {
                    self.current_position = -1;
                    return null;
                }
            },
            .down => {
                if (self.current_position == -1) return null;

                self.current_position += 1;
                if (self.current_position >= @as(isize, @intCast(self.entries.items.len))) {
                    self.current_position = -1;
                    return null;
                }
            },
        }

        return if (self.current_position >= 0)
            self.entries.items[@intCast(self.current_position)]
        else
            null;
    }

    pub fn resetPosition(self: *Self) void {
        self.current_position = -1;
    }

    // load history from file (initial load)
    fn loadFromFile(self: *Self) !void {
        self.incrementalLoad() catch {}; // ignore errors on initial load
        self.last_sync = std.time.timestamp();
    }

    // save history to file (complete rewrite - used on exit)
    fn saveToFile(self: *Self) !void {
        const lock_acquired = try self.tryAcquireLock();
        if (!lock_acquired) return; // skip if can't get lock

        defer self.releaseLock() catch {};

        const file = try std.fs.cwd().createFile(self.history_file, .{});
        defer file.close();

        var buf_writer = std.io.bufferedWriter(file.writer());
        var out_stream = buf_writer.writer();

        // sort by timestamp to maintain global chronological order
        const sorted_entries = try self.allocator.alloc(*HistoryEntry, self.entries.items.len);
        defer self.allocator.free(sorted_entries);

        @memcpy(sorted_entries, self.entries.items);
        std.mem.sort(*HistoryEntry, sorted_entries, {}, struct {
            fn lessThan(_: void, a: *HistoryEntry, b: *HistoryEntry) bool {
                return a.timestamp < b.timestamp;
            }
        }.lessThan);

        // write with full metadata for future sessions
        for (sorted_entries) |entry| {
            try out_stream.print("{}:{}:{}:{s}\n", .{
                entry.timestamp,
                entry.session_id,
                entry.exit_code,
                entry.command,
            });
        }

        try buf_writer.flush();
    }

    pub fn getStats(self: *Self) struct { total: usize, unique: usize } {
        return .{
            .total = self.entries.items.len,
            .unique = self.command_map.count(),
        };
    }
};

// fuzzy matching algorithm similar to fzf
fn fuzzyMatchScore(text: []const u8, pattern: []const u8) ?f32 {
    if (pattern.len == 0) return 1.0;
    if (text.len == 0) return null;

    var score: f32 = 0.0;
    var text_idx: usize = 0;
    var consecutive_matches: u32 = 0;
    var first_match_pos: ?usize = null;

    for (pattern) |pattern_char| {
        var found = false;

        while (text_idx < text.len) {
            const text_char = std.ascii.toLower(text[text_idx]);
            text_idx += 1;

            if (text_char == std.ascii.toLower(pattern_char)) {
                if (first_match_pos == null) first_match_pos = text_idx - 1;

                // base score for match
                score += 1.0;

                // bonus for consecutive matches
                consecutive_matches += 1;
                score += @as(f32, @floatFromInt(consecutive_matches)) * 0.5;

                // bonus for early matches
                const pos_factor = 1.0 - (@as(f32, @floatFromInt(text_idx - 1)) / @as(f32, @floatFromInt(text.len)));
                score += pos_factor * 0.3;

                // bonus for word boundaries
                if (text_idx > 1 and (text[text_idx - 2] == ' ' or text[text_idx - 2] == '_' or text[text_idx - 2] == '-')) {
                    score += 0.8;
                }

                found = true;
                break;
            } else {
                consecutive_matches = 0;
            }
        }

        if (!found) return null; // pattern doesn't match
    }

    // penalty for long text
    score -= @as(f32, @floatFromInt(text.len)) * 0.01;

    // bonus for shorter text
    if (text.len < 20) score += 0.2;

    return if (score > 0) score else null;
}

test "fuzzy matching" {
    const testing = std.testing;

    // exact match
    try testing.expect(fuzzyMatchScore("test", "test").? > 0);

    // prefix match
    try testing.expect(fuzzyMatchScore("testing", "test").? > 0);

    // fuzzy match
    try testing.expect(fuzzyMatchScore("git commit -m", "gcm").? > 0);

    // no match
    try testing.expect(fuzzyMatchScore("hello", "xyz") == null);

    // case insensitive
    try testing.expect(fuzzyMatchScore("Hello", "hello").? > 0);
}

test "history deduplication" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var history = try History.init(allocator, "/tmp/test_zish_history");
    defer history.deinit();

    try history.addCommand("git status", 0);
    try history.addCommand("git status", 0); // duplicate
    try history.addCommand("git commit", 0);

    try testing.expectEqual(@as(usize, 2), history.entries.items.len);

    // find git status entry and check frequency
    var found = false;
    for (history.entries.items) |entry| {
        if (std.mem.eql(u8, entry.command, "git status")) {
            try testing.expectEqual(@as(u32, 2), entry.frequency);
            found = true;
            break;
        }
    }
    try testing.expect(found);
}