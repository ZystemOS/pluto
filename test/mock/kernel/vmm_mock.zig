const mem = @import("mem_mock.zig");
const bitmap = @import("../../../src/kernel/bitmap.zig");
const vmm = @import("../../../src/kernel/vmm.zig");
const arch = @import("arch_mock.zig");
const std = @import("std");

pub const VmmError = error{
    /// A memory region expected to be allocated wasn't
    NotAllocated,
};

pub const Attributes = vmm.Attributes;

pub const BLOCK_SIZE: u32 = 1024;

pub const Mapper = vmm.Mapper;

pub const MapperError = error{
    InvalidVirtualAddress,
    InvalidPhysicalAddress,
    AddressMismatch,
    MisalignedVirtualAddress,
    MisalignedPhysicalAddress,
    NotMapped,
};

pub var kernel_vmm: VirtualMemoryManager(arch.VmmPayload) = undefined;

pub fn VirtualMemoryManager(comptime Payload: type) type {
    return struct {
        const Self = @This();

        pub fn init(start: usize, end: usize, allocator: *std.mem.Allocator, mapper: Mapper(Payload), payload: Payload) std.mem.Allocator.Error!Self {
            return Self{};
        }

        pub fn virtToPhys(self: *const Self, virt: usize) VmmError!usize {
            return 0;
        }

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
