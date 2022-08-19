const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.x86_arch);
const builtin = @import("builtin");
const cmos = @import("cmos.zig");
pub const gdt = @import("gdt.zig");
pub const idt = @import("idt.zig");
const irq = @import("irq.zig");
const isr = @import("isr.zig");
pub const paging = @import("paging.zig");
const pic = @import("pic.zig");
const pci = @import("pci.zig");
const pit = @import("pit.zig");
const rtc = @import("rtc.zig");
const serial = @import("serial.zig");
const syscalls = @import("syscalls.zig");
const tty = @import("tty.zig");
const vga = @import("vga.zig");
const multiboot = @import("multiboot.zig");
const keyboard = @import("keyboard.zig");
const pluto = @import("pluto");
const mem = pluto.mem;
const vmm = pluto.vmm;
const Keyboard = pluto.keyboard.Keyboard;
const Serial = pluto.serial.Serial;
const panic = pluto.panic_root.panic;
const TTY = pluto.tty.TTY;
const Task = pluto.task.Task;
const MemProfile = mem.MemProfile;

/// The type of a device.
pub const Device = pci.PciDeviceInfo;

/// The type of the date and time structure.
pub const DateTime = rtc.DateTime;

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
    int_num: u32,
    error_code: u32,

    // Instruction pointer, code segment and flags
    eip: u32,
    cs: u32,
    eflags: u32,
    user_esp: u32,
    user_ss: u32,

    pub fn empty() CpuState {
        return .{
            .cr3 = undefined,
            .gs = undefined,
            .fs = undefined,
            .es = undefined,
            .ds = undefined,
            .edi = undefined,
            .esi = undefined,
            .ebp = undefined,
            .esp = undefined,
            .ebx = undefined,
            .edx = undefined,
            .ecx = undefined,
            .eax = undefined,
            .int_num = undefined,
            .error_code = undefined,
            .eip = undefined,
            .cs = undefined,
            .eflags = undefined,
            .user_esp = undefined,
            .user_ss = undefined,
        };
    }
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
            : [result] "={al}" (-> Type),
            : [port] "N{dx}" (port),
        ),
        u16 => asm volatile ("inw %[port], %[result]"
            : [result] "={ax}" (-> Type),
            : [port] "N{dx}" (port),
        ),
        u32 => asm volatile ("inl %[port], %[result]"
            : [result] "={eax}" (-> Type),
            : [port] "N{dx}" (port),
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
              [data] "{al}" (data),
        ),
        u16 => asm volatile ("outw %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{ax}" (data),
        ),
        u32 => asm volatile ("outl %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{eax}" (data),
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
        : [gdt_ptr] "{eax}" (gdt_ptr),
    );

    // Load the kernel data segment, index into the GDT
    asm volatile ("mov %%bx, %%ds"
        :
        : [KERNEL_DATA_OFFSET] "{bx}" (gdt.KERNEL_DATA_OFFSET),
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
        : [tab] "=m" (gdt_ptr),
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
        : [offset] "{ax}" (offset),
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
        : [idt_ptr] "{eax}" (idt_ptr),
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
        : [tab] "=m" (idt_ptr),
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
    // Suppress unused var warning
    _ = boot_payload;
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
    // Suppress unused var warning
    _ = boot_payload;
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

    const allocator = mem.fixed_buffer_allocator.allocator();
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
///     IN allocator: std.mem.Allocator - The allocator to use if necessary
///
/// Return: *Keyboard
///     The initialised PS/2 keyboard
///
/// Error: std.mem.Allocator.Error
///     OutOfMemory - There wasn't enough memory to allocate what was needed
///
pub fn initKeyboard(allocator: Allocator) Allocator.Error!*Keyboard {
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
///     IN allocator: Allocator - The allocator use for allocating a stack.
///
/// Error: Allocator.Error
///     OutOfMemory - Unable to allocate space for the stack.
///
pub fn initTask(task: *Task, entry_point: usize, allocator: Allocator) Allocator.Error!void {
    const data_offset = if (task.kernel) gdt.KERNEL_DATA_OFFSET else gdt.USER_DATA_OFFSET | 0b11;
    // Setting the bottom two bits of the code offset designates that this is a ring 3 task
    const code_offset = if (task.kernel) gdt.KERNEL_CODE_OFFSET else gdt.USER_CODE_OFFSET | 0b11;
    // Ring switches push and pop two extra values on interrupt: user_esp and user_ss
    const kernel_stack_bottom = if (task.kernel) task.kernel_stack.len - 18 else task.kernel_stack.len - 20;

    var stack = &task.kernel_stack;

    // TODO Will need to add the exit point
    // Set up everything as a kernel task
    task.vmm.payload = &paging.kernel_directory;
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
///     IN allocator: Allocator - An allocator for getting the devices
///
/// Return: []Device
///     A list of hardware devices.
///
/// Error: Allocator.Error
///     OutOfMemory - Unable to allocate space the operation.
///
pub fn getDevices(allocator: Allocator) Allocator.Error![]Device {
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

test {
    std.testing.refAllDecls(@This());
}
