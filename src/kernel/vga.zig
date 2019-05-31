// Zig version: 0.4.0

const builtin = @import("builtin");
const arch = @import("arch.zig").internals;

const expectEqual = @import("std").testing.expectEqual;
const warn = @import("std").debug.warn;

/// The port address for the VGA register selection.
const PORT_ADDRESS: u16 = 0x03D4;

/// The port address for the VGA data.
const PORT_DATA: u16 = 0x03D5;

// The indexes that is passed to the address port to select the register for the data to be
// read or written to.
const REG_HORIZONTAL_TOTAL: u8                = 0x00;
const REG_HORIZONTAL_DISPLAY_ENABLE_END: u8   = 0x01;
const REG_START_HORIZONTAL_BLINKING: u8       = 0x02;
const REG_END_HORIZONTAL_BLINKING: u8         = 0x03;
const REG_START_HORIZONTAL_RETRACE_PULSE: u8  = 0x04;
const REG_END_HORIZONTAL_RETRACE_PULSE: u8    = 0x05;
const REG_VERTICAL_TOTAL: u8                  = 0x06;
const REG_OVERFLOW: u8                        = 0x07;
const REG_PRESET_ROW_SCAN: u8                 = 0x08;
const REG_MAXIMUM_SCAN_LINE: u8               = 0x09;

/// The command for setting the start of the cursor scan line.
const REG_CURSOR_START: u8                    = 0x0A;

/// The command for setting the end of the cursor scan line.
const REG_CURSOR_END: u8                      = 0x0B;
const REG_START_ADDRESS_HIGH: u8              = 0x0C;
const REG_START_ADDRESS_LOW: u8               = 0x0D;

/// The command for setting the upper byte of the cursor's linear location.
const REG_CURSOR_LOCATION_HIGH: u8            = 0x0E;

/// The command for setting the lower byte of the cursor's linear location.
const REG_CURSOR_LOCATION_LOW: u8             = 0x0F;
const REG_VERTICAL_RETRACE_START: u8          = 0x10;
const REG_VERTICAL_RETRACE_END: u8            = 0x11;
const REG_VERTICAL_DISPLAY_ENABLE_END: u8     = 0x12;
const REG_OFFSET: u8                          = 0x13;
const REG_UNDERLINE_LOCATION: u8              = 0x14;
const REG_START_VERTICAL_BLINKING: u8         = 0x15;
const REG_END_VERTICAL_BLINKING: u8           = 0x16;
const REG_CRT_MODE_CONTROL: u8                = 0x17;
const REG_LINE_COMPARE: u8                    = 0x18;


///The start of the cursor scan line, the very beginning.
const CURSOR_SCANLINE_START: u8   = 0x0;

///The scan line for use in the underline cursor shape.
const CURSOR_SCANLINE_MIDDLE: u8  = 0xE;

///The end of the cursor scan line, the very end.
const CURSOR_SCANLINE_END: u8     = 0xF;

/// If set, disables the cursor.
const CURSOR_DISABLE: u8    = 0x20;

pub const WIDTH: u16        = 80;
pub const HEIGHT: u16       = 25;

// The set of colours that VGA supports and can display for the foreground and background.
pub const COLOUR_BLACK: u4            = 0x00;
pub const COLOUR_BLUE: u4             = 0x01;
pub const COLOUR_GREEN: u4            = 0x02;
pub const COLOUR_CYAN: u4             = 0x03;
pub const COLOUR_RED: u4              = 0x04;
pub const COLOUR_MAGENTA: u4          = 0x05;
pub const COLOUR_BROWN: u4            = 0x06;
pub const COLOUR_LIGHT_GREY: u4       = 0x07;
pub const COLOUR_DARK_GREY: u4        = 0x08;
pub const COLOUR_LIGHT_BLUE: u4       = 0x09;
pub const COLOUR_LIGHT_GREEN: u4      = 0x0A;
pub const COLOUR_LIGHT_CYAN: u4       = 0x0B;
pub const COLOUR_LIGHT_RED: u4        = 0x0C;
pub const COLOUR_LIGHT_MAGENTA: u4    = 0x0D;
pub const COLOUR_LIGHT_BROWN: u4      = 0x0E;
pub const COLOUR_WHITE: u4            = 0x0F;

