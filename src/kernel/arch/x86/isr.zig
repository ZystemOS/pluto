// Zig version: 0.4.0

const panic = @import("../../panic.zig");
const tty = @import("../../tty.zig");
const idt = @import("idt.zig");
const arch = @import("arch.zig");

const NUMBER_OF_ENTRIES: u16 = 32;

extern fn isr0() void;
extern fn isr1() void;
extern fn isr2() void;
extern fn isr3() void;
extern fn isr4() void;
extern fn isr5() void;
extern fn isr6() void;
extern fn isr7() void;
extern fn isr8() void;
extern fn isr9() void;
extern fn isr10() void;
extern fn isr11() void;
extern fn isr12() void;
extern fn isr13() void;
extern fn isr14() void;
extern fn isr15() void;
extern fn isr16() void;
extern fn isr17() void;
extern fn isr18() void;
extern fn isr19() void;
extern fn isr20() void;
extern fn isr21() void;
extern fn isr22() void;
extern fn isr23() void;
extern fn isr24() void;
extern fn isr25() void;
extern fn isr26() void;
extern fn isr27() void;
extern fn isr28() void;
extern fn isr29() void;
extern fn isr30() void;
extern fn isr31() void;

const exception_msg: [NUMBER_OF_ENTRIES][]const u8 = [NUMBER_OF_ENTRIES][]const u8 {
    "Divide By Zero",
    "Single Step (Debugger)",
    "Non Maskable Interrupt",
    "Breakpoint (Debugger)",
    "Overflow",
    "Bound Range Exceeded",
    "Invalid Opcode",
    "No Coprocessor, Device Not Available",
    "Double Fault",
    "Coprocessor Segment Overrun",
    "Invalid Task State Segment (TSS)",
    "Segment Not Present",
    "Stack Segment Overrun",
    "General Protection Fault",
    "Page Fault",
    "Unknown Interrupt",
    "x87 FPU Floating Point Error",
    "Alignment Check",
    "Machine Check",
    "SIMD Floating Point",
    "Virtualization",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Security",
    "Reserved"
};

var isr_handlers: [NUMBER_OF_ENTRIES]fn(*arch.InterruptContext)void = []fn(*arch.InterruptContext)void{unhandled} ** NUMBER_OF_ENTRIES;

fn unhandled(context: *arch.InterruptContext) void {
    const interrupt_num = context.int_num;
    panic.panicFmt(null, "Unhandled exception: {}, number {}", exception_msg[interrupt_num], interrupt_num);
}

export fn isrHandler(context: *arch.InterruptContext) void {
    const isr_num = context.int_num;
    isr_handlers[isr_num](context);
}

pub fn registerIsr(isr_num: u16, handler: fn(*arch.InterruptContext)void) void {
    isr_handlers[isr_num] = handler;
}

pub fn unregisterIsr(isr_num: u16) void {
    isr_handlers[isr_num] = unhandled;
}

pub fn init() void {
    idt.openInterruptGate(0, isr0);
    idt.openInterruptGate(1, isr1);
    idt.openInterruptGate(2, isr2);
    idt.openInterruptGate(3, isr3);
    idt.openInterruptGate(4, isr4);
    idt.openInterruptGate(5, isr5);
    idt.openInterruptGate(6, isr6);
    idt.openInterruptGate(7, isr7);
    idt.openInterruptGate(8, isr8);
    idt.openInterruptGate(9, isr9);
    idt.openInterruptGate(10, isr10);
    idt.openInterruptGate(11, isr11);
    idt.openInterruptGate(12, isr12);
    idt.openInterruptGate(13, isr13);
    idt.openInterruptGate(14, isr14);
    idt.openInterruptGate(15, isr15);
    idt.openInterruptGate(16, isr16);
    idt.openInterruptGate(17, isr17);
    idt.openInterruptGate(18, isr18);
    idt.openInterruptGate(19, isr19);
    idt.openInterruptGate(20, isr20);
    idt.openInterruptGate(21, isr21);
    idt.openInterruptGate(22, isr22);
    idt.openInterruptGate(23, isr23);
    idt.openInterruptGate(24, isr24);
    idt.openInterruptGate(25, isr25);
    idt.openInterruptGate(26, isr26);
    idt.openInterruptGate(27, isr27);
    idt.openInterruptGate(28, isr28);
    idt.openInterruptGate(29, isr29);
    idt.openInterruptGate(30, isr30);
    idt.openInterruptGate(31, isr31);
}