const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const builtin = @import("builtin");
const is_test = builtin.is_test;

const build_options = @import("build_options");
const mock_path = build_options.arch_mock_path;
const gdt = if (is_test) @import(mock_path ++ "gdt_mock.zig") else @import("gdt.zig");
const arch = if (is_test) @import(mock_path ++ "arch_mock.zig") else @import("arch.zig");
const log = if (is_test) @import(mock_path ++ "log_mock.zig") else @import("../../log.zig");

/// The structure that contains all the information that each IDT entry needs.
const IdtEntry = packed struct {
    /// The lower 16 bits of the base address of the interrupt handler offset.
    base_low: u16,

    /// The code segment in the GDT which the handlers will be held.
    selector: u16,

    /// Must be zero, unused.
    zero: u8,

    /// The IDT gate type.
    gate_type: u4,

    /// Must be 0 for interrupt and trap gates.
    storage_segment: u1,

    /// The minimum ring level that the calling code must have to run the handler. So user code may not be able to run some interrupts.
    privilege: u2,

    /// Whether the IDT entry is present.
    present: u1,

    /// The upper 16 bits of the base address of the interrupt handler offset.
    base_high: u16,
};

/// The IDT pointer structure that contains the pointer to the beginning of the IDT and the number
/// of the table (minus 1). Used to load the IST with LIDT instruction.
pub const IdtPtr = packed struct {
    /// The total size of the IDT (minus 1) in bytes.
    limit: u16,

    /// The base address where the IDT is located.
    base: u32,
};

pub const InterruptHandler = extern fn () void;

/// The error set for the IDT
pub const IdtError = error{
    /// A IDT entry already exists for the provided index.
    IdtEntryExists,
};

// ----------
// Task gates
// ----------

/// The base addresses aren't used, so set these to 0. When a interrupt happens, interrupts are not
/// automatically disabled. This is used for referencing the TSS descriptor in the GDT.
const TASK_GATE: u4 = 0x5;

/// Used to specify a interrupt service routine (ISR). When a interrupt happens, interrupts are
/// automatically disabled then enabled upon the IRET instruction which restores the saved EFLAGS.
const INTERRUPT_GATE: u4 = 0xE;

/// Used to specify a interrupt service routine (ISR). When a interrupt happens, interrupts are not
/// automatically disabled and doesn't restores the saved EFLAGS upon the IRET instruction.
const TRAP_GATE: u4 = 0xF;

// ----------
// Privilege levels
// ----------

/// Privilege level 0. Kernel land. The privilege level the calling descriptor minimum will have.
const PRIVILEGE_RING_0: u2 = 0x0;

/// Privilege level 1. The privilege level the calling descriptor minimum will have.
const PRIVILEGE_RING_1: u2 = 0x1;

/// Privilege level 2. The privilege level the calling descriptor minimum will have.
const PRIVILEGE_RING_2: u2 = 0x2;

/// Privilege level 3. User land. The privilege level the calling descriptor minimum will have.
const PRIVILEGE_RING_3: u2 = 0x3;

/// The total number of entries the IDT can have (2^8).
const NUMBER_OF_ENTRIES: u16 = 256;

/// The total size of all the IDT entries (minus 1).
const TABLE_SIZE: u16 = @sizeOf(IdtEntry) * NUMBER_OF_ENTRIES - 1;

/// The IDT pointer that the CPU is loaded with that contains the base address of the IDT and the
/// size.
var idt_ptr: IdtPtr = IdtPtr{
    .limit = TABLE_SIZE,
    .base = 0,
};

/// The IDT entry table of NUMBER_OF_ENTRIES entries. Initially all zero'ed.
var idt_entries: [NUMBER_OF_ENTRIES]IdtEntry = [_]IdtEntry{IdtEntry{
    .base_low = 0,
    .selector = 0,
    .zero = 0,
    .gate_type = 0,
    .storage_segment = 0,
    .privilege = 0,
    .present = 0,
    .base_high = 0,
}} ** NUMBER_OF_ENTRIES;

///
/// Make a IDT entry.
///
/// Arguments:
///     IN base: u32     - The pointer to the interrupt handler.
///     IN selector: u16 - The descriptor segment the interrupt is in. This will usually be the
///                        kernels code segment.
///     IN gate_type: u4 - The type of interrupt. This will usually be the INTERRUPT_GATE.
///     IN privilege: u2 - What privilege to call the interrupt in. This will usually be
///                        the kernel ring level 0.
///
/// Return: IdtEntry
///     A new IDT entry.
///
fn makeEntry(base: u32, selector: u16, gate_type: u4, privilege: u2) IdtEntry {
    return IdtEntry{
        .base_low = @truncate(u16, base),
        .selector = selector,
        .zero = 0,
        .gate_type = gate_type,
        .storage_segment = 0,
        .privilege = privilege,
        // Creating a new entry, so is now present.
        .present = 1,
        .base_high = @truncate(u16, base >> 16),
    };
}

///
/// Check whether a IDT gate is open.
///
/// Arguments:
///     IN entry: IdtEntry - The IDT entry to check.
///
/// Return: bool
///     Whether the provided IDT entry is open or not.
///
fn isIdtOpen(entry: IdtEntry) bool {
    return entry.present == 1;
}

