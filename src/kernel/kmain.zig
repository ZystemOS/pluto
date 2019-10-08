const std = @import("std");
const builtin = @import("builtin");
const is_test = builtin.is_test;
const build_options = @import("build_options");
const mock_path = build_options.mock_path;
const arch = @import("arch.zig").internals;
const multiboot = @import("multiboot.zig");
const tty = @import("tty.zig");
const vga = @import("vga.zig");
const log = @import("log.zig");
const serial = @import("serial.zig");
const mem = if (is_test) @import(mock_path ++ "mem_mock.zig") else @import("mem.zig");
const panic_root = if (is_test) @import(mock_path ++ "panic_mock.zig").panic else @import("panic.zig").panic;

comptime {
    switch (builtin.arch) {
        .i386 => _ = @import("arch/x86/boot.zig"),
        else => {},
    }
}

// This is for unit testing as we need to export KERNEL_ADDR_OFFSET as it is no longer available
// from the linker script
export var KERNEL_ADDR_OFFSET: u32 = if (builtin.is_test) 0xC0000000 else undefined;

// Just call the panic function, as this need to be in the root source file
pub fn panic(msg: []const u8, error_return_trace: ?*builtin.StackTrace) noreturn {
    @setCold(true);
    panic_root(error_return_trace, "{}", msg);
}

export fn kmain(mb_info: *multiboot.multiboot_info_t, mb_magic: u32) void {
    if (mb_magic == multiboot.MULTIBOOT_BOOTLOADER_MAGIC) {
        // Booted with compatible bootloader
        const mem_profile = mem.init(mb_info);
        var buffer = mem_profile.vaddr_end[0..mem_profile.fixed_alloc_size];
        var fixed_allocator = std.heap.FixedBufferAllocator.init(buffer);

        serial.init(serial.DEFAULT_BAUDRATE, serial.Port.COM1) catch |e| {
            panic_root(@errorReturnTrace(), "Failed to initialise serial: {}", e);
        };
        if (build_options.rt_test)
            log.runtimeTests();

        log.logInfo("Init arch " ++ @tagName(builtin.arch) ++ "\n");
        arch.init(&mem_profile, &fixed_allocator.allocator, build_options);
        log.logInfo("Arch init done\n");
        vga.init();
        tty.init();

        log.logInfo("Init done\n");
        tty.print("Hello Pluto from kernel :)\n");
    }
}
