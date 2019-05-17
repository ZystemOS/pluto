//
// kmain
// Zig version:
// Author: DrDeano
// Date: 2019-03-30
//
const builtin = @import("builtin");
const arch = @import("arch.zig");

pub fn panic(msg: []const u8, error_return_trace: ?*builtin.StackTrace) noreturn {
    @setCold(true);
    terminal.write("KERNEL PANIC: ");
    terminal.write(msg);
    while (true) {}
}

pub export fn kmain() void {
    arch.init();
    terminal.initialize();
    terminal.write("Hello, kernel World!");
}

// Hardware text mode color constants
const VGA_COLOUR = enum(u8) {
    VGA_COLOUR_BLACK,
    VGA_COLOUR_BLUE,
    VGA_COLOUR_GREEN,
    VGA_COLOUR_CYAN,
    VGA_COLOUR_RED,
    VGA_COLOUR_MAGENTA,
    VGA_COLOUR_BROWN,
    VGA_COLOUR_LIGHT_GREY,
    VGA_COLOUR_DARK_GREY,
    VGA_COLOUR_LIGHT_BLUE,
    VGA_COLOUR_LIGHT_GREEN,
    VGA_COLOUR_LIGHT_CYAN,
    VGA_COLOUR_LIGHT_RED,
    VGA_COLOUR_LIGHT_MAGENTA,
    VGA_COLOUR_LIGHT_BROWN,
    VGA_COLOUR_WHITE,
};

fn vga_entry_colour(fg: VGA_COLOUR, bg: VGA_COLOUR) u8 {
    return @enumToInt(fg) | (@enumToInt(bg) << 4);
}

fn vga_entry(uc: u8, colour: u8) u16 {
    return u16(uc) | (u16(colour) << 8);
}

const VGA_WIDTH = 80;
const VGA_HEIGHT = 25;

const terminal = struct {
    var row = usize(0);
    var column = usize(0);
    var colour = vga_entry_colour(VGA_COLOUR.VGA_COLOUR_LIGHT_GREY, VGA_COLOUR.VGA_COLOUR_BLACK);

    const buffer = @intToPtr([*]volatile u16, 0xC00B8000);

    fn initialize() void {
        var y = usize(0);
        while (y < VGA_HEIGHT) : (y += 1) {
            var x = usize(0);
            while (x < VGA_WIDTH) : (x += 1) {
                putCharAt(' ', colour, x, y);
            }
        }
    }

    fn setColour(new_colour: u8) void {
        colour = new_colour;
    }

    fn putCharAt(c: u8, new_colour: u8, x: usize, y: usize) void {
        const index = y * VGA_WIDTH + x;
        buffer[index] = vga_entry(c, new_colour);
    }

    fn putChar(c: u8) void {
        putCharAt(c, colour, column, row);
        column += 1;
        if (column == VGA_WIDTH) {
            column = 0;
            row += 1;
            if (row == VGA_HEIGHT)
                row = 0;
        }
    }

    fn write(data: []const u8) void {
        for (data) |c|
            putChar(c);
    }
};
