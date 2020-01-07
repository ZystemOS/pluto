const arch = @import("arch.zig");
const syscalls = @import("syscalls.zig");
const irq = @import("irq.zig");
const idt = @import("idt.zig");

extern fn irqHandler(ctx: *arch.InterruptContext) void;
extern fn isrHandler(ctx: *arch.InterruptContext) void;

///
/// The main handler for all exceptions and interrupts. This will then go and call the correct
/// handler for an ISR or IRQ.
///
/// Arguments:
///     IN ctx: *arch.InterruptContext - Pointer to the exception context containing the contents
///                                      of the registers at the time of a exception.
///
export fn handler(ctx: *arch.InterruptContext) void {
    if (ctx.int_num < irq.IRQ_OFFSET or ctx.int_num == syscalls.INTERRUPT) {
        isrHandler(ctx);
    } else {
        irqHandler(ctx);
    }
}

///
/// The common assembly that all exceptions and interrupts will call.
///
export fn commonStub() callconv(.Naked) void {
    asm volatile (
        \\pusha
        \\push  %%ds
        \\push  %%es
        \\push  %%fs
        \\push  %%gs
        \\mov   $0x10, %%ax
        \\mov   %%ax, %%ds
        \\mov   %%ax, %%es
        \\mov   %%ax, %%fs
        \\mov   %%ax, %%gs
        \\mov   %%esp, %%eax
        \\push  %%eax
        \\call  handler
        \\pop   %%eax
        \\pop   %%gs
        \\pop   %%fs
        \\pop   %%es
        \\pop   %%ds
        \\popa
        \\add   $0x8, %%esp
        \\iret
    );
}

///
/// Generate the function that is the entry point for each exception/interrupt. This will then be
/// used as the handler for the corresponding IDT entry.
///
/// Arguments:
///     IN interrupt_num: u32 - The interrupt number to generate the function for.
///
/// Return: idt.InterruptHandler
///     The stub function that is called for each interrupt/exception.
///
pub fn getInterruptStub(comptime interrupt_num: u32) idt.InterruptHandler {
    return struct {
        fn func() callconv(.Naked) void {
            asm volatile (
                \\ cli
            );

            // These interrupts don't push an error code onto the stack, so will push a zero.
            if (interrupt_num != 8 and !(interrupt_num >= 10 and interrupt_num <= 14) and interrupt_num != 17) {
                asm volatile (
                    \\ pushl $0
                );
            }

            asm volatile (
                \\ pushl %[nr]
                \\ jmp commonStub
                :
                : [nr] "n" (interrupt_num)
            );
        }
    }.func;
}
