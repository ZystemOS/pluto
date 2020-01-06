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

///
/// Write a message to the log output stream with a certain logging level.
///
/// Arguments:
///     IN comptime level: Level - The logging level to use. Determines the message prefix and whether it is filtered.
///     IN comptime format: []const u8 - The message format. Uses the standard format specification options.
///     IN args: var - A struct of the parameters for the format string.
///
pub fn log(comptime level: Level, comptime format: []const u8, args: var) void {
    fmt.format({}, anyerror, logCallback, "[" ++ @tagName(level) ++ "] " ++ format, args) catch unreachable;
}

///
/// Write a message to the log output stream with the INFO level.
///
/// Arguments:
///     IN comptime format: []const u8 - The message format. Uses the standard format specification options.
///     IN args: var - A struct of the parameters for the format string.
///
pub fn logInfo(comptime format: []const u8, args: var) void {
    log(Level.INFO, format, args);
}

///
/// Write a message to the log output stream with the DEBUG level.
///
/// Arguments:
///     IN comptime format: []const u8 - The message format. Uses the standard format specification options.
///     IN args: var - A struct of the parameters for the format string.
///
pub fn logDebug(comptime format: []const u8, args: var) void {
    log(Level.DEBUG, format, args);
}

///
/// Write a message to the log output stream with the WARNING level.
///
/// Arguments:
///     IN comptime format: []const u8 - The message format. Uses the standard format specification options.
///     IN args: var - A struct of the parameters for the format string.
///
pub fn logWarning(comptime format: []const u8, args: var) void {
    log(Level.WARNING, format, args);
}

///
/// Write a message to the log output stream with the ERROR level.
///
/// Arguments:
///     IN comptime format: []const u8 - The message format. Uses the standard format specification options.
///     IN args: var - A struct of the parameters for the format string.
///
pub fn logError(comptime format: []const u8, args: var) void {
    log(Level.ERROR, format, args);
}

pub fn runtimeTests() void {
    inline for (@typeInfo(Level).Enum.fields) |field| {
        const level = @field(Level, field.name);
        log(level, "Test " ++ field.name ++ " level\n", .{});
        log(level, "Test " ++ field.name ++ " level with args {}, {}\n", .{ "a", @as(u32, 1) });
        const logFn = switch (level) {
            .INFO => logInfo,
            .DEBUG => logDebug,
            .WARNING => logWarning,
            .ERROR => logError,
        };
        logFn("Test " ++ field.name ++ " function\n", .{});
        logFn("Test " ++ field.name ++ " function with args {}, {}\n", .{ "a", @as(u32, 1) });
    }
}
