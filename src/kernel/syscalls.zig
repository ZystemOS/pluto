const std = @import("std");
const scheduler = @import("scheduler.zig");
const panic = @import("panic.zig").panic;
const log = std.log.scoped(.syscalls);

/// A compilation of all errors that syscall handlers could return.
pub const Error = error{OutOfMemory};

///
/// Convert an error code to an instance of Error. The conversion must be synchronised with toErrorCode
///
/// Arguments:
///     IN code: usize - The erorr code to convert
///
/// Return: Error
///     The error corresponding to the error code
///
pub fn fromErrorCode(code: usize) Error {
    return switch (code) {
        1 => Error.OutOfMemory,
        else => unreachable,
    };
}

///
/// Convert an instance of Error to an error code. The conversion must be synchronised with fromErrorCode
///
/// Arguments:
///     IN err: Error - The erorr to convert
///
/// Return: usize
///     The error code corresponding to the error
///
pub fn toErrorCode(err: Error) usize {
    return switch (err) {
        Error.OutOfMemory => 1,
    };
}

comptime {
    // Make sure toErrorCode and fromErrorCode are synchronised, and that no errors share the same error code
    inline for (@typeInfo(Error).ErrorSet.?) |err| {
        const error_instance = @field(Error, err.name);
        if (fromErrorCode(toErrorCode(error_instance)) != error_instance) {
            @compileError("toErrorCode and fromErrorCode are not synchronised for syscall error '" ++ err.name ++ "'\n");
        }
        inline for (@typeInfo(Error).ErrorSet.?) |err2| {
            const error2_instance = @field(Error, err2.name);
            if (error_instance != error2_instance and toErrorCode(error_instance) == toErrorCode(error2_instance)) {
                @compileError("Syscall errors '" ++ err.name ++ "' and '" ++ err2.name ++ "' share the same error code\n");
            }
        }
    }
}

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
};

/// A function that can handle a syscall and return a result or an error
pub const Handler = fn (arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize;

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
pub fn handle(syscall: Syscall, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize {
    return try syscall.getHandler()(arg1, arg2, arg3, arg4, arg5);
}

pub fn handleTest1(arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize {
    return 0;
}

pub fn handleTest2(arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize {
    return arg1 + arg2 + arg3 + arg4 + arg5;
}

pub fn handleTest3(arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize {
    return std.mem.Allocator.Error.OutOfMemory;
}

test "getHandler" {
    try std.testing.expectEqual(Syscall.Test1.getHandler(), handleTest1);
    try std.testing.expectEqual(Syscall.Test2.getHandler(), handleTest2);
    try std.testing.expectEqual(Syscall.Test3.getHandler(), handleTest3);
}

test "handle" {
    try std.testing.expectEqual(@as(usize, 0), try handle(.Test1, 0, 0, 0, 0, 0));
    try std.testing.expectEqual(@as(usize, 1 + 2 + 3 + 4 + 5), try handle(.Test2, 1, 2, 3, 4, 5));
    try std.testing.expectError(Error.OutOfMemory, handle(.Test3, 0, 0, 0, 0, 0));
}