///
/// Open a interrupt gate with a given index and a handler to call.
///
/// Arguments:
///     IN index: u8                 - The interrupt number to open.
///     IN handler: InterruptHandler - The interrupt handler for the interrupt.
///
/// Errors:
///     IdtError.InvalidIdtEntry - If the interrupt number is invalid, see isValidInterruptNumber.
///     IdtError.IdtEntryExists  - If the interrupt has already been registered.
///
pub fn openInterruptGate(index: u8, handler: InterruptHandler) IdtError!void {
    // As the IDT is a u8, that maximum can only be 255 which is the maximum IDT entries.
    // So there can't be a out of bounds.
    if (isIdtOpen(idt_entries[index])) {
        return IdtError.IdtEntryExists;
    }

    idt_entries[index] = makeEntry(@intCast(u32, @ptrToInt(handler)), gdt.KERNEL_CODE_OFFSET, INTERRUPT_GATE, PRIVILEGE_RING_0);
}

///
/// Initialise the Interrupt descriptor table
///
pub fn init() void {
    log.logInfo("Init idt\n");

    idt_ptr.base = @intCast(u32, @ptrToInt(&idt_entries));

    arch.lidt(&idt_ptr);
    log.logInfo("Done\n");

    if (build_options.rt_test) runtimeTests();
}

extern fn testHandler0() void {}
extern fn testHandler1() void {}

fn mock_lidt(ptr: *const IdtPtr) void {
    expectEqual(TABLE_SIZE, ptr.limit);
    expectEqual(@intCast(u32, @ptrToInt(&idt_entries[0])), ptr.base);
}

test "IDT entries" {
    expectEqual(u32(8), @sizeOf(IdtEntry));
    expectEqual(u32(6), @sizeOf(IdtPtr));
    expectEqual(TABLE_SIZE, idt_ptr.limit);
    expectEqual(u32(0), idt_ptr.base);
}

test "makeEntry alternating bit pattern" {
    const actual = makeEntry(u32(0b01010101010101010101010101010101), u16(0b0101010101010101), u4(0b0101), u2(0b01));

    const expected = u64(0b0101010101010101101001010000000001010101010101010101010101010101);

    expectEqual(expected, @bitCast(u64, actual));
}

test "isIdtOpen" {
    const not_open = IdtEntry{
        .base_low = 0,
        .selector = 0,
        .zero = 0,
        .gate_type = 0,
        .storage_segment = 0,
        .privilege = 0,
        .present = 0,
        .base_high = 0,
    };

    const open = IdtEntry{
        .base_low = 0,
        .selector = 0,
        .zero = 0,
        .gate_type = 0,
        .storage_segment = 0,
        .privilege = 0,
        .present = 1,
        .base_high = 0,
    };

    expectEqual(false, isIdtOpen(not_open));
    expectEqual(true, isIdtOpen(open));
}

test "openInterruptGate" {
    const index = u8(100);
    openInterruptGate(index, testHandler0) catch unreachable;
    expectError(IdtError.IdtEntryExists, openInterruptGate(index, testHandler0));

    const test_fn_0_addr = @intCast(u32, @ptrToInt(testHandler0));
    const test_fn_1_addr = @intCast(u32, @ptrToInt(testHandler1));

    const expected_entry0 = IdtEntry{
        .base_low = @truncate(u16, test_fn_0_addr),
        .selector = gdt.KERNEL_CODE_OFFSET,
        .zero = 0,
        .gate_type = INTERRUPT_GATE,
        .storage_segment = 0,
        .privilege = PRIVILEGE_RING_0,
        .present = 1,
        .base_high = @truncate(u16, test_fn_0_addr >> 16),
    };

    expectEqual(expected_entry0, idt_entries[index]);

    // Reset
    idt_entries[index] = IdtEntry{
        .base_low = 0,
        .selector = 0,
        .zero = 0,
        .gate_type = 0,
        .storage_segment = 0,
        .privilege = 0,
        .present = 0,
        .base_high = 0,
    };

    openInterruptGate(index, testHandler0) catch unreachable;
    // With different handler
    expectError(IdtError.IdtEntryExists, openInterruptGate(index, testHandler1));

    const expected_entry1 = IdtEntry{
        .base_low = @truncate(u16, test_fn_0_addr),
        .selector = gdt.KERNEL_CODE_OFFSET,
        .zero = 0,
        .gate_type = INTERRUPT_GATE,
        .storage_segment = 0,
        .privilege = PRIVILEGE_RING_0,
        .present = 1,
        .base_high = @truncate(u16, test_fn_0_addr >> 16),
    };

    expectEqual(expected_entry1, idt_entries[index]);

    // Reset
    idt_entries[index] = IdtEntry{
        .base_low = 0,
        .selector = 0,
        .zero = 0,
        .gate_type = 0,
        .storage_segment = 0,
        .privilege = 0,
        .present = 0,
        .base_high = 0,
    };
}

test "init" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    arch.addConsumeFunction("lidt", mock_lidt);

    // Call function
    init();

    // Post testing
    expectEqual(@intCast(u32, @ptrToInt(&idt_entries)), idt_ptr.base);

    // Reset
    idt_ptr.base = 0;
}

///
/// Check that the IDT table was loaded properly by getting the previously loaded table and
/// compare the limit and base address.
///
fn rt_loadedIDTSuccess() void {
    const loaded_idt = arch.sidt();
    expect(idt_ptr.limit == loaded_idt.limit);
    expect(idt_ptr.base == loaded_idt.base);
    log.logInfo("IDT: Tested loading IDT\n");
}

///
/// Run all the runtime tests.
///
fn runtimeTests() void {
    rt_loadedIDTSuccess();
}
