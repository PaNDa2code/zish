// main.zig - zish shell implementation

const std = @import("std");
const build = @import("build.zig.zon");
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
        std.debug.print("zish {s}\n", .{build.version});
        return;
    }

    // initialize shell
    var shell = try Shell.init(allocator);
    defer shell.deinit();

    if (res.args.@"debug-log-file") |log_path| {
        shell.log_file =
            try if (std.fs.path.isAbsolute(log_path))
                try std.fs.createFileAbsolute(log_path, .{})
            else
                std.fs.cwd().createFile(log_path, .{});
    }

    if (res.args.c) |command| {
        const exit_code = try shell.executeCommand(command);
        std.process.exit(exit_code);
    } else {
        // interactive mode
        try shell.run();
    }
}

const params = clap.parseParamsComptime(
    \\-h,   --help                  Display this help and exit.
    \\-v,   --version               print version and exit.
    \\-d,   --debug-log-file <str>  file to write a debug info to.
    \\-c    <str>                   command to execute.
    \\
);

test {
    std.testing.refAllDecls(@This());
}
