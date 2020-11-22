const std = @import("std");
const log = std.log.scoped(.x86_syscalls);
const builtin = @import("builtin");
const is_test = builtin.is_test;
const build_options = @import("build_options");
const mock_path = build_options.arch_mock_path;
const arch = if (is_test) @import(mock_path ++ "arch_mock.zig") else @import("arch.zig");
const testing = std.testing;
const expect = std.testing.expect;
const isr = @import("isr.zig");
const panic = @import("../../panic.zig").panic;
const syscalls = @import("../../syscalls.zig");

/// The isr number associated with syscalls
pub const INTERRUPT: u16 = 0x80;

/// The maximum number of syscall handlers that can be registered
pub const NUM_HANDLERS: u16 = 256;

/// A syscall handler
pub const Handler = fn (ctx: *arch.CpuState, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) syscalls.Error!usize;

/// Errors that syscall utility functions can throw
pub const Error = error{
    SyscallExists,
    InvalidSyscall,
};

comptime {
    std.debug.assert(@typeInfo(syscalls.Syscall).Enum.fields.len <= NUM_HANDLERS);
}

/// The array of registered syscalls
var handlers: [NUM_HANDLERS]?Handler = [_]?Handler{null} ** NUM_HANDLERS;

///
/// Returns true if the syscall is valid, else false.
/// A syscall is valid if it's less than NUM_HANDLERS.
///
/// Arguments:
///     IN syscall: u32 - The syscall to check
///
/// Return: bool
///     Whether the syscall number is valid.
///
pub fn isValidSyscall(syscall: u32) bool {
    return syscall < NUM_HANDLERS;
}

///
/// Handle a syscall. Gets the syscall number from eax within the context and calls the registered
/// handler. If an error occurs ebx will be set to its error code, or 0 otherwise.
/// The syscall result will be stored in eax. If there isn't a registered handler or the syscall is
/// invalid (>= NUM_HANDLERS) then a warning is logged.
///
/// Arguments:
///     IN ctx: *arch.CpuState - The cpu context when the syscall was triggered. The
///                                      syscall number is stored in eax.
///
/// Return: usize
///     The new stack pointer value
///
fn handle(ctx: *arch.CpuState) usize {
    // The syscall number is put in eax
    const syscall = ctx.eax;
    if (isValidSyscall(syscall)) {
        if (handlers[syscall]) |handler| {
            const result = handler(ctx, syscallArg(ctx, 0), syscallArg(ctx, 1), syscallArg(ctx, 2), syscallArg(ctx, 3), syscallArg(ctx, 4));
            if (result) |res| {
                ctx.eax = res;
                ctx.ebx = 0;
            } else |e| {
                ctx.ebx = syscalls.toErrorCode(e);
            }
        } else {
            log.warn("Syscall {} triggered but not registered\n", .{syscall});
        }
    } else {
        log.warn("Syscall {} is invalid\n", .{syscall});
    }
    return @ptrToInt(ctx);
}

///
/// Register a syscall so it can be called by triggering interrupt 128 and putting its number in eax.
///
/// Arguments:
///     IN syscall: usize - The syscall to register the handler with.
///     IN handler: Handler - The handler to register the syscall with.
///
/// Errors: Error
///     Error.SyscallExists - If the syscall has already been registered.
///     Error.InvalidSyscall - If the syscall is invalid. See isValidSyscall.
///
pub fn registerSyscall(syscall: usize, handler: Handler) Error!void {
    if (!isValidSyscall(syscall))
        return Error.InvalidSyscall;
    if (handlers[syscall]) |_|
        return Error.SyscallExists;
    handlers[syscall] = handler;
}

///
/// Trigger a syscall with no arguments. Returns the value put in eax by the syscall or the error returned in ebx.
///
/// Arguments:
///     IN syscall: usize - The syscall to trigger, put in eax.
///
/// Return: usize
///     The return value from the syscall.
///
/// Error: syscalls.Error
///     This function will return the error that the syscall handler returns. See the documentation for the syscall for details.
///
inline fn syscall0(syscall: usize) syscalls.Error!usize {
    const res = asm volatile (
        \\int $0x80
        : [ret] "={eax}" (-> usize)
        : [syscall] "{eax}" (syscall)
        : "ebx"
    );
    const err = asm (""
        : [ret] "={ebx}" (-> usize)
    );
    if (err != 0) {
        return syscalls.fromErrorCode(err);
    }
    return res;
}

