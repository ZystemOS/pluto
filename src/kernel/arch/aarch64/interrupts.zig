const arch = @import("arch.zig");
const log = @import("../../log.zig");

pub extern var exception_table: *usize;

comptime {
    asm (
        \\.globl exception_table
        \\exception_table:
        \\.balign 0x800
        \\.balign 0x80
        \\ b resetHandler
        \\.balign 0x80
        \\ b undefinedInstructionHandler
        \\.balign 0x80
        \\ b softwareInterruptHandler
        \\.balign 0x80
        \\ b prefetchAbortHandler
        \\.balign 0x80
        \\ b dataAbortHandler
        \\.balign 0x80
        \\ // Reserved
        \\ b reservedHandler
        \\.balign 0x80
        \\ b irqHandler
        \\.balign 0x80
        \\ b fastIrqHandler
    );
}

inline fn interruptedInstruction() usize {
    return asm ("mrs %[res], ELR_EL3"
        : [res] "=r" (-> usize)
    );
}

export fn resetHandler() callconv(.Naked) noreturn {
    log.logError("rest at instruction 0x{X}\n", .{interruptedInstruction()});
    while (true) {}
}

export fn undefinedInstructionHandler() callconv(.Naked) noreturn {
    log.logError("undefined instruction at instruction 0x{X}\n", .{interruptedInstruction()});
    while (true) {}
}

export fn softwareInterruptHandler() callconv(.Naked) noreturn {
    log.logError("software interrupt at instruction 0x{X}\n", .{interruptedInstruction()});
    while (true) {}
}

export fn prefetchAbortHandler() callconv(.Naked) noreturn {
    log.logError("prefetch abort at instruction 0x{X}\n", .{interruptedInstruction()});
    while (true) {}
}

export fn dataAbortHandler() callconv(.Naked) noreturn {
    log.logError("data abort at instruction 0x{X}\n", .{interruptedInstruction()});
    while (true) {}
}

export fn reservedHandler() callconv(.Naked) noreturn {
    log.logError("reserved exception at instruction 0x{X}\n", .{interruptedInstruction()});
    while (true) {}
}

export fn irqHandler() callconv(.Naked) noreturn {
    log.logError("irq at instruction 0x{X}\n", .{interruptedInstruction()});
    while (true) {}
}

export fn fastIrqHandler() callconv(.Naked) noreturn {
    log.logError("fast irq at instruction 0x{X}\n", .{interruptedInstruction()});
    while (true) {}
}
