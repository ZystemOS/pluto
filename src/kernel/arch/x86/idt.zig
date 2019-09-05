// Zig version: 0.4.0

const gdt = @import("gdt.zig");
const arch = @import("arch.zig");
const log = @import("../../log.zig");

const NUMBER_OF_ENTRIES: u16 = 256;
const TABLE_SIZE: u16 = @sizeOf(IdtEntry) * NUMBER_OF_ENTRIES - 1;

// The different gate types
const TASK_GATE_32BIT: u4 = 0x5;
const INTERRUPT_GATE_16BIT: u4 = 0x6;
const TRAP_GATE_16BIT: u4 = 0x7;
const INTERRUPT_GATE_32BIT: u4 = 0xE;
const TRAP_GATE_32BIT: u4 = 0xF;

// Privilege levels
const PRIVILEGE_RING_0: u2 = 0x0;
const PRIVILEGE_RING_1: u2 = 0x1;
const PRIVILEGE_RING_2: u2 = 0x2;
const PRIVILEGE_RING_3: u2 = 0x3;

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
    base: *IdtEntry,
};

/// The IDT entry table of NUMBER_OF_ENTRIES entries.
var idt: [NUMBER_OF_ENTRIES]IdtEntry = [_]IdtEntry{makeEntry(0, 0, 0, 0, 0)} ** NUMBER_OF_ENTRIES;

/// The IDT pointer that the CPU is loaded with that contains the base address of the IDT and the
/// size.
const idt_ptr: IdtPtr = IdtPtr{
    .limit = TABLE_SIZE,
    .base = &idt[0],
};

///
/// Make a IDT entry.
///
/// Arguments:
///     IN base: u32     - The pointer to the interrupt handler.
///     IN selector: u16 - The segment the interrupt is in. This will usually be the
///                        kernels code segment.
///     IN gate_type: u4 - The type of interrupt.
///     IN privilege: u2 - What privilege to call the interrupt in. This will usually be
///                        the kernel ring level 0.
///     IN present: u1   - Whether a interrupt handler is present to be called..
///
/// Return:
///     A new IDT entry.
///
fn makeEntry(base: u32, selector: u16, gate_type: u4, privilege: u2, present: u1) IdtEntry {
    return IdtEntry{
        .base_low = @truncate(u16, base),
        .selector = selector,
        .zero = 0,
        .gate_type = gate_type,
        .storage_segment = 0,
        .privilege = privilege,
        .present = present,
        .base_high = @truncate(u16, base >> 16),
    };
}

///
/// Open a interrupt gate with a given index and a handler to call.
///
/// Arguments:
///     IN index: u8             - The interrupt number to close.
///     IN base: extern fn()void - The function handler for the interrupt.
///
pub fn openInterruptGate(index: u8, base: extern fn () void) void {
    idt[index] = makeEntry(@ptrToInt(base), gdt.KERNEL_CODE_OFFSET, INTERRUPT_GATE_32BIT, PRIVILEGE_RING_0, 1);
}

///
/// Close a interrupt gate with a given index
///
/// Arguments:
///     IN index: u8 - The interrupt number to close.
///
pub fn closeInterruptGate(index: u8) void {
    idt[index] = makeEntry(0, 0, 0, 0, 0);
}

///
/// Initialise the Interrupt descriptor table
///
pub fn init() void {
    log.logInfo("Init idt\n");
    arch.lidt(&idt_ptr);
    log.logInfo("Done\n");
}
