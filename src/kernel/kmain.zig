const std = @import("std");
const builtin = @import("builtin");
const is_test = builtin.is_test;
const build_options = @import("build_options");
const mock_path = build_options.mock_path;
const arch = @import("arch.zig").internals;
const tty = @import("tty.zig");
const vga = @import("vga.zig");
const log = @import("log.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");
const vmm = if (is_test) @import(mock_path ++ "vmm_mock.zig") else @import("vmm.zig");
const mem = if (is_test) @import(mock_path ++ "mem_mock.zig") else @import("mem.zig");
const panic_root = if (is_test) @import(mock_path ++ "panic_mock.zig") else @import("panic.zig");
const heap = @import("heap.zig");

comptime {
    if (!is_test) {
        switch (builtin.arch) {
            .i386 => _ = @import("arch/x86/boot.zig"),
            else => {},
        }
    }
}

/// The virtual memory manager associated with the kernel address space
var kernel_vmm: vmm.VirtualMemoryManager(arch.VmmPayload) = undefined;

// This is for unit testing as we need to export KERNEL_ADDR_OFFSET as it is no longer available
// from the linker script
export var KERNEL_ADDR_OFFSET: u32 = if (builtin.is_test) 0xC0000000 else undefined;

// Just call the panic function, as this need to be in the root source file
pub fn panic(msg: []const u8, error_return_trace: ?*builtin.StackTrace) noreturn {
    @setCold(true);
    panic_root.panic(error_return_trace, "{}", .{msg});
}

export fn kmain(boot_payload: arch.BootPayload) void {
    const serial_stream = serial.init(boot_payload);

    log.init(serial_stream);

    const mem_profile = arch.initMem(boot_payload) catch |e| panic_root.panic(@errorReturnTrace(), "Failed to initialise memory profile: {}", .{e});
    var fixed_allocator = mem_profile.fixed_allocator;

    panic_root.init(&mem_profile, &fixed_allocator.allocator) catch |e| {
        panic_root.panic(@errorReturnTrace(), "Failed to initialise panic: {}", .{e});
    };

    pmm.init(&mem_profile, &fixed_allocator.allocator);
    kernel_vmm = vmm.init(&mem_profile, &fixed_allocator.allocator) catch |e| panic_root.panic(@errorReturnTrace(), "Failed to initialise kernel VMM: {}", .{e});

    log.logInfo("Init arch " ++ @tagName(builtin.arch) ++ "\n", .{});
    arch.init(boot_payload, &mem_profile, &fixed_allocator.allocator);
    log.logInfo("Arch init done\n", .{});

    // Give the kernel heap 10% of the available memory. This can be fine-tuned as time goes on.
    var heap_size = mem_profile.mem_kb / 10 * 1024;
    // The heap size must be a power of two so find the power of two smaller than or equal to the heap_size
    if (!std.math.isPowerOfTwo(heap_size)) {
        heap_size = std.math.floorPowerOfTwo(usize, heap_size);
    }
    var kernel_heap = heap.init(arch.VmmPayload, &kernel_vmm, vmm.Attributes{ .kernel = true, .writable = true, .cachable = true }, heap_size, &fixed_allocator.allocator) catch |e| {
        panic_root.panic(@errorReturnTrace(), "Failed to initialise kernel heap: {}\n", .{e});
    };
    tty.init(&kernel_heap.allocator, boot_payload);

    log.logInfo("Init done\n", .{});

    tty.clear();
    const logo =
        \\                  _____    _        _    _   _______    ____
        \\                 |  __ \  | |      | |  | | |__   __|  / __ \
        \\                 | |__) | | |      | |  | |    | |    | |  | |
        \\                 |  ___/  | |      | |  | |    | |    | |  | |
        \\                 | |      | |____  | |__| |    | |    | |__| |
        \\                 |_|      |______|  \____/     |_|     \____/
    ;
    tty.print("{}\n\n", .{logo});

    tty.print("Hello Pluto from kernel :)\n", .{});

    // The panic runtime tests must run last as they never return
    if (build_options.rt_test) panic_root.runtimeTests();
}
