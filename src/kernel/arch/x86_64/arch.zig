const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.x86_64_arch);
const serial = @import("serial.zig");
const stivale2 = @import("stivale2.zig");
const paging = @import("paging.zig");
const tty = @import("tty.zig");
const mem = @import("../../mem.zig");
const vmm = @import("../../vmm.zig");
const Serial = @import("../../serial.zig").Serial;
const panic = @import("../../panic.zig").panic;
const MemProfile = mem.MemProfile;

/// The memory type provided by the Limine bootloader.
const MemType = enum(u32) {
    Usable = 1,
    Reserved = 2,
    ACPI_Reclaimable = 3,
    ACPI_NVS = 4,
    BadMemory = 5,
    BootloaderReclaimable = 0x1000,
    KernelAndModules = 0x1001,
};

/// The memory map entry.
pub const MemMapEntry = packed struct {
    /// The start/base address of the memory entry.
    base_addr: u64,
    /// The length of the memory entry (not aligned)
    len: u64,
    /// The type of memory if it is usable.
    memtype: MemType,
    /// Unused.
    unused: u32,
};

/// The frame buffer provided by the Limine bootloader.
pub const FrameBuffer = packed struct {
    addr: u64,
    width: u16,
    height: u16,
    pitch: u16,
    bits_per_pixel: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
};

/// Additional modules/files loaded by the bootloader.
pub const Module = packed struct {
    /// The start address of the module.
    begin: u64,
    /// The end address of the module.
    end: u64,
    /// The name of the module.
    string: [128]u8,
};

/// Additional multiprocessor information.
pub const SMPInfo = packed struct {
    acpi_processor_uid: u32,
    lapic_id: u32,
    target_stack: u64,
    goto_address: u64,
    extra_argument: u64,
};

/// The command line structure for holding command line information.
const CommandLine = struct {
    /// The command line arguments that the kernel was started with.
    cmdline: []const u8,
};

/// Multiprocessor information
pub const Smp = struct {
    flags: u64,
    bsp_lapic_id: u32,
    cpu_count: u64,
    smp_info: []SMPInfo,
};

/// x86_64's boot payload is the stivale2 structs passed from Limine
pub const BootPayload = struct {
    /// The command line argument passed to the kernel.
    command_line: ?CommandLine = null,
    /// The list of memory maps of usable and unusable memory from the bootloader.
    memmap: []MemMapEntry = &[_]MemMapEntry{},
    /// The frame buffer information.
    frame_buffer: ?FrameBuffer = null,
    /// The list of additional modules/files loaded by the bootloader.
    modules: []Module = &[_]Module{},
    /// The location of the ACPI RSDP structure.
    rsdp_addr: ?u64 = null,
    /// The epoch time of boot.
    epoch: ?u64 = null,
    /// Information on the firmware, Bit 0: 0 = UEFI, 1 = BIOS.
    firmware_flags: ?u64 = null,
    /// Multiprocessor information.
    smp: ?Smp = null,
};

// Make sure the packed structs are packed.
comptime {
    std.debug.assert(@sizeOf(MemMapEntry) == 24);
    std.debug.assert(@sizeOf(FrameBuffer) == 23);
    std.debug.assert(@sizeOf(Module) == 144);
    std.debug.assert(@sizeOf(SMPInfo) == 32);
}

/// The type of the payload passed to a virtual memory mapper.
/// For x86 it's the page directory that should be mapped.
pub const VmmPayload = *paging.PageMapLevel4;

/// The end virtual address.
pub const END_VIRTUAL_MEMORY: usize = 0xFFFFFFFFFFFFFFFF;

/// The payload used in the kernel virtual memory manager.
/// For x86 it's the kernel's page directory.
pub const KERNEL_VMM_PAYLOAD: VmmPayload = &paging.kernel_pml4;

/// The architecture's virtual memory mapper.
/// For x86, it simply forwards the calls to the paging subsystem.
pub const VMM_MAPPER: vmm.Mapper(VmmPayload) = vmm.Mapper(VmmPayload){ .mapFn = paging.map, .unmapFn = paging.unmap };

