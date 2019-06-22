// Zig version: 0.4.0

const arch = @import("arch.zig");
const log = @import("../../log.zig");

const NUMBER_OF_ENTRIES: u16 = 0x06;
const TABLE_SIZE: u16 = @sizeOf(GdtEntry) * NUMBER_OF_ENTRIES - 1;

// The indexes into the GDT where each segment resides.

/// The index of the NULL GDT entry.
const NULL_INDEX: u16           = 0x00;

/// The index of the kernel code GDT entry.
const KERNEL_CODE_INDEX: u16    = 0x01;

/// The index of the kernel data GDT entry.
const KERNEL_DATA_INDEX: u16    = 0x02;

/// The index of the user code GDT entry.
const USER_CODE_INDEX: u16      = 0x03;

/// The index of the user data GDT entry.
const USER_DATA_INDEX: u16      = 0x04;

/// The index of the task state segment GDT entry.
const TSS_INDEX: u16            = 0x05;


// The offsets into the GDT where each segment resides.

/// The offset of the NULL GDT entry.
pub const NULL_OFFSET: u16          = 0x00;

/// The offset of the kernel code GDT entry.
pub const KERNEL_CODE_OFFSET: u16   = 0x08;

/// The offset of the kernel data GDT entry.
pub const KERNEL_DATA_OFFSET: u16   = 0x10;

/// The offset of the user code GDT entry.
pub const USER_CODE_OFFSET: u16     = 0x18;

/// The offset of the user data GDT entry.
pub const USER_DATA_OFFSET: u16     = 0x20;

/// The offset of the TTS GDT entry.
pub const TSS_OFFSET: u16           = 0x28;

// The access bits
const ACCESSED_BIT              = 0x01; // 00000001
const WRITABLE_BIT              = 0x02; // 00000010
const DIRECTION_CONFORMING_BIT  = 0x04; // 00000100
const EXECUTABLE_BIT            = 0x08; // 00001000
const DESCRIPTOR_BIT            = 0x10; // 00010000

const PRIVILEGE_RING_0          = 0x00; // 00000000
const PRIVILEGE_RING_1          = 0x20; // 00100000
const PRIVILEGE_RING_2          = 0x40; // 01000000
const PRIVILEGE_RING_3          = 0x60; // 01100000

const PRESENT_BIT               = 0x80; // 10000000


const KERNEL_SEGMENT = PRESENT_BIT | PRIVILEGE_RING_0 | DESCRIPTOR_BIT;
const USER_SEGMENT = PRESENT_BIT | PRIVILEGE_RING_3 | DESCRIPTOR_BIT;

const CODE_SEGMENT = EXECUTABLE_BIT | WRITABLE_BIT;
const DATA_SEGMENT = WRITABLE_BIT;

const TSS_SEGMENT = PRESENT_BIT | EXECUTABLE_BIT | ACCESSED_BIT;


// The flag bits
const IS_64_BIT         = 0x02; // 0010
const IS_32_BIT         = 0x04; // 0100
const IS_LIMIT_4K_BIT   = 0x08; // 1000

/// The structure that contains all the information that each GDT entry needs.
const GdtEntry = packed struct {
    /// The lower 16 bits of the limit address. Describes the size of memory that can be addressed.
    limit_low: u16,

    /// The lower 24 bits of the base address. Describes the start of memory for the entry.
    base_low: u24,

    /// Bit 0   : accessed             - The CPU will set this when the GDT entry is accessed.
    /// Bit 1   : writable             - The writable bit to say if the memory region is writable. If set, then memory region is readable and writable. If not set, then the memory region is just readable.
    /// Bit 2   : direction_conforming - For a code segment: if set (1), then the code segment can be executed from a lower ring level. If unset (0), then the code segment can only be executed from the same ring level in the privilege flag. For the data segment: if set (1), then the data segment grows downwards. If unset (0), then the data segment grows upwards.
    /// Bit 3   : executable           - The execution bit to say that the memory region is executable.
    /// Bit 4   : descriptor_bit       - The descriptor bit.
    /// Bit 5-6 : privilege            - The ring level of the memory region.
    /// Bit 7   : present              - The present bit to tell that this GDT entry is present.
    access: u8,

    /// The upper 4 bits of the limit address. Describes the size of memory that can be addressed.
    limit_high: u4,

    /// Bit 0 : reserved_zero - This must always be zero.
    /// Bit 1 : is_64bits     - Whether this is a 64 bit system.
    /// Bit 2 : is_32bits     - Whether this is a 32 bit system.
    /// Bit 3 : is_limit_4K   - Whether paging is turned on, and each address is addressed as if it is a page number not physical/logical linear address.
    flags: u4,

    /// The upper 8 bits of the base address. Describes the start of memory for the entry.
    base_high: u8,
};

/// The GDT pointer structure that contains the pointer to the beginning of the GDT and the number
/// of the table (minus 1). Used to load the GDT with LGDT instruction.
pub const GdtPtr = packed struct {
    /// 16bit entry for the number of entries (minus 1).
    limit: u16,

    /// 32bit entry for the base address for the GDT.
    base: *GdtEntry,
};

