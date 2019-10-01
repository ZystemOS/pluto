const builtin = @import("builtin");
const tty = @import("tty.zig");
const arch = @import("arch.zig").internals;
const log = @import("log.zig");

pub fn panic(trace: ?*builtin.StackTrace, comptime format: []const u8, args: ...) noreturn {
    @setCold(true);
    log.logInfo("KERNEL PANIC\n");
    log.logInfo(format, args);
    log.logInfo("HALTING\n");
    arch.haltNoInterrupts();
}
