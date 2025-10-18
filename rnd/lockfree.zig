// lockfree.zig - lock-free data structures for high-performance concurrent access
// Implements atomic operations and memory barriers for zero-contention history updates

const std = @import("std");
const builtin = @import("builtin");
const comptime_opts = @import("comptime_opts.zig");

// Memory ordering semantics
pub const Ordering = enum {
    Relaxed,
    Acquire,
    Release,
    AcqRel,
    SeqCst,

    pub fn toStd(self: Ordering) std.builtin.AtomicOrder {
        return switch (self) {
            .Relaxed => .monotonic,
            .Acquire => .acquire,
            .Release => .release,
            .AcqRel => .acq_rel,
            .SeqCst => .seq_cst,
        };
    }
};

// Cache-aligned atomic types for maximum performance
pub fn AtomicValue(comptime T: type) type {
    return struct {
        value: T align(comptime_opts.Features.cache_line_size),

        const Self = @This();

        pub fn init(initial: T) Self {
            return Self{ .value = initial };
        }

        pub fn load(self: *const Self, ordering: Ordering) T {
            return @atomicLoad(T, &self.value, ordering.toStd());
        }

        pub fn store(self: *Self, new_value: T, ordering: Ordering) void {
            @atomicStore(T, &self.value, new_value, ordering.toStd());
        }

        pub fn swap(self: *Self, new_value: T, ordering: Ordering) T {
            return @atomicRmw(T, &self.value, .Xchg, new_value, ordering.toStd());
        }

        pub fn compareAndSwap(self: *Self, expected: T, desired: T, success: Ordering, failure: Ordering) ?T {
            return @cmpxchgWeak(T, &self.value, expected, desired, success.toStd(), failure.toStd());
        }

        pub fn fetchAdd(self: *Self, operand: T, ordering: Ordering) T {
            return @atomicRmw(T, &self.value, .Add, operand, ordering.toStd());
        }

        pub fn fetchSub(self: *Self, operand: T, ordering: Ordering) T {
            return @atomicRmw(T, &self.value, .Sub, operand, ordering.toStd());
        }
    };
}

// Lock-free ring buffer for high-throughput history updates
pub fn LockFreeRingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T align(comptime_opts.Features.cache_line_size),
        head: AtomicValue(u64),
        tail: AtomicValue(u64),

        const Self = @This();
        const CAPACITY = capacity;

        pub fn init() Self {
            return Self{
                .buffer = undefined,
                .head = AtomicValue(u64).init(0),
                .tail = AtomicValue(u64).init(0),
            };
        }

        pub fn push(self: *Self, item: T) bool {
            const current_tail = self.tail.load(.Acquire);
            const next_tail = current_tail + 1;
            const current_head = self.head.load(.Acquire);

            // Check if buffer is full
            if (next_tail - current_head >= CAPACITY) {
                return false;
            }

            const index = current_tail % CAPACITY;
            self.buffer[index] = item;

            // Memory barrier to ensure write completes before updating tail
            compilerBarrier();

            // Atomically update tail
            if (self.tail.compareAndSwap(current_tail, next_tail, .Release, .Relaxed) != null) {
                // CAS failed, another thread updated tail
                return false;
            }

            return true;
        }

        pub fn pop(self: *Self) ?T {
            const current_head = self.head.load(.Acquire);
            const current_tail = self.tail.load(.Acquire);

            // Check if buffer is empty
            if (current_head >= current_tail) {
                return null;
            }

            const index = current_head % CAPACITY;
            const item = self.buffer[index];

            // Memory barrier
            compilerBarrier();

            // Atomically update head
            if (self.head.compareAndSwap(current_head, current_head + 1, .Release, .Relaxed) != null) {
                // CAS failed, another thread updated head
                return null;
            }

            return item;
        }

        pub fn size(self: *const Self) usize {
            const tail = self.tail.load(.Acquire);
            const head = self.head.load(.Acquire);
            return tail - head;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.size() == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.size() >= CAPACITY;
        }
    };
}

