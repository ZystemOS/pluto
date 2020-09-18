const std = @import("std");
const arch = @import("arch.zig");
const TTY = @import("../../tty.zig").TTY;
const panic = @import("../../panic.zig").panic;
const log = std.log.scoped(.aarch64_tty);
const mailbox = @import("mailbox.zig");
const mem = @import("../../mem.zig");
const Tag = mailbox.Tag;

pub const CHAR_WIDTH: u8 = 8;
pub const CHAR_HEIGHT: u8 = 8;
const BLACK = Pixel{ .red = 0, .blue = 0, .green = 0 };
const WHITE = Pixel{ .red = 255, .blue = 255, .green = 255 };

const Framebuffer = struct {
    width: usize,
    height: usize,
    bytes_per_row: usize,
    text_columns: u8,
    text_rows: u8,
    text_cursor_x: u8,
    text_cursor_y: u8,
    buffer: [*]Pixel,
};

const Pixel = packed struct {
    blue: u8,
    green: u8,
    red: u8,
    alpha: u8 = 0,
};

const font = [_][]const u1{
    // space
    &[_]u1{
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    },
    // !
    &[_]u1{
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 1, 1, 0, 0, 0,
        0, 0, 0, 1, 1, 0, 0, 0,
        0, 0, 0, 1, 1, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 1, 1, 0, 0, 0,
        0, 0, 0, 1, 1, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    },
};

var framebuffer: Framebuffer = undefined;

fn writePixel(x: usize, y: usize, pixel: Pixel) void {
    framebuffer.buffer[y * framebuffer.bytes_per_row / 4 + x] = pixel;
}

fn clearScreen() void {
    var y: usize = 0;
    while (y < framebuffer.height) : (y += 1) {
        var x: usize = 0;
        while (x < framebuffer.width) : (x += 1) {
            writePixel(x, y, BLACK);
        }
    }
}

fn writeChar(x: usize, y: usize, char: u8) void {
    var ch = char;
    if (ch < ' ' or ch > '~')
        ch = ' ';
    var font_index = ch - ' ';
    if (font_index >= font.len) {
        font_index = 1;
    }
    const bitmap = font[font_index];
    const left = x * CHAR_WIDTH;
    const top = y * CHAR_HEIGHT;
    var pixel_x = left;
    var pixel_y = top;
    for (bitmap) |bit| {
        writePixel(pixel_x, pixel_y, if (bit == 0) BLACK else WHITE);
        pixel_x += 1;
        if (pixel_x == left + CHAR_WIDTH) {
            pixel_x = left;
            pixel_y += 1;
        }
    }
}

pub fn writeString(str: []const u8) !void {
    for (str) |ch| {
        if (ch == '\n') {
            setCursor(0, framebuffer.text_cursor_y + 1);
        } else {
            if (framebuffer.text_cursor_y < framebuffer.text_rows and framebuffer.text_cursor_x < framebuffer.text_columns) {
                writeChar(framebuffer.text_cursor_x, framebuffer.text_cursor_y, ch);
                setCursor(framebuffer.text_cursor_x + 1, framebuffer.text_cursor_y);
                if (framebuffer.text_cursor_x >= framebuffer.text_columns) {
                    setCursor(0, framebuffer.text_cursor_y + 1);
                }
            }
        }
    }
}

pub fn setCursor(x: u8, y: u8) void {
    framebuffer.text_cursor_x = x;
    framebuffer.text_cursor_y = y;
}

