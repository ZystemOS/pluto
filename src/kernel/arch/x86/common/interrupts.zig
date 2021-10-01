const arch = @import("arch.zig");
const idt = @import("idt.zig");
const isr = @import("isr.zig");
const irq = @import("irq.zig");
const syscalls = @import("syscalls.zig");
const panic = @import("../../../panic.zig").panic;

/// The type of a interrupt handler. A function that takes a interrupt context and returns the new tasks stack pointer.
pub const InterruptHandler = fn (*arch.CpuState) usize;

///
/// The main handler for all exceptions and interrupts. This will then go and call the correct
/// handler for an ISR or IRQ.
///
/// Arguments:
///     IN ctx: *arch.CpuState - Pointer to the exception context containing the contents
///                              of the registers at the time of a exception.
///
export fn handler(ctx: *arch.CpuState) usize {
    if (ctx.int_num < irq.IRQ_OFFSET or ctx.int_num == syscalls.INTERRUPT) {
        return isr.isrHandler(ctx);
    } else {
        return irq.irqHandler(ctx);
    }
}

///
/// Generate the function that is the entry point for each exception/interrupt. This will then be
/// used as the handler for the corresponding IDT entry.
///
/// Arguments:
///     IN interrupt_num: usize - The interrupt number to generate the function for.
///
/// Return: idt.InterruptHandler
///     The stub function that is called for each interrupt/exception.
///
pub fn getInterruptStub(comptime interrupt_num: usize) idt.InterruptHandler {
    return struct {
        fn func() callconv(.Naked) void {
            asm volatile (
                \\ cli
            );

            // These interrupts don't push an error code onto the stack, so will push a zero.
            if (interrupt_num != 8 and !(interrupt_num >= 10 and interrupt_num <= 14) and interrupt_num != 17) {
                asm volatile (
                    \\ push $0
                );
            }

            asm volatile (
                \\ push %[nr]
                \\ jmp commonStub
                :
                : [nr] "n" (interrupt_num)
            );
        }
    }.func;
}
