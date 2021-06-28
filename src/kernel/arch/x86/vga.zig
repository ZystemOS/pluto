const std = @import("std");
const builtin = std.builtin;
const is_test = builtin.is_test;
const expectEqual = std.testing.expectEqual;
const log = std.log.scoped(.x86_vga);
const build_options = @import("build_options");
const arch = if (is_test) @import("../../../../test/mock/kernel/arch_mock.zig") else @import("arch.zig");
const panic = @import("../../panic.zig").panic;

/// The port address for the VGA register selection.
const PORT_ADDRESS: u16 = 0x03D4;

/// The port address for the VGA data.
const PORT_DATA: u16 = 0x03D5;

/// The indexes that is passed to the address port to select the maximum scan line register for
/// the data to be read or written to.
const REG_MAXIMUM_SCAN_LINE: u8 = 0x09;

/// The register select for setting the cursor start scan lines.
const REG_CURSOR_START: u8 = 0x0A;

/// The register select for setting the cursor end scan lines.
const REG_CURSOR_END: u8 = 0x0B;

/// The command for setting the cursor's linear location (Upper 8 bits).
const REG_CURSOR_LOCATION_HIGH: u8 = 0x0E;

/// The command for setting the cursor's linear location (Lower 8 bits).
const REG_CURSOR_LOCATION_LOW: u8 = 0x0F;

/// The start of the cursor scan line, the very beginning.
const CURSOR_SCANLINE_START: u8 = 0x0;

/// The scan line for use in the underline cursor shape.
const CURSOR_SCANLINE_MIDDLE: u8 = 0xE;

/// The end of the cursor scan line, the very end.
const CURSOR_SCANLINE_END: u8 = 0xF;

/// If set, disables the cursor.
const CURSOR_DISABLE: u8 = 0x20;

/// The number of characters wide the screen is.
pub const WIDTH: u16 = 80;

/// The number of characters heigh the screen is.
pub const HEIGHT: u16 = 25;

// ----------
// The set of colours that VGA supports and can display for the foreground and background.
// ----------

/// Foreground/background VGA colour black.
pub const COLOUR_BLACK: u4 = 0x00;

/// Foreground/background VGA colour blue.
pub const COLOUR_BLUE: u4 = 0x01;

/// Foreground/background VGA colour green.
pub const COLOUR_GREEN: u4 = 0x02;

/// Foreground/background VGA colour cyan.
pub const COLOUR_CYAN: u4 = 0x03;

/// Foreground/background VGA colour red.
pub const COLOUR_RED: u4 = 0x04;

/// Foreground/background VGA colour magenta.
pub const COLOUR_MAGENTA: u4 = 0x05;

/// Foreground/background VGA colour brown.
pub const COLOUR_BROWN: u4 = 0x06;

/// Foreground/background VGA colour light grey.
pub const COLOUR_LIGHT_GREY: u4 = 0x07;

/// Foreground/background VGA colour dark grey.
pub const COLOUR_DARK_GREY: u4 = 0x08;

/// Foreground/background VGA colour light blue.
pub const COLOUR_LIGHT_BLUE: u4 = 0x09;

/// Foreground/background VGA colour light green.
pub const COLOUR_LIGHT_GREEN: u4 = 0x0A;

/// Foreground/background VGA colour light cyan.
pub const COLOUR_LIGHT_CYAN: u4 = 0x0B;

/// Foreground/background VGA colour light red.
pub const COLOUR_LIGHT_RED: u4 = 0x0C;

/// Foreground/background VGA colour light magenta.
pub const COLOUR_LIGHT_MAGENTA: u4 = 0x0D;

/// Foreground/background VGA colour light brown.
pub const COLOUR_LIGHT_BROWN: u4 = 0x0E;

/// Foreground/background VGA colour white.
pub const COLOUR_WHITE: u4 = 0x0F;

/// The set of shapes that can be displayed.
pub const CursorShape = enum {
    /// The cursor has the underline shape.
    UNDERLINE,

    /// The cursor has the block shape.
    BLOCK,
};

/// The cursor scan line start so to know whether is in block or underline mode.
var cursor_scanline_start: u8 = undefined;

/// The cursor scan line end so to know whether is in block or underline mode.
var cursor_scanline_end: u8 = undefined;

