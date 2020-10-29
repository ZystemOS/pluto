const std = @import("std");
const builtin = @import("builtin");
const is_test = builtin.is_test;
const build_options = @import("build_options");
const mock_path = build_options.mock_path;

pub const internals = if (is_test) @import(mock_path ++ "arch_mock.zig") else switch (builtin.arch) {
    .i386 => @import("arch/x86/arch.zig"),
    .aarch64 => @import("arch/aarch64/arch.zig"),
    else => unreachable,
};

test "" {
    _ = switch (builtin.arch) {
        .i386 => @import("arch/x86/arch.zig"),
        .aarch64 => @import("arch/aarch64/arch.zig"),
        else => unreachable,
    };
}
