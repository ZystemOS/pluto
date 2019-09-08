const vga = @import("../../../src/kernel/vga.zig");
const arch = @import("../../../src/kernel/arch.zig").internals;

const expectEqual = @import("std").testing.expectEqual;

test "entryColour" {
    var fg: u4 = vga.COLOUR_BLACK;
    var bg: u4 = vga.COLOUR_BLACK;
    var res: u8 = vga.entryColour(fg, bg);
    expectEqual(u8(0x00), res);

    fg = vga.COLOUR_LIGHT_GREEN;
    bg = vga.COLOUR_BLACK;
    res = vga.entryColour(fg, bg);
    expectEqual(u8(0x0A), res);

    fg = vga.COLOUR_BLACK;
    bg = vga.COLOUR_LIGHT_GREEN;
    res = vga.entryColour(fg, bg);
    expectEqual(u8(0xA0), res);

    fg = vga.COLOUR_BROWN;
    bg = vga.COLOUR_LIGHT_GREEN;
    res = vga.entryColour(fg, bg);
    expectEqual(u8(0xA6), res);
}

test "entry" {
    var colour: u8 = vga.entryColour(vga.COLOUR_BROWN, vga.COLOUR_LIGHT_GREEN);
    expectEqual(u8(0xA6), colour);

    // Character '0' is 0x30
    var video_entry: u16 = vga.entry('0', colour);
    expectEqual(u16(0xA630), video_entry);

    video_entry = vga.entry(0x55, colour);
    expectEqual(u16(0xA655), video_entry);
}

test "updateCursor width out of bounds" {
    const x: u16 = vga.WIDTH;
    const y: u16 = 0;

    const max_cursor: u16 = (vga.HEIGHT - 1) * vga.WIDTH + (vga.WIDTH - 1);
    const expected_upper: u8 = @truncate(u8, (max_cursor >> 8) & 0x00FF);
    const expected_lower: u8 = @truncate(u8, max_cursor & 0x00FF);

    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for changing the hardware cursor:
    arch.addTestParams("outb",
        vga.PORT_ADDRESS, vga.REG_CURSOR_LOCATION_LOW,
        vga.PORT_DATA, expected_lower,
        vga.PORT_ADDRESS, vga.REG_CURSOR_LOCATION_HIGH,
        vga.PORT_DATA, expected_upper);

    vga.updateCursor(x, y);
}

test "updateCursor height out of bounds" {
    const x: u16 = 0;
    const y: u16 = vga.HEIGHT;

    const max_cursor: u16 = (vga.HEIGHT - 1) * vga.WIDTH + (vga.WIDTH - 1);
    const expected_upper: u8 = @truncate(u8, (max_cursor >> 8) & 0x00FF);
    const expected_lower: u8 = @truncate(u8, max_cursor & 0x00FF);

    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for changing the hardware cursor:
    arch.addTestParams("outb",
        vga.PORT_ADDRESS, vga.REG_CURSOR_LOCATION_LOW,
        vga.PORT_DATA, expected_lower,
        vga.PORT_ADDRESS, vga.REG_CURSOR_LOCATION_HIGH,
        vga.PORT_DATA, expected_upper);

    vga.updateCursor(x, y);
}

test "updateCursor width and height out of bounds" {
    const x: u16 = vga.WIDTH;
    const y: u16 = vga.HEIGHT;

    const max_cursor: u16 = (vga.HEIGHT - 1) * vga.WIDTH + (vga.WIDTH - 1);
    const expected_upper: u8 = @truncate(u8, (max_cursor >> 8) & 0x00FF);
    const expected_lower: u8 = @truncate(u8, max_cursor & 0x00FF);

    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for changing the hardware cursor:
    arch.addTestParams("outb",
        vga.PORT_ADDRESS, vga.REG_CURSOR_LOCATION_LOW,
        vga.PORT_DATA, expected_lower,
        vga.PORT_ADDRESS, vga.REG_CURSOR_LOCATION_HIGH,
        vga.PORT_DATA, expected_upper);

    vga.updateCursor(x, y);
}

test "updateCursor width-1 and height out of bounds" {
    const x: u16 = vga.WIDTH - 1;
    const y: u16 = vga.HEIGHT;

    const max_cursor: u16 = (vga.HEIGHT - 1) * vga.WIDTH + (vga.WIDTH - 1);
    const expected_upper: u8 = @truncate(u8, (max_cursor >> 8) & 0x00FF);
    const expected_lower: u8 = @truncate(u8, max_cursor & 0x00FF);

    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for changing the hardware cursor:
    arch.addTestParams("outb",
        vga.PORT_ADDRESS, vga.REG_CURSOR_LOCATION_LOW,
        vga.PORT_DATA, expected_lower,
        vga.PORT_ADDRESS, vga.REG_CURSOR_LOCATION_HIGH,
        vga.PORT_DATA, expected_upper);

    vga.updateCursor(x, y);
}

test "updateCursor width and height-1 out of bounds" {
    const x: u16 = vga.WIDTH;
    const y: u16 = vga.HEIGHT - 1;

    const max_cursor: u16 = (vga.HEIGHT - 1) * vga.WIDTH + (vga.WIDTH - 1);
    const expected_upper: u8 = @truncate(u8, (max_cursor >> 8) & 0x00FF);
    const expected_lower: u8 = @truncate(u8, max_cursor & 0x00FF);

    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for changing the hardware cursor:
    arch.addTestParams("outb",
        vga.PORT_ADDRESS, vga.REG_CURSOR_LOCATION_LOW,
        vga.PORT_DATA, expected_lower,
        vga.PORT_ADDRESS, vga.REG_CURSOR_LOCATION_HIGH,
        vga.PORT_DATA, expected_upper);

    vga.updateCursor(x, y);
}

