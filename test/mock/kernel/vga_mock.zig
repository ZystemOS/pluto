const std = @import("std");
const expect = std.testing.expect;

const arch = @import("arch_mock.zig");
const mock_framework = @import("mock_framework.zig");

pub const initTest = mock_framework.initTest;
pub const freeTest = mock_framework.freeTest;
pub const addTestParams = mock_framework.addTestParams;
pub const addConsumeFunction = mock_framework.addConsumeFunction;
pub const addRepeatFunction = mock_framework.addRepeatFunction;

pub const WIDTH: u16 = 80;
pub const HEIGHT: u16 = 25;

pub const COLOUR_BLACK: u4 = 0x00;
pub const COLOUR_BLUE: u4 = 0x01;
pub const COLOUR_GREEN: u4 = 0x02;
pub const COLOUR_CYAN: u4 = 0x03;
pub const COLOUR_RED: u4 = 0x04;
pub const COLOUR_MAGENTA: u4 = 0x05;
pub const COLOUR_BROWN: u4 = 0x06;
pub const COLOUR_LIGHT_GREY: u4 = 0x07;
pub const COLOUR_DARK_GREY: u4 = 0x08;
pub const COLOUR_LIGHT_BLUE: u4 = 0x09;
pub const COLOUR_LIGHT_GREEN: u4 = 0x0A;
pub const COLOUR_LIGHT_CYAN: u4 = 0x0B;
pub const COLOUR_LIGHT_RED: u4 = 0x0C;
pub const COLOUR_LIGHT_MAGENTA: u4 = 0x0D;
pub const COLOUR_LIGHT_BROWN: u4 = 0x0E;
pub const COLOUR_WHITE: u4 = 0x0F;

pub const CursorShape = enum {
    UNDERLINE,
    BLOCK,
};

pub fn entryColour(fg: u4, bg: u4) u8 {
    return mock_framework.performAction("entryColour", u8, .{ fg, bg });
}

pub fn entry(uc: u8, colour: u8) u16 {
    return mock_framework.performAction("entry", u16, .{ uc, colour });
}

pub fn updateCursor(x: u16, y: u16) void {
    return mock_framework.performAction("updateCursor", void, .{ x, y });
}

pub fn getCursor() u16 {
    return mock_framework.performAction("getCursor", u16, .{});
}

pub fn enableCursor() void {
    return mock_framework.performAction("enableCursor", void, .{});
}

pub fn disableCursor() void {
    return mock_framework.performAction("disableCursor", void, .{});
}

pub fn setCursorShape(shape: CursorShape) void {
    return mock_framework.performAction("setCursorShape", void, .{shape});
}

pub fn init() void {
    return mock_framework.performAction("init", void, .{});
}

// User defined mocked functions

pub fn orig_entryColour(fg: u4, bg: u4) u8 {
    return fg | @as(u8, bg) << 4;
}

pub fn orig_entry(uc: u8, c: u8) u16 {
    return uc | @as(u16, c) << 8;
}

pub fn mock_updateCursor(x: u16, y: u16) anyerror!void {
    // Here we can do any testing we like with the parameters. e.g. test out of bounds
    try expect(x < WIDTH);
    try expect(y < HEIGHT);
}

pub fn mock_enableCursor() void {}

pub fn mock_disableCursor() void {}