/// The size of each allocatable block of memory, normally set to the page size.
pub const MEMORY_BLOCK_SIZE: usize = paging.PAGE_SIZE_4KB;

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
/// Force the CPU to wait for an I/O operation to compete. Use port 0x80 as this is unused.
///
pub fn ioWait() void {
    out(0x80, @as(u8, 0));
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

///
/// Initialise the system's memory. Populates a memory profile with boot modules from grub, the amount of available memory, the reserved regions of virtual and physical memory as well as the start and end of the kernel code
///
/// Arguments:
///     IN boot_payload: BootPayload - The stivale2 info passed by limline.
///
/// Return: MemProfile
///     The constructed memory profile.
///
/// Error: Allocator.Error
///     Allocator.Error.OutOfMemory - There wasn't enough memory in the allocated created to populate the memory profile, consider increasing mem.FIXED_ALLOC_SIZE
///
pub fn initMem(boot_payload: BootPayload) Allocator.Error!MemProfile {
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});

    log.debug("KERNEL_ADDR_OFFSET:    0x{X}\n", .{@ptrToInt(&KERNEL_ADDR_OFFSET)});
    log.debug("KERNEL_STACK_START:    0x{X}\n", .{@ptrToInt(&KERNEL_STACK_START)});
    log.debug("KERNEL_STACK_END:      0x{X}\n", .{@ptrToInt(&KERNEL_STACK_END)});
    log.debug("KERNEL_VADDR_START:    0x{X}\n", .{@ptrToInt(&KERNEL_VADDR_START)});
    log.debug("KERNEL_VADDR_END:      0x{X}\n", .{@ptrToInt(&KERNEL_VADDR_END)});
    log.debug("KERNEL_PHYSADDR_START: 0x{X}\n", .{@ptrToInt(&KERNEL_PHYSADDR_START)});
    log.debug("KERNEL_PHYSADDR_END:   0x{X}\n", .{@ptrToInt(&KERNEL_PHYSADDR_END)});

    mem.ADDR_OFFSET = @ptrToInt(&KERNEL_ADDR_OFFSET);

    const allocator = &mem.fixed_buffer_allocator.allocator;
    var reserved_physical_mem = std.ArrayList(mem.Range).init(allocator);
    var reserved_virtual_mem = std.ArrayList(mem.Map).init(allocator);

    var prev_mammap_entry: MemMapEntry = MemMapEntry{
        .base_addr = 0,
        .len = boot_payload.memmap[0].base_addr,
        .memtype = .Usable,
        .unused = 0,
    };

    // Reserve the unavailable sections from the memory map
    // Also calculate the total RAM in the same loop
    // TTY buffer is mapped in here
    for (boot_payload.memmap) |entry| {
        var base_addr = entry.base_addr;
        var entry_len = entry.len;
        if (entry.memtype == MemType.KernelAndModules) {
            // Kernel ELF sections and modules are aligned to 4096
            entry_len = std.mem.alignForward(entry_len, 4096);
        } else if (entry.memtype == MemType.BootloaderReclaimable) {
            // Bootloader reclaimable memory base address are aligned to 4096
            base_addr = std.mem.alignBackward(base_addr, 4096);
            entry_len = std.mem.alignForward(entry_len, 4096);
        }

        // Check for hold and mark unusable
        const prev_end_addr = prev_mammap_entry.base_addr + prev_mammap_entry.len;
        if (prev_end_addr != base_addr) {
            try reserved_physical_mem.append(.{
                .start = @intCast(usize, prev_end_addr),
                .end = base_addr,
            });
        }
        prev_mammap_entry.base_addr = base_addr;
        prev_mammap_entry.len = entry_len;
        prev_mammap_entry.memtype = entry.memtype;

        if (entry.memtype != MemType.Usable and entry.memtype != MemType.BootloaderReclaimable and entry.memtype != MemType.KernelAndModules) {
            // If addr + len is greater than maxInt(usize) just ignore whatever comes after maxInt(usize) since it can't be addressed anyway
            // TODO: I thing this needs to be u40 for 64 bit or u48?
            const end: usize = if (base_addr > std.math.maxInt(usize) - entry_len) std.math.maxInt(usize) else @intCast(usize, base_addr + entry_len);
            try reserved_physical_mem.append(.{
                .start = @intCast(usize, base_addr),
                .end = end,
            });
        }
    }

    // Last entry will be in prev_mammap_entry
    // Get the end address to the total size.
    const memory_size_bytes = prev_mammap_entry.base_addr + prev_mammap_entry.len;

    // Map the kernel code
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

    // TODO: Maybe need to map the other sections like all the .debug section. See readelf

    var modules = try std.ArrayList(mem.Module).initCapacity(allocator, boot_payload.modules.len);
    for (boot_payload.modules) |*module| {
        const virtual = mem.Range{
            .start = mem.physToVirt(module.begin),
            .end = mem.physToVirt(module.end),
        };
        const physical = mem.Range{
            .start = module.begin,
            .end = module.end,
        };
        modules.appendAssumeCapacity(.{
            .region = virtual,
            .name = std.mem.trimRight(u8, module.string[0..], "\u{0}"),
        });
        try reserved_virtual_mem.append(.{
            .physical = physical,
            .virtual = virtual,
        });
    }

    return MemProfile{
        .vaddr_end = @ptrCast([*]u8, &KERNEL_VADDR_END),
        .vaddr_start = @ptrCast([*]u8, &KERNEL_VADDR_START),
        .physaddr_end = @ptrCast([*]u8, &KERNEL_PHYSADDR_END),
        .physaddr_start = @ptrCast([*]u8, &KERNEL_PHYSADDR_START),
        .mem_kb = memory_size_bytes / 1024,
        .modules = modules.items,
        .physical_reserved = reserved_physical_mem.items,
        .virtual_reserved = reserved_virtual_mem.items,
        .fixed_allocator = mem.fixed_buffer_allocator,
    };
}

test "" {
    std.testing.refAllDecls(@This());
}
