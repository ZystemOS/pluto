// Zig version: 0.4.0

const panic = @import("../../panic.zig");
const tty = @import("../../tty.zig");
const idt = @import("idt.zig");
const arch = @import("arch.zig");

const NUMBER_OF_ENTRIES: u16 = 16;

const IRQ_OFFSET: u16 = 32;

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

// Keep track of the number of spurious irq's
var spurious_irq_counter: u32 = 0;

var irq_handlers: [NUMBER_OF_ENTRIES]fn(*arch.InterruptContext)void = []fn(*arch.InterruptContext)void {unhandled} ** NUMBER_OF_ENTRIES;

fn unhandled(context: *arch.InterruptContext) void {
    const interrupt_num: u8 = @truncate(u8, context.int_num - IRQ_OFFSET);
    panic.panicFmt(null, "Unhandled IRQ number {}", interrupt_num);
}

// TODO Move to PIC
fn sendEndOfInterrupt(irq_num: u8) void {
    if (irq_num >= 8) {
        arch.outb(0xA0, 0x20);
    }

    arch.outb(0x20, 0x20);
}

// TODO Move to PIC
fn spuriousIrq(irq_num: u8) bool {
    // Only for IRQ 7 and 15
    if(irq_num == 7) {
        // Read master ISR
        arch.outb(0x20, 0x0B);
        const in_service = arch.inb(0x21);
        // Check the MSB is zero, if so, then is a spurious irq
        if ((in_service & 0x80) == 0) {
            spurious_irq_counter += 1;
            return true;
        }
    } else if (irq_num == 15) {
        // Read slave ISR
        arch.outb(0xA0, 0x0B);
        const in_service = arch.inb(0xA1);
        // Check the MSB is zero, if so, then is a spurious irq
        if ((in_service & 0x80) == 0) {
            // Need to send EOI to the master
            arch.outb(0x20, 0x20);
            spurious_irq_counter += 1;
            return true;
        }
    }

    return false;
}

export fn irqHandler(context: *arch.InterruptContext) void {
    const irq_num: u8 = @truncate(u8, context.int_num - IRQ_OFFSET);
    // Make sure it isn't a spurious irq
    if (!spuriousIrq(irq_num)) {
        irq_handlers[irq_num](context);
        // Send the end of interrupt command
        sendEndOfInterrupt(irq_num);
    }
}

pub fn registerIrq(irq_num: u16, handler: fn(*arch.InterruptContext)void) void {
    irq_handlers[irq_num] = handler;
    clearMask(irq_num);
}

pub fn unregisterIrq(irq_num: u16) void {
    irq_handlers[irq_num] = unhandled;
    setMask(irq_num);
}

pub fn setMask(irq_num: u16) void {
    // TODO Change to PIC constants
    const port: u16 = if (irq_num < 8) 0x20 else 0xA0;
    const value = arch.inb(port) | (1 << irq_num);
    arch.outb(port, value);
}

pub fn clearMask(irq_num: u16) void {
    // TODO Change to PIC constants
    const port: u16 = if (irq_num < 8) 0x20 else 0xA0;
    const value = arch.inb(port) & ~(1 << irq_num);
    arch.outb(port, value);
}

// TODO Move this to the PIC once got one
fn remapIrq() void {
    // Initiate
    arch.outb(0x20, 0x11);
    arch.outb(0xA0, 0x11);

    // Offsets
    arch.outb(0x21, IRQ_OFFSET);
    arch.outb(0xA1, IRQ_OFFSET + 8);

    // IRQ lines
    arch.outb(0x21, 0x04);
    arch.outb(0xA1, 0x02);

    // 80x86 mode
    arch.outb(0x21, 0x01);
    arch.outb(0xA1, 0x01);

    // Mask
    arch.outb(0x21, 0xFF);
    arch.outb(0xA1, 0xFF);

}

pub fn init() void {
    // Remap the PIC IRQ so not to overlap with other exceptions
    remapIrq();

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