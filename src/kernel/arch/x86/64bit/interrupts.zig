const arch = @import("arch.zig");
const idt = @import("idt.zig");
const log = @import("std").log.scoped(.asas);
const panic = @import("../../../panic.zig").panic;

usingnamespace @import("../common/interrupts.zig");

///
/// The main handler for all exceptions and interrupts. This will then go and call the correct
/// handler for an ISR or IRQ.
///
/// Arguments:
///     IN ctx: *arch.CpuState - Pointer to the exception context containing the contents
///                              of the registers at the time of a exception.
///
export fn handler(ctx: *arch.CpuState) usize {
    log.info("??\n", .{});
    panic(@errorReturnTrace(), "TODO: Implement handlers\n", .{});
}

///
/// The common assembly that all exceptions and interrupts will call.
///
export fn commonStub() callconv(.Naked) void {
    asm volatile (
        \\push  %%rdx
        \\push  %%rcx
        \\push  %%rbx
        \\push  %%rax
        \\push  %%rsp
        \\push  %%rbp
        \\push  %%rsi
        \\push  %%rdi
        \\push  %%r15
        \\push  %%r14
        \\push  %%r13
        \\push  %%r12
        \\push  %%r11
        \\push  %%r10
        \\push  %%r9
        \\push  %%r8
        \\mov  %%ds, %%rax
        \\push %%rax
        \\mov  %%es, %%rax
        \\push %%rax
        \\mov  0x10, %%ax
        \\mov  %%ax, %%ds
        \\mov  %%ax, %%es
        \\call handler
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
        \\sub   $0x16, %%esp
        \\iretq
    );
}
