const std = @import("std");
const expectEqual = std.testing.expectEqual;
const log = @import("log.zig");

pub const Module = struct {
    /// The region of memory occupied by the module
    region: Range,
    /// The module's name
    name: []const u8,
};

pub const Map = struct {
    /// The virtual range to reserve
    virtual: Range,
    /// The physical range to map to, if any
    physical: ?Range,
};

/// A range of memory
pub const Range = struct {
    /// The start of the range, inclusive
    start: usize,
    /// The end of the range, exclusive
    end: usize,
};

pub const MemProfile = struct {
    /// The virtual end address of the kernel code.
    vaddr_end: [*]u8,

    /// The virtual end address of the kernel code.
    vaddr_start: [*]u8,

    /// The physical end address of the kernel code.
    physaddr_end: [*]u8,

    /// The physical start address of the kernel code.
    physaddr_start: [*]u8,

    /// The amount of memory in the system, in kilobytes.
    mem_kb: usize,

    /// The modules loaded into memory at boot.
    modules: []Module,

    /// The virtual regions of reserved memory. Should not include what is tracked by the vaddr_* fields but should include the regions occupied by the modules. These are reserved and mapped by the VMM
    virtual_reserved: []Map,

    /// The physical regions of reserved memory. Should not include what is tracked by the physaddr_* fields but should include the regions occupied by the modules. These are reserved by the PMM
    physical_reserved: []Range,

    /// The allocator to use before a heap can be set up.
    fixed_allocator: std.heap.FixedBufferAllocator,
};

/// The size of the fixed allocator used before the heap is set up. Set to 1MiB.
pub const FIXED_ALLOC_SIZE: usize = 1024 * 1024;

/// The kernel's virtual address offset. It's assigned in the init function and this file's tests.
/// We can't just use KERNEL_ADDR_OFFSET since using externs in the virtToPhys test is broken in
/// release-safe. This is a workaround until that is fixed.
pub var ADDR_OFFSET: usize = undefined;

///
/// Convert a virtual address to its physical counterpart by subtracting the kernel virtual offset from the virtual address.
///
/// Arguments:
///     IN virt: anytype - The virtual address to covert. Either an integer or pointer.
///
/// Return: @TypeOf(virt)
///     The physical address.
///
pub fn virtToPhys(virt: anytype) @TypeOf(virt) {
    const T = @TypeOf(virt);
    return switch (@typeInfo(T)) {
        .Pointer => @intToPtr(T, @ptrToInt(virt) - ADDR_OFFSET),
        .Int => virt - ADDR_OFFSET,
        else => @compileError("Only pointers and integers are supported"),
    };
}

///
/// Convert a physical address to its virtual counterpart by adding the kernel virtual offset to the physical address.
///
/// Arguments:
///     IN phys: anytype - The physical address to covert. Either an integer or pointer.
///
/// Return: @TypeOf(virt)
///     The virtual address.
///
pub fn physToVirt(phys: anytype) @TypeOf(phys) {
    const T = @TypeOf(phys);
    return switch (@typeInfo(T)) {
        .Pointer => @intToPtr(T, @ptrToInt(phys) + ADDR_OFFSET),
        .Int => phys + ADDR_OFFSET,
        else => @compileError("Only pointers and integers are supported"),
    };
}

test "physToVirt" {
    ADDR_OFFSET = 0xC0000000;
    const offset: usize = ADDR_OFFSET;
    expectEqual(physToVirt(@as(usize, 0)), offset + 0);
    expectEqual(physToVirt(@as(usize, 123)), offset + 123);
    expectEqual(@ptrToInt(physToVirt(@intToPtr(*align(1) usize, 123))), offset + 123);
}

test "virtToPhys" {
    ADDR_OFFSET = 0xC0000000;
    const offset: usize = ADDR_OFFSET;
    expectEqual(virtToPhys(offset + 0), 0);
    expectEqual(virtToPhys(offset + 123), 123);
    expectEqual(@ptrToInt(virtToPhys(@intToPtr(*align(1) usize, offset + 123))), 123);
}
