// Zig version: 0.4.0

const builtin = @import("builtin");
const tty = @import("tty.zig");
const arch = @import("arch.zig").internals;

pub fn panicFmt(trace: ?*builtin.StackTrace, comptime format: []const u8, args: ...) noreturn {
    @setCold(true);
    tty.print("KERNEL PANIC\n");
    tty.print(format, args);
    tty.print("\nHALTING\n");
    arch.haltNoInterrupts();
}