///
/// Trigger a syscall with one argument. Returns the value put in eax by the syscall or the error returned in ebx.
///
/// Arguments:
///     IN syscall: usize - The syscall to trigger, put in eax.
///     IN arg: usize - The argument to pass. Put in ebx.
///
/// Return: usize
///     The return value from the syscall.
///
/// Error: syscalls.Error
///     This function will return the error that the syscall handler returns. See the documentation for the syscall for details.
///
inline fn syscall1(syscall: usize, arg: usize) syscalls.Error!usize {
    const res = asm volatile (
        \\int $0x80
        : [ret] "={eax}" (-> usize)
        : [syscall] "{eax}" (syscall),
          [arg1] "{ebx}" (arg)
    );
    const err = asm (""
        : [ret] "={ebx}" (-> usize)
    );
    if (err != 0) {
        return syscalls.fromErrorCode(err);
    }
    return res;
}

///
/// Trigger a syscall with two arguments. Returns the value put in eax by the syscall or the error returned in ebx.
///
/// Arguments:
///     IN syscall: usize - The syscall to trigger, put in eax.
///     IN arg1: usize - The first argument to pass. Put in ebx.
///     IN arg2: usize - The second argument to pass. Put in ecx.
///
/// Return: usize
///     The return value from the syscall.
///
/// Error: syscalls.Error
///     This function will return the error that the syscall handler returns. See the documentation for the syscall for details.
///
inline fn syscall2(syscall: usize, arg1: usize, arg2: usize) syscalls.Error!usize {
    const res = asm volatile (
        \\int $0x80
        : [ret] "={eax}" (-> usize)
        : [syscall] "{eax}" (syscall),
          [arg1] "{ebx}" (arg1),
          [arg2] "{ecx}" (arg2)
    );
    const err = asm (""
        : [ret] "={ebx}" (-> usize)
    );
    if (err != 0) {
        return syscalls.fromErrorCode(err);
    }
    return res;
}

///
/// Trigger a syscall with three arguments. Returns the value put in eax by the syscall or the error returned in ebx.
///
/// Arguments:
///     IN syscall: usize - The syscall to trigger, put in eax.
///     IN arg1: usize - The first argument to pass. Put in ebx.
///     IN arg2: usize - The second argument to pass. Put in ecx.
///     IN arg3: usize - The third argument to pass. Put in edx.
///
/// Return: usize
///     The return value from the syscall.
///
/// Error: syscalls.Error
///     This function will return the error that the syscall handler returns. See the documentation for the syscall for details.
///
inline fn syscall3(syscall: usize, arg1: usize, arg2: usize, arg3: usize) syscalls.Error!usize {
    const res = asm volatile (
        \\int $0x80
        : [ret] "={eax}" (-> usize)
        : [syscall] "{eax}" (syscall),
          [arg1] "{ebx}" (arg1),
          [arg2] "{ecx}" (arg2),
          [arg3] "{edx}" (arg3)
    );
    const err = asm (""
        : [ret] "={ebx}" (-> usize)
    );
    if (err != 0) {
        return syscalls.fromErrorCode(err);
    }
    return res;
}

///
/// Trigger a syscall with four arguments. Returns the value put in eax by the syscall or the error returned in ebx.
///
/// Arguments:
///     IN syscall: usize - The syscall to trigger, put in eax.
///     IN arg1: usize - The first argument to pass. Put in ebx.
///     IN arg2: usize - The second argument to pass. Put in ecx.
///     IN arg3: usize - The third argument to pass. Put in edx.
///     IN arg4: usize - The fourth argument to pass. Put in esi.
///
/// Return: usize
///     The return value from the syscall.
///
/// Error: syscalls.Error
///     This function will return the error that the syscall handler returns. See the documentation for the syscall for details.
///
inline fn syscall4(syscall: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) syscalls.Error!usize {
    const res = asm volatile (
        \\int $0x80
        : [ret] "={eax}" (-> usize)
        : [syscall] "{eax}" (syscall),
          [arg1] "{ebx}" (arg1),
          [arg2] "{ecx}" (arg2),
          [arg3] "{edx}" (arg3),
          [arg4] "{esi}" (arg4)
    );
    const err = asm (""
        : [ret] "={ebx}" (-> usize)
    );
    if (err != 0) {
        return syscalls.fromErrorCode(err);
    }
    return res;
}

