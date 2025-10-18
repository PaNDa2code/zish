// simd.zig - SIMD optimizations for string processing
// designed for maximum performance on x86_64 and AArch64

const std = @import("std");
const builtin = @import("builtin");

// Vector types based on target architecture
pub const VectorU8x16 = @Vector(16, u8);
pub const VectorU8x32 = @Vector(32, u8);

// Check if SIMD is available at compile time
pub const has_sse2 = builtin.cpu.arch == .x86_64;
pub const has_avx2 = has_sse2; // Simplified for now
pub const has_neon = builtin.cpu.arch == .aarch64;

// SIMD-optimized character search
pub fn findCharacter(haystack: []const u8, needle: u8) ?usize {
    if (has_avx2 and haystack.len >= 32) {
        return findCharacterAVX2(haystack, needle);
    } else if (has_sse2 and haystack.len >= 16) {
        return findCharacterSSE2(haystack, needle);
    } else if (has_neon and haystack.len >= 16) {
        return findCharacterNEON(haystack, needle);
    } else {
        return std.mem.indexOfScalar(u8, haystack, needle);
    }
}

// AVX2 implementation for x86_64
fn findCharacterAVX2(haystack: []const u8, needle: u8) ?usize {
    const chunk_size = 32;
    var i: usize = 0;

    // Create vector with repeated needle character
    const needle_vec: VectorU8x32 = @splat(needle);

    while (i + chunk_size <= haystack.len) {
        // Load 32 bytes from haystack
        const haystack_chunk: VectorU8x32 = haystack[i..i + chunk_size][0..chunk_size].*;

        // Compare all bytes at once
        const mask = haystack_chunk == needle_vec;

        // Convert mask to bitmask and find first set bit
        const bitmask = @as(u32, @bitCast(mask));
        if (bitmask != 0) {
            return i + @ctz(bitmask);
        }

        i += chunk_size;
    }

    // Handle remainder with scalar search
    return std.mem.indexOfScalar(u8, haystack[i..], needle);
}

// SSE2 implementation for x86_64
fn findCharacterSSE2(haystack: []const u8, needle: u8) ?usize {
    const chunk_size = 16;
    var i: usize = 0;

    const needle_vec: VectorU8x16 = @splat(needle);

    while (i + chunk_size <= haystack.len) {
        const haystack_chunk: VectorU8x16 = haystack[i..i + chunk_size][0..chunk_size].*;

        const mask = haystack_chunk == needle_vec;
        const bitmask = @as(u16, @bitCast(mask));

        if (bitmask != 0) {
            return i + @ctz(bitmask);
        }

        i += chunk_size;
    }

    return std.mem.indexOfScalar(u8, haystack[i..], needle);
}

// NEON implementation for AArch64
fn findCharacterNEON(haystack: []const u8, needle: u8) ?usize {
    // Similar to SSE2 but using ARM NEON intrinsics
    // For now, fall back to scalar
    return std.mem.indexOfScalar(u8, haystack, needle);
}

// SIMD-optimized whitespace skipping for lexer
pub fn skipWhitespace(input: []const u8, start: usize) usize {
    if (has_avx2 and input.len - start >= 32) {
        return skipWhitespaceAVX2(input, start);
    }

    // Scalar fallback
    var i = start;
    while (i < input.len and isWhitespace(input[i])) {
        i += 1;
    }
    return i;
}

fn skipWhitespaceAVX2(input: []const u8, start: usize) usize {
    const chunk_size = 32;
    var i = start;

    // Whitespace characters as vectors
    const space_vec: VectorU8x32 = @splat(' ');
    const tab_vec: VectorU8x32 = @splat('\t');
    const newline_vec: VectorU8x32 = @splat('\n');
    const cr_vec: VectorU8x32 = @splat('\r');

    while (i + chunk_size <= input.len) {
        const chunk: VectorU8x32 = input[i..i + chunk_size][0..chunk_size].*;

        // Check for whitespace characters
        const is_space = chunk == space_vec;
        const is_tab = chunk == tab_vec;
        const is_newline = chunk == newline_vec;
        const is_cr = chunk == cr_vec;

        const is_whitespace = is_space | is_tab | is_newline | is_cr;
        const whitespace_mask = @as(u32, @bitCast(is_whitespace));

        // If not all characters are whitespace, find first non-whitespace
        if (whitespace_mask != 0xFFFFFFFF) {
            const non_whitespace_mask = ~whitespace_mask;
            if (non_whitespace_mask != 0) {
                return i + @ctz(non_whitespace_mask);
            }
        }

        i += chunk_size;
    }

    // Handle remainder
    while (i < input.len and isWhitespace(input[i])) {
        i += 1;
    }

    return i;
}

