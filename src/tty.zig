const std = @import("std");

pub const Color = enum(u8) {
    // Reset
    reset = 0,

    // Regular colors
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,

    // Bright colors
    bright_black = 90,
    bright_red = 91,
    bright_green = 92,
    bright_yellow = 93,
    bright_blue = 94,
    bright_magenta = 95,
    bright_cyan = 96,
    bright_white = 97,

    // Background colors
    bg_black = 40,
    bg_red = 41,
    bg_green = 42,
    bg_yellow = 43,
    bg_blue = 44,
    bg_magenta = 45,
    bg_cyan = 46,
    bg_white = 47,

    // Bright background colors
    bg_bright_black = 100,
    bg_bright_red = 101,
    bg_bright_green = 102,
    bg_bright_yellow = 103,
    bg_bright_blue = 104,
    bg_bright_magenta = 105,
    bg_bright_cyan = 106,
    bg_bright_white = 107,

    pub fn format(
        self: Color,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        var buf: [6]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "\x1b[{d}m", .{@intFromEnum(self)}) catch unreachable;
        return writer.writeAll(slice);
    }
};

pub const Style = enum(u8) {
    reset = 0,
    bold = 1,
    dim = 2,
    italic = 3,
    underline = 4,
    blink = 5,
    blink_fast = 6,
    reverse = 7,
    hidden = 8,
    strikethrough = 9,

    // Reset specific styles
    normal_intensity = 22, // Reset bold/dim
    no_italic = 23,
    no_underline = 24,
    no_blink = 25,
    no_reverse = 27,
    no_hidden = 28,
    no_strikethrough = 29,

    pub fn format(
        self: Style,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        var buf: [6]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "\x1b[{d}m", .{@intFromEnum(self)}) catch unreachable;
        return writer.writeAll(slice);
    }
};
