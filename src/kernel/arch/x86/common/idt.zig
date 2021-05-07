/// The function type for the interrupt handler
pub const InterruptHandler = fn () callconv(.Naked) void;

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
pub const TASK_GATE: u4 = 0x5;

/// Used to specify a interrupt service routine (ISR). When a interrupt happens, interrupts are
/// automatically disabled then enabled upon the IRET instruction which restores the saved EFLAGS.
pub const INTERRUPT_GATE: u4 = 0xE;

/// Used to specify a interrupt service routine (ISR). When a interrupt happens, interrupts are not
/// automatically disabled and doesn't restores the saved EFLAGS upon the IRET instruction.
pub const TRAP_GATE: u4 = 0xF;

// ----------
// Privilege levels
// ----------

/// Privilege level 0. Kernel land. The privilege level the calling descriptor minimum will have.
pub const PRIVILEGE_RING_0: u2 = 0x0;

/// Privilege level 1. The privilege level the calling descriptor minimum will have.
pub const PRIVILEGE_RING_1: u2 = 0x1;

/// Privilege level 2. The privilege level the calling descriptor minimum will have.
pub const PRIVILEGE_RING_2: u2 = 0x2;

/// Privilege level 3. User land. The privilege level the calling descriptor minimum will have.
pub const PRIVILEGE_RING_3: u2 = 0x3;

/// The total number of entries the IDT can have (2^8).
pub const NUMBER_OF_ENTRIES: u16 = 256;
