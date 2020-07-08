const std = @import("std");
const arch = @import("arch.zig");
const TTY = @import("../../tty.zig").TTY;
const panic = @import("../../panic.zig").panic;
const log = @import("../../log.zig");
const mailbox = @import("mailbox.zig");
const Tag = mailbox.Tag;

const CHAR_WIDTH: u8 = 8;
const CHAR_HEIGHT: u8 = 8;
const BLACK = Pixel{ .red = 0, .blue = 0, .green = 0 };
const WHITE = Pixel{ .red = 255, .blue = 255, .green = 255 };

const Framebuffer = struct {
    width: usize,
    height: usize,
    columns: u8,
    rows: u8,
    x: u8,
    y: u8,
    buffer: [*]Pixel,
};

const Pixel = packed struct {
    red: u8,
    green: u8,
    blue: u8,
};

const font = [_][]const u1{
    &[_]u1{},
    // !
    &[_]u1{
        0, 0, 0, 1, 1, 0, 0, 0,
        0, 0, 0, 1, 1, 0, 0, 0,
        0, 0, 0, 1, 1, 0, 0, 0,
        0, 0, 0, 1, 1, 0, 0, 0,
        0, 0, 0, 1, 1, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 1, 1, 0, 0, 0,
        0, 0, 0, 1, 1, 0, 0, 0,
    },
};

var framebuffer: Framebuffer = undefined;

fn writePixel(x: usize, y: usize, pixel: Pixel) void {
    log.logDebug("Writing pixel {} to ({}, {}) at fb {}, which is address {x}\n", .{ pixel, x, y, @ptrToInt(framebuffer.buffer), @ptrToInt(&framebuffer.buffer[y * framebuffer.columns + x]) });
    framebuffer.buffer[y * framebuffer.columns + x] = pixel;
}

fn writeChar(x: usize, y: usize, char: u8) void {
    var ch = char;
    if (char < ' ' or char > '~')
        ch = ' ';
    const bitmap = font[ch - ' '];
    var x2 = x;
    var y2 = y;
    for (bitmap) |bit, i| {
        const pixel = if (bit == 0) BLACK else WHITE;
        writePixel(x2, y2, pixel);
        x2 += 1;
        if (x2 >= CHAR_WIDTH) {
            x2 = x;
            y2 += 1;
        }
    }
}

fn writeString(str: []const u8) !void {
    for (str) |ch| {
        if (ch == '\n') {
            setCursor(0, framebuffer.y + 1);
        } else {
            if (framebuffer.y < framebuffer.rows and framebuffer.x < framebuffer.columns) {
                writeChar(framebuffer.x, framebuffer.y, ch);
                setCursor(framebuffer.x + 1, framebuffer.y);
                if (framebuffer.x >= framebuffer.columns) {
                    setCursor(0, framebuffer.y + 1);
                }
            }
        }
    }
}

fn setCursor(x: u8, y: u8) void {
    framebuffer.x = x;
    framebuffer.y = y;
}

pub fn init(allocator2: *std.mem.Allocator, board: arch.BootPayload) TTY {
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
        24,
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
    };
    const mmio_addr = board.mmioAddress();
    var pkg = mailbox.send(mmio_addr, allocate_fb, allocator) catch |e| panic(@errorReturnTrace(), "Failed to configure TTY: {}\n", .{e});
    log.logDebug("Data is {}\n", .{pkg.data[0..]});
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

    if (pkg.data[11] != @enumToInt(Tag.SET_PHYS_DIMENSIONS)) panic(null, "SET_PHYS_DIMENSIONS tag wasn't present in response\n", .{});
    if (pkg.data[12] != 8) panic(null, "SET_PHYS_DIMENSIONS size wasn't as expected in response\n", .{});
    if (pkg.data[13] != @enumToInt(mailbox.Code.RESPONSE_SUCCESS) | 8) panic(null, "SET_PHYS_DIMENSIONS code wasn't as expected in response\n", .{});

    if (pkg.data[16] != @enumToInt(Tag.SET_VIRT_DIMENSIONS)) panic(null, "SET_VIRT_DIMENSIONS tag wasn't present in response\n", .{});
    if (pkg.data[17] != 8) panic(null, "SET_VIRT_DIMENSIONS size wasn't as expected in response\n", .{});
    if (pkg.data[18] != @enumToInt(mailbox.Code.RESPONSE_SUCCESS) | 8) panic(null, "SET_VIRT_DIMENSIONS code wasn't as expected in response\n", .{});

    log.logDebug("FB is at {} and is of size {}\n", .{ pkg.data[4], pkg.data[5] });
    log.logDebug("Data is {}\n", .{pkg.data[0..]});

    framebuffer = .{
        .width = 640,
        .height = 480,
        .columns = @truncate(u8, 640) / CHAR_WIDTH,
        .rows = @truncate(u8, 480) / CHAR_HEIGHT,
        .x = 0,
        .y = 0,
        .buffer = @intToPtr([*]Pixel, pkg.data[4]),
    };
    writePixel(0, 0, WHITE);
    writePixel(0, 1, WHITE);
    writePixel(1, 0, WHITE);
    writePixel(1, 1, WHITE);
    return .{
        .print = writeString,
        .setCursor = setCursor,
        .cols = framebuffer.columns,
        .rows = framebuffer.rows,
        .clear = null,
    };
}
