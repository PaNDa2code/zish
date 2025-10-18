// strings.zig - high-performance zero-copy string operations
// designed for maximum throughput with safety guarantees

const std = @import("std");
const types = @import("types.zig");

// Zero-copy string slice with bounds checking
pub const StringSlice = struct {
    data: [*]const u8,
    len: usize,
    capacity: usize, // for bounds checking

    const Self = @This();

    pub fn init(buffer: []const u8) Self {
        return Self{
            .data = buffer.ptr,
            .len = buffer.len,
            .capacity = buffer.len,
        };
    }

    pub fn slice(self: Self, start: usize, end: usize) !Self {
        if (start > end or end > self.len) return error.OutOfBounds;
        return Self{
            .data = self.data + start,
            .len = end - start,
            .capacity = self.capacity - start,
        };
    }

    pub fn bytes(self: Self) []const u8 {
        return self.data[0..self.len];
    }

    pub fn eql(self: Self, other: []const u8) bool {
        if (self.len != other.len) return false;

        // Use SIMD comparison for large strings
        if (self.len >= 32) {
            return simdEqual(self.data[0..self.len], other);
        }

        // Fast path for small strings
        return std.mem.eql(u8, self.data[0..self.len], other);
    }

    pub fn startsWith(self: Self, prefix: []const u8) bool {
        if (prefix.len > self.len) return false;
        return std.mem.eql(u8, self.data[0..prefix.len], prefix);
    }

    pub fn indexOf(self: Self, needle: []const u8) ?usize {
        if (needle.len > self.len) return null;

        // Use optimized search for single characters
        if (needle.len == 1) {
            return std.mem.indexOfScalar(u8, self.data[0..self.len], needle[0]);
        }

        // Use Boyer-Moore for longer patterns
        return boyerMooreSearch(self.data[0..self.len], needle);
    }

    pub fn trim(self: Self) Self {
        var start: usize = 0;
        var end: usize = self.len;

        // Trim leading whitespace
        while (start < end and isWhitespace(self.data[start])) {
            start += 1;
        }

        // Trim trailing whitespace
        while (end > start and isWhitespace(self.data[end - 1])) {
            end -= 1;
        }

        return Self{
            .data = self.data + start,
            .len = end - start,
            .capacity = self.capacity - start,
        };
    }
};

// SIMD-optimized string comparison
fn simdEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    const chunk_size = 32; // AVX2 vector size
    var i: usize = 0;

    // Process 32-byte chunks with SIMD (when available)
    while (i + chunk_size <= a.len) {
        // On x86_64 with AVX2, this could use vectorized comparison
        // For now, use optimized memory comparison
        if (!std.mem.eql(u8, a[i..i + chunk_size], b[i..i + chunk_size])) {
            return false;
        }
        i += chunk_size;
    }

    // Handle remainder
    return std.mem.eql(u8, a[i..], b[i..]);
}

// Boyer-Moore string search for patterns > 1 character
fn boyerMooreSearch(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    if (needle.len == 0) return 0;

    // Simple case - fall back to standard library for now
    // TODO: Implement full Boyer-Moore algorithm
    return std.mem.indexOf(u8, haystack, needle);
}

// Fast whitespace detection using lookup table
const whitespace_lut: [256]bool = blk: {
    var lut: [256]bool = [_]bool{false} ** 256;
    lut[' '] = true;
    lut['\t'] = true;
    lut['\n'] = true;
    lut['\r'] = true;
    lut['\x0B'] = true; // vertical tab
    lut['\x0C'] = true; // form feed
    break :blk lut;
};

inline fn isWhitespace(c: u8) bool {
    return whitespace_lut[c];
}

// String builder for efficient concatenation
pub const StringBuilder = struct {
    buffer: []u8,
    len: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
        return Self{
            .buffer = try allocator.alloc(u8, capacity),
            .len = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
    }

    pub fn append(self: *Self, str: []const u8) !void {
        if (self.len + str.len > self.buffer.len) {
            // Grow buffer exponentially
            const new_capacity = @max(self.buffer.len * 2, self.len + str.len);
            self.buffer = try self.allocator.realloc(self.buffer, new_capacity);
        }

        @memcpy(self.buffer[self.len..self.len + str.len], str);
        self.len += str.len;
    }

    pub fn slice(self: Self) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn clear(self: *Self) void {
        self.len = 0;
    }
};

// Compile-time string hashing for fast lookups
pub fn compileTimeHash(comptime str: []const u8) u64 {
    return std.hash.Wyhash.hash(0, str);
}

// Perfect hash map for shell keywords (built at compile time)
const KeywordMap = std.ComptimeStringMap(types.TokenType, .{
    .{ "if", .If },
    .{ "then", .Then },
    .{ "else", .Else },
    .{ "elif", .Elif },
    .{ "fi", .Fi },
    .{ "for", .For },
    .{ "while", .While },
    .{ "until", .Until },
    .{ "do", .Do },
    .{ "done", .Done },
    .{ "case", .Case },
    .{ "esac", .Esac },
    .{ "function", .Function },
});

pub fn lookupKeyword(word: []const u8) ?types.TokenType {
    return KeywordMap.get(word);
}

// Memory pool for temporary strings during parsing
pub const StringPool = struct {
    arena: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init(backing_allocator: std.mem.Allocator) Self {
        return Self{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn create(self: *Self, str: []const u8) ![]u8 {
        const copy = try self.arena.allocator().dupe(u8, str);
        return copy;
    }

    pub fn reset(self: *Self) void {
        _ = self.arena.reset(.retain_capacity);
    }
};