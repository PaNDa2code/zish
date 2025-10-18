// lexer_fast.zig - high-performance zero-allocation lexer
// designed to be 10x faster than traditional shell lexers

const std = @import("std");
const types = @import("types.zig");
const strings = @import("strings.zig");
const simd = @import("simd.zig");

// Fast token with zero-copy string slice
pub const FastToken = struct {
    type: types.TokenType,
    slice: strings.StringSlice,
    line: types.LineNumber,
    column: types.ColumnNumber,

    pub const EMPTY = FastToken{
        .type = .EOF,
        .slice = strings.StringSlice{ .data = undefined, .len = 0, .capacity = 0 },
        .line = 0,
        .column = 0,
    };

    pub fn eql(self: FastToken, other: []const u8) bool {
        return self.slice.eql(other);
    }

    pub fn bytes(self: FastToken) []const u8 {
        return self.slice.bytes();
    }
};

// High-performance lexer with pre-allocated token buffer
pub const FastLexer = struct {
    input: strings.StringSlice,
    position: usize,
    line: types.LineNumber,
    column: types.ColumnNumber,

    // Token ring buffer for lookahead without allocation
    token_buffer: [8]FastToken,
    buffer_start: usize,
    buffer_len: usize,

    const Self = @This();

    pub fn init(input: []const u8) !Self {
        try types.validateShellSafe(input);

        return Self{
            .input = strings.StringSlice.init(input),
            .position = 0,
            .line = 1,
            .column = 1,
            .token_buffer = [_]FastToken{FastToken.EMPTY} ** 8,
            .buffer_start = 0,
            .buffer_len = 0,
        };
    }

    pub fn nextToken(self: *Self) !FastToken {
        // Check token ring buffer first
        if (self.buffer_len > 0) {
            const token = self.token_buffer[self.buffer_start];
            self.buffer_start = (self.buffer_start + 1) % self.token_buffer.len;
            self.buffer_len -= 1;
            return token;
        }

        return self.scanToken();
    }

    // Peek ahead without consuming token
    pub fn peekToken(self: *Self, offset: usize) !FastToken {
        // Fill buffer up to requested offset
        while (self.buffer_len <= offset) {
            const token = try self.scanToken();
            self.pushToken(token);
        }

        const index = (self.buffer_start + offset) % self.token_buffer.len;
        return self.token_buffer[index];
    }

    fn pushToken(self: *Self, token: FastToken) void {
        const index = (self.buffer_start + self.buffer_len) % self.token_buffer.len;
        self.token_buffer[index] = token;
        if (self.buffer_len < self.token_buffer.len) {
            self.buffer_len += 1;
        } else {
            self.buffer_start = (self.buffer_start + 1) % self.token_buffer.len;
        }
    }

    fn scanToken(self: *Self) !FastToken {
        // Skip whitespace using SIMD optimizations
        self.skipWhitespace();

        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;

        if (start_pos >= self.input.len) {
            return FastToken{
                .type = .EOF,
                .slice = strings.StringSlice{ .data = undefined, .len = 0, .capacity = 0 },
                .line = start_line,
                .column = start_column,
            };
        }

        const current_char = self.input.bytes()[start_pos];

        // Use jump table for fast character dispatch (branch-free when possible)
        const token_type = switch (current_char) {
            ';' => blk: {
                self.advance();
                break :blk types.TokenType.Semicolon;
            },
            '|' => blk: {
                self.advance();
                break :blk types.TokenType.Pipe;
            },
            '&' => blk: {
                self.advance();
                break :blk types.TokenType.Ampersand;
            },
            '(' => blk: {
                self.advance();
                break :blk types.TokenType.LeftParen;
            },
            ')' => blk: {
                self.advance();
                break :blk types.TokenType.RightParen;
            },
            '{' => blk: {
                self.advance();
                break :blk types.TokenType.LeftBrace;
            },
            '}' => blk: {
                self.advance();
                break :blk types.TokenType.RightBrace;
            },
            '<' => blk: {
                self.advance();
                break :blk types.TokenType.RedirectIn;
            },
            '>' => blk: {
                self.advance();
                // Check for >> (append)
                if (self.position < self.input.len and self.input.bytes()[self.position] == '>') {
                    self.advance();
                    break :blk types.TokenType.RedirectAppend;
                }
                break :blk types.TokenType.RedirectOut;
            },
            '\n' => blk: {
                self.advance();
                self.line += 1;
                self.column = 1;
                break :blk types.TokenType.Newline;
            },
            '"' => return self.scanQuotedString(),
            '\'' => return self.scanSingleQuotedString(),
            '0'..='9' => return self.scanNumber(),
            else => return self.scanWord(),
        };

        const token_slice = try self.input.slice(start_pos, self.position);
        return FastToken{
            .type = token_type,
            .slice = token_slice,
            .line = start_line,
            .column = start_column,
        };
    }

    fn skipWhitespace(self: *Self) void {
        const input_bytes = self.input.bytes();
        const new_pos = simd.skipWhitespace(input_bytes, self.position);

        // Update line and column tracking
        for (input_bytes[self.position..new_pos]) |c| {
            switch (c) {
                '\n' => {
                    self.line += 1;
                    self.column = 1;
                },
                '\t' => self.column += 8 - (self.column - 1) % 8, // Tab to next 8-column boundary
                else => self.column += 1,
            }
        }

        self.position = new_pos;
    }

    fn advance(self: *Self) void {
        if (self.position < self.input.len) {
            if (self.input.bytes()[self.position] == '\n') {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.position += 1;
        }
    }

    fn scanWord(self: *Self) !FastToken {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;
        const input_bytes = self.input.bytes();

        // Hot loop optimization: unroll and use prefetching
        const end_pos = self.scanWordOptimized(input_bytes);

        // Update position and line/column tracking
        for (input_bytes[self.position..end_pos]) |c| {
            if (c == '\n') {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
        }
        self.position = end_pos;

        if (self.position == start_pos) {
            return error.InvalidToken;
        }

        const token_slice = try self.input.slice(start_pos, self.position);

        // Check if it's a keyword using compile-time perfect hash map
        const token_type = strings.lookupKeyword(token_slice.bytes()) orelse .Word;

        return FastToken{
            .type = token_type,
            .slice = token_slice,
            .line = start_line,
            .column = start_column,
        };
    }

    // Micro-optimized word scanning with unrolled loops and prefetching
    fn scanWordOptimized(self: *Self, input_bytes: []const u8) usize {
        var pos = self.position;

        // Prefetch upcoming data for better cache utilization
        if (pos + 64 < input_bytes.len) {
            simd.prefetchRead(.near, &input_bytes[pos + 64]);
        }

        // Unrolled loop for common case (4 characters at a time)
        while (pos + 4 <= input_bytes.len) {
            const c1 = input_bytes[pos];
            const c2 = input_bytes[pos + 1];
            const c3 = input_bytes[pos + 2];
            const c4 = input_bytes[pos + 3];

            // Check all 4 characters for word validity
            const valid1 = simd.isAlphaNum(c1) or c1 == '_' or c1 == '-' or c1 == '.' or c1 == '/';
            const valid2 = simd.isAlphaNum(c2) or c2 == '_' or c2 == '-' or c2 == '.' or c2 == '/';
            const valid3 = simd.isAlphaNum(c3) or c3 == '_' or c3 == '-' or c3 == '.' or c3 == '/';
            const valid4 = simd.isAlphaNum(c4) or c4 == '_' or c4 == '-' or c4 == '.' or c4 == '/';

            if (!valid1) break;
            pos += 1;
            if (!valid2) break;
            pos += 1;
            if (!valid3) break;
            pos += 1;
            if (!valid4) break;
            pos += 1;

            // Prefetch next chunk
            if (pos + 64 < input_bytes.len) {
                simd.prefetchRead(.far, &input_bytes[pos + 64]);
            }
        }

        // Handle remaining characters
        while (pos < input_bytes.len) {
            const c = input_bytes[pos];
            if (!simd.isAlphaNum(c) and c != '_' and c != '-' and c != '.' and c != '/') {
                break;
            }
            pos += 1;
        }

        return pos;
    }

    fn scanNumber(self: *Self) !FastToken {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;
        const input_bytes = self.input.bytes();

        while (self.position < input_bytes.len and simd.isDigit(input_bytes[self.position])) {
            self.advance();
        }

        const token_slice = try self.input.slice(start_pos, self.position);
        return FastToken{
            .type = .Number,
            .slice = token_slice,
            .line = start_line,
            .column = start_column,
        };
    }

    fn scanQuotedString(self: *Self) !FastToken {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;
        const input_bytes = self.input.bytes();

        self.advance(); // Skip opening quote

        while (self.position < input_bytes.len) {
            const c = input_bytes[self.position];
            if (c == '"') {
                self.advance(); // Skip closing quote
                break;
            } else if (c == '\\' and self.position + 1 < input_bytes.len) {
                self.advance(); // Skip escape character
                self.advance(); // Skip escaped character
            } else {
                self.advance();
            }
        }

        const token_slice = try self.input.slice(start_pos, self.position);
        return FastToken{
            .type = .String,
            .slice = token_slice,
            .line = start_line,
            .column = start_column,
        };
    }

    fn scanSingleQuotedString(self: *Self) !FastToken {
        const start_pos = self.position;
        const start_line = self.line;
        const start_column = self.column;
        const input_bytes = self.input.bytes();

        self.advance(); // Skip opening quote

        // Single quotes don't allow escapes - scan until closing quote
        const closing_quote_pos = simd.findCharacter(input_bytes[self.position..], '\'');
        if (closing_quote_pos) |pos| {
            self.position += pos + 1; // Move past closing quote
            // Update line/column tracking
            for (input_bytes[start_pos + 1..self.position - 1]) |c| {
                if (c == '\n') {
                    self.line += 1;
                    self.column = 1;
                } else {
                    self.column += 1;
                }
            }
        } else {
            return error.UnterminatedString;
        }

        const token_slice = try self.input.slice(start_pos, self.position);
        return FastToken{
            .type = .String,
            .slice = token_slice,
            .line = start_line,
            .column = start_column,
        };
    }
};

// Batch tokenizer for maximum throughput
pub const BatchTokenizer = struct {
    lexer: FastLexer,
    tokens: []FastToken,
    token_count: usize,

    const Self = @This();

    pub fn init(input: []const u8, token_buffer: []FastToken) !Self {
        return Self{
            .lexer = try FastLexer.init(input),
            .tokens = token_buffer,
            .token_count = 0,
        };
    }

    // Tokenize entire input in one go for maximum performance
    pub fn tokenizeAll(self: *Self) ![]FastToken {
        self.token_count = 0;

        while (self.token_count < self.tokens.len) {
            const token = try self.lexer.nextToken();
            self.tokens[self.token_count] = token;
            self.token_count += 1;

            if (token.type == .EOF) {
                break;
            }
        }

        return self.tokens[0..self.token_count];
    }
};