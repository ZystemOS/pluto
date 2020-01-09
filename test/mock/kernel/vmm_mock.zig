const mem = @import("mem_mock.zig");
const multiboot = @import("../../../src/kernel/multiboot.zig");
const arch = @import("arch_mock.zig");
const std = @import("std");

pub fn Mapper(comptime Payload: type) type {
    return struct {};
}

pub fn VirtualMemoryManager(comptime Payload: type) type {
    return struct {};
}

pub fn init(mem_profile: *const mem.MemProfile, mb_info: *multiboot.multiboot_info_t, allocator: *std.mem.Allocator) std.mem.Allocator.Error!VirtualMemoryManager(arch.VmmPayload) {
    return std.mem.Allocator.Error.OutOfMemory;
}
