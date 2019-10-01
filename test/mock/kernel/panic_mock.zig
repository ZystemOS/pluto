const builtin = @import("builtin");
const std = @import("std");

pub fn panic(trace: ?*builtin.StackTrace, comptime format: []const u8, args: ...) noreturn {
    @setCold(true);
    std.debug.panic(format, args);
}
