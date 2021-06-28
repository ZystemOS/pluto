const std = @import("std");
const builtin = std.builtin;
const is_test = builtin.is_test;
const build_options = @import("build_options");

pub const internals = if (is_test) @import("../../test/mock/kernel/arch_mock.zig") else switch (builtin.cpu.arch) {
    .i386 => @import("arch/x86/arch.zig"),
    else => unreachable,
};

test "" {
    _ = @import("arch/x86/arch.zig");
}
