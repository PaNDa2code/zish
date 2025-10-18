// comptime_opts.zig - compile-time optimizations for maximum performance
// All optimizations computed at build time for zero runtime cost

const std = @import("std");
const types = @import("types.zig");
const builtin = @import("builtin");

// Compile-time feature detection
pub const Features = struct {
    pub const has_sse2 = builtin.cpu.arch == .x86_64;
    pub const has_avx2 = has_sse2 and builtin.cpu.features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx2));
    pub const has_neon = builtin.cpu.arch == .aarch64;
    pub const is_debug = builtin.mode == .Debug;
    pub const is_release_fast = builtin.mode == .ReleaseFast;

    pub const simd_width = if (has_avx2) 32 else if (has_sse2 or has_neon) 16 else 8;

    // Target-specific optimizations
    pub const prefer_branch_prediction = builtin.cpu.arch == .x86_64;
    pub const has_fast_unaligned_access = builtin.cpu.arch == .x86_64;
    pub const cache_line_size = if (builtin.cpu.arch == .x86_64) 64 else 32;
};

// Compile-time perfect hash for shell builtins
const builtin_commands = [_][]const u8{
    "cd", "pwd", "echo", "exit", "export", "unset", "history", "alias",
    "unalias", "jobs", "fg", "bg", "kill", "wait", "read", "test",
    "source", ".", "exec", "eval", "shift", "getopts", "trap", "type",
    "which", "command", "builtin", "help", "times", "umask", "ulimit"
};

const BuiltinHashMap = std.ComptimeStringMap(u8, blk: {
    var kvs: [builtin_commands.len]struct { []const u8, u8 } = undefined;
    for (builtin_commands, 0..) |cmd, i| {
        kvs[i] = .{ cmd, @intCast(i) };
    }
    break :blk kvs;
});

pub fn isBuiltinCommand(command: []const u8) ?u8 {
    return BuiltinHashMap.get(command);
}

// Compile-time lookup tables for character classification
pub const CharClass = packed struct {
    whitespace: bool = false,
    alpha: bool = false,
    digit: bool = false,
    special: bool = false,
    quote: bool = false,
    escape: bool = false,

    pub const LOOKUP_TABLE: [256]CharClass = comptime blk: {
        var table: [256]CharClass = [_]CharClass{.{}} ** 256;

        // Whitespace
        inline for ([_]u8{ ' ', '\t', '\n', '\r', '\x0B', '\x0C' }) |c| {
            table[c].whitespace = true;
        }

        // Alphabetic
        for ('a'..='z') |c| table[c].alpha = true;
        for ('A'..='Z') |c| table[c].alpha = true;
        table['_'].alpha = true;

        // Digits
        for ('0'..='9') |c| table[c].digit = true;

        // Shell special characters
        inline for ([_]u8{ '|', '&', ';', '(', ')', '<', '>', '{', '}', '!', '$' }) |c| {
            table[c].special = true;
        }

        // Quotes
        table['"'].quote = true;
        table['\''].quote = true;
        table['`'].quote = true;

        // Escape character
        table['\\'].escape = true;

        break :blk table;
    };
};

pub inline fn getCharClass(c: u8) CharClass {
    return CharClass.LOOKUP_TABLE[c];
}

// Compile-time string validation patterns
pub const ValidationPattern = enum {
    shell_safe,
    identifier,
    path,
    url,

    const SHELL_SAFE_PATTERN = comptime buildValidationMask(&[_]u8{0x00, 0x08, 0x7F}); // NULL, backspace, DEL
    const IDENTIFIER_PATTERN = comptime buildAlphaNumMask();

    fn buildValidationMask(comptime forbidden: []const u8) [32]u8 {
        var mask = [_]u8{0xFF} ** 32;
        for (forbidden) |c| {
            const byte_idx = c / 8;
            const bit_idx = c % 8;
            mask[byte_idx] &= ~(@as(u8, 1) << @intCast(bit_idx));
        }
        return mask;
    }

    fn buildAlphaNumMask() [32]u8 {
        var mask = [_]u8{0x00} ** 32;
        // Set bits for a-z, A-Z, 0-9, _
        for ('a'..='z') |c| {
            const byte_idx = c / 8;
            const bit_idx = c % 8;
            mask[byte_idx] |= (@as(u8, 1) << @intCast(bit_idx));
        }
        for ('A'..='Z') |c| {
            const byte_idx = c / 8;
            const bit_idx = c % 8;
            mask[byte_idx] |= (@as(u8, 1) << @intCast(bit_idx));
        }
        for ('0'..='9') |c| {
            const byte_idx = c / 8;
            const bit_idx = c % 8;
            mask[byte_idx] |= (@as(u8, 1) << @intCast(bit_idx));
        }
        // Underscore
        const c = '_';
        const byte_idx = c / 8;
        const bit_idx = c % 8;
        mask[byte_idx] |= (@as(u8, 1) << @intCast(bit_idx));
        return mask;
    }

    pub fn validate(self: ValidationPattern, input: []const u8) bool {
        const mask = switch (self) {
            .shell_safe => SHELL_SAFE_PATTERN,
            .identifier => IDENTIFIER_PATTERN,
            .path, .url => return true, // TODO: implement
        };

        for (input) |c| {
            const byte_idx = c / 8;
            const bit_idx = c % 8;
            if ((mask[byte_idx] & (@as(u8, 1) << @intCast(bit_idx))) == 0) {
                return false;
            }
        }
        return true;
    }
};

