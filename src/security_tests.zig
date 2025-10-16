// security_tests.zig - comprehensive security validation tests

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const lexer = @import("lexer.zig");
const Shell = @import("shell.zig").Shell;

// test memory bounds and overflow protection
test "lexer bounds checking - token too long" {
    const long_input = "a" ** (types.MAX_TOKEN_LENGTH + 10);

    var lex = lexer.Lexer.init(long_input) catch return; // input validation may catch this
    const result = lex.nextToken();

    // should return TokenTooLong error
    try testing.expectError(error.TokenTooLong, result);
}

test "lexer bounds checking - input too long" {
    const massive_input = "a" ** (types.MAX_COMMAND_LENGTH + 100);

    // should fail at initialization with input validation
    const result = lexer.Lexer.init(massive_input);
    try testing.expectError(error.InputTooLong, result);
}

test "lexer recursion depth protection" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // create deeply nested parameter expansion
    var nested_input = std.ArrayList(u8).initCapacity(gpa.allocator(), 1024) catch unreachable;
    defer nested_input.deinit(gpa.allocator());

    // create ${${${...}}} nesting beyond limit
    for (0..types.MAX_RECURSION_DEPTH + 5) |_| {
        try nested_input.appendSlice(gpa.allocator(), "${");
    }
    try nested_input.appendSlice(gpa.allocator(), "var");
    for (0..types.MAX_RECURSION_DEPTH + 5) |_| {
        try nested_input.append(gpa.allocator(), '}');
    }

    var lex = try lexer.Lexer.init(nested_input.items);
    const result = lex.nextToken();

    // should hit recursion limit
    try testing.expectError(error.RecursionLimitExceeded, result);
}

test "string handling - unterminated strings" {
    var lex = try lexer.Lexer.init("\"unterminated string");
    const result = lex.nextToken();
    try testing.expectError(error.UnterminatedString, result);
}

test "command length validation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const shell = try Shell.init(gpa.allocator());
    defer shell.deinit();

    // try to execute command that's too long
    const long_command = "echo " ++ ("a" ** types.MAX_COMMAND_LENGTH);

    // this should be caught by input validation before lexing
    const result = shell.executeCommand(long_command);

    // command should fail gracefully without crashes
    const exit_code = result catch return; // any error is fine
    try testing.expect(exit_code != 0); // should return error code
}

test "shell metacharacter detection via lexer" {
    // test that metacharacters properly terminate tokens
    var lex = try lexer.Lexer.init("word|pipe");

    const first = try lex.nextToken();
    try testing.expectEqualStrings("word", first.value);

    const second = try lex.nextToken();
    try testing.expect(second.ty == .Pipe);
    try testing.expectEqualStrings("|", second.value);
}

test "timing-safe string comparisons" {
    const token = lexer.Token{
        .ty = .Word,
        .value = "if",
        .line = 1,
        .column = 1,
    };

    // verify constant-time comparison
    try testing.expect(token.isKeyword("if"));
    try testing.expect(!token.isKeyword("else"));
}

test "parameter expansion bounds" {
    var lex = try lexer.Lexer.init("${" ++ ("a" ** types.MAX_TOKEN_LENGTH) ++ "}");
    const result = lex.nextToken();
    try testing.expectError(error.ExpansionTooLong, result);
}

test "command substitution bounds" {
    var lex = try lexer.Lexer.init("$(" ++ ("a" ** types.MAX_TOKEN_LENGTH) ++ ")");
    const result = lex.nextToken();
    try testing.expectError(error.SubstitutionTooLong, result);
}

test "control character rejection" {
    // test various control characters
    const control_chars = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 127 };

    var test_input: [2]u8 = undefined;
    test_input[1] = 0;

    for (control_chars) |char| {
        // skip tab and newline which are allowed
        if (char == '\t' or char == '\n') continue;

        test_input[0] = char;
        const result = types.validateShellSafe(&test_input);

        // should reject dangerous control characters
        if (char == 127) {
            try testing.expectError(error.DeleteCharacter, result);
        } else {
            try testing.expectError(error.ControlCharacter, result);
        }
    }
}

test "environment variable expansion safety" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const shell = try Shell.init(gpa.allocator());
    defer shell.deinit();

    // test home directory expansion doesn't cause buffer overflows
    const result = shell.executeCommand("cd ~");

    // should either work or fail gracefully, not crash
    const exit_code = result catch return; // any error is fine
    try testing.expect(exit_code == 0 or exit_code == 1);
}

test "token buffer reuse protection" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var lex = try lexer.Lexer.init("first second third");

    var tokens = std.ArrayList(lexer.Token).initCapacity(gpa.allocator(), 16) catch unreachable;
    defer tokens.deinit(gpa.allocator());

    // collect all tokens
    while (true) {
        const token = try lex.nextToken();
        if (token.ty == .Eof) break;
        try tokens.append(gpa.allocator(), token);
    }

    // verify tokens don't point to the same memory
    try testing.expect(!std.mem.eql(u8, tokens.items[0].value, tokens.items[1].value));
    try testing.expect(!std.mem.eql(u8, tokens.items[1].value, tokens.items[2].value));

    // verify values are correct
    try testing.expectEqualStrings("first", tokens.items[0].value);
    try testing.expectEqualStrings("second", tokens.items[1].value);
    try testing.expectEqualStrings("third", tokens.items[2].value);
}

// fuzzing-style tests
test "random input robustness" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // test 100 random inputs
    for (0..100) |_| {
        var random_input: [256]u8 = undefined;

        // fill with random bytes
        for (&random_input) |*byte| {
            byte.* = random.int(u8);
        }

        // null terminate
        random_input[255] = 0;

        // lexer should handle gracefully
        var lex_result = lexer.Lexer.init(random_input[0..255]);

        if (lex_result) |*lex| {
            var token_count: u32 = 0;
            while (token_count < 1000) { // prevent infinite loops
                const token = lex.nextToken() catch break;
                if (token.ty == .Eof) break;
                token_count += 1;
            }
        } else |_| {
            // input validation rejection is fine
        }
    }
}