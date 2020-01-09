const multiboot = @import("../../../src/kernel/multiboot.zig");

pub const MemProfile = struct {
    vaddr_end: [*]u8,
    vaddr_start: [*]u8,
    physaddr_end: [*]u8,
    physaddr_start: [*]u8,
    mem_kb: u32,
    fixed_alloc_size: u32,
    mem_map: []multiboot.multiboot_memory_map_t,
    boot_modules: []multiboot.multiboot_module_t,
};

// The virtual/physical start/end of the kernel code
var KERNEL_PHYSADDR_START: u32 = 0x00100000;
var KERNEL_PHYSADDR_END: u32 = 0x01000000;
var KERNEL_VADDR_START: u32 = 0xC0100000;
var KERNEL_VADDR_END: u32 = 0xC1100000;
var KERNEL_ADDR_OFFSET: u32 = 0xC0000000;

// The size of the fixed allocator used before the heap is set up. Set to 1MiB.
const FIXED_ALLOC_SIZE = 1024 * 1024;

pub fn init(mb_info: *multiboot.multiboot_info_t) MemProfile {
    return MemProfile{
        .vaddr_end = @ptrCast([*]u8, &KERNEL_VADDR_END),
        .vaddr_start = @ptrCast([*]u8, &KERNEL_VADDR_START),
        .physaddr_end = @ptrCast([*]u8, &KERNEL_PHYSADDR_END),
        .physaddr_start = @ptrCast([*]u8, &KERNEL_PHYSADDR_START),
        // Total memory available including the initial 1MiB that grub doesn't include
        .mem_kb = mb_info.mem_upper + mb_info.mem_lower + 1024,
        .fixed_alloc_size = FIXED_ALLOC_SIZE,
        .mem_map = undefined,
        .boot_modules = undefined,
    };
}

pub fn virtToPhys(virt: var) @TypeOf(virt) {
    const T = @TypeOf(virt);
    return switch (@typeInfo(T)) {
        .Pointer => @intToPtr(T, @ptrToInt(virt) - KERNEL_ADDR_OFFSET),
        .Int => virt - KERNEL_ADDR_OFFSET,
        else => @compileError("Only pointers and integers are supported"),
    };
}

pub fn physToVirt(phys: var) @TypeOf(phys) {
    const T = @TypeOf(phys);
    return switch (@typeInfo(T)) {
        .Pointer => @intToPtr(T, @ptrToInt(phys) + KERNEL_ADDR_OFFSET),
        .Int => phys + KERNEL_ADDR_OFFSET,
        else => @compileError("Only pointers and integers are supported"),
    };
}