///
/// Trigger a syscall with five arguments. Returns the value put in eax by the syscall or the error returned in ebx.
///
/// Arguments:
///     IN syscall: usize - The syscall to trigger, put in eax.
///     IN arg1: usize - The first argument to pass. Put in ebx.
///     IN arg2: usize - The second argument to pass. Put in ecx.
///     IN arg3: usize - The third argument to pass. Put in edx.
///     IN arg4: usize - The fourth argument to pass. Put in esi.
///     IN arg5: usize - The fifth argument to pass. Put in edi.
///
/// Return: usize
///     The return value from the syscall.
///
/// Error: syscalls.Error
///     This function will return the error that the syscall handler returns. See the documentation for the syscall for details.
///
inline fn syscall5(syscall: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) syscalls.Error!usize {
    const res = asm volatile (
        \\int $0x80
        : [ret] "={eax}" (-> usize)
        : [syscall] "{eax}" (syscall),
          [arg1] "{ebx}" (arg1),
          [arg2] "{ecx}" (arg2),
          [arg3] "{edx}" (arg3),
          [arg4] "{esi}" (arg4),
          [arg5] "{edi}" (arg5)
    );
    const err = asm (""
        : [ret] "={ebx}" (-> usize)
    );
    if (err != 0) {
        return syscalls.fromErrorCode(err);
    }
    return res;
}

///
/// Gets the syscall argument according to the given index. 0 => ebx, 1 => ecx, 2 => edx,
/// 3 => esi and 4 => edi.
///
/// Arguments:
///     IN ctx: *arch.CpuState - The interrupt context from which to get the argument
///     IN arg_idx: comptime u32 - The argument index to get. Between 0 and 4.
///
/// Return: usize
///     The syscall argument from the given index.
///
inline fn syscallArg(ctx: *arch.CpuState, comptime arg_idx: u32) usize {
    return switch (arg_idx) {
        0 => ctx.ebx,
        1 => ctx.ecx,
        2 => ctx.edx,
        3 => ctx.esi,
        4 => ctx.edi,
        else => @compileError("Arg index must be between 0 and 4"),
    };
}

///
/// Construct a handler for a syscall.
///
/// Arguments:
///     IN comptime syscall: Syscall - The syscall to construct the handler for.
///
/// Return: Handler
///     The handler function constructed.
///
fn makeHandler(comptime syscall: syscalls.Syscall) Handler {
    return struct {
        fn func(ctx: *arch.CpuState, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) syscalls.Error!usize {
            return syscalls.handle(syscall, arg1, arg2, arg3, arg4, arg5);
        }
    }.func;
}

///
/// Initialise syscalls. Registers the isr associated with INTERRUPT and sets up handlers for each syscall.
///
pub fn init() void {
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});

    isr.registerIsr(INTERRUPT, handle) catch |e| {
        panic(@errorReturnTrace(), "Failed to register syscall ISR: {}\n", .{e});
    };

    inline for (std.meta.fields(syscalls.Syscall)) |field| {
        const syscall = @intToEnum(syscalls.Syscall, field.value);
        registerSyscall(field.value, makeHandler(syscall)) catch |e| {
            panic(@errorReturnTrace(), "Failed to register syscall for '" ++ field.name ++ "': {}\n", .{e});
        };
    }

    switch (build_options.test_mode) {
        .Initialisation => runtimeTests(),
        else => {},
    }
}

/// Tests
var test_int: u32 = 0;

fn testHandler0(ctx: *arch.CpuState, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) syscalls.Error!usize {
    test_int += 1;
    return 0;
}

fn testHandler1(ctx: *arch.CpuState, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) syscalls.Error!usize {
    test_int += arg1;
    return 1;
}

fn testHandler2(ctx: *arch.CpuState, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) syscalls.Error!usize {
    test_int += arg1 + arg2;
    return 2;
}

fn testHandler3(ctx: *arch.CpuState, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) syscalls.Error!usize {
    test_int += arg1 + arg2 + arg3;
    return 3;
}

