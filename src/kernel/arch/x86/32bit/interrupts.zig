const arch = @import("arch.zig");
const syscalls = @import("syscalls.zig");
const irq = @import("irq.zig");
const idt = @import("idt.zig");

usingnamespace @import("../common/interrupts.zig");

extern fn irqHandler(ctx: *arch.CpuState) usize;
extern fn isrHandler(ctx: *arch.CpuState) usize;

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
        return isrHandler(ctx);
    } else {
        return irqHandler(ctx);
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
        \\mov %%cr3, %%eax
        \\push %%eax
        \\mov   $0x10, %%ax
        \\mov   %%ax, %%ds
        \\mov   %%ax, %%es
        \\mov   %%ax, %%fs
        \\mov   %%ax, %%gs
        \\mov   %%esp, %%eax
        \\push  %%eax
        \\call  handler
        \\mov   %%eax, %%esp
    );

    // Pop off the new cr3 then check if it's the same as the previous cr3
    // If so don't change cr3 to avoid a TLB flush
    asm volatile (
        \\pop   %%eax
        \\mov   %%cr3, %%ebx
        \\cmp   %%eax, %%ebx
        \\je    same_cr3
        \\mov   %%eax, %%cr3
        \\same_cr3:
        \\pop   %%gs
        \\pop   %%fs
        \\pop   %%es
        \\pop   %%ds
        \\popa
    );
    // The Tss.esp0 value is the stack pointer used when an interrupt occurs. This should be the current process' stack pointer
    // So skip the rest of the CpuState, set Tss.esp0 then un-skip the last few fields of the CpuState
    asm volatile (
        \\add   $0x1C, %%esp
        \\.extern main_tss_entry
        \\mov   %%esp, (main_tss_entry + 4)
        \\sub   $0x14, %%esp
        \\iret
    );
}
