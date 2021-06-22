const idt = @import("idt.zig");

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
