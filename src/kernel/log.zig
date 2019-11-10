const serial = @import("serial.zig");
const fmt = @import("std").fmt;

pub const Level = enum {
    INFO,
    DEBUG,
    WARNING,
    ERROR,
};

fn logCallback(context: void, str: []const u8) anyerror!void {
    serial.writeBytes(str, serial.Port.COM1);
}

pub fn log(comptime level: Level, comptime format: []const u8, args: ...) void {
    fmt.format({}, anyerror, logCallback, "[" ++ @tagName(level) ++ "] " ++ format, args) catch unreachable;
}

pub fn logInfo(comptime format: []const u8, args: ...) void {
    log(Level.INFO, format, args);
}

pub fn logDebug(comptime format: []const u8, args: ...) void {
    log(Level.DEBUG, format, args);
}

pub fn logWarning(comptime format: []const u8, args: ...) void {
    log(Level.WARNING, format, args);
}

pub fn logError(comptime format: []const u8, args: ...) void {
    log(Level.ERROR, format, args);
}

pub fn runtimeTests() void {
    inline for (@typeInfo(Level).Enum.fields) |field| {
        const level = @field(Level, field.name);
        log(level, "Test " ++ field.name ++ " level\n");
        log(level, "Test " ++ field.name ++ " level with args {}, {}\n", "a", @as(u32, 1));
        const logFn = switch (level) {
            .INFO => logInfo,
            .DEBUG => logDebug,
            .WARNING => logWarning,
            .ERROR => logError,
        };
        logFn("Test " ++ field.name ++ " function\n");
        logFn("Test " ++ field.name ++ " function with args {}, {}\n", "a", @as(u32, 1));
    }
}