// Lock-free hash map for concurrent history lookups
pub fn LockFreeHashMap(comptime K: type, comptime V: type, comptime capacity: usize) type {
    const Entry = struct {
        key: K,
        value: V,
        version: AtomicValue(u64),
        deleted: AtomicValue(bool),

        pub fn init(key: K, value: V) @This() {
            return @This(){
                .key = key,
                .value = value,
                .version = AtomicValue(u64).init(1),
                .deleted = AtomicValue(bool).init(false),
            };
        }
    };

    return struct {
        entries: [capacity]Entry align(comptime_opts.Features.cache_line_size),
        size_counter: AtomicValue(usize),

        const Self = @This();
        const CAPACITY = capacity;

        pub fn init() Self {
            return Self{
                .entries = [_]Entry{Entry.init(undefined, undefined)} ** CAPACITY,
                .size_counter = AtomicValue(usize).init(0),
            };
        }

        fn hash(self: *const Self, key: K) usize {
            _ = self;
            // Simple hash function - could be replaced with better one
            const bytes = std.mem.asBytes(&key);
            var h: u64 = 0x9e3779b9;
            for (bytes) |byte| {
                h ^= @as(u64, byte);
                h *%= 0x9e3779b9;
            }
            return h % CAPACITY;
        }

        pub fn put(self: *Self, key: K, value: V) bool {
            var index = self.hash(key);
            var attempts: usize = 0;

            while (attempts < CAPACITY) {
                const entry = &self.entries[index];
                const version = entry.version.load(.Acquire);
                const deleted = entry.deleted.load(.Acquire);

                if (version == 0 or deleted) {
                    // Empty or deleted slot, try to claim it
                    if (entry.version.compareAndSwap(version, version + 1, .AcqRel, .Relaxed) == null) {
                        entry.key = key;
                        entry.value = value;
                        entry.deleted.store(false, .Release);

                        if (version == 0) {
                            _ = self.size_counter.fetchAdd(1, .Relaxed);
                        }
                        return true;
                    }
                } else if (std.meta.eql(entry.key, key)) {
                    // Key exists, update value
                    entry.value = value;
                    _ = entry.version.fetchAdd(1, .Release);
                    return true;
                }

                // Linear probing
                index = (index + 1) % CAPACITY;
                attempts += 1;
            }

            return false; // Hash map is full
        }

        pub fn get(self: *const Self, key: K) ?V {
            var index = self.hash(key);
            var attempts: usize = 0;

            while (attempts < CAPACITY) {
                const entry = &self.entries[index];
                const version = entry.version.load(.Acquire);
                const deleted = entry.deleted.load(.Acquire);

                if (version == 0) {
                    // Empty slot, key not found
                    return null;
                }

                if (!deleted and std.meta.eql(entry.key, key)) {
                    // Found the key
                    return entry.value;
                }

                index = (index + 1) % CAPACITY;
                attempts += 1;
            }

            return null;
        }

        pub fn remove(self: *Self, key: K) bool {
            var index = self.hash(key);
            var attempts: usize = 0;

            while (attempts < CAPACITY) {
                const entry = &self.entries[index];
                const version = entry.version.load(.Acquire);
                const deleted = entry.deleted.load(.Acquire);

                if (version == 0) {
                    return false; // Key not found
                }

                if (!deleted and std.meta.eql(entry.key, key)) {
                    // Mark as deleted
                    entry.deleted.store(true, .Release);
                    _ = self.size_counter.fetchSub(1, .Relaxed);
                    return true;
                }

                index = (index + 1) % CAPACITY;
                attempts += 1;
            }

            return false;
        }

        pub fn size(self: *const Self) usize {
            return self.size_counter.load(.Relaxed);
        }
    };
}

// Memory barriers for ordering guarantees
pub inline fn compilerBarrier() void {
    asm volatile ("" ::: "memory");
}