pub fn init(allocator2: *std.heap.FixedBufferAllocator, board: arch.BootPayload) TTY {
    var alloc_buff = [_]u8{0} ** (4 * 1024);
    var fixed_allocator = std.heap.FixedBufferAllocator.init(alloc_buff[0..]);
    var allocator = &fixed_allocator.allocator;

    var fb_addr: u32 = undefined;
    var fb_size: u32 = undefined;
    const fb_alignment: u32 = 16;

    // Set phys and virt dimensions to 640x480 and colour depth to the size of a pixel in bits
    const allocate_fb = &[_]u32{
        @enumToInt(Tag.ALLOCATE_BUFF),
        8,
        0,
        fb_alignment,
        0,
        @enumToInt(Tag.SET_BITS_PER_PIXEL),
        4,
        0,
        32,
        @enumToInt(Tag.SET_PHYS_DIMENSIONS),
        8,
        0,
        640,
        480,
        @enumToInt(Tag.SET_VIRT_DIMENSIONS),
        8,
        0,
        640,
        480,
        @enumToInt(Tag.GET_BYTES_PER_ROW),
        4,
        0,
        0,
    };
    const mmio_addr = board.mmioAddress();
    var pkg = mailbox.send(mmio_addr, allocate_fb, allocator) catch |e| panic(@errorReturnTrace(), "Failed to configure TTY: {}\n", .{e});
    // log.debug("Data is {}\n", .{pkg.data[0..]});
    defer allocator.free(pkg.data);
    var msg = mailbox.read(mmio_addr);

    if (@bitCast(u32, msg) != @bitCast(u32, pkg.message)) panic(null, "Framebuffer allocation responded with {X} but {X} was expected\n", .{ @bitCast(u32, msg), @bitCast(u32, pkg.message) });
    if (pkg.data[0] != (allocate_fb.len + 3) * @sizeOf(u32)) panic(null, "Response length {} was not the expected {}\n", .{ pkg.data[0], allocate_fb.len + 3 });
    if (pkg.data[1] != @enumToInt(mailbox.Code.RESPONSE_SUCCESS)) panic(null, "Response code {} was not the expected {}\n", .{ pkg.data[1], mailbox.Code.RESPONSE_SUCCESS });

    if (pkg.data[2] != @enumToInt(Tag.ALLOCATE_BUFF)) panic(null, "ALLOCATE_BUFF tag wasn't present in response\n", .{});
    if (pkg.data[3] != 8) panic(null, "ALLOCATE_BUFF size wasn't as expected in response\n", .{});
    if (pkg.data[4] != @enumToInt(mailbox.Code.RESPONSE_SUCCESS) | 8) panic(null, "ALLOCATE_BUFF code wasn't as expected in response\n", .{});

    if (pkg.data[7] != @enumToInt(Tag.SET_BITS_PER_PIXEL)) panic(null, "SET_BITS_PER_PIXEL tag wasn't present in response\n", .{});
    if (pkg.data[8] != 4) panic(null, "SET_BITS_PER_PIXEL size wasn't as expected in response\n", .{});
    if (pkg.data[9] != @enumToInt(mailbox.Code.RESPONSE_SUCCESS) | 4) panic(null, "SET_BITS_PER_PIXEL code wasn't as expected in response\n", .{});
    if (pkg.data[10] != allocate_fb[8]) panic(null, "SET_BITS_PER_PIXEL depth is {} and not {}\n", .{ pkg.data[10], allocate_fb[8] });

    if (pkg.data[11] != @enumToInt(Tag.SET_PHYS_DIMENSIONS)) panic(null, "SET_PHYS_DIMENSIONS tag wasn't present in response\n", .{});
    if (pkg.data[12] != 8) panic(null, "SET_PHYS_DIMENSIONS size wasn't as expected in response\n", .{});
    if (pkg.data[13] != @enumToInt(mailbox.Code.RESPONSE_SUCCESS) | 8) panic(null, "SET_PHYS_DIMENSIONS code wasn't as expected in response\n", .{});

    if (pkg.data[16] != @enumToInt(Tag.SET_VIRT_DIMENSIONS)) panic(null, "SET_VIRT_DIMENSIONS tag wasn't present in response\n", .{});
    if (pkg.data[17] != 8) panic(null, "SET_VIRT_DIMENSIONS size wasn't as expected in response\n", .{});
    if (pkg.data[18] != @enumToInt(mailbox.Code.RESPONSE_SUCCESS) | 8) panic(null, "SET_VIRT_DIMENSIONS code wasn't as expected in response\n", .{});

    if (pkg.data[21] != @enumToInt(Tag.GET_BYTES_PER_ROW)) panic(null, "GET_BYTES_PER_ROW tag wasn't present in response\n", .{});
    if (pkg.data[22] != 4) panic(null, "GET_BYTES_PER_ROW size wasn't as expected in response\n", .{});
    if (pkg.data[23] != @enumToInt(mailbox.Code.RESPONSE_SUCCESS) | 4) panic(null, "GET_BYTES_PER_ROW code wasn't as expected in response\n", .{});

    pkg.data[5] &= 0x3fffffff;
    //  log.debug("FB is at 0x{x} and is of size {}\n", .{ pkg.data[5], pkg.data[6] });
    //  log.debug("bytes per row is {}\n", .{pkg.data[24]});
    //  log.debug("Data is {}\n", .{pkg.data[0..]});

    framebuffer = .{
        .width = 640,
        .height = 480,
        .bytes_per_row = pkg.data[24],
        .text_columns = @truncate(u8, @as(u32, 640) / CHAR_WIDTH),
        .text_rows = @truncate(u8, @as(u32, 480) / CHAR_HEIGHT),
        .text_cursor_x = 0,
        .text_cursor_y = 0,
        .buffer = @intToPtr([*]Pixel, pkg.data[5]),
    };

    return .{
        .print = writeString,
        .setCursor = setCursor,
        .cols = framebuffer.text_columns,
        .rows = framebuffer.text_rows,
        .clear = clearScreen,
    };
}