///
/// Set the VGA register port to read from or write to.
///
/// Arguments:
///     IN index: u8 - The index to send to the port address to select the register to write data
///                    to.
///
inline fn sendPort(index: u8) void {
    arch.out(PORT_ADDRESS, index);
}

///
/// Send data to the set VGA register port.
///
/// Arguments:
///     IN data: u8 - The data to send to the selected register.
///
inline fn sendData(data: u8) void {
    arch.out(PORT_DATA, data);
}

///
/// Get data from a set VGA register port.
///
/// Return: u8
///     The data in the selected register.
///
inline fn getData() u8 {
    return arch.in(u8, PORT_DATA);
}
///
/// Set the VGA register port to write to and sending data to that VGA register port.
///
/// Arguments:
///     IN index: u8 - The index to send to the port address to select the register to write the
//                     data to.
///     IN data: u8 - The data to send to the selected register.
///
inline fn sendPortData(index: u8, data: u8) void {
    sendPort(index);
    sendData(data);
}

///
/// Set the VGA register port to read from and get the data from that VGA register port.
///
/// Arguments:
///     IN index: u8 - The index to send to the port address to select the register to read the
///                    data from.
///
/// Return: u8
///     The data in the selected register.
///
inline fn getPortData(index: u8) u8 {
    sendPort(index);
    return getData();
}

///
/// Takes two 4 bit values that represent the foreground and background colour of the text and
/// returns a 8 bit value that gives both to be displayed.
///
/// Arguments:
///     IN fg: u4 - The foreground colour.
///     IN bg: u4 - The background colour.
///
/// Return: u8
///     Both combined into 1 byte for the colour to be displayed.
///
pub fn entryColour(fg: u4, bg: u4) u8 {
    return fg | @as(u8, bg) << 4;
}

///
/// Create the 2 bytes entry that the VGA used to display a character with a foreground and
/// background colour.
///
/// Arguments:
///     IN char: u8   - The character ro display.
///     IN colour: u8 - The foreground and background colour.
///
/// Return: u16
///     A VGA entry.
///
pub fn entry(char: u8, colour: u8) u16 {
    return char | @as(u16, colour) << 8;
}

///
/// Update the hardware on screen cursor.
///
/// Arguments:
///     IN x: u16 - The horizontal position of the cursor (column).
///     IN y: u16 - The vertical position of the cursor (row).
///
pub fn updateCursor(x: u16, y: u16) void {
    var pos: u16 = undefined;

    // Make sure new cursor position is within the screen
    if (x < WIDTH and y < HEIGHT) {
        pos = y * WIDTH + x;
    } else {
        // If not within the screen, then just put the cursor at the very end
        pos = (HEIGHT - 1) * WIDTH + (WIDTH - 1);
    }

    const pos_upper = (pos >> 8) & 0x00FF;
    const pos_lower = pos & 0x00FF;

    // Set the cursor position
    sendPortData(REG_CURSOR_LOCATION_LOW, @truncate(u8, pos_lower));
    sendPortData(REG_CURSOR_LOCATION_HIGH, @truncate(u8, pos_upper));
}

///
/// Get the linear position of the hardware cursor.
///
/// Return: u16
///     The linear cursor position.
///
pub fn getCursor() u16 {
    var cursor: u16 = 0;

    cursor |= getPortData(REG_CURSOR_LOCATION_LOW);
    cursor |= @as(u16, getPortData(REG_CURSOR_LOCATION_HIGH)) << 8;

    return cursor;
}

///
/// Enables the blinking cursor so that is is visible.
///
pub fn enableCursor() void {
    sendPortData(REG_CURSOR_START, cursor_scanline_start);
    sendPortData(REG_CURSOR_END, cursor_scanline_end);
}

///
/// Disables the blinking cursor so that is is invisible.
///
pub fn disableCursor() void {
    sendPortData(REG_CURSOR_START, CURSOR_DISABLE);
}

///
/// Set the shape of the cursor. This can be and underline or block shape.
///
/// Arguments:
///     IN shape: CursorShape - The enum CursorShape that selects which shape to use.
///
pub fn setCursorShape(shape: CursorShape) void {
    switch (shape) {
        CursorShape.UNDERLINE => {
            cursor_scanline_start = CURSOR_SCANLINE_MIDDLE;
            cursor_scanline_end = CURSOR_SCANLINE_END;
        },
        CursorShape.BLOCK => {
            cursor_scanline_start = CURSOR_SCANLINE_START;
            cursor_scanline_end = CURSOR_SCANLINE_END;
        },
    }

    sendPortData(REG_CURSOR_START, cursor_scanline_start);
    sendPortData(REG_CURSOR_END, cursor_scanline_end);
}

