// main.zig

const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
// const evaluator = @import("evaluator.zig");

pub fn main() !void {
    // Get allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Setup terminal I/O
    const stdin = std.io.getStdIn();
    const stdout = std.io.getStdOut();
    var stdin_reader = stdin.reader();
    var stdout_writer = stdout.writer();

    // Read line buffer
    var line_buf: [4096]u8 = undefined;

    while (true) {
        // Print prompt
        try stdout_writer.print("zish> ", .{});

        // Read a line
        const line = (try stdin_reader.readUntilDelimiterOrEof(&line_buf, '\n')) orelse {
            try stdout_writer.print("\n", .{});
            break; // EOF reached
        };

        if (line.len == 0) continue;

        // Initialize lexer
        var lex = lexer.Lexer.init(allocator, line);
        defer lex.deinit();

        // Print tokens for now (for testing)
        while (true) {
            const token = lex.nextToken() catch |err| {
                try stdout_writer.print("Error: {}\n", .{err});
                break;
            };

            if (token.ty == .Eof) break;

            try stdout_writer.print("Token: {s} '{s}' at line {}, column {}\n", .{
                @tagName(token.ty),
                token.value,
                token.line,
                token.column,
            });
        }

        // TODO: Add parser and evaluator once we've verified lexer works
    }
}

test {
    std.testing.refAllDecls(@This());
}
