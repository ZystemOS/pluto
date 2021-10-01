const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const log = std.log.scoped(.isr);
const build_options = @import("build_options");
const arch = @import("arch.zig");
const idt = @import("idt.zig");
const interrupts = @import("interrupts.zig");
const panic = @import("../../../panic.zig").panic;

/// The error set for the ISR. This will be from installing a ISR handler.
const IsrError = error{
    /// The ISR index is invalid.
    InvalidIsr,

    /// A ISR handler already exists.
    IsrExists,
};

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

/// The list of exceptions in order with their error code
pub const ExceptionCodes = enum(u8) {
    DivideByZero,
    SingleStepDebug,
    NonMaskableInterrupt,
    BreakpointDebug,
    Overflow,
    BoundRangeExceeded,
    InvalidOpcode,
    DeviceNotAvailable,
    DoubleFault,
    CoprocessorSegmentOverrun,
    InvalidTaskStateSegment,
    SegmentNotPresent,
    StackSegmentFault,
    GeneralProtectionFault,
    PageFault,
    Reserved,
    X87FloatPoint,
    AlignmentCheck,
    MachineCheck,
    SIMDFloatPoint,
    Virtualisation,
    Syscall = 0x80,
};

/// The of exception handlers initialised to null. Need to open a ISR for these to be valid.
var isr_handlers: [NUMBER_OF_ENTRIES]?interrupts.InterruptHandler = [_]?interrupts.InterruptHandler{null} ** NUMBER_OF_ENTRIES;

/// The syscall handler.
var syscall_handler: ?interrupts.InterruptHandler = null;

///
/// Open an IDT entry with index and handler. This will handle error by panicking as will assume that
/// only one IDT entry will be open for each ISR.
///
/// Arguments:
///     IN comptime IdtEntry: type       - The type of the IDT entry.
///     IN table: *idt.IDT(IdtEntry)     - The IDT to open the interrupt in.
///     IN index: u8                     - The IDT interrupt number to open.
///     IN handler: idt.InterruptHandler - The IDT handler to register for the interrupt number.
///
fn openIsr(comptime IdtEntry: type, table: *idt.IDT(IdtEntry), index: u8, handler: idt.InterruptHandler) void {
    table.openInterruptGate(index, handler) catch |err| switch (err) {
        error.IdtEntryExists => {
            panic(@errorReturnTrace(), "Error opening ISR number: {} exists\n", .{index});
        },
    };
}

///
/// The exception handler that each of the exceptions will call when a exception happens. If the
/// handler performs a context switch, then will return the new stack pointer of the the new task
/// or return the same stack pointer of the original task.
///
/// Arguments:
///     IN ctx: *arch.CpuState - Pointer to the exception context containing the contents of the
///                              register at the time of the exception.
///
/// Return: usize
///     The stack pointer of the stack to switch to (if switching).
///
pub fn isrHandler(ctx: *arch.CpuState) usize {
    // Get the interrupt number
    const isr_num = ctx.int_num;

    var ret_esp = @ptrToInt(ctx);

    if (isValidIsr(isr_num)) {
        if (isr_num == @enumToInt(ExceptionCodes.Syscall)) {
            // A syscall, so use the syscall handler
            if (syscall_handler) |handler| {
                ret_esp = handler(ctx);
            } else {
                panic(@errorReturnTrace(), "Syscall handler not registered\n", .{});
            }
        } else {
            if (isr_handlers[isr_num]) |handler| {
                // Regular ISR exception, if there is one registered.
                ret_esp = handler(ctx);
            } else {
                log.info("State: {X}\n", .{ctx});
                panic(@errorReturnTrace(), "ISR {s} ({}) triggered with error code 0x{X} but not registered\n", .{ exception_msg[isr_num], isr_num, ctx.error_code });
            }
        }
    } else {
        panic(@errorReturnTrace(), "Invalid ISR index: {}\n", .{isr_num});
    }
    return ret_esp;
}

///
/// Checks if the ISR is valid and returns true if it is, else false. To be valid it must be
/// greater than or equal to 0 and less than NUMBER_OF_ENTRIES or be a syscall entry.
///
/// Arguments:
///     IN isr_num: usize - The ISR number to check
///
/// Return: bool
///     Whether a ISR handler index is valid.
///
pub fn isValidIsr(isr_num: usize) bool {
    return isr_num < NUMBER_OF_ENTRIES or isr_num == @enumToInt(ExceptionCodes.Syscall);
}