// Fast character classification using lookup tables
const char_class_table: [256]u8 = blk: {
    var table: [256]u8 = [_]u8{0} ** 256;

    // Bit flags for character classes
    const WHITESPACE = 1;
    const ALPHA = 2;
    const DIGIT = 4;
    const SPECIAL = 8;

    // Whitespace
    table[' '] |= WHITESPACE;
    table['\t'] |= WHITESPACE;
    table['\n'] |= WHITESPACE;
    table['\r'] |= WHITESPACE;
    table['\x0B'] |= WHITESPACE;
    table['\x0C'] |= WHITESPACE;

    // Letters
    for ('a'..='z', 0..) |_, i| table[i + 'a'] |= ALPHA;
    for ('A'..='Z', 0..) |_, i| table[i + 'A'] |= ALPHA;
    table['_'] |= ALPHA;

    // Digits
    for ('0'..='9', 0..) |_, i| table[i + '0'] |= DIGIT;

    // Shell special characters
    const specials = "|&;()<>{}><!";
    for (specials) |c| {
        table[c] |= SPECIAL;
    }

    break :blk table;
};

pub inline fn isWhitespace(c: u8) bool {
    return (char_class_table[c] & 1) != 0;
}

pub inline fn isAlpha(c: u8) bool {
    return (char_class_table[c] & 2) != 0;
}

pub inline fn isDigit(c: u8) bool {
    return (char_class_table[c] & 4) != 0;
}

pub inline fn isSpecial(c: u8) bool {
    return (char_class_table[c] & 8) != 0;
}

pub inline fn isAlphaNum(c: u8) bool {
    return (char_class_table[c] & 6) != 0;
}

// SIMD string comparison
pub fn compareStrings(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    if (has_avx2 and a.len >= 32) {
        return compareStringsAVX2(a, b);
    } else if (has_sse2 and a.len >= 16) {
        return compareStringsSSE2(a, b);
    }

    return std.mem.eql(u8, a, b);
}

fn compareStringsAVX2(a: []const u8, b: []const u8) bool {
    const chunk_size = 32;
    var i: usize = 0;

    while (i + chunk_size <= a.len) {
        const a_chunk: VectorU8x32 = a[i..i + chunk_size][0..chunk_size].*;
        const b_chunk: VectorU8x32 = b[i..i + chunk_size][0..chunk_size].*;

        if (!@reduce(.And, a_chunk == b_chunk)) {
            return false;
        }

        i += chunk_size;
    }

    // Handle remainder
    return std.mem.eql(u8, a[i..], b[i..]);
}

fn compareStringsSSE2(a: []const u8, b: []const u8) bool {
    const chunk_size = 16;
    var i: usize = 0;

    while (i + chunk_size <= a.len) {
        const a_chunk: VectorU8x16 = a[i..i + chunk_size][0..chunk_size].*;
        const b_chunk: VectorU8x16 = b[i..i + chunk_size][0..chunk_size].*;

        if (!@reduce(.And, a_chunk == b_chunk)) {
            return false;
        }

        i += chunk_size;
    }

    return std.mem.eql(u8, a[i..], b[i..]);
}

// High-performance hash function using SIMD when possible
pub fn hashString(data: []const u8) u64 {
    // Use built-in fast hash for now, could be optimized with CRC32 intrinsics
    return std.hash.Wyhash.hash(0, data);
}

// CPU cache prefetching hints for performance optimization
pub inline fn prefetchRead(comptime distance: enum { near, far }, ptr: *const anyopaque) void {
    if (has_sse2) {
        const addr = @intFromPtr(ptr);
        switch (distance) {
            .near => asm volatile ("prefetcht0 (%[addr])" :: [addr] "r" (addr) : "memory"),
            .far => asm volatile ("prefetcht1 (%[addr])" :: [addr] "r" (addr) : "memory"),
        }
    }
}

