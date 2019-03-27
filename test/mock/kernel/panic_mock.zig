const builtin = @import("builtin");
const std = @import("std");
const MemProfile = @import("mem_mock.zig").MemProfile;

pub fn panic(trace: ?*builtin.StackTrace, comptime format: []const u8, args: var) noreturn {
    @setCold(true);
    std.debug.panic(format, args);
}

pub fn init(mem_profile: *const MemProfile, allocator: *std.mem.Allocator) !void {
    // This is never run so just return an arbitrary error to satisfy the compiler
    return error.NotNeeded;
}