// Compile-time branch prediction hints
pub inline fn likely(condition: bool) bool {
    if (Features.prefer_branch_prediction) {
        return @call(.always_inline, std.math.expect, .{ condition, true });
    }
    return condition;
}

pub inline fn unlikely(condition: bool) bool {
    if (Features.prefer_branch_prediction) {
        return @call(.always_inline, std.math.expect, .{ condition, false });
    }
    return condition;
}

// Compile-time memory layout optimization
pub fn CacheAlignedArray(comptime T: type, comptime len: usize) type {
    return struct {
        data: [len]T align(Features.cache_line_size),

        pub fn get(self: *const @This(), index: usize) *const T {
            return &self.data[index];
        }

        pub fn getMut(self: *@This(), index: usize) *T {
            return &self.data[index];
        }
    };
}

// Compile-time function specialization
pub fn SpecializedHasher(comptime max_len: usize) type {
    return struct {
        pub fn hash(input: []const u8) u64 {
            if (comptime max_len <= 8) {
                return hashShort(input);
            } else if (comptime max_len <= 32) {
                return hashMedium(input);
            } else {
                return std.hash.Wyhash.hash(0, input);
            }
        }

        fn hashShort(input: []const u8) u64 {
            // Optimized for very short strings (<=8 bytes)
            var result: u64 = 0;
            for (input, 0..) |byte, i| {
                result ^= (@as(u64, byte) << @intCast(i * 8));
            }
            return result;
        }

        fn hashMedium(input: []const u8) u64 {
            // Optimized for medium strings (<=32 bytes)
            return std.hash.Fnv1a_64.hash(input);
        }
    };
}

// Compile-time code generation for hot paths
pub fn generateOptimizedLexer() type {
    return struct {
        pub fn tokenizeIdentifier(input: []const u8, start: usize) usize {
            var pos = start;

            // Unrolled loop for common case
            while (pos + 8 <= input.len) {
                comptime var i = 0;
                inline while (i < 8) : (i += 1) {
                    if (!getCharClass(input[pos + i]).alpha and !getCharClass(input[pos + i]).digit) {
                        return pos + i;
                    }
                }
                pos += 8;
            }

            // Handle remainder
            while (pos < input.len) {
                const c = getCharClass(input[pos]);
                if (!c.alpha and !c.digit) break;
                pos += 1;
            }

            return pos;
        }
    };
}

// Compile-time constant folding for performance-critical values
pub const Constants = struct {
    pub const DEFAULT_HISTORY_SIZE = 10000;
    pub const MAX_PROMPT_LENGTH = 256;
    pub const TOKEN_BUFFER_SIZE = 1024;
    pub const STRING_POOL_SIZE = 1024 * 1024; // 1MB

    // Pre-computed powers of 2 for fast alignment
    pub const ALIGNMENT_MASKS = comptime blk: {
        var masks: [8]usize = undefined;
        var i = 0;
        while (i < 8) : (i += 1) {
            masks[i] = (@as(usize, 1) << @intCast(i)) - 1;
        }
        break :blk masks;
    };

    pub fn alignUp(comptime alignment: usize, value: usize) usize {
        const mask = comptime (alignment - 1);
        return (value + mask) & ~mask;
    }

    pub fn alignDown(comptime alignment: usize, value: usize) usize {
        const mask = comptime (alignment - 1);
        return value & ~mask;
    }
};

// Compile-time error handling optimization
pub fn OptimizedError(comptime ErrorSet: type) type {
    const error_count = @typeInfo(ErrorSet).ErrorSet.?.len;

    return struct {
        pub const uses_error_code = error_count <= 256;
        pub const ErrorCode = if (uses_error_code) u8 else u16;

        pub fn encodeError(err: ErrorSet) ErrorCode {
            return @intFromError(err);
        }

        pub fn decodeError(code: ErrorCode) ErrorSet {
            return @errorFromInt(code);
        }
    };
}

// Compile-time memory pool sizing
pub fn OptimalPoolSize(comptime T: type, comptime usage_pattern: enum { frequent, moderate, rare }) usize {
    const base_size = @sizeOf(T);
    const multiplier = switch (usage_pattern) {
        .frequent => 1000,
        .moderate => 100,
        .rare => 10,
    };

    // Align to cache line boundary
    return Constants.alignUp(Features.cache_line_size, base_size * multiplier);
}

// Compile-time format string optimization
pub fn OptimizedFormat(comptime fmt: []const u8) type {
    // Pre-parse format string at compile time
    const arg_count = std.mem.count(u8, fmt, "{}");

    return struct {
        pub const format_string = fmt;
        pub const argument_count = arg_count;
        pub const is_simple = arg_count <= 3 and std.mem.indexOf(u8, fmt, "{d}") == null;

        pub fn format(args: anytype) []const u8 {
            if (comptime is_simple) {
                return simpleFormat(args);
            } else {
                return std.fmt.comptimePrint(fmt, args);
            }
        }

        fn simpleFormat(args: anytype) []const u8 {
            // Specialized formatting for common cases
            comptime unreachable; // Implement based on specific format patterns
        }
    };
}