pub inline fn prefetchWrite(ptr: *anyopaque) void {
    if (has_sse2) {
        const addr = @intFromPtr(ptr);
        asm volatile ("prefetcht0 (%[addr])" :: [addr] "r" (addr) : "memory");
    }
}

// Prefetch multiple cache lines for large data structures
pub fn prefetchRange(start: *const anyopaque, len: usize) void {
    if (!has_sse2) return;

    const cache_line_size = 64;
    const start_addr = @intFromPtr(start);
    const end_addr = start_addr + len;

    var addr = start_addr;
    while (addr < end_addr) {
        prefetchRead(.near, @ptrFromInt(addr));
        addr += cache_line_size;
    }
}

// Optimized memory copy with prefetching
pub fn prefetchedMemcpy(dest: []u8, src: []const u8) void {
    const len = @min(dest.len, src.len);

    // Prefetch source data ahead of time
    if (len >= 256) {
        prefetchRange(src.ptr, len);
    }

    // Use SIMD copy with prefetching
    if (has_avx2 and len >= 32) {
        prefetchedMemcpyAVX2(dest, src, len);
    } else if (has_sse2 and len >= 16) {
        prefetchedMemcpySSE2(dest, src, len);
    } else {
        @memcpy(dest[0..len], src[0..len]);
    }
}

fn prefetchedMemcpyAVX2(dest: []u8, src: []const u8, len: usize) void {
    var i: usize = 0;
    const prefetch_distance = 128; // Prefetch 2 cache lines ahead

    while (i + 32 <= len) {
        // Prefetch data ahead for better cache utilization
        if (i + prefetch_distance < len) {
            prefetchRead(.near, @ptrFromInt(@intFromPtr(src.ptr) + i + prefetch_distance));
            prefetchWrite(@ptrFromInt(@intFromPtr(dest.ptr) + i + prefetch_distance));
        }

        // Load and store 32-byte vectors
        const src_chunk: @Vector(32, u8) = src[i..i + 32][0..32].*;
        dest[i..i + 32][0..32].* = src_chunk;
        i += 32;
    }

    // Handle remainder
    if (i < len) {
        @memcpy(dest[i..len], src[i..len]);
    }
}

fn prefetchedMemcpySSE2(dest: []u8, src: []const u8, len: usize) void {
    var i: usize = 0;
    const prefetch_distance = 64;

    while (i + 16 <= len) {
        if (i + prefetch_distance < len) {
            prefetchRead(.near, @ptrFromInt(@intFromPtr(src.ptr) + i + prefetch_distance));
            prefetchWrite(@ptrFromInt(@intFromPtr(dest.ptr) + i + prefetch_distance));
        }

        const src_chunk: @Vector(16, u8) = src[i..i + 16][0..16].*;
        dest[i..i + 16][0..16].* = src_chunk;
        i += 16;
    }

    if (i < len) {
        @memcpy(dest[i..len], src[i..len]);
    }
}

// Vectorized case conversion
pub fn toLowercase(input: []u8) void {
    if (has_avx2 and input.len >= 32) {
        toLowercaseAVX2(input);
    } else {
        // Scalar fallback
        for (input) |*c| {
            if (c.* >= 'A' and c.* <= 'Z') {
                c.* += 32;
            }
        }
    }
}

fn toLowercaseAVX2(input: []u8) void {
    const chunk_size = 32;
    var i: usize = 0;

    const upper_a: VectorU8x32 = @splat('A');
    const upper_z: VectorU8x32 = @splat('Z');
    const case_diff: VectorU8x32 = @splat(32);

    while (i + chunk_size <= input.len) {
        var chunk: VectorU8x32 = input[i..i + chunk_size][0..chunk_size].*;

        const is_upper = (chunk >= upper_a) & (chunk <= upper_z);
        const to_add = @select(u8, is_upper, case_diff, @splat(@as(u8, 0)));

        chunk += to_add;

        // Store back
        for (chunk, 0..) |c, j| {
            input[i + j] = c;
        }

        i += chunk_size;
    }

    // Handle remainder
    for (input[i..]) |*c| {
        if (c.* >= 'A' and c.* <= 'Z') {
            c.* += 32;
        }
    }
}