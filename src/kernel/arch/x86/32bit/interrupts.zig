const gdt_common = @import("../common/gdt.zig");

///
/// The common assembly that all exceptions and interrupts will call.
///
export fn commonStub() callconv(.Naked) void {
    // Calling convention for x86 is for first parameter is on the stack
    asm volatile (
        \\pusha
        \\push  %%ds
        \\push  %%es
        \\push  %%fs
        \\push  %%gs
        \\mov   %%cr3, %%eax
        \\push  %%eax
        \\mov   %[offset], %%ds
        \\mov   %[offset], %%es
        \\mov   %[offset], %%fs
        \\mov   %[offset], %%gs
        \\mov   %%esp, %%eax
        \\push  %%eax
        \\call  handler
        \\mov   %%eax, %%esp
        :
        : [offset] "rm" (gdt_common.KERNEL_DATA_OFFSET)
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
        \\.extern tss_entry
        \\mov   %%esp, (tss_entry + 4)
        \\sub   $0x14, %%esp
        \\iret
    );
}
