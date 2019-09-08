const arch = @import("arch.zig").internals;

/// The port address for the VGA register selection.
pub const PORT_ADDRESS: u16 = 0x03D4;

/// The port address for the VGA data.
pub const PORT_DATA: u16    = 0x03D5;

/// The indexes that is passed to the address port to select the register for the data to be
/// read or written to.
pub const REG_HORIZONTAL_TOTAL: u8                = 0x00;
pub const REG_HORIZONTAL_DISPLAY_ENABLE_END: u8   = 0x01;
pub const REG_START_HORIZONTAL_BLINKING: u8       = 0x02;
pub const REG_END_HORIZONTAL_BLINKING: u8         = 0x03;
pub const REG_START_HORIZONTAL_RETRACE_PULSE: u8  = 0x04;
pub const REG_END_HORIZONTAL_RETRACE_PULSE: u8    = 0x05;
pub const REG_VERTICAL_TOTAL: u8                  = 0x06;
pub const REG_OVERFLOW: u8                        = 0x07;
pub const REG_PRESET_ROW_SCAN: u8                 = 0x08;
pub const REG_MAXIMUM_SCAN_LINE: u8               = 0x09;

/// The register select for setting the cursor scan lines.
pub const REG_CURSOR_START: u8                    = 0x0A;
pub const REG_CURSOR_END: u8                      = 0x0B;
pub const REG_START_ADDRESS_HIGH: u8              = 0x0C;
pub const REG_START_ADDRESS_LOW: u8               = 0x0D;

/// The command for setting the cursor's linear location.
pub const REG_CURSOR_LOCATION_HIGH: u8            = 0x0E;
pub const REG_CURSOR_LOCATION_LOW: u8             = 0x0F;

/// Other VGA registers.
pub const REG_VERTICAL_RETRACE_START: u8          = 0x10;
pub const REG_VERTICAL_RETRACE_END: u8            = 0x11;
pub const REG_VERTICAL_DISPLAY_ENABLE_END: u8     = 0x12;
pub const REG_OFFSET: u8                          = 0x13;
pub const REG_UNDERLINE_LOCATION: u8              = 0x14;
pub const REG_START_VERTICAL_BLINKING: u8         = 0x15;
pub const REG_END_VERTICAL_BLINKING: u8           = 0x16;
pub const REG_CRT_MODE_CONTROL: u8                = 0x17;
pub const REG_LINE_COMPARE: u8                    = 0x18;

/// The start of the cursor scan line, the very beginning.
pub const CURSOR_SCANLINE_START: u8   = 0x0;

/// The scan line for use in the underline cursor shape.
pub const CURSOR_SCANLINE_MIDDLE: u8  = 0xE;

/// The end of the cursor scan line, the very end.
pub const CURSOR_SCANLINE_END: u8     = 0xF;

/// If set, disables the cursor.
pub const CURSOR_DISABLE: u8    = 0x20;

/// The number of characters wide the screen is.
pub const WIDTH: u16        = 80;

/// The number of characters heigh the screen is.
pub const HEIGHT: u16       = 25;

/// The set of colours that VGA supports and can display for the foreground and background.
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

/// A inline function for setting the VGA register port to read from or write to.
inline fn sendPort(port: u8) void {
    arch.outb(PORT_ADDRESS, port);
}

/// A inline function for sending data to the set VGA register port.
inline fn sendData(data: u8) void {
    arch.outb(PORT_DATA, data);
}

/// A inline function for setting the VGA register port to read from or write toa and sending data
/// to the set VGA register port.
inline fn sendPortData(port: u8, data: u8) void {
    sendPort(port);
    sendData(data);
}

/// A inline function for getting data from a set VGA register port.
inline fn getData() u8 {
    return arch.inb(PORT_DATA);
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
    return u8(fg) | u8(bg) << 4;
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
    return u16(char) | u16(colour) << 8;
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

    sendPort(REG_CURSOR_LOCATION_LOW);
    cursor |= u16(getData());

    sendPort(REG_CURSOR_LOCATION_HIGH);
    cursor |= u16(getData()) << 8;

    return cursor;
}

///
/// Enables the blinking cursor to that is is visible.
///
pub fn enableCursor() void {
    sendPortData(REG_CURSOR_START, cursor_scanline_start);
    sendPortData(REG_CURSOR_END, cursor_scanline_end);
}

///
/// Disables the blinking cursor to that is is visible.
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
    // Set the maximum scan line to 0x0F
    sendPortData(REG_MAXIMUM_SCAN_LINE, CURSOR_SCANLINE_END);

    // Set by default the underline cursor
    setCursorShape(CursorShape.UNDERLINE);
}
