const arch = @import("arch.zig");
const testing = @import("std").testing;
const assert = @import("std").debug.assert;
const isr = @import("isr.zig");
const log = @import("../../log.zig");
const options = @import("build_options");
const panic = @import("../../panic.zig").panic;

/// The isr number associated with syscalls
pub const INTERRUPT: u16 = 0x80;

/// The maximum number of syscall handlers that can be registered
pub const NUM_HANDLERS: u16 = 256;

/// A syscall handler
pub const SyscallHandler = fn (ctx: *arch.InterruptContext, arg1: u32, arg2: u32, arg3: u32, arg4: u32, arg5: u32) u32;

/// Errors that syscall utility functions can throw
pub const SyscallError = error{
    SyscallExists,
    InvalidSyscall,
};

/// The array of registered syscalls
var handlers: [NUM_HANDLERS]?SyscallHandler = [_]?SyscallHandler{null} ** NUM_HANDLERS;

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
/// handler. If there isn't a registered handler or the syscall is invalid (>= NUM_HANDLERS) then a
/// warning is logged.
///
/// Arguments:
///     IN ctx: *arch.InterruptContext - The cpu context when the syscall was triggered. The
///                                      syscall number is stored in eax.
///
fn handle(ctx: *arch.InterruptContext) void {
    // The syscall number is put in eax
    const syscall = ctx.eax;
    if (isValidSyscall(syscall)) {
        if (handlers[syscall]) |handler| {
            ctx.eax = handler(ctx, syscallArg(ctx, 0), syscallArg(ctx, 1), syscallArg(ctx, 2), syscallArg(ctx, 3), syscallArg(ctx, 4));
        } else {
            log.logWarning("Syscall {} triggered but not registered\n", .{syscall});
        }
    } else {
        log.logWarning("Syscall {} is invalid\n", .{syscall});
    }
}

///
/// Register a syscall so it can be called by triggering interrupt 128.
///
/// Arguments:
///     IN syscall: u8 - The syscall number to register the handler with.
///     IN handler: SyscallHandler - The handler to register the syscall with.
///
/// Errors:
///     SyscallError.InvalidSyscall - If the syscall is invalid (see isValidSyscall).
///     SyscallError.SyscallExists - If the syscall has already been registered.
///
pub fn registerSyscall(syscall: u8, handler: SyscallHandler) SyscallError!void {
    if (!isValidSyscall(syscall))
        return SyscallError.InvalidSyscall;
    if (handlers[syscall]) |_|
        return SyscallError.SyscallExists;
    handlers[syscall] = handler;
}

///
/// Trigger a syscall with no arguments. Returns the value put in eax by the syscall.
///
/// Arguments:
///     IN syscall: u32 - The syscall to trigger, put in eax.
///
/// Return: u32
///     The return value from the syscall.
///
inline fn syscall0(syscall: u32) u32 {
    return asm volatile (
        \\int $0x80
        : [ret] "={eax}" (-> u32)
        : [syscall] "{eax}" (syscall)
    );
}

///
/// Trigger a syscall with one argument. Returns the value put in eax by the syscall.
///
/// Arguments:
///     IN syscall: u32 - The syscall to trigger, put in eax.
///     IN arg: u32 - The argument to pass. Put in ebx.
///
/// Return: u32
///     The return value from the syscall.
///
inline fn syscall1(syscall: u32, arg: u32) u32 {
    return asm volatile (
        \\int $0x80
        : [ret] "={eax}" (-> u32)
        : [syscall] "{eax}" (syscall),
          [arg1] "{ebx}" (arg)
    );
}

///
/// Trigger a syscall with two arguments. Returns the value put in eax by the syscall.
///
/// Arguments:
///     IN syscall: u32 - The syscall to trigger, put in eax.
///     IN arg1: u32 - The first argument to pass. Put in ebx.
///     IN arg2: u32 - The second argument to pass. Put in ecx.
///
/// Return: u32
///     The return value from the syscall.
///
inline fn syscall2(syscall: u32, arg1: u32, arg2: u32) u32 {
    return asm volatile (
        \\int $0x80
        : [ret] "={eax}" (-> u32)
        : [syscall] "{eax}" (syscall),
          [arg1] "{ebx}" (arg1),
          [arg2] "{ecx}" (arg2)
    );
}

///
/// Trigger a syscall with three arguments. Returns the value put in eax by the syscall.
///
/// Arguments:
///     IN syscall: u32 - The syscall to trigger, put in eax.
///     IN arg1: u32 - The first argument to pass. Put in ebx.
///     IN arg2: u32 - The second argument to pass. Put in ecx.
///     IN arg3: u32 - The third argument to pass. Put in edx.
///
/// Return: u32
///     The return value from the syscall.
///
inline fn syscall3(syscall: u32, arg1: u32, arg2: u32, arg3: u32) u32 {
    return asm volatile (
        \\int $0x80
        : [ret] "={eax}" (-> u32)
        : [syscall] "{eax}" (syscall),
          [arg1] "{ebx}" (arg1),
          [arg2] "{ecx}" (arg2),
          [arg3] "{edx}" (arg3)
    );
}

///
/// Trigger a syscall with four arguments. Returns the value put in eax by the syscall.
///
/// Arguments:
///     IN syscall: u32 - The syscall to trigger, put in eax.
///     IN arg1: u32 - The first argument to pass. Put in ebx.
///     IN arg2: u32 - The second argument to pass. Put in ecx.
///     IN arg3: u32 - The third argument to pass. Put in edx.
///     IN arg4: u32 - The fourth argument to pass. Put in esi.
///
/// Return: u32
///     The return value from the syscall.
///
inline fn syscall4(syscall: u32, arg1: u32, arg2: u32, arg3: u32, arg4: u32) u32 {
    return asm volatile (
        \\int $0x80
        : [ret] "={eax}" (-> u32)
        : [syscall] "{eax}" (syscall),
          [arg1] "{ebx}" (arg1),
          [arg2] "{ecx}" (arg2),
          [arg3] "{edx}" (arg3),
          [arg4] "{esi}" (arg4)
    );
}

