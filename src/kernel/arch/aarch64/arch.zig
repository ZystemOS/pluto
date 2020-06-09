const std = @import("std");
const vmm = @import("../../vmm.zig");
const mem = @import("../../mem.zig");
const rpi = @import("rpi.zig");
/// The type of the payload passed to a virtual memory mapper.
// TODO: implement
pub const VmmPayload = usize;
pub const BootPayload = *const rpi.RaspberryPiBoard;

// TODO: implement
pub const MEMORY_BLOCK_SIZE: usize = 4 * 1024;

// TODO: implement
pub const VMM_MAPPER: vmm.Mapper(VmmPayload) = vmm.Mapper(VmmPayload){ .mapFn = undefined, .unmapFn = undefined };

// TODO: implement
pub const KERNEL_VMM_PAYLOAD: VmmPayload = 0;

pub fn initMem(payload: BootPayload) std.mem.Allocator.Error!mem.MemProfile {
    // TODO: implement
    mem.ADDR_OFFSET = 0;
    return mem.MemProfile{ .vaddr_end = @intToPtr([*]u8, 0x12345678), .vaddr_start = @intToPtr([*]u8, 0x12345678), .physaddr_start = @intToPtr([*]u8, 0x12345678), .physaddr_end = @intToPtr([*]u8, 0x12345678), .mem_kb = 0, .modules = &[_]mem.Module{}, .virtual_reserved = &[_]mem.Map{}, .physical_reserved = &[_]mem.Range{}, .fixed_allocator = undefined };
}

// TODO: implement
pub fn init(payload: BootPayload, mem_profile: *const mem.MemProfile, allocator: *std.mem.Allocator) void {}

// TODO: implement
pub fn inb(port: u32) u8 {
    return 0;
}

// TODO: implement
pub fn outb(port: u32, byte: u8) void {}

// TODO: implement
pub fn halt() noreturn {
    while (true) {}
}

// TODO: implement
pub fn haltNoInterrupts() noreturn {
    while (true) {}
}
