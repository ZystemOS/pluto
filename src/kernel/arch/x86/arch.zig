// Zig version: 0.4.0

const builtin = @import("builtin");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const irq = @import("irq.zig");
const isr = @import("isr.zig");
const log = @import("../../log.zig");
const pit = @import("pit.zig");

pub const InterruptContext = struct {
    // Extra segments
    gs: u32,
    fs: u32,
    es: u32,
    ds: u32,

    // Destination, source, base pointer
    edi: u32,
    esi: u32,
    ebp: u32,
    esp: u32,

    // General registers
    ebx: u32,
    edx: u32,
    ecx: u32,
    eax: u32,

    // Interrupt number and error code
    int_num: u32,
    error_code: u32,

    // Instruction pointer, code segment and flags
    eip: u32,
    cs: u32,
    eflags: u32,
    user_esp: u32,
    ss: u32,
};

///
/// Initialise the architecture
///
pub fn init() void {
    disableInterrupts();

    gdt.init();
    idt.init();

    isr.init();
    irq.init();

    pit.init();

    // Enable interrupts
    enableInterrupts();
}

///
/// Inline assembly to write to a given port with a byte of data.
///
/// Arguments:
///     IN port: u16 - The port to write to.
///     IN data: u8  - The byte of data that will be sent.
///
pub fn outb(port: u16, data: u8) void {
    asm volatile ("outb %[data], %[port]"
        :
        : [port] "{dx}" (port),
          [data] "{al}" (data)
    );
}

///
/// Inline assembly that reads data from a given port and returns its value.
///
/// Arguments:
///     IN port: u16 - The port to read data from.
///
/// Return:
///     The data that the port returns.
///
pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8)
        : [port] "N{dx}" (port)
    );
}

///
/// A simple way of waiting for I/O event to happen by doing an I/O event to flush the I/O
/// event being waited.
///
pub fn ioWait() void {
    outb(0x80, 0);
}

///
/// Load the GDT and refreshing the code segment with the code segment offset of the kernel as we
/// are still in kernel land. Also loads the kernel data segment into all the other segment
/// registers.
///
/// Arguments:
///     IN gdt_ptr: *gdt.GdtPtr - The address to the GDT.
///
pub fn lgdt(gdt_ptr: *const gdt.GdtPtr) void {
    // Load the GDT into the CPU
    asm volatile ("lgdt (%%eax)" : : [gdt_ptr] "{eax}" (gdt_ptr));
    // Load the kernel data segment, index into the GDT
    asm volatile ("mov %%bx, %%ds" : : [KERNEL_DATA_OFFSET] "{bx}" (gdt.KERNEL_DATA_OFFSET));
    asm volatile ("mov %%bx, %%es");
    asm volatile ("mov %%bx, %%fs");
    asm volatile ("mov %%bx, %%gs");
    asm volatile ("mov %%bx, %%ss");
    // Load the kernel code segment into the CS register
    asm volatile (
        \\ljmp $0x08, $1f
        \\1:
    );
}

///
/// Load the TSS into the CPU.
///
pub fn ltr() void {
    asm volatile ("ltr %%ax" : : [TSS_OFFSET] "{ax}" (gdt.TSS_OFFSET));
}

/// Load the IDT into the CPU.
pub fn lidt(idt_ptr: *const idt.IdtPtr) void {
    asm volatile ("lidt (%%eax)" : : [idt_ptr] "{eax}" (idt_ptr));
}

///
/// Enable interrupts
///
pub fn enableInterrupts() void {
    asm volatile ("sti");
}

///
/// Disable interrupts
///
pub fn disableInterrupts() void {
    asm volatile ("cli");
}

///
/// Halt the CPU, but interrupts will still be called
///
pub fn halt() void {
    asm volatile ("hlt");
}

///
/// Wait the kernel but still can handle interrupts.
///
pub fn spinWait() noreturn {
    while (true) {
        enableInterrupts();
        halt();
        disableInterrupts();
    }
}

///
/// Halt the kernel.
///
pub fn haltNoInterrupts() noreturn {
    while (true) {
        disableInterrupts();
        halt();
    }
}
