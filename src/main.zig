// main.zig - zish shell implementation

const std = @import("std");
const build = @import("build.zig.zon");
const clap = @import("clap");
const Shell = @import("Shell.zig");
const build_options = @import("build_options");

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .allocator = gpa.allocator(),
    }) catch |err| {
        diag.reportToFile(.stderr(), err) catch {};
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        clap.helpToFile(.stdout(), clap.Help, &params, .{}) catch {};
        return;
    }

    if (res.args.version != 0) {
        std.debug.print("zish {s}\n", .{build.version});
        return;
    }

    // initialize shell
    var shell = Shell.init(allocator) catch |err| {
        std.debug.print("zish: failed to initialize shell: {}\n", .{err});
        std.process.exit(1);
    };
    defer shell.deinit();

    if (res.args.@"debug-log-file") |log_path| {
        shell.log_file = if (std.fs.path.isAbsolute(log_path))
            std.fs.createFileAbsolute(log_path, .{}) catch |err| {
                std.debug.print("zish: failed to create log file: {}\n", .{err});
                std.process.exit(1);
            }
        else
            std.fs.cwd().createFile(log_path, .{}) catch |err| {
                std.debug.print("zish: failed to create log file: {}\n", .{err});
                std.process.exit(1);
            };
    }

    if (res.args.c) |command| {
        // set positional parameters if provided
        inline for (res.positionals, 0..) |positional_slice, idx| {
            for (positional_slice, 0..) |arg, arg_idx| {
                var buf: [32]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "{d}", .{idx * 100 + arg_idx}) catch continue;
                const key_copy = allocator.dupe(u8, key) catch continue;
                const val_copy = allocator.dupe(u8, arg) catch continue;
                shell.variables.put(key_copy, val_copy) catch {};
            }
        }

        const exit_code = shell.executeCommand(command) catch |err| {
            std.debug.print("zish: error executing command: {}\n", .{err});
            std.process.exit(1);
        };

        // Add to history in non-interactive mode
        if (shell.history) |h| {
            h.addCommand(command, exit_code) catch {};
        }

        // Flush stdout buffer before exit
        shell.stdout().flush() catch {};
        std.process.exit(exit_code);
    } else if (res.positionals.len > 0 and res.positionals[0].len > 0) {
        // script file mode
        const script_path = res.positionals[0][0];

        // set positional parameters: $0 is script name, $1+ are args
        inline for (res.positionals, 0..) |positional_slice, idx| {
            for (positional_slice, 0..) |arg, arg_idx| {
                var buf: [32]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "{d}", .{idx * 100 + arg_idx}) catch continue;
                const key_copy = allocator.dupe(u8, key) catch continue;
                const val_copy = allocator.dupe(u8, arg) catch continue;
                shell.variables.put(key_copy, val_copy) catch {};
            }
        }

        const script_content = std.fs.cwd().readFileAlloc(allocator, script_path, 1024 * 1024) catch |err| {
            std.debug.print("zish: cannot read script '{s}': {}\n", .{ script_path, err });
            std.process.exit(1);
        };
        defer allocator.free(script_content);

        const exit_code = shell.executeCommand(script_content) catch |err| {
            std.debug.print("zish: error executing script: {}\n", .{err});
            std.process.exit(1);
        };
        shell.stdout().flush() catch {};
        std.process.exit(exit_code);
    } else {
        // interactive mode
        shell.run() catch |err| {
            std.debug.print("zish: error in interactive mode: {}\n", .{err});
            std.process.exit(1);
        };
    }
}

const params = clap.parseParamsComptime(
    \\-h,   --help                  Display this help and exit.
    \\-v,   --version               print version and exit.
    \\-l,   --login                 Start as login shell.
    \\-d,   --debug-log-file <str>  file to write a debug info to.
    \\-c    <str>                   command to execute.
    \\<str>...
    \\
);

test {
    std.testing.refAllDecls(@This());
}
