const builtin = @import("builtin");

pub const internals = switch (builtin.arch) {
    builtin.Arch.i386 => @import("arch/x86/arch.zig"),
    else => unreachable,
};
