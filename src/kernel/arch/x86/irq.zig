// Zig version: 0.4.0

const panic = @import("../../panic.zig");
const idt = @import("idt.zig");
const arch = @import("arch.zig");
const pic = @import("pic.zig");

const NUMBER_OF_ENTRIES: u16 = 16;

const IRQ_OFFSET: u16 = 32;

// The external assembly that is fist called to set up the interrupt handler.
extern fn irq0() void;
extern fn irq1() void;
extern fn irq2() void;
extern fn irq3() void;
extern fn irq4() void;
extern fn irq5() void;
extern fn irq6() void;
extern fn irq7() void;
extern fn irq8() void;
extern fn irq9() void;
extern fn irq10() void;
extern fn irq11() void;
extern fn irq12() void;
extern fn irq13() void;
extern fn irq14() void;
extern fn irq15() void;

/// The list of IRQ handlers initialised to unhandled.
var irq_handlers: [NUMBER_OF_ENTRIES]fn(*arch.InterruptContext)void = []fn(*arch.InterruptContext)void {unhandled} ** NUMBER_OF_ENTRIES;

///
/// A dummy handler that will make a call to panic as it is a unhandled interrupt.
///
/// Arguments:
///     IN context: *arch.InterruptContext - Pointer to the interrupt context containing the
///                                          contents of the register at the time of the interrupt.
///
fn unhandled(context: *arch.InterruptContext) void {
    const interrupt_num: u8 = @truncate(u8, context.int_num - IRQ_OFFSET);
    panic.panicFmt(null, "Unhandled IRQ number {}", interrupt_num);
}

///
/// The IRQ handler that each of the IRQ's will call when a interrupt happens.
///
/// Arguments:
///     IN context: *arch.InterruptContext - Pointer to the interrupt context containing the
///                                          contents of the register at the time of the interrupt.
///
export fn irqHandler(context: *arch.InterruptContext) void {
    const irq_num: u8 = @truncate(u8, context.int_num - IRQ_OFFSET);
    // Make sure it isn't a spurious irq
    if (!pic.spuriousIrq(irq_num)) {
        irq_handlers[irq_num](context);
        // Send the end of interrupt command
        pic.sendEndOfInterrupt(irq_num);
    }
}

///
/// Register a IRQ by setting its interrupt handler to the given function. This will also clear the
/// mask bit in the PIC so interrupts can happen.
///
/// Arguments:
///     IN irq_num: u16 - The IRQ number to register.
///
pub fn registerIrq(irq_num: u16, handler: fn(*arch.InterruptContext)void) void {
    irq_handlers[irq_num] = handler;
    pic.clearMask(irq_num);
}

///
/// Unregister a IRQ by setting its interrupt handler to the unhandled function call to panic. This
/// will also set the mask bit in the PIC so no interrupts can happen anyway.
///
/// Arguments:
///     IN irq_num: u16 - The IRQ number to unregister.
///
pub fn unregisterIrq(irq_num: u16) void {
    irq_handlers[irq_num] = unhandled;
    pic.setMask(irq_num);
}

///
/// Initialise the IRQ interrupts by first remapping the port addresses and then opening up all
/// the IDT interrupt gates for each IRQ.
///
pub fn init() void {
    // Remap the PIC IRQ so not to overlap with other exceptions
    pic.remapIrq();

    // Open all the IRQ's
    idt.openInterruptGate(32, irq0);
    idt.openInterruptGate(33, irq1);
    idt.openInterruptGate(34, irq2);
    idt.openInterruptGate(35, irq3);
    idt.openInterruptGate(36, irq4);
    idt.openInterruptGate(37, irq5);
    idt.openInterruptGate(38, irq6);
    idt.openInterruptGate(39, irq7);
    idt.openInterruptGate(40, irq8);
    idt.openInterruptGate(41, irq9);
    idt.openInterruptGate(42, irq10);
    idt.openInterruptGate(43, irq11);
    idt.openInterruptGate(44, irq12);
    idt.openInterruptGate(45, irq13);
    idt.openInterruptGate(46, irq14);
    idt.openInterruptGate(47, irq15);
}