fn testHandler4(ctx: *arch.CpuState, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) syscalls.Error!usize {
    test_int += arg1 + arg2 + arg3 + arg4;
    return 4;
}

fn testHandler5(ctx: *arch.CpuState, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) syscalls.Error!usize {
    test_int += arg1 + arg2 + arg3 + arg4 + arg5;
    return 5;
}

fn testHandler6(ctx: *arch.CpuState, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) syscalls.Error!usize {
    return syscalls.Error.OutOfMemory;
}

test "registerSyscall returns SyscallExists" {
    try registerSyscall(122, testHandler0);
    std.testing.expectError(Error.SyscallExists, registerSyscall(122, testHandler0));
}

fn runtimeTests() void {
    registerSyscall(121, testHandler6) catch |e| panic(@errorReturnTrace(), "FAILURE registering handler 6: {}\n", .{e});
    registerSyscall(122, testHandler0) catch |e| panic(@errorReturnTrace(), "FAILURE registering handler 0: {}\n", .{e});
    registerSyscall(123, testHandler1) catch |e| panic(@errorReturnTrace(), "FAILURE registering handler 1: {}\n", .{e});
    registerSyscall(124, testHandler2) catch |e| panic(@errorReturnTrace(), "FAILURE registering handler 2: {}\n", .{e});
    registerSyscall(125, testHandler3) catch |e| panic(@errorReturnTrace(), "FAILURE registering handler 3: {}\n", .{e});
    registerSyscall(126, testHandler4) catch |e| panic(@errorReturnTrace(), "FAILURE registering handler 4: {}\n", .{e});
    registerSyscall(127, testHandler5) catch |e| panic(@errorReturnTrace(), "FAILURE registering handler 5: {}\n", .{e});

    if (test_int != 0) {
        panic(@errorReturnTrace(), "FAILURE initial test_int not 0: {}\n", .{test_int});
    }

    if (syscall0(122)) |res| {
        if (res != 0 or test_int != 1) {
            panic(@errorReturnTrace(), "FAILURE syscall0\n", .{});
        }
    } else |e| {
        panic(@errorReturnTrace(), "FAILURE syscall0 errored: {}\n", .{e});
    }

    if (syscall1(123, 2)) |res| {
        if (res != 1 or test_int != 3) {
            panic(@errorReturnTrace(), "FAILURE syscall1\n", .{});
        }
    } else |e| {
        panic(@errorReturnTrace(), "FAILURE syscall1 errored: {}\n", .{e});
    }

    if (syscall2(124, 2, 3)) |res| {
        if (res != 2 or test_int != 8) {
            panic(@errorReturnTrace(), "FAILURE syscall2\n", .{});
        }
    } else |e| {
        panic(@errorReturnTrace(), "FAILURE syscall2 errored: {}\n", .{e});
    }

    if (syscall3(125, 2, 3, 4)) |res| {
        if (res != 3 or test_int != 17) {
            panic(@errorReturnTrace(), "FAILURE syscall3\n", .{});
        }
    } else |e| {
        panic(@errorReturnTrace(), "FAILURE syscall3 errored: {}\n", .{e});
    }

    if (syscall4(126, 2, 3, 4, 5)) |res| {
        if (res != 4 or test_int != 31) {
            panic(@errorReturnTrace(), "FAILURE syscall4\n", .{});
        }
    } else |e| {
        panic(@errorReturnTrace(), "FAILURE syscall4 errored: {}\n", .{e});
    }

    if (syscall5(127, 2, 3, 4, 5, 6)) |res| {
        if (res != 5 or test_int != 51) {
            panic(@errorReturnTrace(), "FAILURE syscall5\n", .{});
        }
    } else |e| {
        panic(@errorReturnTrace(), "FAILURE syscall5 errored: {}\n", .{e});
    }

    if (syscall0(121)) |res| {
        panic(@errorReturnTrace(), "FAILURE syscall6\n", .{});
    } else |e| {
        if (e != syscalls.Error.OutOfMemory) {
            panic(@errorReturnTrace(), "FAILURE syscall6 returned the wrong error: {}\n", .{e});
        }
    }

    log.info("Tested all args\n", .{});
}
