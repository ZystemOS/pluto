const builtin = @import("builtin");
const gdt = switch (builtin.arch) {
    .i386 => @import("../32bit/gdt.zig"),
    .x86_64 => @import("../64bit/gdt.zig"),
    else => unreachable,
};
const idt = switch (builtin.arch) {
    .i386 => @import("../32bit/idt.zig"),
    .x86_64 => @import("../64bit/idt.zig"),
    else => unreachable,
};

const serial = @import("serial.zig");
const panic = @import("../../../panic.zig").panic;

const Serial = @import("../../../serial.zig").Serial;

const BootPayload = switch (builtin.arch) {
    .i386 => @import("../32bit/arch.zig").BootPayload,
    .x86_64 => @import("../64bit/arch.zig").BootPayload,
    else => unreachable,
};

///
/// Assembly that reads data from a given port and returns its value.
///
/// Arguments:
///     IN comptime Type: type - The type of the data. This can only be u8, u16 or u32.
///     IN port: u16           - The port to read data from.
///
/// Return: Type
///     The data that the port returns.
///
pub fn in(comptime Type: type, port: u16) Type {
    return switch (Type) {
        u8 => asm volatile ("inb %[port], %[result]"
            : [result] "={al}" (-> Type)
            : [port] "N{dx}" (port)
        ),
        u16 => asm volatile ("inw %[port], %[result]"
            : [result] "={ax}" (-> Type)
            : [port] "N{dx}" (port)
        ),
        u32 => asm volatile ("inl %[port], %[result]"
            : [result] "={eax}" (-> Type)
            : [port] "N{dx}" (port)
        ),
        else => @compileError("Invalid data type. Only u8, u16 or u32, found: " ++ @typeName(Type)),
    };
}

///
/// Assembly to write to a given port with a give type of data.
///
/// Arguments:
///     IN port: u16     - The port to write to.
///     IN data: anytype - The data that will be sent This must be a u8, u16 or u32 type.
///
pub fn out(port: u16, data: anytype) void {
    switch (@TypeOf(data)) {
        u8 => asm volatile ("outb %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{al}" (data)
        ),
        u16 => asm volatile ("outw %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{ax}" (data)
        ),
        u32 => asm volatile ("outl %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{eax}" (data)
        ),
        else => @compileError("Invalid data type. Only u8, u16 or u32, found: " ++ @typeName(@TypeOf(data))),
    }
}

///
/// Get the previously loaded GDT from the CPU.
///
/// Return: gdt.GdtPtr
///     The previously loaded GDT from the CPU.
///
pub fn sgdt() gdt.GdtPtr {
    var gdt_ptr = gdt.GdtPtr{ .limit = undefined, .base = undefined };
    asm volatile ("sgdt %[tab]"
        : [tab] "=m" (gdt_ptr)
    );
    return gdt_ptr;
}

///
/// Tell the CPU where the TSS is located in the GDT.
///
/// Arguments:
///     IN offset: u16 - The offset in the GDT where the TSS segment is located.
///
pub fn ltr(offset: u16) void {
    asm volatile ("ltr %%ax"
        :
        : [offset] "{ax}" (offset)
    );
}

///
/// Load the IDT into the CPU.
///
/// Arguments:
///     IN idt_ptr: *const idt.IdtPtr - The address of the iDT.
///
pub fn lidt(idt_ptr: *const idt.IdtPtr) void {
    asm volatile ("lidt (%%eax)"
        :
        : [idt_ptr] "{eax}" (idt_ptr)
    );
}

///
/// Get the previously loaded IDT from the CPU.
///
/// Return: idt.IdtPtr
///     The previously loaded IDT from the CPU.
///
pub fn sidt() idt.IdtPtr {
    var idt_ptr = idt.IdtPtr{ .limit = undefined, .base = undefined };
    asm volatile ("sidt %[tab]"
        : [tab] "=m" (idt_ptr)
    );
    return idt_ptr;
}

///
/// Enable interrupts.
///
pub fn enableInterrupts() void {
    asm volatile ("sti");
}

///
/// Disable interrupts.
///
pub fn disableInterrupts() void {
    asm volatile ("cli");
}

///
/// Halt the CPU, but interrupts will still be called.
///
pub fn halt() void {
    asm volatile ("hlt");
}

///
/// Wait the kernel but still can handle interrupts.
///
pub fn spinWait() noreturn {
    enableInterrupts();
    while (true) {
        halt();
    }
}

///
/// Halt the kernel. No interrupts will be handled.
///
pub fn haltNoInterrupts() noreturn {
    while (true) {
        disableInterrupts();
        halt();
    }
}

///
/// Force the CPU to wait for an I/O operation to compete. Use port 0x80 as this is unused.
///
pub fn ioWait() void {
    out(0x80, @as(u8, 0));
}

///
/// Write a byte to serial port com1. Used by the serial initialiser
///
/// Arguments:
///     IN byte: u8 - The byte to write
///
fn writeSerialCom1(byte: u8) void {
    serial.write(byte, serial.Port.COM1);
}

///
/// Initialise serial communication using port COM1 and construct a Serial instance
///
/// Arguments:
///     IN boot_payload: arch.BootPayload - The payload passed at boot. Not currently used by x86
///                                         or x86_64.
///
/// Return: serial.Serial
///     The Serial instance constructed with the function used to write bytes
///
pub fn initSerial(boot_payload: BootPayload) Serial {
    serial.init(serial.DEFAULT_BAUDRATE, serial.Port.COM1) catch |e| {
        panic(@errorReturnTrace(), "Failed to initialise serial: {}", .{e});
    };
    return Serial{
        .write = writeSerialCom1,
    };
}
