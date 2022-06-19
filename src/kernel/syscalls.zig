const std = @import("std");
const scheduler = @import("scheduler.zig");
const panic = @import("panic.zig").panic;
const log = std.log.scoped(.syscalls);
const builtin = @import("builtin");
const is_test = builtin.is_test;
const arch = if (is_test) @import("arch_mock") else @import("arch");

/// A compilation of all errors that syscall handlers could return.
pub const Error = error{OutOfMemory};

/// All implemented syscalls
pub const Syscall = enum {
    Test1,
    Test2,
    Test3,

    ///
    /// Get the handler associated with the syscall
    ///
    /// Arguments:
    ///     IN self: Syscall - The syscall to get the handler for
    ///
    /// Return: Handler
    ///     The handler that takes care of this syscall
    ///
    fn getHandler(self: @This()) Handler {
        return switch (self) {
            .Test1 => handleTest1,
            .Test2 => handleTest2,
            .Test3 => handleTest3,
        };
    }

    ///
    /// Check if the syscall is just used for testing, and therefore shouldn't be exposed at runtime
    ///
    /// Arguments:
    ///     IN self: Syscall - The syscall to check
    ///
    /// Return: bool
    ///     true if the syscall is only to be used for testing, else false
    ///
    pub fn isTest(self: @This()) bool {
        return switch (self) {
            .Test1, .Test2, .Test3 => true,
        };
    }
};

/// A function that can handle a syscall and return a result or an error
pub const Handler = fn (ctx: *const arch.CpuState, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize;

///
/// Convert an error code to an instance of Error. The conversion must be synchronised with toErrorCode
/// Passing an error code that does not correspond to an error results in safety-protected undefined behaviour
///
/// Arguments:
///     IN code: u16 - The erorr code to convert
///
/// Return: Error
///     The error corresponding to the error code
///
pub fn fromErrorCode(code: u16) anyerror {
    return @intToError(code);
}

///
/// Convert an instance of Error to an error code. The conversion must be synchronised with fromErrorCode
///
/// Arguments:
///     IN err: Error - The erorr to convert
///
/// Return: u16
///     The error code corresponding to the error
///
pub fn toErrorCode(err: anyerror) u16 {
    return @errorToInt(err);
}

///
/// Handle a syscall and return a result or error
///
/// Arguments:
///     IN syscall: Syscall - The syscall to handle
///     IN argX: usize - The xth argument that was passed to the syscall
///
/// Return: usize
///     The syscall result
///
/// Error: Error
///     The error raised by the handler
///
pub fn handle(syscall: Syscall, ctx: *const arch.CpuState, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize {
    return try syscall.getHandler()(ctx, arg1, arg2, arg3, arg4, arg5);
}

pub fn handleTest1(ctx: *const arch.CpuState, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize {
    // Suppress unused variable warnings
    _ = ctx;
    _ = arg1;
    _ = arg2;
    _ = arg3;
    _ = arg4;
    _ = arg5;
    return 0;
}

pub fn handleTest2(ctx: *const arch.CpuState, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize {
    _ = ctx;
    return arg1 + arg2 + arg3 + arg4 + arg5;
}

pub fn handleTest3(ctx: *const arch.CpuState, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize {
    // Suppress unused variable warnings
    _ = ctx;
    _ = arg1;
    _ = arg2;
    _ = arg3;
    _ = arg4;
    _ = arg5;
    return std.mem.Allocator.Error.OutOfMemory;
}

test "getHandler" {
    try std.testing.expectEqual(Syscall.Test1.getHandler(), handleTest1);
    try std.testing.expectEqual(Syscall.Test2.getHandler(), handleTest2);
    try std.testing.expectEqual(Syscall.Test3.getHandler(), handleTest3);
}

test "handle" {
    const state = arch.CpuState.empty();
    try std.testing.expectEqual(@as(usize, 0), try handle(.Test1, &state, 0, 0, 0, 0, 0));
    try std.testing.expectEqual(@as(usize, 1 + 2 + 3 + 4 + 5), try handle(.Test2, &state, 1, 2, 3, 4, 5));
    try std.testing.expectError(Error.OutOfMemory, handle(.Test3, &state, 0, 0, 0, 0, 0));
}
