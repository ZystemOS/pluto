const std = @import("std");
const multiboot = @import("../../../src/kernel/multiboot.zig");

pub const Module = struct {
    region: Range,
    name: []const u8,
};

pub const Map = struct {
    virtual: Range,
    physical: ?Range,
};

pub const Range = struct {
    start: usize,
    end: usize,
};

pub const MemProfile = struct {
    vaddr_end: [*]u8,
    vaddr_start: [*]u8,
    physaddr_end: [*]u8,
    physaddr_start: [*]u8,
    mem_kb: u32,
    modules: []Module,
    virtual_reserved: []Map,
    physical_reserved: []Range,
    fixed_allocator: std.heap.FixedBufferAllocator,
};

// The size of the fixed allocator used before the heap is set up. Set to 1MiB.
const FIXED_ALLOC_SIZE = 1024 * 1024;

pub fn virtToPhys(virt: anytype) @TypeOf(virt) {
    const T = @TypeOf(virt);
    return switch (@typeInfo(T)) {
        .Pointer => @intToPtr(T, @ptrToInt(virt) - KERNEL_ADDR_OFFSET),
        .Int => virt - KERNEL_ADDR_OFFSET,
        else => @compileError("Only pointers and integers are supported"),
    };
}

pub fn physToVirt(phys: anytype) @TypeOf(phys) {
    const T = @TypeOf(phys);
    return switch (@typeInfo(T)) {
        .Pointer => @intToPtr(T, @ptrToInt(phys) + KERNEL_ADDR_OFFSET),
        .Int => phys + KERNEL_ADDR_OFFSET,
        else => @compileError("Only pointers and integers are supported"),
    };
}
