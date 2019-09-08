const mock_framework = @import("mock_framework.zig");

pub const Level = enum {
    INFO,
    DEBUG,
    WARNING,
    ERROR
};

fn logCallback(context: void, str: []const u8) anyerror!void {}

pub fn log(comptime level: Level, comptime format: []const u8, args: ...) void {
    //return mock_framework.performAction("log", void, level, format, args);
}

pub fn logInfo(comptime format: []const u8, args: ...) void {
    //return mock_framework.performAction("logInfo", void, format, args);
}

pub fn logDebug(comptime format: []const u8, args: ...) void {
    //return mock_framework.performAction("logDebug", void, format, args);
}

pub fn logWarning(comptime format: []const u8, args: ...) void {
    //return mock_framework.performAction("logWarning", void, format, args);
}

pub fn logError(comptime format: []const u8, args: ...) void {
    //return mock_framework.performAction("logError", void, format, args);
}

pub fn addRepeatFunction(comptime fun_name: []const u8, function: var) void {
    mock_framework.addRepeatFunction(fun_name, function);
}

pub fn addTestFunction(comptime fun_name: []const u8, function: var) void {
    mock_framework.addRepeatFunction(fun_name, function);
}

pub fn addTestParams(comptime fun_name: []const u8, params: ...) void {
    mock_framework.addTestParams(fun_name, params);
}

pub fn initTest() void {
    mock_framework.initTest();
}

pub fn freeTest() void {
    mock_framework.freeTest();
}