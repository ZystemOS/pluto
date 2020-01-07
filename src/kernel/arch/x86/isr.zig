const std = @import("std");
const builtin = @import("builtin");
const is_test = builtin.is_test;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const build_options = @import("build_options");
const mock_path = build_options.arch_mock_path;
const syscalls = @import("syscalls.zig");
const panic = if (is_test) @import(mock_path ++ "panic_mock.zig").panic else @import("../../panic.zig").panic;
const idt = if (is_test) @import(mock_path ++ "idt_mock.zig") else @import("idt.zig");
const arch = if (is_test) @import(mock_path ++ "arch_mock.zig") else @import("arch.zig");
const log = if (is_test) @import(mock_path ++ "log_mock.zig") else @import("../../log.zig");
const interrupts = @import("interrupts.zig");

/// The error set for the ISR. This will be from installing a ISR handler.
pub const IsrError = error{
    /// The ISR index is invalid.
    InvalidIsr,

    /// A ISR handler already exists.
    IsrExists,
};

/// The type of a ISR handler. A function that takes a interrupt context and returns void.
const IsrHandler = fn (*arch.InterruptContext) void;

/// The number of ISR entries.
const NUMBER_OF_ENTRIES: u8 = 32;

/// The exception messaged that is printed when a exception happens
const exception_msg: [NUMBER_OF_ENTRIES][]const u8 = [NUMBER_OF_ENTRIES][]const u8{
    "Divide By Zero",
    "Single Step (Debugger)",
    "Non Maskable Interrupt",
    "Breakpoint (Debugger)",
    "Overflow",
    "Bound Range Exceeded",
    "Invalid Opcode",
    "No Coprocessor, Device Not Available",
    "Double Fault",
    "Coprocessor Segment Overrun",
    "Invalid Task State Segment (TSS)",
    "Segment Not Present",
    "Stack Segment Overrun",
    "General Protection Fault",
    "Page Fault",
    "Unknown Interrupt",
    "x87 FPU Floating Point Error",
    "Alignment Check",
    "Machine Check",
    "SIMD Floating Point",
    "Virtualization",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Security",
    "Reserved",
};

/// Divide By Zero exception.
pub const DIVIDE_BY_ZERO: u8 = 0;

/// Single Step (Debugger) exception.
pub const SINGLE_STEP_DEBUG: u8 = 1;

/// Non Maskable Interrupt exception.
pub const NON_MASKABLE_INTERRUPT: u8 = 2;

/// Breakpoint (Debugger) exception.
pub const BREAKPOINT_DEBUG: u8 = 3;

/// Overflow exception.
pub const OVERFLOW: u8 = 4;

/// Bound Range Exceeded exception.
pub const BOUND_RANGE_EXCEEDED: u8 = 5;

/// Invalid Opcode exception.
pub const INVALID_OPCODE: u8 = 6;

/// No Coprocessor, Device Not Available exception.
pub const DEVICE_NOT_AVAILABLE: u8 = 7;

/// Double Fault exception.
pub const DOUBLE_FAULT: u8 = 8;

/// Coprocessor Segment Overrun exception.
pub const COPROCESSOR_SEGMENT_OVERRUN: u8 = 9;

/// Invalid Task State Segment (TSS) exception.
pub const INVALID_TASK_STATE_SEGMENT: u8 = 10;

/// Segment Not Present exception.
pub const SEGMENT_NOT_PRESENT: u8 = 11;

/// Stack Segment Overrun exception.
pub const STACK_SEGMENT_FAULT: u8 = 12;

/// General Protection Fault exception.
pub const GENERAL_PROTECTION_FAULT: u8 = 13;

/// Page Fault exception.
pub const PAGE_FAULT: u8 = 14;

/// x87 FPU Floating Point Error exception.
pub const X87_FLOAT_POINT: u8 = 16;

/// Alignment Check exception.
pub const ALIGNMENT_CHECK: u8 = 17;

/// Machine Check exception.
pub const MACHINE_CHECK: u8 = 18;

/// SIMD Floating Point exception.
pub const SIMD_FLOAT_POINT: u8 = 19;