///
/// Register an exception handler by setting its exception handler to the given function.
///
/// Arguments:
///     IN isr_num: u16                         - The exception number to register.
///     IN handler: interrupts.InterruptHandler - The handler to register.
///
/// Errors: IsrError
///     IsrError.InvalidIsr - If the ISR index is invalid (see isValidIsr).
///     IsrError.IsrExists  - If the ISR handler has already been registered.
///
pub fn registerIsr(isr_num: u16, handler: interrupts.InterruptHandler) IsrError!void {
    // Check if a valid ISR index
    if (isValidIsr(isr_num)) {
        if (isr_num == @enumToInt(ExceptionCodes.Syscall)) {
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
/// Arguments:
///     IN comptime IdtEntry: type   - The type for the IDT.
///     IN table: *idt.IDT(IdtEntry) - The IDT.
///
pub fn init(comptime IdtEntry: type, table: *idt.IDT(IdtEntry)) void {
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});

    // Open all the IDT entries, including the syscall handler
    comptime var i = 0;
    inline while (i < 32) : (i += 1) {
        openIsr(IdtEntry, table, i, interrupts.getInterruptStub(i));
    }

    openIsr(IdtEntry, table, @enumToInt(ExceptionCodes.Syscall), interrupts.getInterruptStub(@enumToInt(ExceptionCodes.Syscall)));

    switch (build_options.test_mode) {
        .Initialisation => runtimeTests(IdtEntry),
        else => {},
    }
}

/// A test IDT entry. This will just take the init parameters and save them.
const TestIdtEntry = struct {
    base: usize,
    selector: u16,
    gate_type: u4,
    privilege: u2,

    pub fn isIdtOpen(self: TestIdtEntry) bool {
        return false;
    }

    pub fn init(base: usize, selector: u16, gate_type: u4, privilege: u2) TestIdtEntry {
        return .{
            .base = base,
            .selector = selector,
            .gate_type = gate_type,
            .privilege = privilege,
        };
    }
};

fn testFunction0() callconv(.Naked) void {}

fn testFunction1(ctx: *arch.CpuState) u32 {
    return 0;
}

fn testFunction2(ctx: *arch.CpuState) u32 {
    return 0;
}

test "isValidIsr" {
    comptime var i = 0;
    inline while (i < NUMBER_OF_ENTRIES) : (i += 1) {
        expect(isValidIsr(i));
    }

    expect(isValidIsr(@enumToInt(ExceptionCodes.Syscall)));

    expect(!isValidIsr(200));
}

test "openIsr" {
    var table = idt.IDT(TestIdtEntry){};
    openIsr(TestIdtEntry, &table, index, handler);
}

test "registerIsr re-register syscall handler" {
    expect(null == syscall_handler);

    try registerIsr(@enumToInt(ExceptionCodes.Syscall), testFunction1);
    expectError(IsrError.IsrExists, registerIsr(@enumToInt(ExceptionCodes.Syscall), testFunction2));

    expectEqual(testFunction1, syscall_handler.?);

    syscall_handler = null;
}

test "registerIsr register syscall handler" {
    expect(null == syscall_handler);

    try registerIsr(@enumToInt(ExceptionCodes.Syscall), testFunction1);

    expectEqual(testFunction1, syscall_handler.?);

    syscall_handler = null;
}

test "registerIsr re-register isr handler" {
    // Check all handlers are null
    for (isr_handlers) |handler| {
        expect(null == handler);
    }

    try registerIsr(0, testFunction1);
    expectError(IsrError.IsrExists, registerIsr(0, testFunction2));

    for (isr_handlers) |handler, i| {
        if (i != 0) {
            expect(null == handler);
        } else {
            expectEqual(testFunction1, handler.?);
        }
    }

    isr_handlers[0] = null;
}

test "registerIsr register isr handler" {
    // Check all handlers are null
    for (isr_handlers) |handler| {
        expect(null == handler);
    }

    try registerIsr(0, testFunction1);

    for (isr_handlers) |handler, i| {
        if (i != 0) {
            expect(null == handler);
        } else {
            expectEqual(testFunction1, handler.?);
        }
    }

    isr_handlers[0] = null;
}

test "registerIsr invalid isr index" {
    expectError(IsrError.InvalidIsr, registerIsr(200, testFunction1));
}

test "init" {
    var table = idt.IDT(TestIdtEntry){};
    init(TestIdtEntry, &table, index, handler);
}

///
/// Test that all handlers are null at initialisation.
///
fn rt_unregisteredHandlers() void {
    // Ensure all ISR are not registered yet
    for (isr_handlers) |handler, i| {
        if (handler) |_| {
            panic(@errorReturnTrace(), "FAILURE: Handler found for ISR: {}-{}\n", .{ i, handler });
        }
    }

    if (syscall_handler) |handler| {
        panic(@errorReturnTrace(), "FAILURE: Pre-testing failed for syscall: {}\n", .{handler});
    }

    log.info("Tested registered handlers\n", .{});
}

///
/// Test that all IDT entries for the ISRs are open.
///
/// Arguments:
///     IN comptime IdtEntry: type - The type of the IDT entry.
///
fn rt_openedIdtEntries(comptime IdtEntry: type) void {
    const loaded_idt = arch.sidt(IdtEntry);
    const idt_entries = @intToPtr([*]IdtEntry, @ptrToInt(loaded_idt.base))[0..idt.NUMBER_OF_ENTRIES];

    for (idt_entries) |entry, i| {
        if (isValidIsr(i)) {
            if (!entry.isIdtOpen()) {
                panic(@errorReturnTrace(), "FAILURE: IDT entry for {} is not open\n", .{i});
            }
        }
    }

    log.info("Tested opened IDT entries\n", .{});
}

///
/// Run all the runtime tests.
///
/// Arguments:
///     IN comptime IdtEntry: type - The type of the IDT entry.
///
pub fn runtimeTests(comptime IdtEntry: type) void {
    rt_unregisteredHandlers();
    rt_openedIdtEntries(IdtEntry);
}
