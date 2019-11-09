const multiboot = @import("multiboot.zig");
const std = @import("std");
const expectEqual = std.testing.expectEqual;
const log = @import("log.zig");

pub const MemProfile = struct {
    vaddr_end: [*]u8,
    vaddr_start: [*]u8,
    physaddr_end: [*]u8,
    physaddr_start: [*]u8,
    mem_kb: u32,
    fixed_alloc_size: u32,
    boot_modules: []multiboot.multiboot_module_t,
};

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

/// The size of the fixed allocator used before the heap is set up. Set to 1MiB.
const FIXED_ALLOC_SIZE = 1024 * 1024;

/// The kernel's virtual address offset. It's assigned in the init function and this file's tests.
/// We can't just use KERNEL_ADDR_OFFSET since using externs in the virtToPhys test is broken in
/// release-safe. This is a workaround until that is fixed.
var ADDR_OFFSET: usize = undefined;

///
/// Initialise the system's memory profile based on linker symbols and the multiboot info struct.
///
/// Arguments:
///     IN mb_info: *multiboot.multiboot_info_t - The multiboot info passed by the bootloader.
///
/// Return: MemProfile
///     The memory profile constructed from the exported linker symbols and the relevant multiboot info.
///
pub fn init(mb_info: *multiboot.multiboot_info_t) MemProfile {
    log.logInfo("Init mem\n");
    const mods_count = mb_info.mods_count;
    ADDR_OFFSET = @ptrToInt(&KERNEL_ADDR_OFFSET);
    const mem_profile = MemProfile{
        .vaddr_end = @ptrCast([*]u8, &KERNEL_VADDR_END),
        .vaddr_start = @ptrCast([*]u8, &KERNEL_VADDR_START),
        .physaddr_end = @ptrCast([*]u8, &KERNEL_PHYSADDR_END),
        .physaddr_start = @ptrCast([*]u8, &KERNEL_PHYSADDR_START),
        // Total memory available including the initial 1MiB that grub doesn't include
        .mem_kb = mb_info.mem_upper + mb_info.mem_lower + 1024,
        .fixed_alloc_size = FIXED_ALLOC_SIZE,
        .boot_modules = @intToPtr([*]multiboot.multiboot_mod_list, physToVirt(mb_info.mods_addr))[0..mods_count],
    };
    log.logInfo("Done\n");
    return mem_profile;
}

///
/// Convert a virtual address to its physical counterpart by subtracting the kernel virtual offset from the virtual address.
///
/// Arguments:
///     IN virt: var - The virtual address to covert. Either an integer or pointer.
///
/// Return: @typeOf(virt)
///     The physical address.
///
pub inline fn virtToPhys(virt: var) @typeOf(virt) {
    const T = @typeOf(virt);
    return switch (@typeId(T)) {
        .Pointer => @intToPtr(T, @ptrToInt(virt) - ADDR_OFFSET),
        .Int => virt - ADDR_OFFSET,
        else => @compileError("Only pointers and integers are supported"),
    };
}

///
/// Convert a physical address to its virtual counterpart by adding the kernel virtual offset to the physical address.
///
/// Arguments:
///     IN phys: var - The physical address to covert. Either an integer or pointer.
///
/// Return: @typeOf(virt)
///     The virtual address.
///
pub inline fn physToVirt(phys: var) @typeOf(phys) {
    const T = @typeOf(phys);
    return switch (@typeId(T)) {
        .Pointer => @intToPtr(T, @ptrToInt(phys) + ADDR_OFFSET),
        .Int => phys + ADDR_OFFSET,
        else => @compileError("Only pointers and integers are supported"),
    };
}

test "physToVirt" {
    ADDR_OFFSET = 0xC0000000;
    const offset: usize = ADDR_OFFSET;
    expectEqual(physToVirt(usize(0)), offset + 0);
    expectEqual(physToVirt(usize(123)), offset + 123);
    expectEqual(@ptrToInt(physToVirt(@intToPtr(*usize, 123))), offset + 123);
}

test "virtToPhys" {
    ADDR_OFFSET = 0xC0000000;
    const offset: usize = ADDR_OFFSET;
    expectEqual(virtToPhys(offset + 0), 0);
    expectEqual(virtToPhys(offset + 123), 123);
    expectEqual(@ptrToInt(virtToPhys(@intToPtr(*usize, offset + 123))), 123);
}