///
/// Initialise the VGA text mode. This sets the cursor and underline shape.
///
pub fn init() void {
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});

    // Set the maximum scan line to 0x0F
    sendPortData(REG_MAXIMUM_SCAN_LINE, CURSOR_SCANLINE_END);

    // Set by default the underline cursor
    setCursorShape(CursorShape.UNDERLINE);

    switch (build_options.test_mode) {
        .Initialisation => runtimeTests(),
        else => {},
    }
}

test "entryColour" {
    var fg = COLOUR_BLACK;
    var bg = COLOUR_BLACK;
    var res = entryColour(fg, bg);
    try expectEqual(@as(u8, 0x00), res);

    fg = COLOUR_LIGHT_GREEN;
    bg = COLOUR_BLACK;
    res = entryColour(fg, bg);
    try expectEqual(@as(u8, 0x0A), res);

    fg = COLOUR_BLACK;
    bg = COLOUR_LIGHT_GREEN;
    res = entryColour(fg, bg);
    try expectEqual(@as(u8, 0xA0), res);

    fg = COLOUR_BROWN;
    bg = COLOUR_LIGHT_GREEN;
    res = entryColour(fg, bg);
    try expectEqual(@as(u8, 0xA6), res);
}

test "entry" {
    const colour = entryColour(COLOUR_BROWN, COLOUR_LIGHT_GREEN);
    try expectEqual(@as(u8, 0xA6), colour);

    // Character '0' is 0x30
    var video_entry = entry('0', colour);
    try expectEqual(@as(u16, 0xA630), video_entry);

    video_entry = entry(0x55, colour);
    try expectEqual(@as(u16, 0xA655), video_entry);
}

test "updateCursor width out of bounds" {
    const x = WIDTH;
    const y = 0;

    const max_cursor = (HEIGHT - 1) * WIDTH + (WIDTH - 1);
    const expected_upper = @truncate(u8, (max_cursor >> 8) & 0x00FF);
    const expected_lower = @truncate(u8, max_cursor & 0x00FF);

    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for changing the hardware cursor:
    arch.addTestParams("out", .{ PORT_ADDRESS, REG_CURSOR_LOCATION_LOW, PORT_DATA, expected_lower, PORT_ADDRESS, REG_CURSOR_LOCATION_HIGH, PORT_DATA, expected_upper });

    updateCursor(x, y);
}

test "updateCursor height out of bounds" {
    const x = 0;
    const y = HEIGHT;

    const max_cursor = (HEIGHT - 1) * WIDTH + (WIDTH - 1);
    const expected_upper = @truncate(u8, (max_cursor >> 8) & 0x00FF);
    const expected_lower = @truncate(u8, max_cursor & 0x00FF);

    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for changing the hardware cursor:
    arch.addTestParams("out", .{ PORT_ADDRESS, REG_CURSOR_LOCATION_LOW, PORT_DATA, expected_lower, PORT_ADDRESS, REG_CURSOR_LOCATION_HIGH, PORT_DATA, expected_upper });

    updateCursor(x, y);
}

test "updateCursor width and height out of bounds" {
    const x = WIDTH;
    const y = HEIGHT;

    const max_cursor = (HEIGHT - 1) * WIDTH + (WIDTH - 1);
    const expected_upper = @truncate(u8, (max_cursor >> 8) & 0x00FF);
    const expected_lower = @truncate(u8, max_cursor & 0x00FF);

    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for changing the hardware cursor:
    arch.addTestParams("out", .{ PORT_ADDRESS, REG_CURSOR_LOCATION_LOW, PORT_DATA, expected_lower, PORT_ADDRESS, REG_CURSOR_LOCATION_HIGH, PORT_DATA, expected_upper });

    updateCursor(x, y);
}

