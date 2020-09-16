const std = @import("std");
const logger = std.log.scoped(.kmain);
const builtin = @import("builtin");
const is_test = builtin.is_test;
const build_options = @import("build_options");
const mock_path = build_options.mock_path;
const arch = @import("arch.zig").internals;
const tty = @import("tty.zig");
const vga = @import("vga.zig");
const log_root = @import("log.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");
const vmm = if (is_test) @import(mock_path ++ "vmm_mock.zig") else @import("vmm.zig");
const mem = if (is_test) @import(mock_path ++ "mem_mock.zig") else @import("mem.zig");
const panic_root = if (is_test) @import(mock_path ++ "panic_mock.zig") else @import("panic.zig");
const task = if (is_test) @import(mock_path ++ "task_mock.zig") else @import("task.zig");
const heap = @import("heap.zig");
const scheduler = @import("scheduler.zig");
const vfs = @import("filesystem/vfs.zig");
const initrd = @import("filesystem/initrd.zig");
const keyboard = @import("keyboard.zig");

comptime {
    if (!is_test) {
        switch (builtin.arch) {
            .i386 => _ = @import("arch/x86/boot.zig"),
            .aarch64 => _ = @import("arch/aarch64/boot.zig"),
            else => {},
        }
    }
}

// This is for unit testing as we need to export KERNEL_ADDR_OFFSET as it is no longer available
// from the linker script
// These will need to be kept up to date with the debug logs in the mem init.
export var KERNEL_ADDR_OFFSET: u32 = if (builtin.is_test) 0xC0000000 else undefined;
export var KERNEL_STACK_START: u32 = if (builtin.is_test) 0xC014A000 else undefined;
export var KERNEL_STACK_END: u32 = if (builtin.is_test) 0xC014E000 else undefined;
export var KERNEL_VADDR_START: u32 = if (builtin.is_test) 0xC0100000 else undefined;
export var KERNEL_VADDR_END: u32 = if (builtin.is_test) 0xC014E000 else undefined;
export var KERNEL_PHYSADDR_START: u32 = if (builtin.is_test) 0x100000 else undefined;
export var KERNEL_PHYSADDR_END: u32 = if (builtin.is_test) 0x14E000 else undefined;

// Just call the panic function, as this need to be in the root source file
pub fn panic(msg: []const u8, error_return_trace: ?*builtin.StackTrace) noreturn {
    @setCold(true);
    panic_root.panic(error_return_trace, "{}", .{msg});
}

pub const log_level: std.log.Level = .debug;
// Define root.log to override the std implementation
pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    log_root.log(level, "(" ++ @tagName(scope) ++ "): " ++ format, args);
}

