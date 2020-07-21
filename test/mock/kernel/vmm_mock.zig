const mem = @import("mem_mock.zig");
const bitmap = @import("../../../src/kernel/bitmap.zig");
const arch = @import("arch_mock.zig");
const std = @import("std");

pub const VmmError = error{
    /// A memory region expected to be allocated wasn't
    NotAllocated,
};

pub const Attributes = struct {
    kernel: bool,
    writable: bool,
    cachable: bool,
};
pub const BLOCK_SIZE: u32 = 1024;

pub fn Mapper(comptime Payload: type) type {
    return struct {};
}

pub fn VirtualMemoryManager(comptime Payload: type) type {
    return struct {
        const Self = @This();

        pub fn alloc(self: *Self, num: u32, attrs: Attributes) std.mem.Allocator.Error!?usize {
            return std.mem.Allocator.Error.OutOfMemory;
        }

        pub fn free(self: *Self, vaddr: usize) (bitmap.Bitmap(u32).BitmapError || VmmError)!void {
            return VmmError.NotAllocated;
        }
    };
}

pub fn init(mem_profile: *const mem.MemProfile, allocator: *std.mem.Allocator) std.mem.Allocator.Error!VirtualMemoryManager(arch.VmmPayload) {
    return std.mem.Allocator.Error.OutOfMemory;
}
