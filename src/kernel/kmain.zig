// Zig version: 0.4.0

const builtin = @import("builtin");
const arch = if (builtin.is_test) @import("../../test/kernel/arch_mock.zig") else @import("arch.zig");
const multiboot = @import("multiboot.zig");
const tty = @import("tty.zig");
const vga = @import("vga.zig");

pub fn panic(msg: []const u8, error_return_trace: ?*builtin.StackTrace) noreturn {
    @setCold(true);
    tty.print("\nKERNEL PANIC: {}\n", msg);
    while (true) {}
}

pub export fn kmain(mb_info: *multiboot.multiboot_info_t, mb_magic: u32) void {
    if (mb_magic == multiboot.MULTIBOOT_BOOTLOADER_MAGIC) {
        // Booted with compatible bootloader
        arch.init();
        vga.init();
        tty.init();
        tty.print("\nHello Pluto from kernel :)\n");
    }
}
