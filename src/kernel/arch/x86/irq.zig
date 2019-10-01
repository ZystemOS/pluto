// Zig version: 0.4.0

const panic = @import("../../panic.zig").panic;
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
var irq_handlers: [NUMBER_OF_ENTRIES]fn (*arch.InterruptContext) void = [_]fn (*arch.InterruptContext) void{unhandled} ** NUMBER_OF_ENTRIES;

///
/// A dummy handler that will make a call to panic as it is a unhandled interrupt.
///
/// Arguments:
///     IN context: *arch.InterruptContext - Pointer to the interrupt context containing the
///                                          contents of the register at the time of the interrupt.
///
fn unhandled(context: *arch.InterruptContext) void {
    const interrupt_num: u8 = @truncate(u8, context.int_num - IRQ_OFFSET);
    panic(null, "Unhandled IRQ number {}", interrupt_num);
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
/// Open an IDT entry with index and handler. This will also handle the errors.
///
/// Arguments:
///     IN index: u8                     - The IDT interrupt number.
///     IN handler: idt.InterruptHandler - The IDT handler.
///
fn openIrq(index: u8, handler: idt.InterruptHandler) void {
    idt.openInterruptGate(index, handler) catch |err| switch (err) {
        error.IdtEntryExists => {
            panic(@errorReturnTrace(), "Error opening IRQ number: {} exists", index);
        },
    };
}

///
/// Register a IRQ by setting its interrupt handler to the given function. This will also clear the
/// mask bit in the PIC so interrupts can happen.
///
/// Arguments:
///     IN irq_num: u8 - The IRQ number to register.
///
pub fn registerIrq(irq_num: u8, handler: fn (*arch.InterruptContext) void) void {
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
    // Open all the IRQ's
    openIrq(32, irq0);
    openIrq(33, irq1);
    openIrq(34, irq2);
    openIrq(35, irq3);
    openIrq(36, irq4);
    openIrq(37, irq5);
    openIrq(38, irq6);
    openIrq(39, irq7);
    openIrq(40, irq8);
    openIrq(41, irq9);
    openIrq(42, irq10);
    openIrq(43, irq11);
    openIrq(44, irq12);
    openIrq(45, irq13);
    openIrq(46, irq14);
    openIrq(47, irq15);
}
