const build_options = @import("build_options");
const std = @import("std");
const Serial = @import("serial.zig").Serial;
const fmt = std.fmt;

/// The errors that can occur when logging
const LoggingError = error{};

/// The OutStream for the format function
const OutStream = std.io.OutStream(void, LoggingError, logCallback);

pub const Level = enum {
    INFO,
    DEBUG,
    WARNING,
    ERROR,
};

var serial: Serial = undefined;

fn logCallback(context: void, str: []const u8) LoggingError!usize {
    serial.writeBytes(str);
    return str.len;
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
    fmt.format(OutStream{ .context = {} }, "[" ++ @tagName(level) ++ "] " ++ format, args) catch unreachable;
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

///
/// Initialise the logging stream using the given Serial instance.
///
/// Arguments:
///     IN ser: Serial - The serial instance to use when logging
///
pub fn init(ser: Serial) void {
    serial = ser;

    if (build_options.rt_test) runtimeTests();
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
