// main.zig - zish shell implementation

const std = @import("std");
const clap = @import("clap");
const Shell = @import("shell.zig").Shell;
const build_options = @import("build_options");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .allocator = gpa.allocator(),
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(.stdout(), clap.Help, &params, .{});
        return;
    }

    if (res.args.version != 0) {
        std.debug.print("zish {s}\n", .{build_options.version});
        return;
    }

    // initialize shell
    var shell = try Shell.init(allocator);
    defer shell.deinit();

    if (res.positionals[0].len > 0) {
        var command_parts = try std.ArrayList(u8).initCapacity(allocator, 256);
        defer command_parts.deinit(allocator);
        for (res.positionals[0]) |pos| {
            try command_parts.append(allocator, ' ');
            try command_parts.appendSlice(allocator, pos);
        }
        const exit_code = try shell.executeCommand(command_parts.items);
        std.process.exit(exit_code);
    } else {
        // interactive mode
        try shell.run();
    }
}

const params = clap.parseParamsComptime(
    \\-h,   --help              Display this help and exit.
    \\-v,   --version           print version and exit.
    \\-c    <str>...            command to run.
    \\<str>...
    \\
);

test {
    std.testing.refAllDecls(@This());
}

