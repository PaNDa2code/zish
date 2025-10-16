// secure_env.zig - capability-based environment with memory safety

const std = @import("std");
const secure = @import("secure_types.zig");

// capability-based environment system
pub const securenvironment = struct {
    arena: std.heap.arenaallocator,
    capabilities: std.enumset(secure.environmentcapability),
    variables: std.hashmap(secure.internedstring, []const u8, stringcontext, 80),
    current_dir: []const u8,
    exit_status: i32,

    const self = @this();
    const stringcontext = struct {
        pub fn hash(_: @this(), s: secure.internedstring) u64 {
            return std.hash_map.hashstring(s.data);
        }
        pub fn eql(_: @this(), a: secure.internedstring, b: secure.internedstring) bool {
            return a.eql(b);
        }
    };

    pub fn init(parent_allocator: std.mem.allocator, caps: std.enumset(secure.environmentcapability)) !*self {
        var arena = std.heap.arenaallocator.init(parent_allocator);
        const allocator = arena.allocator();

        const env = try allocator.create(self);
        env.* = .{
            .arena = arena,
            .capabilities = caps,
            .variables = std.hashmap(secure.internedstring, []const u8, stringcontext, 80).init(allocator),
            .current_dir = try std.fs.cwd().realpathallocarena(allocator, "."),
            .exit_status = 0,
        };

        // safely import only permitted environment variables
        try env.importsystemenv();
        return env;
    }

    pub fn deinit(self: *self) void {
        // arena cleanup handles all memory - no double-free possible
        self.arena.deinit();
    }

    pub fn get(self: *self, name: []const u8) ?[]const u8 {
        const interned = secure.internedstring{ .data = name };
        return self.variables.get(interned);
    }

    pub fn set(self: *self, name: []const u8, value: []const u8) !void {
        try secure.validateshellsafe(name);
        try secure.validateshellsafe(value);

        if (value.len > secure.max_env_value_length) {
            return error.environmentvaluetoolong;
        }

        const allocator = self.arena.allocator();
        const name_copy = try allocator.dupe(u8, name);
        const value_copy = try allocator.dupe(u8, value);

        const interned_name = secure.internedstring{ .data = name_copy };

        // arena-based allocation means no need to free old values
        try self.variables.put(interned_name, value_copy);
    }

    pub fn unset(self: *self, name: []const u8) bool {
        const interned = secure.internedstring{ .data = name };
        return self.variables.remove(interned);
    }

    pub fn getcurrentdir(self: *self) []const u8 {
        return self.current_dir;
    }

    pub fn setcurrentdir(self: *self, path: []const u8) !void {
        try secure.validateshellsafe(path);

        const allocator = self.arena.allocator();
        const new_path = std.fs.cwd().realpathallocarena(allocator, path) catch |err| {
            return err;
        };

        self.current_dir = new_path;
        try self.set("pwd", new_path);
    }

    pub fn expandvariable(self: *self, name: []const u8) ![]const u8 {
        // handle special variables with arena allocation - no stack return issues
        const allocator = self.arena.allocator();

        if (std.mem.eql(u8, name, "?")) {
            return std.fmt.allocprint(allocator, "{}", .{self.exit_status});
        }
        if (std.mem.eql(u8, name, "pwd")) {
            return self.current_dir;
        }

        return self.get(name) orelse "";
    }

    // capability-restricted environment import
    fn importsystemenv(self: *self) !void {
        if (self.capabilities.contains(.readuserinfo)) {
            try self.importsafeenvvars(&[_][]const u8{ "home", "user" });
        }

        if (self.capabilities.contains(.readlocale)) {
            try self.importsafeenvvars(&[_][]const u8{ "lang", "lc_all" });
        }

        if (self.capabilities.contains(.readterminal)) {
            try self.importsafeenvvars(&[_][]const u8{ "term" });
        }

        if (self.capabilities.contains(.readpath)) {
            // restricted path import - validate each component
            if (std.posix.getenv("path")) |path_value| {
                const clean_path = try self.sanitizepath(path_value);
                try self.set("path", clean_path);
            }
        }

        // always set safe defaults
        try self.set("pwd", self.current_dir);
        try self.set("shell", "/bin/zish");
    }

    fn importsafeenvvars(self: *self, var_names: []const []const u8) !void {
        for (var_names) |var_name| {
            if (std.posix.getenv(var_name)) |value| {
                const clean_value = try self.sanitizeenvvalue(value);
                try self.set(var_name, clean_value);
            }
        }
    }

    fn sanitizeenvvalue(self: *self, value: []const u8) ![]const u8 {
        // length limit
        if (value.len > secure.max_env_value_length) {
            return error.environmentvaluetoolong;
        }

        // reject dangerous characters
        for (value) |c| {
            switch (c) {
                // allow safe characters
                'a'...'z', 'a'...'z', '0'...'9', '/', '-', '_', '.', ':' => {},
                // reject everything else including shell metacharacters
                else => return error.unsafeenvironmentvalue,
            }
        }

        return self.arena.allocator().dupe(u8, value);
    }

    fn sanitizepath(self: *self, path_value: []const u8) ![]const u8 {
        const allocator = self.arena.allocator();
        var safe_paths = std.arraylist([]const u8).init(allocator);

        var path_iter = std.mem.split(u8, path_value, ":");
        while (path_iter.next()) |path_component| {
            // only allow safe path components
            if (self.ispathsafe(path_component)) {
                try safe_paths.append(try allocator.dupe(u8, path_component));
            }
        }

        return std.mem.join(allocator, ":", safe_paths.items);
    }

    fn ispathsafe(self: *self, path: []const u8) bool {
        _ = self;

        // reject dangerous paths
        if (path.len == 0) return false;
        if (std.mem.startswith(u8, path, "/tmp")) return false;  // temp dirs unsafe
        if (std.mem.indexofscalar(u8, path, ' ')) |_| return false;  // spaces unsafe
        if (path[0] == '.') return false;  // relative paths unsafe
        if (path[0] != '/') return false;  // must be absolute

        // basic validation - only standard system paths
        const safe_prefixes = [_][]const u8{
            "/usr/bin", "/usr/local/bin", "/bin", "/sbin",
        };

        for (safe_prefixes) |prefix| {
            if (std.mem.startswith(u8, path, prefix)) return true;
        }

        return false;
    }

    pub fn setexitstatus(self: *self, status: i32) void {
        self.exit_status = status;
    }

    pub fn getexitstatus(self: *self) i32 {
        return self.exit_status;
    }

    // secure environment export for external commands
    pub fn getenvp(self: *self) ![][*:0]const u8 {
        const allocator = self.arena.allocator();
        var env_array = std.arraylist([*:0]const u8).init(allocator);

        var iterator = self.variables.iterator();
        while (iterator.next()) |entry| {
            // create null-terminated environment string
            const env_str = try std.fmt.allocprintz(allocator, "{s}={s}", .{
                entry.key_ptr.data,
                entry.value_ptr.*,
            });
            try env_array.append(env_str.ptr);
        }

        return env_array.toownedslice();
    }
};

// compile-time security invariants
comptime {
    // ensure environment cannot be used to bypass security
    if (@sizeof(secure.internedstring) > 16) {
        @compileerror("interned strings too large - potential dos vector");
    }
}