///
/// Trigger a syscall with five arguments. Returns the value put in eax by the syscall.
///
/// Arguments:
///     IN syscall: u32 - The syscall to trigger, put in eax.
///     IN arg1: u32 - The first argument to pass. Put in ebx.
///     IN arg2: u32 - The second argument to pass. Put in ecx.
///     IN arg3: u32 - The third argument to pass. Put in edx.
///     IN arg4: u32 - The fourth argument to pass. Put in esi.
///     IN arg5: u32 - The fifth argument to pass. Put in edi.
///
/// Return: u32
///     The return value from the syscall.
///
inline fn syscall5(syscall: u32, arg1: u32, arg2: u32, arg3: u32, arg4: u32, arg5: u32) u32 {
    return asm volatile (
        \\int $0x80
        : [ret] "={eax}" (-> u32)
        : [syscall] "{eax}" (syscall),
          [arg1] "{ebx}" (arg1),
          [arg2] "{ecx}" (arg2),
          [arg3] "{edx}" (arg3),
          [arg4] "{esi}" (arg4),
          [arg5] "{edi}" (arg5)
    );
}

///
/// Gets the syscall argument according to the given index. 0 => ebx, 1 => ecx, 2 => edx,
/// 3 => esi and 4 => edi.
///
/// Arguments:
///     IN ctx: *arch.InterruptContext - The interrupt context from which to get the argument
///     IN arg_idx: comptime u32 - The argument index to get. Between 0 and 4.
///
/// Return: u32
///     The syscall argument from the given index.
///
inline fn syscallArg(ctx: *arch.InterruptContext, comptime arg_idx: u32) u32 {
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
/// Initialise syscalls. Registers the isr associated with INTERRUPT.
///
pub fn init() void {
    log.logInfo("Init syscalls\n", .{});
    defer log.logInfo("Done syscalls\n", .{});

    isr.registerIsr(INTERRUPT, handle) catch unreachable;
    if (options.rt_test) runtimeTests();
}

/// Tests
var testInt: u32 = 0;

fn testHandler0(ctx: *arch.InterruptContext, arg1: u32, arg2: u32, arg3: u32, arg4: u32, arg5: u32) u32 {
    testInt += 1;
    return 0;
}

fn testHandler1(ctx: *arch.InterruptContext, arg1: u32, arg2: u32, arg3: u32, arg4: u32, arg5: u32) u32 {
    testInt += arg1;
    return 1;
}

fn testHandler2(ctx: *arch.InterruptContext, arg1: u32, arg2: u32, arg3: u32, arg4: u32, arg5: u32) u32 {
    testInt += arg1 + arg2;
    return 2;
}

fn testHandler3(ctx: *arch.InterruptContext, arg1: u32, arg2: u32, arg3: u32, arg4: u32, arg5: u32) u32 {
    testInt += arg1 + arg2 + arg3;
    return 3;
}

fn testHandler4(ctx: *arch.InterruptContext, arg1: u32, arg2: u32, arg3: u32, arg4: u32, arg5: u32) u32 {
    testInt += arg1 + arg2 + arg3 + arg4;
    return 4;
}

fn testHandler5(ctx: *arch.InterruptContext, arg1: u32, arg2: u32, arg3: u32, arg4: u32, arg5: u32) u32 {
    testInt += arg1 + arg2 + arg3 + arg4 + arg5;
    return 5;
}

test "registerSyscall returns SyscallExists" {
    registerSyscall(123, testHandler0) catch unreachable;
    registerSyscall(123, testHandler0) catch |err| {
        return;
    };
    assert(false);
}

fn runtimeTests() void {
    registerSyscall(123, testHandler0) catch panic(@errorReturnTrace(), "FAILURE\n", .{});
    registerSyscall(124, testHandler1) catch panic(@errorReturnTrace(), "FAILURE\n", .{});
    registerSyscall(125, testHandler2) catch panic(@errorReturnTrace(), "FAILURE\n", .{});
    registerSyscall(126, testHandler3) catch panic(@errorReturnTrace(), "FAILURE\n", .{});
    registerSyscall(127, testHandler4) catch panic(@errorReturnTrace(), "FAILURE\n", .{});
    registerSyscall(128, testHandler5) catch panic(@errorReturnTrace(), "FAILURE\n", .{});

    if (testInt != 0) {
        panic(@errorReturnTrace(), "FAILURE\n", .{});
    }

    if (syscall0(123) != 0 or testInt != 1) {
        panic(@errorReturnTrace(), "FAILURE\n", .{});
    }

    if (syscall1(124, 2) != 1 or testInt != 3) {
        panic(@errorReturnTrace(), "FAILURE\n", .{});
    }

    if (syscall2(125, 2, 3) != 2 or testInt != 8) {
        panic(@errorReturnTrace(), "FAILURE\n", .{});
    }

    if (syscall3(126, 2, 3, 4) != 3 or testInt != 17) {
        panic(@errorReturnTrace(), "FAILURE\n", .{});
    }

    if (syscall4(127, 2, 3, 4, 5) != 4 or testInt != 31) {
        panic(@errorReturnTrace(), "FAILURE\n", .{});
    }

    if (syscall5(128, 2, 3, 4, 5, 6) != 5 or testInt != 51) {
        panic(@errorReturnTrace(), "FAILURE\n", .{});
    }

    log.logInfo("Syscall: Tested all args\n", .{});
}
