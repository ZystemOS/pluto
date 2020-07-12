const mock_framework = @import("mock_framework.zig");
pub const initTest = mock_framework.initTest;
pub const freeTest = mock_framework.freeTest;
pub const addTestParams = mock_framework.addTestParams;
pub const addConsumeFunction = mock_framework.addConsumeFunction;
pub const addRepeatFunction = mock_framework.addRepeatFunction;

pub const Level = enum {
    INFO,
    DEBUG,
    WARNING,
    ERROR,
};

pub fn log(comptime level: Level, comptime format: []const u8, args: anytype) void {
    //return mock_framework.performAction("log", void, level, format, args);
}

pub fn logInfo(comptime format: []const u8, args: anytype) void {
    //return mock_framework.performAction("logInfo", void, format, args);
}

pub fn logDebug(comptime format: []const u8, args: anytype) void {
    //return mock_framework.performAction("logDebug", void, format, args);
}

pub fn logWarning(comptime format: []const u8, args: anytype) void {
    //return mock_framework.performAction("logWarning", void, format, args);
}

pub fn logError(comptime format: []const u8, args: anytype) void {
    //return mock_framework.performAction("logError", void, format, args);
}
