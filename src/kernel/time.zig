const std = @import("std");
const builtin = std.builtin;

pub const DateTime = struct {
    second: u32,
    minute: u32,
    hour: u32,
    day: u32,
    month: u32,
    year: u32,
    century: u32,
    day_of_week: u32,
};

pub fn getDateTime() DateTime {
    return switch (builtin.os.tag) {
        .freestanding => @import("../arch.zig").internals.getDateTime(),
        // TODO: Use the std lib std.time.timestamp() and convert
        // Hard code 12:12:13 12/12/12 for testing
        // https://github.com/ziglang/zig/issues/8396
        else => .{
            .second = 13,
            .minute = 12,
            .hour = 12,
            .day = 12,
            .month = 12,
            .year = 2012,
            .century = 2000,
            .day_of_week = 4,
        },
    };
}