test "updateCursor width-1 and height out of bounds" {
    const x = WIDTH - 1;
    const y = HEIGHT;

    const max_cursor = (HEIGHT - 1) * WIDTH + (WIDTH - 1);
    const expected_upper = @truncate(u8, (max_cursor >> 8) & 0x00FF);
    const expected_lower = @truncate(u8, max_cursor & 0x00FF);

    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for changing the hardware cursor:
    arch.addTestParams("out", .{ PORT_ADDRESS, REG_CURSOR_LOCATION_LOW, PORT_DATA, expected_lower, PORT_ADDRESS, REG_CURSOR_LOCATION_HIGH, PORT_DATA, expected_upper });

    updateCursor(x, y);
}

test "updateCursor width and height-1 out of bounds" {
    const x = WIDTH;
    const y = HEIGHT - 1;

    const max_cursor = (HEIGHT - 1) * WIDTH + (WIDTH - 1);
    const expected_upper = @truncate(u8, (max_cursor >> 8) & 0x00FF);
    const expected_lower = @truncate(u8, max_cursor & 0x00FF);

    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for changing the hardware cursor:
    arch.addTestParams("out", .{ PORT_ADDRESS, REG_CURSOR_LOCATION_LOW, PORT_DATA, expected_lower, PORT_ADDRESS, REG_CURSOR_LOCATION_HIGH, PORT_DATA, expected_upper });

    updateCursor(x, y);
}

test "updateCursor in bounds" {
    var x: u8 = 0x0A;
    var y: u8 = 0x0A;
    const expected = y * WIDTH + x;

    var expected_upper = @truncate(u8, (expected >> 8) & 0x00FF);
    var expected_lower = @truncate(u8, expected & 0x00FF);

    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for changing the hardware cursor:
    arch.addTestParams("out", .{ PORT_ADDRESS, REG_CURSOR_LOCATION_LOW, PORT_DATA, expected_lower, PORT_ADDRESS, REG_CURSOR_LOCATION_HIGH, PORT_DATA, expected_upper });
    updateCursor(x, y);
}

test "getCursor 1: 10" {
    const expect: u16 = 10;

    // Mocking out the arch.outb and arch.inb calls for getting the hardware cursor:
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("out", .{ PORT_ADDRESS, REG_CURSOR_LOCATION_LOW });
    arch.addTestParams("in", .{ PORT_DATA, @as(u8, 10) });
    arch.addTestParams("out", .{ PORT_ADDRESS, REG_CURSOR_LOCATION_HIGH });
    arch.addTestParams("in", .{ PORT_DATA, @as(u8, 0) });

    const actual = getCursor();
    try expectEqual(expect, actual);
}

test "getCursor 2: 0xBEEF" {
    const expect: u16 = 0xBEEF;

    // Mocking out the arch.outb and arch.inb calls for getting the hardware cursor:
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("out", .{ PORT_ADDRESS, REG_CURSOR_LOCATION_LOW });
    arch.addTestParams("in", .{ PORT_DATA, @as(u8, 0xEF) });
    arch.addTestParams("out", .{ PORT_ADDRESS, REG_CURSOR_LOCATION_HIGH });
    arch.addTestParams("in", .{ PORT_DATA, @as(u8, 0xBE) });

    const actual = getCursor();
    try expectEqual(expect, actual);
}

test "enableCursor" {
    arch.initTest();
    defer arch.freeTest();

    // Need to init the cursor start and end positions, so call the init() to set this up
    arch.addTestParams("out", .{
        PORT_ADDRESS, REG_MAXIMUM_SCAN_LINE, PORT_DATA, CURSOR_SCANLINE_END,    PORT_ADDRESS, REG_CURSOR_START, PORT_DATA, CURSOR_SCANLINE_MIDDLE, PORT_ADDRESS, REG_CURSOR_END, PORT_DATA, CURSOR_SCANLINE_END,
        // Mocking out the arch.outb calls for enabling the cursor:
        // These are the default cursor positions from init()
        PORT_ADDRESS, REG_CURSOR_START,      PORT_DATA, CURSOR_SCANLINE_MIDDLE, PORT_ADDRESS, REG_CURSOR_END,   PORT_DATA, CURSOR_SCANLINE_END,
    });

    init();
    enableCursor();
}

test "disableCursor" {
    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for disabling the cursor:
    arch.addTestParams("out", .{ PORT_ADDRESS, REG_CURSOR_START, PORT_DATA, CURSOR_DISABLE });
    disableCursor();
}