pub inline fn cpuFence() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("mfence" ::: "memory");
    } else if (comptime builtin.cpu.arch == .aarch64) {
        asm volatile ("dsb sy" ::: "memory");
    } else {
        @fence(.seq_cst);
    }
}

// CPU pause/hint instructions for spin loops
pub inline fn cpuPause() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("pause");
    } else if (comptime builtin.cpu.arch == .aarch64) {
        asm volatile ("yield");
    }
}

// Lock-free history entry for concurrent shell instances
pub const LockFreeHistoryEntry = struct {
    command_hash: u64,
    command: []const u8,
    timestamp: i64,
    frequency: AtomicValue(u32),
    exit_code: u8,
    flags: AtomicValue(u8),

    pub fn init(hash: u64, command: []const u8, timestamp: i64, exit_code: u8) @This() {
        return @This(){
            .command_hash = hash,
            .command = command,
            .timestamp = timestamp,
            .frequency = AtomicValue(u32).init(1),
            .exit_code = exit_code,
            .flags = AtomicValue(u8).init(0),
        };
    }

    pub fn incrementFrequency(self: *@This()) u32 {
        return self.frequency.fetchAdd(1, .Relaxed) + 1;
    }

    pub fn getFrequency(self: *const @This()) u32 {
        return self.frequency.load(.Relaxed);
    }
};

// High-performance spin lock for critical sections
pub const SpinLock = struct {
    locked: AtomicValue(bool),

    const Self = @This();

    pub fn init() Self {
        return Self{
            .locked = AtomicValue(bool).init(false),
        };
    }

    pub fn tryLock(self: *Self) bool {
        return self.locked.compareAndSwap(false, true, .Acquire, .Relaxed) == null;
    }

    pub fn lock(self: *Self) void {
        var attempts: u32 = 0;
        while (!self.tryLock()) {
            attempts += 1;

            // Exponential backoff with CPU pause
            if (attempts < 10) {
                cpuPause();
            } else if (attempts < 100) {
                var i: u8 = 0;
                while (i < 10) : (i += 1) {
                    cpuPause();
                }
            } else {
                // Fall back to OS yield after many attempts
                std.Thread.yield() catch {};
                attempts = 0;
            }
        }
    }

    pub fn unlock(self: *Self) void {
        self.locked.store(false, .Release);
    }
};

// Lock-free statistics tracking
pub const LockFreeStats = struct {
    operations: AtomicValue(u64),
    total_time_ns: AtomicValue(u64),
    errors: AtomicValue(u32),
    cache_hits: AtomicValue(u64),
    cache_misses: AtomicValue(u64),

    pub fn init() @This() {
        return @This(){
            .operations = AtomicValue(u64).init(0),
            .total_time_ns = AtomicValue(u64).init(0),
            .errors = AtomicValue(u32).init(0),
            .cache_hits = AtomicValue(u64).init(0),
            .cache_misses = AtomicValue(u64).init(0),
        };
    }

    pub fn recordOperation(self: *@This(), duration_ns: u64) void {
        _ = self.operations.fetchAdd(1, .Relaxed);
        _ = self.total_time_ns.fetchAdd(duration_ns, .Relaxed);
    }

    pub fn recordError(self: *@This()) void {
        _ = self.errors.fetchAdd(1, .Relaxed);
    }

    pub fn recordCacheHit(self: *@This()) void {
        _ = self.cache_hits.fetchAdd(1, .Relaxed);
    }

    pub fn recordCacheMiss(self: *@This()) void {
        _ = self.cache_misses.fetchAdd(1, .Relaxed);
    }

    pub fn getAverageLatencyNs(self: *const @This()) u64 {
        const ops = self.operations.load(.Relaxed);
        const time = self.total_time_ns.load(.Relaxed);
        return if (ops > 0) time / ops else 0;
    }

    pub fn getCacheHitRatio(self: *const @This()) f64 {
        const hits = self.cache_hits.load(.Relaxed);
        const misses = self.cache_misses.load(.Relaxed);
        const total = hits + misses;
        return if (total > 0) @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total)) else 0.0;
    }
};