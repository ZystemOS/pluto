const gdt_common = @import("../common/gdt.zig");

///
/// The common assembly that all exceptions and interrupts will call.
///
export fn commonStub() callconv(.Naked) void {
    // Calling convention for x86_64 is for first parameter is in RDI (not the stack as for x86 (32 bit))
    asm volatile (
        \\push %%rdx
        \\push %%rcx
        \\push %%rbx
        \\push %%rax
        \\push %%rsp
        \\push %%rbp
        \\push %%rsi
        \\push %%rdi
        \\push %%r15
        \\push %%r14
        \\push %%r13
        \\push %%r12
        \\push %%r11
        \\push %%r10
        \\push %%r9
        \\push %%r8
        \\mov  %%ds, %%rax
        \\push %%rax
        \\mov  %%es, %%rax
        \\push %%rax
        \\mov  %[offset], %%ds
        \\mov  %[offset], %%es
        \\mov  %%rsp, %%rdi
        \\call handler
        \\mov  %%rax, %%rsp
        \\pop  %%rax
        \\mov  %%ax, %%es
        \\pop  %%rax
        \\mov  %%ax, %%ds
        \\pop  %%rdx
        \\pop  %%rcx
        \\pop  %%rbx
        \\pop  %%rax
        \\pop  %%rsp
        \\pop  %%rbp
        \\pop  %%rsi
        \\pop  %%rdi
        \\pop  %%r15
        \\pop  %%r14
        \\pop  %%r13
        \\pop  %%r12
        \\pop  %%r11
        \\pop  %%r10
        \\pop  %%r9
        \\pop  %%r8
        \\sub  $0x16, %%esp
        \\iretq
        :
        : [offset] "rm" (gdt_common.KERNEL_DATA_OFFSET)
    );
}
