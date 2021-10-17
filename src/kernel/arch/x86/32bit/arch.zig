const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.x86_arch);
const builtin = std.builtin;
const cmos = @import("cmos.zig");
const gdt_32 = @import("gdt.zig");
const idt_32 = @import("idt.zig");
const irq = @import("irq.zig");
const paging = @import("paging.zig");
const pci = @import("pci.zig");
const pit = @import("pit.zig");
const rtc = @import("rtc.zig");
const syscalls = @import("syscalls.zig");
const tty = @import("tty.zig");
const vga = @import("vga.zig");
const mem = @import("../../../mem.zig");
const multiboot = @import("multiboot.zig");
const vmm = @import("../../../vmm.zig");
const keyboard = @import("keyboard.zig");
const panic = @import("../../../panic.zig").panic;
const TTY = @import("../../../tty.zig").TTY;
const Keyboard = @import("../../../keyboard.zig").Keyboard;
const Task = @import("../../../task.zig").Task;
const MemProfile = mem.MemProfile;
const interrupts = @import("interrupts.zig");

usingnamespace @import("../common/arch.zig");

/// The type of a device.
pub const Device = pci.PciDeviceInfo;

/// The type of the date and time structure.
pub const DateTime = rtc.DateTime;

/// The end virtual address.
pub const END_VIRTUAL_MEMORY: usize = 0xFFFFFFFF;

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
pub const CpuState32 = packed struct {
    // Page directory
    cr3: usize,
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
    // These will be 32 bits and need to use usize to satisfy the type system for passing the
    // interrupt number around.
    int_num: usize,
    error_code: u32,

    // Instruction pointer, code segment and flags
    eip: u32,
    cs: u32,
    eflags: u32,
    user_esp: u32,
    user_ss: u32,
};

comptime {
    std.debug.assert(@sizeOf(CpuState32) == 80);
}

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
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});

    log.debug("KERNEL_ADDR_OFFSET:    0x{X}\n", .{@ptrToInt(&KERNEL_ADDR_OFFSET)});
    log.debug("KERNEL_STACK_START:    0x{X}\n", .{@ptrToInt(&KERNEL_STACK_START)});
    log.debug("KERNEL_STACK_END:      0x{X}\n", .{@ptrToInt(&KERNEL_STACK_END)});
    log.debug("KERNEL_VADDR_START:    0x{X}\n", .{@ptrToInt(&KERNEL_VADDR_START)});
    log.debug("KERNEL_VADDR_END:      0x{X}\n", .{@ptrToInt(&KERNEL_VADDR_END)});
    log.debug("KERNEL_PHYSADDR_START: 0x{X}\n", .{@ptrToInt(&KERNEL_PHYSADDR_START)});
    log.debug("KERNEL_PHYSADDR_END:   0x{X}\n", .{@ptrToInt(&KERNEL_PHYSADDR_END)});

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
/// Initialise a stack used for creating a task.
/// Currently only support fn () noreturn functions for the entry point.
///
/// Arguments:
///     IN task: *Task           - The task to be initialised. The function will only modify whatever
///                                is required by the architecture. In the case of x86, it will put
///                                the initial CpuState on the kernel stack.
///     IN entry_point: usize    - The pointer to the entry point of the function. Functions only
///                                supported is fn () noreturn
///     IN allocator: *Allocator - The allocator use for allocating a stack.
///
/// Error: Allocator.Error
///     OutOfMemory - Unable to allocate space for the stack.
///
pub fn initTask(task: *Task, entry_point: usize, allocator: *Allocator) Allocator.Error!void {
    const data_offset = if (task.kernel) gdt_common.KERNEL_DATA_OFFSET else gdt_common.USER_DATA_OFFSET | 0b11;
    // Setting the bottom two bits of the code offset designates that this is a ring 3 task
    const code_offset = if (task.kernel) gdt_common.KERNEL_CODE_OFFSET else gdt_common.USER_CODE_OFFSET | 0b11;
    // Ring switches push and pop two extra values on interrupt: user_esp and user_ss
    const kernel_stack_bottom = if (task.kernel) task.kernel_stack.len - 18 else task.kernel_stack.len - 20;

    var stack = &task.kernel_stack;

    // TODO Will need to add the exit point
    // Set up everything as a kernel task
    stack.*[kernel_stack_bottom] = mem.virtToPhys(@ptrToInt(&paging.kernel_directory));
    stack.*[kernel_stack_bottom + 1] = data_offset; // gs
    stack.*[kernel_stack_bottom + 2] = data_offset; // fs
    stack.*[kernel_stack_bottom + 3] = data_offset; // es
    stack.*[kernel_stack_bottom + 4] = data_offset; // ds

    stack.*[kernel_stack_bottom + 5] = 0; // edi
    stack.*[kernel_stack_bottom + 6] = 0; // esi
    // End of the stack
    stack.*[kernel_stack_bottom + 7] = @ptrToInt(&stack.*[stack.len - 1]); // ebp
    stack.*[kernel_stack_bottom + 8] = 0; // esp (temp) this won't be popped by popa bc intel is dump XD

    stack.*[kernel_stack_bottom + 9] = 0; // ebx
    stack.*[kernel_stack_bottom + 10] = 0; // edx
    stack.*[kernel_stack_bottom + 11] = 0; // ecx
    stack.*[kernel_stack_bottom + 12] = 0; // eax

    stack.*[kernel_stack_bottom + 13] = 0; // int_num
    stack.*[kernel_stack_bottom + 14] = 0; // error_code

    stack.*[kernel_stack_bottom + 15] = entry_point; // eip
    stack.*[kernel_stack_bottom + 16] = code_offset; // cs
    stack.*[kernel_stack_bottom + 17] = 0x202; // eflags

    if (!task.kernel) {
        // Put the extra values on the kernel stack needed when chaning privilege levels
        stack.*[kernel_stack_bottom + 18] = @ptrToInt(&task.user_stack[task.user_stack.len - 1]); // user_esp
        stack.*[kernel_stack_bottom + 19] = data_offset; // user_ss

        if (!builtin.is_test) {
            // Create a new page directory for the user task by mirroring the kernel directory
            // We need kernel mem mapped so we don't get a page fault when entering kernel code from an interrupt
            task.vmm.payload = &(try allocator.allocAdvanced(paging.Directory, paging.PAGE_SIZE_4KB, 1, .exact))[0];
            task.vmm.payload.* = paging.kernel_directory.copy();
            stack.*[kernel_stack_bottom] = vmm.kernel_vmm.virtToPhys(@ptrToInt(task.vmm.payload)) catch |e| {
                panic(@errorReturnTrace(), "Failed to get the physical address of the user task's page directory: {}\n", .{e});
            };
        }
    }
    task.stack_pointer = @ptrToInt(&stack.*[kernel_stack_bottom]);
}

