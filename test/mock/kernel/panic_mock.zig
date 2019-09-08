const builtin = @import("builtin");
const panic = @import("std").debug.panic;

pub fn panicFmt(trace: ?*builtin.StackTrace, comptime format: []const u8, args: ...) noreturn {
    @setCold(true);
    panic(format, args);
}