test "setCursorShape UNDERLINE" {
    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for setting the cursor shape to underline:
    // This will also check that the scan line variables were set properly as these are using in
    // the arch.outb call
    arch.addTestParams("out", .{ PORT_ADDRESS, REG_CURSOR_START, PORT_DATA, CURSOR_SCANLINE_MIDDLE, PORT_ADDRESS, REG_CURSOR_END, PORT_DATA, CURSOR_SCANLINE_END });

    setCursorShape(CursorShape.UNDERLINE);
}

test "setCursorShape BLOCK" {
    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for setting the cursor shape to block:
    // This will also check that the scan line variables were set properly as these are using in
    // the arch.outb call
    arch.addTestParams("out", .{ PORT_ADDRESS, REG_CURSOR_START, PORT_DATA, CURSOR_SCANLINE_START, PORT_ADDRESS, REG_CURSOR_END, PORT_DATA, CURSOR_SCANLINE_END });

    setCursorShape(CursorShape.BLOCK);
}

test "init" {
    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for setting the cursor max scan line and the shape to block:
    // This will also check that the scan line variables were set properly as these are using in
    // the arch.outb call for setting the cursor shape.
    arch.addTestParams("out", .{ PORT_ADDRESS, REG_MAXIMUM_SCAN_LINE, PORT_DATA, CURSOR_SCANLINE_END, PORT_ADDRESS, REG_CURSOR_START, PORT_DATA, CURSOR_SCANLINE_MIDDLE, PORT_ADDRESS, REG_CURSOR_END, PORT_DATA, CURSOR_SCANLINE_END });

    init();
}

///
/// Check that the maximum scan line is CURSOR_SCANLINE_END (0xF) when VGA is initialised.
///
fn rt_correctMaxScanLine() void {
    const max_scan_line = getPortData(REG_MAXIMUM_SCAN_LINE);

    if (max_scan_line != CURSOR_SCANLINE_END) {
        panic(@errorReturnTrace(), "FAILURE: Max scan line not {}, found {}\n", .{ CURSOR_SCANLINE_END, max_scan_line });
    }

    log.info("Tested max scan line\n", .{});
}

///
/// Check that the cursor is an underline when the VGA initialises.
///
fn rt_correctCursorShape() void {
    // Check the global variables are correct
    if (cursor_scanline_start != CURSOR_SCANLINE_MIDDLE or cursor_scanline_end != CURSOR_SCANLINE_END) {
        panic(@errorReturnTrace(), "FAILURE: Global cursor scanline incorrect. Start: {}, end: {}\n", .{ cursor_scanline_start, cursor_scanline_end });
    }

    const cursor_start = getPortData(REG_CURSOR_START);
    const cursor_end = getPortData(REG_CURSOR_END);

    if (cursor_start != CURSOR_SCANLINE_MIDDLE or cursor_end != CURSOR_SCANLINE_END) {
        panic(@errorReturnTrace(), "FAILURE: Cursor scanline are incorrect. Start: {}, end: {}\n", .{ cursor_start, cursor_end });
    }

    log.info("Tested cursor shape\n", .{});
}

///
/// Update the cursor to a known value. Then get the cursor and check they match. This will also
/// save the previous cursor position and restore is to the original position.
///
fn rt_setCursorGetCursor() void {
    // The known locations
    const x: u16 = 10;
    const y: u16 = 20;

    // Save the previous location
    const prev_linear_loc = getCursor();
    const prev_x_loc = @truncate(u8, prev_linear_loc % WIDTH);
    const prev_y_loc = @truncate(u8, prev_linear_loc / WIDTH);

    // Set the known location
    updateCursor(x, y);

    // Get the cursor
    const actual_linear_loc = getCursor();
    const actual_x_loc = @truncate(u8, actual_linear_loc % WIDTH);
    const actual_y_loc = @truncate(u8, actual_linear_loc / WIDTH);

    if (x != actual_x_loc or y != actual_y_loc) {
        panic(@errorReturnTrace(), "FAILURE: VGA cursor not the same: a_x: {}, a_y: {}, e_x: {}, e_y: {}\n", .{ x, y, actual_x_loc, actual_y_loc });
    }

    // Restore the previous x and y
    updateCursor(prev_x_loc, prev_y_loc);

    log.info("Tested updating cursor\n", .{});
}

///
/// Run all the runtime tests.
///
fn runtimeTests() void {
    rt_correctMaxScanLine();
    rt_correctCursorShape();
    rt_setCursorGetCursor();
}