/// The set of shapes that can be displayed.
pub const CursorShape = enum(u1) {
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
/// Takes two 4 bit values that represent the foreground and background colour of the text and
/// returns a 8 bit value that gives both to be displayed.
///
/// Arguments:
///     IN fg: u4 - The foreground colour.
///     IN bg: u4 - The background colour.
///
/// Return:
///     Both combined into 1 byte for the colour to be displayed.
///
pub fn entryColour(fg: u4, bg: u4) u8 {
    return u8(fg) | u8(bg) << 4;
}

///
/// Create the 2 bytes entry that the VGA used to display a character with a foreground and
/// background colour.
///
/// Arguments:
///     IN uc: u8     - The character.
///     IN colour: u8 - The foreground and background colour.
///
/// Return:
///     The VGA entry.
///
pub fn entry(uc: u8, colour: u8) u16 {
    return u16(uc) | u16(colour) << 8;
}

///
/// Update the hardware on screen cursor.
///
/// Arguments:
///     IN x: u16 - The horizontal position of the cursor.
///     IN y: u16 - The vertical position of the cursor.
///
/// Return:
///     The VGA entry.
///
pub fn updateCursor(x: u16, y: u16) void {
    var pos: u16 = undefined;
    var pos_upper: u16 = undefined;
    var pos_lower: u16 = undefined;

    // Make sure new cursor position is within the screen
    if (x < WIDTH and y < HEIGHT) {
        pos = y * WIDTH + x;
    } else {
        // If not within the screen, then just put the cursor at the very end
        pos = (HEIGHT - 1) * WIDTH + (WIDTH - 1);
    }

    pos_upper = (pos >> 8) & 0x00FF;
    pos_lower = pos & 0x00FF;

    // Set the cursor position
    arch.outb(PORT_ADDRESS, REG_CURSOR_LOCATION_LOW);
    arch.outb(PORT_DATA, @truncate(u8, pos_lower));

    arch.outb(PORT_ADDRESS, REG_CURSOR_LOCATION_HIGH);
    arch.outb(PORT_DATA, @truncate(u8, pos_upper));
}

///
/// Get the hardware cursor position.
///
/// Return:
///     The linear cursor position.
///
pub fn getCursor() u16 {
    var cursor: u16 = 0;

    arch.outb(PORT_ADDRESS, REG_CURSOR_LOCATION_LOW);
    cursor |= u16(arch.inb(PORT_DATA));

    arch.outb(PORT_ADDRESS, REG_CURSOR_LOCATION_HIGH);
    cursor |= u16(arch.inb(PORT_DATA)) << 8;

    return cursor;
}

///
/// Enables the blinking cursor to that is is visible.
///
pub fn enableCursor() void {
    arch.outb(PORT_ADDRESS, REG_CURSOR_START);
    arch.outb(PORT_DATA, cursor_scanline_start);

    arch.outb(PORT_ADDRESS, REG_CURSOR_END);
    arch.outb(PORT_DATA, cursor_scanline_end);
}

///
/// Disables the blinking cursor to that is is visible.
///
pub fn disableCursor() void {
    arch.outb(PORT_ADDRESS, REG_CURSOR_START);
    arch.outb(PORT_DATA, CURSOR_DISABLE);
}

///
/// Set the shape of the cursor. This can be and underline or block shape.
///
/// Arguments:
///     IN shape: CURSOR_SHAPE - The enum CURSOR_SHAPE that selects which shape to use.
///
pub fn setCursorShape(shape: CursorShape) void {
    switch (shape) {
        CursorShape.UNDERLINE => {
            arch.outb(PORT_ADDRESS, REG_CURSOR_START);
            arch.outb(PORT_DATA, CURSOR_SCANLINE_MIDDLE);

            arch.outb(PORT_ADDRESS, REG_CURSOR_END);
            arch.outb(PORT_DATA, CURSOR_SCANLINE_END);

            cursor_scanline_start = CURSOR_SCANLINE_MIDDLE;
            cursor_scanline_end = CURSOR_SCANLINE_END;
        },
        CursorShape.BLOCK => {
            arch.outb(PORT_ADDRESS, REG_CURSOR_START);
            arch.outb(PORT_DATA, CURSOR_SCANLINE_START);

            arch.outb(PORT_ADDRESS, REG_CURSOR_END);
            arch.outb(PORT_DATA, CURSOR_SCANLINE_END);

            cursor_scanline_start = CURSOR_SCANLINE_START;
            cursor_scanline_end = CURSOR_SCANLINE_END;
        },
    }
}

///
/// Initialise the VGA text mode. This sets the cursor and underline shape.
///
pub fn init() void {
    // Set the maximum scan line to 0x0F
    arch.outb(PORT_ADDRESS, REG_MAXIMUM_SCAN_LINE);
    arch.outb(PORT_DATA, CURSOR_SCANLINE_END);

    // Set by default the underline cursor
    setCursorShape(CursorShape.UNDERLINE);
}

test "entryColour" {
    var fg: u4 = COLOUR_BLACK;
    var bg: u4 = COLOUR_BLACK;
    var res: u8 = entryColour(fg, bg);
    expectEqual(u8(0x00), res);

    fg = COLOUR_LIGHT_GREEN;
    bg = COLOUR_BLACK;
    res = entryColour(fg, bg);
    expectEqual(u8(0x0A), res);

    fg = COLOUR_BLACK;
    bg = COLOUR_LIGHT_GREEN;
    res = entryColour(fg, bg);
    expectEqual(u8(0xA0), res);

    fg = COLOUR_BROWN;
    bg = COLOUR_LIGHT_GREEN;
    res = entryColour(fg, bg);
    expectEqual(u8(0xA6), res);
}

test "entry" {
    var colour: u8 = entryColour(COLOUR_BROWN, COLOUR_LIGHT_GREEN);
    expectEqual(u8(0xA6), colour);

    // Character '0' is 0x30
    var video_entry: u16 = entry('0', colour);
    expectEqual(u16(0xA630), video_entry);

    video_entry = entry(0x55, colour);
    expectEqual(u16(0xA655), video_entry);
}

fn testOutOfBounds(x: u16, y: u16) bool {
    if (x < HEIGHT and y < WIDTH) {
        return true;
    }
    return false;
}

fn testUpperVal(x: u16, y: u16) u16 {
    const pos: u16 = x * WIDTH + y;
    const pos_upper: u16 = (pos >> 8) & 0x00FF;
    return pos_upper;
}

fn testLowerVal(x: u16, y: u16) u16 {
    const pos: u16 = x * WIDTH + y;
    const pos_lower: u16 = pos & 0x00FF;
    return pos_lower;
}

test "updateCursor out of bounds" {
    var x: u16 = 0;
    var y: u16 = 0;
    var res: bool = testOutOfBounds(x, y);
    expectEqual(true, res);

    x = HEIGHT - 1;
    res = testOutOfBounds(x, y);
    expectEqual(true, res);

    y = WIDTH - 1;
    res = testOutOfBounds(x, y);
    expectEqual(true, res);

    x = HEIGHT;
    y = WIDTH;
    res = testOutOfBounds(x, y);
    expectEqual(false, res);

    x = HEIGHT - 1;
    y = WIDTH;
    res = testOutOfBounds(x, y);
    expectEqual(false, res);

    x = HEIGHT;
    y = WIDTH - 1;
    res = testOutOfBounds(x, y);
    expectEqual(false, res);
}

test "updateCursor lower values" {
    var x: u16 = 0x0000;
    var y: u16 = 0x0000;
    var res: u16 = testLowerVal(x, y);
    var expected: u16 = 0x0000;
    expectEqual(expected, res);

    x = 0x0000;
    y = 0x000A;
    res = testLowerVal(x, y);
    expected = 0x000A;
    expectEqual(expected, res);

    x = 0x000A;
    y = 0x0000;
    res = testLowerVal(x, y);
    expected = 0x0020;
    expectEqual(expected, res);

    x = 0x000A;
    y = 0x000A;
    res = testLowerVal(x, y);
    expected = 0x002A;
    expectEqual(expected, res);
}

test "updateCursor upper values" {
    var x: u16 = 0x0000;
    var y: u16 = 0x0000;
    var res: u16 = testUpperVal(x, y);
    var expected: u16 = 0x0000;
    expectEqual(expected, res);

    x = 0x0000;
    y = 0x000A;
    res = testUpperVal(x, y);
    expected = 0x0000;
    expectEqual(expected, res);

    x = 0x000A;
    y = 0x0000;
    res = testUpperVal(x, y);
    expected = 0x0003;
    expectEqual(expected, res);

    x = 0x000A;
    y = 0x000A;
    res = testUpperVal(x, y);
    expected = 0x0003;
    expectEqual(expected, res);
}

test "getCursor all" {
    warn(" Waiting for mocking ");
    var res = getCursor();
}

test "enableCursor all" {
    warn(" Waiting for mocking ");
    enableCursor();
}

test "disableCursor all" {
    warn(" Waiting for mocking ");
    disableCursor();
}

test "setCursorShape all" {
    setCursorShape(CursorShape.UNDERLINE);
    expectEqual(CURSOR_SCANLINE_MIDDLE, cursor_scanline_start);
    expectEqual(CURSOR_SCANLINE_END, cursor_scanline_end);

    setCursorShape(CursorShape.BLOCK);
    expectEqual(CURSOR_SCANLINE_START, cursor_scanline_start);
    expectEqual(CURSOR_SCANLINE_END, cursor_scanline_end);
}

test "init all" {
    warn(" Waiting for mocking ");
    init();
    expectEqual(CURSOR_SCANLINE_MIDDLE, cursor_scanline_start);
    expectEqual(CURSOR_SCANLINE_END, cursor_scanline_end);
}