test "updateCursor in bounds" {
    var x: u16 = 0x000A;
    var y: u16 = 0x000A;
    const expected: u16 = y * vga.WIDTH + x;

    var expected_upper: u8 = @truncate(u8, (expected >> 8) & 0x00FF);
    var expected_lower: u8 = @truncate(u8, expected & 0x00FF);

    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for changing the hardware cursor:
    arch.addTestParams("outb",
        vga.PORT_ADDRESS, vga.REG_CURSOR_LOCATION_LOW,
        vga.PORT_DATA, expected_lower,
        vga.PORT_ADDRESS, vga.REG_CURSOR_LOCATION_HIGH,
        vga.PORT_DATA, expected_upper);
    vga.updateCursor(x, y);
}

test "getCursor 1: 10" {
    const expect: u16 = u16(10);

    // Mocking out the arch.outb and arch.inb calls for getting the hardware cursor:
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("outb",
        vga.PORT_ADDRESS, vga.REG_CURSOR_LOCATION_LOW);

    arch.addTestParams("inb",
        vga.PORT_DATA, u8(10));

    arch.addTestParams("outb",
        vga.PORT_ADDRESS, vga.REG_CURSOR_LOCATION_HIGH);

    arch.addTestParams("inb",
        vga.PORT_DATA, u8(0));

    const actual: u16 = vga.getCursor();
    expectEqual(expect, actual);
}

test "getCursor 2: 0xBEEF" {
    const expect: u16 = u16(0xBEEF);

    // Mocking out the arch.outb and arch.inb calls for getting the hardware cursor:
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("outb",
        vga.PORT_ADDRESS, vga.REG_CURSOR_LOCATION_LOW);

    arch.addTestParams("inb",
        vga.PORT_DATA, u8(0xEF));

    arch.addTestParams("outb",
        vga.PORT_ADDRESS, vga.REG_CURSOR_LOCATION_HIGH);

    arch.addTestParams("inb",
        vga.PORT_DATA, u8(0xBE));

    const actual: u16 = vga.getCursor();
    expectEqual(expect, actual);
}

test "enableCursor all" {
    arch.initTest();
    defer arch.freeTest();

    // Need to init the cursor start and end positions, so call the vga.init() to set this up
    arch.addTestParams("outb",
        vga.PORT_ADDRESS, vga.REG_MAXIMUM_SCAN_LINE,
        vga.PORT_DATA, vga.CURSOR_SCANLINE_END,
        vga.PORT_ADDRESS, vga.REG_CURSOR_START,
        vga.PORT_DATA, vga.CURSOR_SCANLINE_MIDDLE,
        vga.PORT_ADDRESS, vga.REG_CURSOR_END,
        vga.PORT_DATA, vga.CURSOR_SCANLINE_END,
        // Mocking out the arch.outb calls for enabling the cursor:
        // These are the default cursor positions from vga.init()
        vga.PORT_ADDRESS, vga.REG_CURSOR_START,
        vga.PORT_DATA, vga.CURSOR_SCANLINE_MIDDLE,
        vga.PORT_ADDRESS, vga.REG_CURSOR_END,
        vga.PORT_DATA, vga.CURSOR_SCANLINE_END);

    vga.init();
    vga.enableCursor();
}

test "disableCursor all" {
    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for disabling the cursor:
    arch.addTestParams("outb",
        vga.PORT_ADDRESS, vga.REG_CURSOR_START,
        vga.PORT_DATA, vga.CURSOR_DISABLE);
    vga.disableCursor();
}

test "setCursorShape UNDERLINE" {
    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for setting the cursor shape to underline:
    // This will also check that the scan line variables were set properly as these are using in
    // the arch.outb call
    arch.addTestParams("outb",
        vga.PORT_ADDRESS, vga.REG_CURSOR_START,
        vga.PORT_DATA, vga.CURSOR_SCANLINE_MIDDLE,
        vga.PORT_ADDRESS, vga.REG_CURSOR_END,
        vga.PORT_DATA, vga.CURSOR_SCANLINE_END);

    vga.setCursorShape(vga.CursorShape.UNDERLINE);
}

test "setCursorShape BLOCK" {
    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for setting the cursor shape to block:
    // This will also check that the scan line variables were set properly as these are using in
    // the arch.outb call
    arch.addTestParams("outb",
        vga.PORT_ADDRESS, vga.REG_CURSOR_START,
        vga.PORT_DATA, vga.CURSOR_SCANLINE_START,
        vga.PORT_ADDRESS, vga.REG_CURSOR_END,
        vga.PORT_DATA, vga.CURSOR_SCANLINE_END);

    vga.setCursorShape(vga.CursorShape.BLOCK);
}

test "init all" {
    arch.initTest();
    defer arch.freeTest();

    // Mocking out the arch.outb calls for setting the cursor max scan line and the shape to block:
    // This will also check that the scan line variables were set properly as these are using in
    // the arch.outb call for setting the cursor shape.
    arch.addTestParams("outb",
        vga.PORT_ADDRESS, vga.REG_MAXIMUM_SCAN_LINE,
        vga.PORT_DATA, vga.CURSOR_SCANLINE_END,
        vga.PORT_ADDRESS, vga.REG_CURSOR_START,
        vga.PORT_DATA, vga.CURSOR_SCANLINE_MIDDLE,
        vga.PORT_ADDRESS, vga.REG_CURSOR_END,
        vga.PORT_DATA, vga.CURSOR_SCANLINE_END);

    vga.init();
}