///
/// The TSS entry structure
///
const TtsEntry = packed struct {
    /// Pointer to the previous TSS entry
    prev_tss: u32,

    /// Ring 0 32 bit stack pointer.
    esp0: u32,

    /// Ring 0 32 bit stack pointer.
    ss0: u32,

    /// Ring 1 32 bit stack pointer.
    esp1: u32,

    /// Ring 1 32 bit stack pointer.
    ss1: u32,

    /// Ring 2 32 bit stack pointer.
    esp2: u32,

    /// Ring 2 32 bit stack pointer.
    ss2: u32,

    /// The CR3 control register 3.
    cr3: u32,

    /// 32 bit instruction pointer.
    eip: u32,

    /// 32 bit flags register.
    eflags: u32,

    /// 32 bit accumulator register.
    eax: u32,

    /// 32 bit counter register.
    ecx: u32,

    /// 32 bit data register.
    edx: u32,

    /// 32 bit base register.
    ebx: u32,

    /// 32 bit stack pointer register.
    esp: u32,

    /// 32 bit base pointer register.
    ebp: u32,

    /// 32 bit source register.
    esi: u32,

    /// 32 bit destination register.
    edi: u32,

    /// The extra segment.
    es: u32,

    /// The code segment.
    cs: u32,

    /// The stack segment.
    ss: u32,

    /// The data segment.
    ds: u32,

    /// A extra segment FS.
    fs: u32,

    /// A extra segment GS.
    gs: u32,

    /// The local descriptor table register.
    ldtr: u32,

    /// ?
    trap: u16,

    /// A pointer to a I/O port bitmap for the current task which specifies individual ports the program should have access to.
    io_permissions_base_offset: u16,
};

///
/// Make a GDT entry.
///
/// Arguments:
///     IN access: u8 - The access bits for the descriptor.
///     IN flags: u4  - The flag bits for the descriptor.
///
/// Return:
///     A new GDT entry with the give access and flag bits set with the base at 0x00000000 and limit at 0xFFFFF.
///
fn makeEntry(base: u32, limit: u20, access: u8, flags: u4) GdtEntry {
    return GdtEntry {
        .limit_low = @truncate(u16, limit),
        .base_low = @truncate(u24, base),
        .access = access,
        .limit_high = @truncate(u4, limit >> 16),
        .flags = flags,
        .base_high = @truncate(u8, base >> 24),
    };
}

/// The GDT entry table of NUMBER_OF_ENTRIES entries.
var gdt_entries: [NUMBER_OF_ENTRIES]GdtEntry = []GdtEntry {
    // Null descriptor
    makeEntry(0, 0, 0, 0),

    // Kernel Code
    makeEntry(0, 0xFFFFF, KERNEL_SEGMENT | CODE_SEGMENT, IS_32_BIT | IS_LIMIT_4K_BIT),

    // Kernel Data
    makeEntry(0, 0xFFFFF, KERNEL_SEGMENT | DATA_SEGMENT, IS_32_BIT | IS_LIMIT_4K_BIT),

    // User Code
    makeEntry(0, 0xFFFFF, USER_SEGMENT | CODE_SEGMENT, IS_32_BIT | IS_LIMIT_4K_BIT),

    // User Data
    makeEntry(0, 0xFFFFF, USER_SEGMENT | DATA_SEGMENT, IS_32_BIT | IS_LIMIT_4K_BIT),

    // Fill in TSS at runtime
    makeEntry(0, 0, 0, 0),
};

/// The GDT pointer that the CPU is loaded with that contains the base address of the GDT and the
/// size.
const gdt_ptr: GdtPtr = GdtPtr {
    .limit = TABLE_SIZE,
    .base = &gdt_entries[0],
};

/// The task state segment entry.
var tss: TtsEntry = TtsEntry {
    .prev_tss = 0,
    .esp0 = undefined,
    .ss0 = KERNEL_DATA_OFFSET,
    .esp1 = 0,
    .ss1 = 0,
    .esp2 = 0,
    .ss2 = 0,
    .cr3 = 0,
    .eip = 0,
    .eflags = 0,
    .eax = 0,
    .ecx = 0,
    .edx = 0,
    .ebx = 0,
    .esp = 0,
    .ebp = 0,
    .esi = 0,
    .edi = 0,
    .es = 0,
    .cs = 0,
    .ss = 0,
    .ds = 0,
    .fs = 0,
    .gs = 0,
    .ldtr = 0,
    .trap = 0,
    .io_permissions_base_offset = @sizeOf(TtsEntry),
};

///
/// Set the stack pointer in the TSS entry
///
/// Arguments:
///     IN esp0: u32 - The stack pointer
///
pub fn setTssStack(esp0: u32) void {
    tss.esp0 = esp0;
}

///
/// Initialise the Global Descriptor table
///
pub fn init() void {
    log.logInfo("Init gdt\n");
    // Initiate TSS
    gdt_entries[TSS_INDEX] = makeEntry(@ptrToInt(&tss), @sizeOf(TtsEntry) - 1, TSS_SEGMENT, 0);

    // Load the GDT
    arch.lgdt(&gdt_ptr);

    // Load the TSS
    arch.ltr();
}
