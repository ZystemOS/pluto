const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pic = @import("pic.zig");
const irq = @import("irq.zig");
const isr = @import("isr.zig");
const pit = @import("pit.zig");
const rtc = @import("rtc.zig");
const paging = @import("paging.zig");
const syscalls = @import("syscalls.zig");
const mem = @import("../../mem.zig");
const multiboot = @import("../../multiboot.zig");
const pmm = @import("pmm.zig");
const vmm = @import("../../vmm.zig");
const MemProfile = mem.MemProfile;

/// The interrupt context that is given to a interrupt handler. It contains most of the registers
/// and the interrupt number and error code (if there is one).
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

/// The type of the payload passed to a virtual memory mapper.
/// For x86 it's the page directory that should be mapped.
pub const VmmPayload = *paging.Directory;

/// The payload used in the kernel virtual memory manager.
/// For x86 it's the kernel's page directory.
pub const KERNEL_VMM_PAYLOAD = &paging.kernel_directory;

/// The architecture's virtual memory mapper.
/// For x86, it simply forwards the calls to the paging subsystem.
pub const VMM_MAPPER: vmm.Mapper(VmmPayload) = vmm.Mapper(VmmPayload){ .mapFn = paging.map, .unmapFn = paging.unmap };

/// The size of each allocatable block of memory, normally set to the page size.
pub const MEMORY_BLOCK_SIZE = paging.PAGE_SIZE_4KB;

///
/// Assembly to write to a given port with a byte of data.
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
/// Assembly that reads data from a given port and returns its value.
///
/// Arguments:
///     IN port: u16 - The port to read data from.
///
/// Return: u8
///     The data that the port returns.
///
pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8)
        : [port] "N{dx}" (port)
    );
}

///
/// Force the CPU to wait for an I/O operation to compete. Use port 0x80 as this is unused.
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
    asm volatile ("lgdt (%%eax)"
        :
        : [gdt_ptr] "{eax}" (gdt_ptr)
    );

    // Load the kernel data segment, index into the GDT
    asm volatile ("mov %%bx, %%ds"
        :
        : [KERNEL_DATA_OFFSET] "{bx}" (gdt.KERNEL_DATA_OFFSET)
    );

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
/// Get the previously loaded GDT from the CPU.
///
/// Return: gdt.GdtPtr
///     The previously loaded GDT from the CPU.
///
pub fn sgdt() gdt.GdtPtr {
    var gdt_ptr = gdt.GdtPtr{ .limit = 0, .base = 0 };
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
    var idt_ptr = idt.IdtPtr{ .limit = 0, .base = 0 };
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
    while (true) {
        enableInterrupts();
        halt();
        disableInterrupts();
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
/// Initialise the architecture
///
/// Arguments:
///     IN mem_profile: *const MemProfile - The memory profile of the computer. Used to set up
///                                         paging.
///     IN allocator: *Allocator          - The allocator use to handle memory.
///     IN comptime options: type         - The build options that is passed to the kernel to be
///                                         used for run time testing.
///
pub fn init(mb_info: *multiboot.multiboot_info_t, mem_profile: *const MemProfile, allocator: *Allocator) void {
    disableInterrupts();

    gdt.init();
    idt.init();

    pic.init();
    isr.init();
    irq.init();

    paging.init(mb_info, mem_profile, allocator);

    pit.init();
    rtc.init();

    syscalls.init();

    enableInterrupts();
}

test "" {
    _ = @import("gdt.zig");
    _ = @import("idt.zig");
    _ = @import("pic.zig");
    _ = @import("isr.zig");
    _ = @import("irq.zig");
    _ = @import("pit.zig");
    _ = @import("cmos.zig");
    _ = @import("rtc.zig");
    _ = @import("syscalls.zig");
    _ = @import("paging.zig");
}
