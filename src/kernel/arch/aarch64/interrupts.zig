const arch = @import("arch.zig");
const Cpu = arch.Cpu;
const log = @import("../../log.zig");
const rpi = @import("rpi.zig");

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
    pc_alignment = 0x22,
    data_abort = 0x25,
    sp_alignment = 0x26,
    _,
};

pub var exception_handler_depth: u32 = undefined;

export fn exceptionHandler() noreturn {
    exception_handler_depth += 1;
    if (exception_handler_depth > 1) {
        if (exception_handler_depth == 2) {
            log.logError("\n", .{});
            log.logError("arm exception taken when already active!\n", .{});
        }
        rpi.spinLed(50);
    }
    const exception_entry_offset = @truncate(u32, Cpu.lr.read() & 0x780);
    var elr_elx: usize = undefined;
    var esr_elx: usize = undefined;
    var far_elx: usize = undefined;
    var mair_elx: usize = undefined;
    var sctlr_elx: usize = undefined;
    var spsr_elx: usize = undefined;
    var tcr_elx: usize = undefined;
    var ttbr0_elx: usize = undefined;
    var vbar_elx: usize = undefined;
    inline for ([_]u32{ 1, 2, 3 }) |exception_level| {
        if (exception_level == currentExceptionLevel()) {
            elr_elx = Cpu.elr.el(exception_level).read();
            esr_elx = Cpu.esr.el(exception_level).read();
            far_elx = Cpu.far.el(exception_level).read();
            mair_elx = Cpu.mair.el(exception_level).read();
            sctlr_elx = Cpu.sctlr.el(exception_level).read();
            spsr_elx = Cpu.spsr.el(exception_level).read();
            tcr_elx = Cpu.tcr.el(exception_level).read();
            ttbr0_elx = Cpu.ttbr0.el(exception_level).read();
            vbar_elx = Cpu.vbar.el(exception_level).read();
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
                    0x21 => {
                        if (far_elx == 0x1) {
                            seen_previously = true;
                            log.logError("this exception has been seen previously in development\n", .{});
                            log.logError("    data abort in level {} (while using sp_el{} and not sp_el0)\n", .{ currentExceptionLevel(), currentExceptionLevel() });
                            log.logError("    32 bit instruction at 0x{x} accessing 0x{x}\n", .{ elr_elx, far_elx });
                            log.logError("    test 32 bit read of address 0x1\n", .{});
                        } else {
                            seen_previously = true;
                            log.logError("this exception has been seen previously in development\n", .{});
                            log.logError("    data abort, read, alignment fault ...\n", .{});
                        }
                    },
                    0x61 => {
                        seen_previously = true;
                        log.logError("this exception has been seen previously in development\n", .{});
                        log.logError("    data abort, write, alignment\n", .{});
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
    log.logError("    mair_el{} 0x{x}\n", .{ currentExceptionLevel(), mair_elx });
    log.logError("    sctlr_el{} 0x{x}\n", .{ currentExceptionLevel(), sctlr_elx });
    log.logError("    spsr_el{} 0x{x}\n", .{ currentExceptionLevel(), spsr_elx });
    log.logError("    tcr_el{} 0x{x}\n", .{ currentExceptionLevel(), tcr_elx });
    log.logError("    ttbr0_el{} 0x{x}\n", .{ currentExceptionLevel(), ttbr0_elx });
    log.logError("    vbar_el{} 0x{x}\n", .{ currentExceptionLevel(), vbar_elx });
    log.logError("exception done\n", .{});
    rpi.spinLed(100);
}

pub inline fn currentExceptionLevel() u2 {
    return @truncate(u2, Cpu.CurrentEL.read() >> 2);
}