export fn kmain(boot_payload: arch.BootPayload) void {
    const serial_stream = serial.init(boot_payload);

    log_root.init(serial_stream);

    const mem_profile = arch.initMem(boot_payload) catch |e| {
        panic_root.panic(@errorReturnTrace(), "Failed to initialise memory profile: {}", .{e});
    };
    var fixed_allocator = mem_profile.fixed_allocator;

    panic_root.init(&mem_profile, &fixed_allocator.allocator) catch |e| {
        panic_root.panic(@errorReturnTrace(), "Failed to initialise panic: {}\n", .{e});
    };

    if (builtin.arch != .aarch64) {
        pmm.init(&mem_profile, &fixed_allocator.allocator);
        var kernel_vmm = vmm.init(&mem_profile, &fixed_allocator.allocator) catch |e| {
            panic_root.panic(@errorReturnTrace(), "Failed to initialise kernel VMM: {}", .{e});
        };

        logger.info("Init arch " ++ @tagName(builtin.arch) ++ "\n", .{});
        arch.init(&mem_profile);
        logger.info("Arch init done\n", .{});

        // Give the kernel heap 10% of the available memory. This can be fine-tuned as time goes on.
        var heap_size = mem_profile.mem_kb / 10 * 1024;
        // The heap size must be a power of two so find the power of two smaller than or equal to the heap_size
        if (!std.math.isPowerOfTwo(heap_size)) {
            heap_size = std.math.floorPowerOfTwo(usize, heap_size);
        }
        var kernel_heap = heap.init(arch.VmmPayload, kernel_vmm, vmm.Attributes{ .kernel = true, .writable = true, .cachable = true }, heap_size) catch |e| {
            panic_root.panic(@errorReturnTrace(), "Failed to initialise kernel heap: {}\n", .{e});
        };

        tty.init(&kernel_heap.allocator, boot_payload);
        var arch_kb = keyboard.init(&fixed_allocator.allocator) catch |e| {
            panic_root.panic(@errorReturnTrace(), "Failed to inititalise keyboard: {}\n", .{e});
        };
        if (arch_kb) |kb| {
            keyboard.addKeyboard(kb) catch |e| panic_root.panic(@errorReturnTrace(), "Failed to add architecture keyboard: {}\n", .{e});
        }

        scheduler.init(&kernel_heap.allocator) catch |e| {
            panic_root.panic(@errorReturnTrace(), "Failed to initialise scheduler: {}\n", .{e});
        };

        // Get the ramdisk module
        const rd_module = for (mem_profile.modules) |module| {
            if (std.mem.eql(u8, module.name, "initrd.ramdisk")) {
                break module;
            }
        } else null;

        if (rd_module) |module| {
            // Load the ram disk
            const rd_len: usize = module.region.end - module.region.start;
            const ramdisk_bytes = @intToPtr([*]u8, module.region.start)[0..rd_len];
            var initrd_stream = std.io.fixedBufferStream(ramdisk_bytes);
            var ramdisk_filesystem = initrd.InitrdFS.init(&initrd_stream, &kernel_heap.allocator) catch |e| {
                panic_root.panic(@errorReturnTrace(), "Failed to initialise ramdisk: {}\n", .{e});
            };
            defer ramdisk_filesystem.deinit();

            // Can now free the module as new memory is allocated for the ramdisk filesystem
            kernel_vmm.free(module.region.start) catch |e| {
                panic_root.panic(@errorReturnTrace(), "Failed to free ramdisk: {}\n", .{e});
            };

            // Need to init the vfs after the ramdisk as we need the root node from the ramdisk filesystem
            vfs.setRoot(ramdisk_filesystem.root_node);

            // Load all files here
        }

        // Initialisation is finished, now does other stuff
        logger.info("Init\n", .{});

        // Main initialisation finished so can enable interrupts
        arch.enableInterrupts();

        logger.info("Creating init2\n", .{});

        // Create a init2 task
        var idle_task = task.Task.create(initStage2, &kernel_heap.allocator) catch |e| {
            panic_root.panic(@errorReturnTrace(), "Failed to create init stage 2 task: {}\n", .{e});
        };
        scheduler.scheduleTask(idle_task, &kernel_heap.allocator) catch |e| {
            panic_root.panic(@errorReturnTrace(), "Failed to schedule init stage 2 task: {}\n", .{e});
        };
    } else {
        tty.init(&fixed_allocator.allocator, boot_payload);
        initStage2();
    }

    // Can't return for now, later this can return maybe
    // TODO: Maybe make this the idle task
    arch.spinWait();
}

///
/// Stage 2 initialisation. This will initialise main kernel features after the architecture
/// initialisation.
///
fn initStage2() noreturn {
    tty.clear();
    const logo =
        \\                  _____    _        _    _   _______    ____
        \\                 |  __ \  | |      | |  | | |__   __|  / __ \
        \\                 | |__) | | |      | |  | |    | |    | |  | |
        \\                 |  ___/  | |      | |  | |    | |    | |  | |
        \\                 | |      | |____  | |__| |    | |    | |__| |
        \\                 |_|      |______|  \____/     |_|     \____/
    ;
    tty.print("Hello Pluto from kernel :)\n\n", .{});
    tty.print("{}\n\n", .{logo});

    logger.info("Hello Pluto from kernel :)\n", .{});

    switch (build_options.test_mode) {
        .Initialisation => {
            logger.info("SUCCESS\n", .{});
        },
        else => {},
    }
    // Can't return for now, later this can return maybe
    arch.spinWait();
}
