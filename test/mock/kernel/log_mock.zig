const std = @import("std");
const mock_framework = @import("mock_framework.zig");
pub const initTest = mock_framework.initTest;
pub const freeTest = mock_framework.freeTest;
pub const addTestParams = mock_framework.addTestParams;
pub const addConsumeFunction = mock_framework.addConsumeFunction;
pub const addRepeatFunction = mock_framework.addRepeatFunction;

pub fn log(comptime level: std.log.Level, comptime format: []const u8, args: anytype) void {
    // Just print to std print
    std.debug.print(format, args);
}