///
/// Get a list of hardware devices attached to the system.
///
/// Arguments:
///     IN allocator: *Allocator - An allocator for getting the devices
///
/// Return: []Device
///     A list of hardware devices.
///
/// Error: Allocator.Error
///     OutOfMemory - Unable to allocate space the operation.
///
pub fn getDevices(allocator: *Allocator) Allocator.Error![]Device {
    return pci.getDevices(allocator);
}

///
/// Get the system date and time.
///
/// Return: DateTime
///     The current date and time.
///
pub fn getDateTime() DateTime {
    return rtc.getDateTime();
}

///
/// Initialise the architecture
///
/// Arguments:
///     IN mem_profile: *const MemProfile - The memory profile of the computer. Used to set up
///                                         paging.
///
pub fn init(mem_profile: *const MemProfile) void {
    gdt_common.init(gdt_32.Tss, &gdt_32.tss_entry);
    idt_common.init(idt_32.IdtEntry, &idt_32.table);

    // This line is needed to reference the getInterruptStub() function
    // Why is this?
    _ = interrupts;

    pic_common.init();
    isr_common.init(idt_32.IdtEntry, &idt_32.table);
    irq_common.init(idt_32.IdtEntry, &idt_32.table);

    paging.init(mem_profile);

    pit.init();
    rtc.init();

    syscalls.init();

    // Initialise the VGA and TTY here since their tests belong the architecture and so should be a part of the
    // arch init test messages
    vga.init();
    tty.init();
}

///
/// Check the state of the user task used for runtime testing for the expected values. These should mirror those in test/user_program.s
///
/// Arguments:
///     IN ctx: *const CpuState - The task's saved state
///
/// Return: bool
///     True if the expected values were found, else false
///
pub fn runtimeTestCheckUserTaskState(ctx: *const CpuState) bool {
    return ctx.eax == 0xCAFE and ctx.ebx == 0xBEEF;
}

test "" {
    std.testing.refAllDecls(@This());
}
