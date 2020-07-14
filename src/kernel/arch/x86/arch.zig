const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const cmos = @import("cmos.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const irq = @import("irq.zig");
const isr = @import("isr.zig");
const paging = @import("paging.zig");
const pic = @import("pic.zig");
const pit = @import("pit.zig");
const rtc = @import("rtc.zig");
const serial = @import("serial.zig");
const syscalls = @import("syscalls.zig");
const tty = @import("tty.zig");
const vga = @import("vga.zig");
const mem = @import("../../mem.zig");
const multiboot = @import("multiboot.zig");
const vmm = @import("../../vmm.zig");
const keyboard = @import("keyboard.zig");
const Serial = @import("../../serial.zig").Serial;
const panic = @import("../../panic.zig").panic;
const TTY = @import("../../tty.zig").TTY;
const Keyboard = @import("../../keyboard.zig").Keyboard;
const MemProfile = mem.MemProfile;

/// The virtual end of the kernel code.
extern var KERNEL_VADDR_END: *u32;

/// The virtual start of the kernel code.
extern var KERNEL_VADDR_START: *u32;

/// The physical end of the kernel code.
extern var KERNEL_PHYSADDR_END: *u32;

/// The physical start of the kernel code.
extern var KERNEL_PHYSADDR_START: *u32;

/// The boot-time offset that the virtual addresses are from the physical addresses.
extern var KERNEL_ADDR_OFFSET: *u32;

/// The virtual address of the top limit of the stack.
extern var KERNEL_STACK_START: *u32;

/// The virtual address of the base of the stack.
extern var KERNEL_STACK_END: *u32;

/// The interrupt context that is given to a interrupt handler. It contains most of the registers
/// and the interrupt number and error code (if there is one).
pub const CpuState = packed struct {
    // Extra segments
    ss: u32,
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
    user_ss: u32,
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

/// The default stack size of a task. Currently this is set to a page size.
pub const STACK_SIZE: u32 = MEMORY_BLOCK_SIZE / @sizeOf(u32);

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

///
/// Initialise the TTY and construct a TTY instance
///
/// Arguments:
///     IN boot_payload: BootPayload - The payload passed to the kernel on boot
///
/// Return: tty.TTY
///     The TTY instance constructed with the information required by the rest of the kernel
///
pub fn initTTY(boot_payload: BootPayload) TTY {
    return .{
        .print = tty.writeString,
        .setCursor = tty.setCursor,
        .cols = vga.WIDTH,
        .rows = vga.HEIGHT,
        .clear = tty.clearScreen,
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
/// Error: Allocator.Error
///     Allocator.Error.OutOfMemory - There wasn't enough memory in the allocated created to populate the memory profile, consider increasing mem.FIXED_ALLOC_SIZE
///
pub fn initMem(mb_info: BootPayload) Allocator.Error!MemProfile {
    std.log.info(.arch_x86, "Init\n", .{});
    defer std.log.info(.arch_x86, "Done\n", .{});

    std.log.debug(.arch_x86, "KERNEL_ADDR_OFFSET:    0x{X}\n", .{@ptrToInt(&KERNEL_ADDR_OFFSET)});
    std.log.debug(.arch_x86, "KERNEL_STACK_START:    0x{X}\n", .{@ptrToInt(&KERNEL_STACK_START)});
    std.log.debug(.arch_x86, "KERNEL_STACK_END:      0x{X}\n", .{@ptrToInt(&KERNEL_STACK_END)});
    std.log.debug(.arch_x86, "KERNEL_VADDR_START:    0x{X}\n", .{@ptrToInt(&KERNEL_VADDR_START)});
    std.log.debug(.arch_x86, "KERNEL_VADDR_END:      0x{X}\n", .{@ptrToInt(&KERNEL_VADDR_END)});
    std.log.debug(.arch_x86, "KERNEL_PHYSADDR_START: 0x{X}\n", .{@ptrToInt(&KERNEL_PHYSADDR_START)});
    std.log.debug(.arch_x86, "KERNEL_PHYSADDR_END:   0x{X}\n", .{@ptrToInt(&KERNEL_PHYSADDR_END)});

    const mods_count = mb_info.mods_count;
    mem.ADDR_OFFSET = @ptrToInt(&KERNEL_ADDR_OFFSET);
    const mmap_addr = mb_info.mmap_addr;
    const num_mmap_entries = mb_info.mmap_length / @sizeOf(multiboot.multiboot_memory_map_t);

    const allocator = &mem.fixed_buffer_allocator.allocator;
    var reserved_physical_mem = std.ArrayList(mem.Range).init(allocator);
    var reserved_virtual_mem = std.ArrayList(mem.Map).init(allocator);
    const mem_map = @intToPtr([*]multiboot.multiboot_memory_map_t, mmap_addr)[0..num_mmap_entries];

    // Reserve the unavailable sections from the multiboot memory map
    for (mem_map) |entry| {
        if (entry.@"type" != multiboot.MULTIBOOT_MEMORY_AVAILABLE) {
            // If addr + len is greater than maxInt(usize) just ignore whatever comes after maxInt(usize) since it can't be addressed anyway
            const end: usize = if (entry.addr > std.math.maxInt(usize) - entry.len) std.math.maxInt(usize) else @intCast(usize, entry.addr + entry.len);
            try reserved_physical_mem.append(.{
                .start = @intCast(usize, entry.addr),
                .end = end,
            });
        }
    }

    // Map the multiboot info struct itself
    const mb_region = mem.Range{
        .start = @ptrToInt(mb_info),
        .end = @ptrToInt(mb_info) + @sizeOf(multiboot.multiboot_info_t),
    };
    const mb_physical = mem.Range{
        .start = mem.virtToPhys(mb_region.start),
        .end = mem.virtToPhys(mb_region.end),
    };
    try reserved_virtual_mem.append(.{
        .virtual = mb_region,
        .physical = mb_physical,
    });

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
    var modules = std.ArrayList(mem.Module).init(allocator);
    for (boot_modules) |module| {
        const virtual = mem.Range{
            .start = mem.physToVirt(module.mod_start),
            .end = mem.physToVirt(module.mod_end),
        };
        const physical = mem.Range{
            .start = module.mod_start,
            .end = module.mod_end,
        };
        try modules.append(.{
            .region = virtual,
            .name = std.mem.span(mem.physToVirt(@intToPtr([*:0]u8, module.cmdline))),
        });
        try reserved_virtual_mem.append(.{
            .physical = physical,
            .virtual = virtual,
        });
    }

    // Map the kernel stack
    const kernel_stack_virt = mem.Range{
        .start = @ptrToInt(&KERNEL_STACK_START),
        .end = @ptrToInt(&KERNEL_STACK_END),
    };
    const kernel_stack_phy = mem.Range{
        .start = mem.virtToPhys(kernel_stack_virt.start),
        .end = mem.virtToPhys(kernel_stack_virt.end),
    };
    try reserved_virtual_mem.append(.{
        .virtual = kernel_stack_virt,
        .physical = kernel_stack_phy,
    });

    // Map the rest of the kernel
    const kernel_virt = mem.Range{
        .start = @ptrToInt(&KERNEL_VADDR_START),
        .end = @ptrToInt(&KERNEL_STACK_START),
    };
    const kernel_phy = mem.Range{
        .start = mem.virtToPhys(kernel_virt.start),
        .end = mem.virtToPhys(kernel_virt.end),
    };
    try reserved_virtual_mem.append(.{
        .virtual = kernel_virt,
        .physical = kernel_phy,
    });

    return MemProfile{
        .vaddr_end = @ptrCast([*]u8, &KERNEL_VADDR_END),
        .vaddr_start = @ptrCast([*]u8, &KERNEL_VADDR_START),
        .physaddr_end = @ptrCast([*]u8, &KERNEL_PHYSADDR_END),
        .physaddr_start = @ptrCast([*]u8, &KERNEL_PHYSADDR_START),
        // Total memory available including the initial 1MiB that grub doesn't include
        .mem_kb = mb_info.mem_upper + mb_info.mem_lower + 1024,
        .modules = modules.items,
        .physical_reserved = reserved_physical_mem.items,
        .virtual_reserved = reserved_virtual_mem.items,
        .fixed_allocator = mem.fixed_buffer_allocator,
    };
}

///
/// Initialise the keyboard that may depend on the chipset or architecture in general.
/// x86 initialises the keyboard connected to the PS/2 port
///
/// Arguments:
///     IN allocator: *std.mem.Allocator - The allocator to use if necessary
///
/// Return: *Keyboard
///     The initialised PS/2 keyboard
///
/// Error: std.mem.Allocator.Error
///     OutOfMemory - There wasn't enough memory to allocate what was needed
///
pub fn initKeyboard(allocator: *Allocator) Allocator.Error!*Keyboard {
    return keyboard.init(allocator);
}

///
/// Initialise a 32bit kernel stack used for creating a task.
/// Currently only support fn () noreturn functions for the entry point.
///
/// Arguments:
///     IN entry_point: usize    - The pointer to the entry point of the function. Functions only
///                                supported is fn () noreturn
///     IN allocator: *Allocator - The allocator use for allocating a stack.
///
/// Return: struct { stack: []u32, pointer: usize }
///     The stack and stack pointer with the stack initialised as a 32bit kernel stack.
///
/// Error: Allocator.Error
///     OutOfMemory - Unable to allocate space for the stack.
///
pub fn initTaskStack(entry_point: usize, allocator: *Allocator) Allocator.Error!struct { stack: []u32, pointer: usize } {
    // TODO Will need to add the exit point
    // Set up everything as a kernel task
    var stack = try allocator.alloc(u32, STACK_SIZE);
    stack[STACK_SIZE - 18] = gdt.KERNEL_DATA_OFFSET; // ss
    stack[STACK_SIZE - 17] = gdt.KERNEL_DATA_OFFSET; // gs
    stack[STACK_SIZE - 16] = gdt.KERNEL_DATA_OFFSET; // fs
    stack[STACK_SIZE - 15] = gdt.KERNEL_DATA_OFFSET; // es
    stack[STACK_SIZE - 14] = gdt.KERNEL_DATA_OFFSET; // ds

    stack[STACK_SIZE - 13] = 0; // edi
    stack[STACK_SIZE - 12] = 0; // esi
    // End of the stack
    stack[STACK_SIZE - 11] = @ptrToInt(&stack[STACK_SIZE - 1]); // ebp
    stack[STACK_SIZE - 10] = 0; // esp (temp) this won't be popped by popa bc intel is dump XD

    stack[STACK_SIZE - 9] = 0; // ebx
    stack[STACK_SIZE - 8] = 0; // edx
    stack[STACK_SIZE - 7] = 0; // ecx
    stack[STACK_SIZE - 6] = 0; // eax

    stack[STACK_SIZE - 5] = 0; // int_num
    stack[STACK_SIZE - 4] = 0; // error_code

    stack[STACK_SIZE - 3] = entry_point; // eip
    stack[STACK_SIZE - 2] = gdt.KERNEL_CODE_OFFSET; // cs
    stack[STACK_SIZE - 1] = 0x202; // eflags

    const ret = .{ .stack = stack, .pointer = @ptrToInt(&stack[STACK_SIZE - 18]) };
    return ret;
}

///
/// Initialise the architecture
///
/// Arguments:
///     IN mem_profile: *const MemProfile - The memory profile of the computer. Used to set up
///                                         paging.
///
pub fn init(mem_profile: *const MemProfile) void {
    gdt.init();
    idt.init();

    pic.init();
    isr.init();
    irq.init();

    paging.init(mem_profile);

    pit.init();
    rtc.init();

    syscalls.init();

    // Initialise the VGA and TTY here since their tests belong the architecture and so should be a part of the
    // arch init test messages
    vga.init();
    tty.init();
}

test "" {
    std.meta.refAllDecls(@This());
}
