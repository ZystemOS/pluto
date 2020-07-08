const arch = @import("arch.zig");
const log = @import("../../log.zig");

pub extern var exception_table: *usize;

comptime {
    asm (
        \\.globl exception_table
        \\.balign 0x800
        \\exception_table:
        \\.balign 0x80
        \\ bl exceptionHandler
        \\.balign 0x80
        \\ bl exceptionHandler
        \\.balign 0x80
        \\ bl exceptionHandler
        \\.balign 0x80
        \\ bl exceptionHandler
        \\.balign 0x80
        \\ bl exceptionHandler
        \\.balign 0x80
        \\ bl exceptionHandler
        \\.balign 0x80
        \\ bl exceptionHandler
        \\.balign 0x80
        \\ bl exceptionHandler
        \\.balign 0x80
        \\ bl exceptionHandler
        \\.balign 0x80
        \\ bl exceptionHandler
        \\.balign 0x80
        \\ bl exceptionHandler
        \\.balign 0x80
        \\ bl exceptionHandler
        \\.balign 0x80
        \\ bl exceptionHandler
        \\.balign 0x80
        \\ bl exceptionHandler
        \\.balign 0x80
        \\ bl exceptionHandler
        \\.balign 0x80
        \\ bl exceptionHandler
    );
}

const ExceptionTakenFrom = enum(u2) {
    same_level_while_using_sp_el0,
    same_level_while_using_sp_elx,
    lower_level_aarch64,
    lower_level_aarch32,
};

const ExceptionCategory = enum(u2) {
    synchronous,
    irq_or_virq,
    fiq_or_vfiq,
    serror_or_vserror,
};

const ExceptionClass = enum(u6) {
    instruction_abort = 0x21,
    data_abort = 0x25,
    sp_alignment = 0x26,
    _,
};

export fn exceptionHandler() noreturn {
    const exception_entry_offset = @truncate(u32, lr() & 0x780);
    var elr_elx: usize = undefined;
    var esr_elx: usize = undefined;
    var far_elx: usize = undefined;
    var sctlr_elx: usize = undefined;
    var spsr_elx: usize = undefined;
    var vbar_elx: usize = undefined;
    inline for ([_]u32{ 1, 2, 3 }) |exception_level| {
        if (exception_level == currentExceptionLevel()) {
            elr_elx = mrsEl("elr_el", exception_level);
            esr_elx = mrsEl("esr_el", exception_level);
            far_elx = mrsEl("far_el", exception_level);
            sctlr_elx = mrsEl("sctlr_el", exception_level);
            spsr_elx = mrsEl("spsr_el", exception_level);
            vbar_elx = mrsEl("vbar_el", exception_level);
        }
    }
    const esr_elx_class = @intToEnum(ExceptionClass, @truncate(u6, esr_elx >> 26));
    const esr_elx_instruction_is_32_bits = esr_elx & 0x2000000 != 0;
    const esr_elx_iss = esr_elx & 0x1ffffff;
    log.logError("\n", .{});
    log.logError("arm exception taken to level {}\n", .{currentExceptionLevel()});
    var seen_previously = false;
    if (currentExceptionLevel() == 3 and exception_entry_offset == 0x200 and esr_elx_instruction_is_32_bits) {
        switch (esr_elx_class) {
            .data_abort => {
                switch (esr_elx_iss) {
                    0x0 => {
                        seen_previously = true;
                        log.logError("this exception has been seen previously in development\n", .{});
                        log.logError("    data abort in level {} (while using sp_el{} and not sp_el0)\n", .{ currentExceptionLevel(), currentExceptionLevel() });
                        log.logError("    32 bit instruction at 0x{x} accessing 0x{x}\n", .{ elr_elx, far_elx });
                    },
                    else => {},
                }
            },
            .instruction_abort => {
                switch (esr_elx_iss) {
                    0x0, 0x10 => {
                        seen_previously = true;
                        log.logError("this exception has been seen previously in development\n", .{});
                        log.logError("    instruction abort (variant: esr_el{}.iss = 0x{x}) in level {} (while using sp_el{} and not sp_el0)\n", .{ currentExceptionLevel(), esr_elx_iss, currentExceptionLevel(), currentExceptionLevel() });
                        log.logError("    32 bit instruction at 0x{x} accessing 0x{x}\n", .{ elr_elx, far_elx });
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
    if (!seen_previously) {
        log.logError("this exception has not been seen previously in development - please update aarch64/interrupts.zig\n", .{});
    }
    log.logError("details\n", .{});
    log.logError("    elr_el{} 0x{x}\n", .{ currentExceptionLevel(), elr_elx });
    log.logError("    esr_el{} 0x{x}: {}, 32 bit instruction {}, iss 0x{x}\n", .{ currentExceptionLevel(), esr_elx, esr_elx_class, esr_elx_instruction_is_32_bits, esr_elx_iss });
    log.logError("    exception entry offset 0x{x} {} {}\n", .{ exception_entry_offset, @intToEnum(ExceptionTakenFrom, @truncate(u2, exception_entry_offset >> 9)), @intToEnum(ExceptionCategory, @truncate(u2, exception_entry_offset >> 7)) });
    log.logError("    far_el{} 0x{x}\n", .{ currentExceptionLevel(), far_elx });
    log.logError("    sctlr_el{} 0x{x}\n", .{ currentExceptionLevel(), sctlr_elx });
    log.logError("    spsr_el{} 0x{x}\n", .{ currentExceptionLevel(), spsr_elx });
    log.logError("    vbar_el{} 0x{x}\n", .{ currentExceptionLevel(), vbar_elx });
    while (true) {}
}

inline fn lr() usize {
    return register("lr");
}

inline fn sp() usize {
    return register("sp");
}

fn cpsr() usize {
    return mrs("cpsr");
}

fn spsr() usize {
    return mrs("spsr");
}

fn sctlr() usize {
    var word = asm ("mrc p15, 0, %[word], c1, c0, 0"
        : [word] "=r" (-> usize)
    );
    return word;
}

inline fn mrs(comptime register_name: []const u8) usize {
    const word = asm ("mrs %[word], " ++ register_name
        : [word] "=r" (-> usize)
    );
    return word;
}

inline fn register(comptime register_name: []const u8) usize {
    const word = asm ("mov %[word], " ++ register_name
        : [word] "=r" (-> usize)
    );
    return word;
}

inline fn mrsEl(comptime register_name: []const u8, comptime exception_level: u32) usize {
    const exception_level_string = switch (exception_level) {
        1 => "1",
        2 => "2",
        3 => "3",
        else => unreachable,
    };
    return mrs(register_name ++ exception_level_string);
}

pub inline fn currentExceptionLevel() u2 {
    return @truncate(u2, mrs("CurrentEL") >> 2);
}
