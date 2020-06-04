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
const serial = @import("serial.zig");
const paging = @import("paging.zig");
const syscalls = @import("syscalls.zig");
const mem = @import("../../mem.zig");
const multiboot = @import("multiboot.zig");
const pmm = @import("pmm.zig");
const vmm = @import("../../vmm.zig");
const log = @import("../../log.zig");
const tty = @import("../../tty.zig");
const Serial = @import("../../serial.zig").Serial;
const panic = @import("../../panic.zig").panic;
const MemProfile = mem.MemProfile;

/// The virtual end of the kernel code
extern var KERNEL_VADDR_END: *u32;

/// The virtual start of the kernel code
extern var KERNEL_VADDR_START: *u32;

/// The physical end of the kernel code
extern var KERNEL_PHYSADDR_END: *u32;

/// The physical start of the kernel code
extern var KERNEL_PHYSADDR_START: *u32;

/// The boot-time offset that the virtual addresses are from the physical addresses
extern var KERNEL_ADDR_OFFSET: *u32;

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

/// x86's boot payload is the multiboot info passed by grub
pub const BootPayload = *multiboot.multiboot_info_t;

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
pub const MEMORY_BLOCK_SIZE: usize = paging.PAGE_SIZE_4KB;

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
/// Return: serial.Serial
///     The Serial instance constructed with the function used to write bytes
///
pub fn initSerial() Serial {
    serial.init(serial.DEFAULT_BAUDRATE, serial.Port.COM1) catch |e| {
        panic(@errorReturnTrace(), "Failed to initialise serial: {}", .{e});
    };
    return Serial{
        .write = writeSerialCom1,
    };
}

///
/// Initialise the system's memory. Populates a memory profile with boot modules from grub, the amount of available memory, the reserved regions of virtual and physical memory as well as the start and end of the kernel code
///
/// Arguments:
///     IN mb_info: *multiboot.multiboot_info_t - The multiboot info passed by grub
///
/// Return: mem.MemProfile
///     The constructed memory profile
///
/// Error: std.mem.Allocator.Error
///     std.mem.Allocator.Error.OutOfMemory - There wasn't enough memory in the allocated created to populate the memory profile, consider increasing mem.FIXED_ALLOC_SIZE
///
pub fn initMem(mb_info: BootPayload) std.mem.Allocator.Error!MemProfile {
    log.logInfo("Init mem\n", .{});
    defer log.logInfo("Done mem\n", .{});

    const mods_count = mb_info.mods_count;
    mem.ADDR_OFFSET = @ptrToInt(&KERNEL_ADDR_OFFSET);
    const mmap_addr = mb_info.mmap_addr;
    const num_mmap_entries = mb_info.mmap_length / @sizeOf(multiboot.multiboot_memory_map_t);
    const vaddr_end = @ptrCast([*]u8, &KERNEL_VADDR_END);

    var allocator = std.heap.FixedBufferAllocator.init(vaddr_end[0..mem.FIXED_ALLOC_SIZE]);
    var reserved_physical_mem = std.ArrayList(mem.Range).init(&allocator.allocator);
    var reserved_virtual_mem = std.ArrayList(mem.Map).init(&allocator.allocator);
    const mem_map = @intToPtr([*]multiboot.multiboot_memory_map_t, mmap_addr)[0..num_mmap_entries];

    // Reserve the unavailable sections from the multiboot memory map
    for (mem_map) |entry| {
        if (entry.@"type" != multiboot.MULTIBOOT_MEMORY_AVAILABLE) {
            // If addr + len is greater than maxInt(usize) just ignore whatever comes after maxInt(usize) since it can't be addressed anyway
            const end: usize = if (entry.addr > std.math.maxInt(usize) - entry.len) std.math.maxInt(usize) else @intCast(usize, entry.addr + entry.len);
            try reserved_physical_mem.append(.{ .start = @intCast(usize, entry.addr), .end = end });
        }
    }
    // Map the multiboot info struct itself
    const mb_region = mem.Range{
        .start = @ptrToInt(mb_info),
        .end = @ptrToInt(mb_info) + @sizeOf(multiboot.multiboot_info_t),
    };
    const mb_physical = mem.Range{ .start = mem.virtToPhys(mb_region.start), .end = mem.virtToPhys(mb_region.end) };
    try reserved_virtual_mem.append(.{ .virtual = mb_region, .physical = mb_physical });

    // Map the tty buffer
    const tty_addr = mem.virtToPhys(tty.getVideoBufferAddress());
    const tty_region = mem.Range{
        .start = tty_addr,
        .end = tty_addr + 32 * 1024,
    };
    try reserved_virtual_mem.append(.{
        .physical = tty_region,
        .virtual = .{
            .start = mem.physToVirt(tty_region.start),
            .end = mem.physToVirt(tty_region.end),
        },
    });

    // Map the boot modules
    const boot_modules = @intToPtr([*]multiboot.multiboot_mod_list, mem.physToVirt(mb_info.mods_addr))[0..mods_count];
    var modules = std.ArrayList(mem.Module).init(&allocator.allocator);
    for (boot_modules) |module| {
        const virtual = mem.Range{ .start = mem.physToVirt(module.mod_start), .end = mem.physToVirt(module.mod_end) };
        const physical = mem.Range{ .start = module.mod_start, .end = module.mod_end };
        try modules.append(.{ .region = virtual, .name = std.mem.span(mem.physToVirt(@intToPtr([*:0]u8, module.cmdline))) });
        try reserved_virtual_mem.append(.{ .physical = physical, .virtual = virtual });
    }

    return MemProfile{
        .vaddr_end = vaddr_end,
        .vaddr_start = @ptrCast([*]u8, &KERNEL_VADDR_START),
        .physaddr_end = @ptrCast([*]u8, &KERNEL_PHYSADDR_END),
        .physaddr_start = @ptrCast([*]u8, &KERNEL_PHYSADDR_START),
        // Total memory available including the initial 1MiB that grub doesn't include
        .mem_kb = mb_info.mem_upper + mb_info.mem_lower + 1024,
        .modules = modules.items,
        .physical_reserved = reserved_physical_mem.items,
        .virtual_reserved = reserved_virtual_mem.items,
        .fixed_allocator = allocator,
    };
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