/// Virtualisation exception.
pub const VIRTUALISATION: u8 = 20;

/// Security exception.
pub const SECURITY: u8 = 30;

/// The of exception handlers initialised to null. Need to open a ISR for these to be valid.
var isr_handlers: [NUMBER_OF_ENTRIES]?IsrHandler = [_]?IsrHandler{null} ** NUMBER_OF_ENTRIES;

/// The syscall hander.
var syscall_handler: ?IsrHandler = null;

///
/// The exception handler that each of the exceptions will call when a exception happens.
///
/// Arguments:
///     IN ctx: *arch.InterruptContext - Pointer to the exception context containing the contents
///                                      of the register at the time of the exception.
///
export fn isrHandler(ctx: *arch.InterruptContext) void {
    // Get the interrupt number
    const isr_num = ctx.int_num;

    if (isValidIsr(isr_num)) {
        if (isr_num == syscalls.INTERRUPT) {
            // A syscall, so use the syscall handler
            if (syscall_handler) |handler| {
                handler(ctx);
            } else {
                panic(@errorReturnTrace(), "Syscall handler not registered\n", .{});
            }
        } else {
            if (isr_handlers[isr_num]) |handler| {
                // Regular ISR exception, if there is one registered.
                handler(ctx);
            } else {
                panic(@errorReturnTrace(), "ISR not registered to: {}-{}\n", .{ isr_num, exception_msg[isr_num] });
            }
        }
    } else {
        panic(@errorReturnTrace(), "Invalid ISR index: {}\n", .{isr_num});
    }
}

///
/// Open an IDT entry with index and handler. This will also handle the errors.
///
/// Arguments:
///     IN index: u8                     - The IDT interrupt number.
///     IN handler: idt.InterruptHandler - The IDT handler.
///
fn openIsr(index: u8, handler: idt.InterruptHandler) void {
    idt.openInterruptGate(index, handler) catch |err| switch (err) {
        error.IdtEntryExists => {
            panic(@errorReturnTrace(), "Error opening ISR number: {} exists\n", .{index});
        },
    };
}

///
/// Checks if the isr is valid and returns true if it is, else false.
/// To be valid it must be greater than or equal to 0 and less than NUMBER_OF_ENTRIES.
///
/// Arguments:
///     IN isr_num: u16 - The isr number to check
///
/// Return: bool
///     Whether a ISR hander index if valid.
///
pub fn isValidIsr(isr_num: u32) bool {
    return isr_num < NUMBER_OF_ENTRIES or isr_num == syscalls.INTERRUPT;
}

///
/// Register an exception by setting its exception handler to the given function.
///
/// Arguments:
///     IN irq_num: u16 - The exception number to register.
///
/// Errors: IsrError
///     IsrError.InvalidIsr - If the ISR index is invalid (see isValidIsr).
///     IsrError.IsrExists  - If the ISR handler has already been registered.
///
pub fn registerIsr(isr_num: u16, handler: IsrHandler) IsrError!void {
    // Check if a valid ISR index
    if (isValidIsr(isr_num)) {
        if (isr_num == syscalls.INTERRUPT) {
            // Syscall handler
            if (syscall_handler) |_| {
                // One already registered
                return IsrError.IsrExists;
            } else {
                // Register a handler
                syscall_handler = handler;
            }
        } else {
            if (isr_handlers[isr_num]) |_| {
                // One already registered
                return IsrError.IsrExists;
            } else {
                // Register a handler
                isr_handlers[isr_num] = handler;
            }
        }
    } else {
        return IsrError.InvalidIsr;
    }
}

///
/// Initialise the exception and opening up all the IDT interrupt gates for each exception.
///
pub fn init() void {
    log.logInfo("Init isr\n", .{});

    comptime var i = 0;
    inline while (i < 32) : (i += 1) {
        openIsr(i, interrupts.getInterruptStub(i));
    }

    openIsr(syscalls.INTERRUPT, interrupts.getInterruptStub(syscalls.INTERRUPT));

    log.logInfo("Done\n", .{});

    if (build_options.rt_test) runtimeTests();
}

