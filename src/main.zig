// main.zig - zish shell implementation

const std = @import("std");
const Shell = @import("shell.zig").Shell;
const build_options = @import("build_options");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // initialize shell
    var shell = try Shell.init(allocator);
    defer shell.deinit();

    // check command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        // check for version flags
        if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v")) {
            std.debug.print("zish {s}\n", .{build_options.version});
            return;
        }

        // single command mode - join all args as command
        var command_parts = try std.ArrayList(u8).initCapacity(allocator, 256);
        defer command_parts.deinit(allocator);

        for (args[1..], 0..) |arg, i| {
            if (i > 0) try command_parts.append(allocator, ' ');
            try command_parts.appendSlice(allocator, arg);
        }

        const exit_code = try shell.executeCommand(command_parts.items);
        std.process.exit(exit_code);
    } else {
        // interactive mode
        try shell.run();
    }
}

test {
    std.testing.refAllDecls(@This());
}