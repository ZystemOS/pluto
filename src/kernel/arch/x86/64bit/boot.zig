const std = @import("std");
const stivale2 = @import("stivale2.zig");
const arch = @import("arch.zig");

/// The Stivale2 header used by the Limine bootloader to load the kernel with additional options.
const Header = packed struct {
    /// The kernel entry point or 0 for entry point of Elf file.
    entry_point: u64,
    /// The stack address.
    stack: *u8,
    /// Unused flags
    flags: u64,
    /// Pointer to the linked list of tags.
    tags: u64,
};

/// The kernels stack size.
const stack_size: usize = 16 * 1024;

/// The kernels stack.
export var kernel_stack: [stack_size]u8 align(64) linksection(".bss.stack") = undefined;

/// The Stivale2 header.
export var stivale_header align(4) linksection(".stivale2hdr") = Header{
    .entry_point = 0,
    .stack = &kernel_stack[stack_size - 1],
    .flags = 0,
    .tags = 0,
};

extern fn kmain(mb_info: *const arch.BootPayload) void;

///
/// Parse the Stivale2 structure provided by the Limine bootloader into the boot payload.
///
/// Arguments:
///     IN stivale_info: *stivale2.stivale2_struct - Pointer to the Stivale2 structure.
///
/// Return: arch.BootPayload
///     The parsed structure into the architecture boot payload.
///
fn parseStivale(stivale_info: *stivale2.stivale2_struct) arch.BootPayload {
    var ret = arch.BootPayload{};
    if (stivale_info.tags != 0) {
        var tag: *stivale2.stivale2_tag = undefined;
        var raw_tag = stivale_info.tags;
        while (raw_tag != 0) : (raw_tag = tag.next) {
            tag = @intToPtr(*stivale2.stivale2_tag, raw_tag);
            switch (tag.identifier) {
                stivale2.STIVALE2_STRUCT_TAG_CMDLINE_ID => {
                    const cast_cmdline = @ptrCast(*stivale2.stivale2_struct_tag_cmdline, tag);
                    const cmd = std.mem.span(@intToPtr([*c]const u8, cast_cmdline.cmdline));
                    if (cmd.len != 0) {
                        ret.command_line = .{
                            .cmdline = cmd[0..cmd.len],
                        };
                    }
                },
                stivale2.STIVALE2_STRUCT_TAG_MEMMAP_ID => {
                    const cast_mmap = @ptrCast(*stivale2.stivale2_struct_tag_memmap, tag);
                    ret.memmap = @intToPtr([*]arch.MemMapEntry, @ptrToInt(&cast_mmap.memmap))[0..cast_mmap.entries];
                },
                stivale2.STIVALE2_STRUCT_TAG_FRAMEBUFFER_ID => {
                    ret.frame_buffer = @intToPtr(*arch.FrameBuffer, @ptrToInt(tag) + 16).*;
                },
                stivale2.STIVALE2_STRUCT_TAG_MODULES_ID => {
                    const cast_module = @ptrCast(*stivale2.stivale2_struct_tag_modules, tag);
                    ret.modules = @intToPtr([*]arch.Module, @ptrToInt(&cast_module.modules))[0..cast_module.module_count];
                },
                stivale2.STIVALE2_STRUCT_TAG_RSDP_ID => {
                    const cast_rsdp = @ptrCast(*stivale2.stivale2_struct_tag_rsdp, tag);
                    ret.rsdp_addr = cast_rsdp.rsdp;
                },
                stivale2.STIVALE2_STRUCT_TAG_EPOCH_ID => {
                    const cast_epoch = @ptrCast(*stivale2.stivale2_struct_tag_epoch, tag);
                    ret.epoch = cast_epoch.epoch;
                },
                stivale2.STIVALE2_STRUCT_TAG_FIRMWARE_ID => {
                    const cast_firmware = @ptrCast(*stivale2.stivale2_struct_tag_firmware, tag);
                    ret.firmware_flags = cast_firmware.flags;
                },
                stivale2.STIVALE2_STRUCT_TAG_SMP_ID => {
                    const cast_smp = @ptrCast(*stivale2.stivale2_struct_tag_smp, tag);
                    ret.smp = .{
                        .flags = cast_smp.flags,
                        .bsp_lapic_id = cast_smp.bsp_lapic_id,
                        .cpu_count = cast_smp.cpu_count,
                        .smp_info = @intToPtr([*]arch.SMPInfo, @ptrToInt(&cast_smp.smp_info))[0..cast_smp.cpu_count],
                    };
                },
                else => undefined,
            }
        }
    }
    return ret;
}

///
/// The entry point into the kernel.
///
/// Arguments:
///     IN stivale_info: *stivale2.stivale2_struct - The Stivale2 structure passed by the Limine bootloader.
///
export fn _start(stivale_info: *stivale2.stivale2_struct) align(16) linksection(".text.boot") noreturn {
    arch.disableInterrupts();
    const payload = parseStivale(stivale_info);
    kmain(&payload);
    arch.haltNoInterrupts();
}