fn testFunction0() callconv(.Naked) void {}
fn testFunction1(ctx: *arch.InterruptContext) void {}
fn testFunction2(ctx: *arch.InterruptContext) void {}
fn testFunction3(ctx: *arch.InterruptContext) void {}
fn testFunction4(ctx: *arch.InterruptContext) void {}

test "openIsr" {
    idt.initTest();
    defer idt.freeTest();

    const index: u8 = 0;
    const handler = testFunction0;
    const ret: idt.IdtError!void = {};

    idt.addTestParams("openInterruptGate", .{ index, handler, ret });

    openIsr(index, handler);
}

test "isValidIsr" {
    comptime var i = 0;
    inline while (i < NUMBER_OF_ENTRIES) : (i += 1) {
        expectEqual(true, isValidIsr(i));
    }

    expect(isValidIsr(syscalls.INTERRUPT));

    expect(!isValidIsr(200));
}

test "registerIsr re-register syscall handler" {
    // Pre testing
    expect(null == syscall_handler);

    // Call function
    try registerIsr(syscalls.INTERRUPT, testFunction3);
    expectError(IsrError.IsrExists, registerIsr(syscalls.INTERRUPT, testFunction4));

    // Post testing
    expectEqual(testFunction3, syscall_handler.?);

    // Clean up
    syscall_handler = null;
}

test "registerIsr register syscall handler" {
    // Pre testing
    expect(null == syscall_handler);

    // Call function
    try registerIsr(syscalls.INTERRUPT, testFunction3);

    // Post testing
    expectEqual(testFunction3, syscall_handler.?);

    // Clean up
    syscall_handler = null;
}

test "registerIsr re-register isr handler" {
    // Pre testing
    for (isr_handlers) |h| {
        expect(null == h);
    }

    // Call function
    try registerIsr(0, testFunction1);
    expectError(IsrError.IsrExists, registerIsr(0, testFunction2));

    // Post testing
    for (isr_handlers) |h, i| {
        if (i != 0) {
            expect(null == h);
        } else {
            expectEqual(testFunction1, h.?);
        }
    }

    // Clean up
    isr_handlers[0] = null;
}

test "registerIsr register isr handler" {
    // Pre testing
    for (isr_handlers) |h| {
        expect(null == h);
    }

    // Call function
    try registerIsr(0, testFunction1);

    // Post testing
    for (isr_handlers) |h, i| {
        if (i != 0) {
            expect(null == h);
        } else {
            expectEqual(testFunction1, h.?);
        }
    }

    // Clean up
    isr_handlers[0] = null;
}

test "registerIsr invalid isr index" {
    expectError(IsrError.InvalidIsr, registerIsr(200, testFunction1));
}

///
/// Test that all handers are null at initialisation.
///
fn rt_unregisteredHandlers() void {
    // Ensure all ISR are not registered yet
    for (isr_handlers) |h, i| {
        if (h) |_| {
            panic(@errorReturnTrace(), "Handler found for ISR: {}-{}\n", .{ i, h });
        }
    }

    if (syscall_handler) |h| {
        panic(@errorReturnTrace(), "Pre-testing failed for syscall: {}\n", .{h});
    }

    log.logInfo("ISR: Tested registered handlers\n", .{});
}

///
/// Test that all IDT entries for the ISRs are open.
///
fn rt_openedIdtEntries() void {
    const loaded_idt = arch.sidt();
    const idt_entries = @intToPtr([*]idt.IdtEntry, loaded_idt.base)[0..idt.NUMBER_OF_ENTRIES];

    for (idt_entries) |entry, i| {
        if (isValidIsr(i)) {
            if (!idt.isIdtOpen(entry)) {
                panic(@errorReturnTrace(), "IDT entry for {} is not open\n", .{i});
            }
        }
    }

    log.logInfo("ISR: Tested opened IDT entries\n", .{});
}

///
/// Run all the runtime tests.
///
fn runtimeTests() void {
    rt_unregisteredHandlers();
    rt_openedIdtEntries();
}
