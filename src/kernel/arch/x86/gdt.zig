const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const builtin = @import("builtin");
const is_test = builtin.is_test;

const build_options = @import("build_options");
const mock_path = build_options.arch_mock_path;
const arch = if (is_test) @import(mock_path ++ "arch_mock.zig") else @import("arch.zig");
const log = if (is_test) @import(mock_path ++ "log_mock.zig") else @import("../../log.zig");

/// The access bits for a GDT entry.
const AccessBits = packed struct {
    /// Whether the segment has been access. This shouldn't be set as it is set by the CPU when the
    /// segment is accessed.
    accessed: u1,

    /// For code segments, when set allows the code segment to be readable. Code segments are
    /// always executable. For data segments, when set allows the data segment to be writeable.
    /// Data segments are always readable.
    read_write: u1,

    /// For code segments, when set allows this code segments to be executed from a equal or lower
    /// privilege level. The privilege bits represent the highest privilege level that is allowed
    /// to execute this segment. If not set, then the code segment can only be executed from the
    /// same ring level specified in the privilege level bits. For data segments, when set the data
    /// segment grows downwards. When not set, the data segment grows upwards. So for both code and
    /// data segments, this shouldn't be set.
    direction_conforming: u1,

    /// When set, the segment can be executed, a code segments. When not set, the segment can't be
    /// executed, data segment.
    executable: u1,

    /// Should be set for code and data segments, but not set for TSS.
    descriptor: u1,

    /// Privilege/ring level. The kernel level is level 3, the highest privilege. The user level is
    /// level 0, the lowest privilege.
    privilege: u2,

    /// Whether the segment is present. This must be set for all valid selectors, not the null
    /// segment.
    present: u1,
};

/// The flag bits for a GDT entry.
const FlagBits = packed struct {
    /// The lowest bits must be 0 as this is reserved for future use.
    reserved_zero: u1,

    /// When set indicates the segment is a x86-64 segment. If set, then the IS_32_BIT flag must
    /// not be set. If both are set, then will throw an exception.
    is_64_bit: u1,

    /// When set indicates the segment is a 32 bit protected mode segment. When not set, indicates
    /// the segment is a 16 bit protected mode segment.
    is_32_bit: u1,

    /// The granularity bit. When set the limit is in 4KB blocks (page granularity). When not set,
    /// then limit is in 1B blocks (byte granularity). This should be set as we are doing paging.
    granularity: u1,
};

/// The structure that contains all the information that each GDT entry needs.
const GdtEntry = packed struct {
    /// The lower 16 bits of the limit address. Describes the size of memory that can be addressed.
    limit_low: u16,

    /// The lower 24 bits of the base address. Describes the start of memory for the entry.
    base_low: u24,

    /// The access bits, see AccessBits for all the options. 8 bits.
    access: AccessBits,

    /// The upper 4 bits of the limit address. Describes the size of memory that can be addressed.
    limit_high: u4,

    /// The flag bits, see above for all the options. 4 bits.
    flags: FlagBits,

    /// The upper 8 bits of the base address. Describes the start of memory for the entry.
    base_high: u8,
};

/// The TSS entry structure
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

/// The GDT pointer structure that contains the pointer to the beginning of the GDT and the number
/// of the table (minus 1). Used to load the GDT with LGDT instruction.
pub const GdtPtr = packed struct {
    /// 16bit entry for the number of entries (minus 1).
    limit: u16,

    /// 32bit entry for the base address for the GDT.
    base: u32,
};

/// The total number of entries in the GTD: null, kernel code, kernel data, user code, user data
/// and TSS
const NUMBER_OF_ENTRIES: u16 = 0x06;

/// The size of the GTD in bytes (minus 1).
const TABLE_SIZE: u16 = @sizeOf(GdtEntry) * NUMBER_OF_ENTRIES - 1;

// ----------
// The indexes into the GDT where each segment resides.
// ----------

/// The index of the NULL GDT entry.
const NULL_INDEX: u16 = 0x00;

/// The index of the kernel code GDT entry.
const KERNEL_CODE_INDEX: u16 = 0x01;

/// The index of the kernel data GDT entry.
const KERNEL_DATA_INDEX: u16 = 0x02;

/// The index of the user code GDT entry.
const USER_CODE_INDEX: u16 = 0x03;

/// The index of the user data GDT entry.
const USER_DATA_INDEX: u16 = 0x04;

/// The index of the task state segment GDT entry.
const TSS_INDEX: u16 = 0x05;

/// The null segment, everything is set to zero.
const NULL_SEGMENT: AccessBits = AccessBits{
    .accessed = 0,
    .read_write = 0,
    .direction_conforming = 0,
    .executable = 0,
    .descriptor = 0,
    .privilege = 0,
    .present = 0,
};

/// This bit pattern represents a kernel code segment with bits: readable, executable, descriptor,
/// privilege 0, and present set.
const KERNEL_SEGMENT_CODE: AccessBits = AccessBits{
    .accessed = 0,
    .read_write = 1,
    .direction_conforming = 0,
    .executable = 1,
    .descriptor = 1,
    .privilege = 0,
    .present = 1,
};

/// This bit pattern represents a kernel data segment with bits: writeable, descriptor, privilege 0,
/// and present set.
const KERNEL_SEGMENT_DATA: AccessBits = AccessBits{
    .accessed = 0,
    .read_write = 1,
    .direction_conforming = 0,
    .executable = 0,
    .descriptor = 1,
    .privilege = 0,
    .present = 1,
};

/// This bit pattern represents a user code segment with bits: readable, executable, descriptor,
/// privilege 3, and present set.
const USER_SEGMENT_CODE: AccessBits = AccessBits{
    .accessed = 0,
    .read_write = 1,
    .direction_conforming = 0,
    .executable = 1,
    .descriptor = 1,
    .privilege = 3,
    .present = 1,
};

/// This bit pattern represents a user data segment with bits: writeable, descriptor, privilege 3,
/// and present set.
const USER_SEGMENT_DATA: AccessBits = AccessBits{
    .accessed = 0,
    .read_write = 1,
    .direction_conforming = 0,
    .executable = 0,
    .descriptor = 1,
    .privilege = 3,
    .present = 1,
};

/// This bit pattern represents a TSS segment with bits: accessed, executable and present set.
const TSS_SEGMENT: AccessBits = AccessBits{
    .accessed = 1,
    .read_write = 0,
    .direction_conforming = 0,
    .executable = 1,
    .descriptor = 0,
    .privilege = 0,
    .present = 1,
};

/// The bit pattern for all bits set to zero.
const NULL_FLAGS: FlagBits = FlagBits{
    .reserved_zero = 0,
    .is_64_bit = 0,
    .is_32_bit = 0,
    .granularity = 0,
};

/// The bit pattern for all segments where we are in 32 bit protected mode and paging enabled.
const PAGING_32_BIT: FlagBits = FlagBits{
    .reserved_zero = 0,
    .is_64_bit = 0,
    .is_32_bit = 1,
    .granularity = 1,
};

// ----------
// The offsets into the GDT where each segment resides.
// ----------

/// The offset of the NULL GDT entry.
pub const NULL_OFFSET: u16 = 0x00;

/// The offset of the kernel code GDT entry.
pub const KERNEL_CODE_OFFSET: u16 = 0x08;

/// The offset of the kernel data GDT entry.
pub const KERNEL_DATA_OFFSET: u16 = 0x10;

/// The offset of the user code GDT entry.
pub const USER_CODE_OFFSET: u16 = 0x18;

/// The offset of the user data GDT entry.
pub const USER_DATA_OFFSET: u16 = 0x20;

/// The offset of the TTS GDT entry.
pub const TSS_OFFSET: u16 = 0x28;

/// The GDT entry table of NUMBER_OF_ENTRIES entries.
var gdt_entries: [NUMBER_OF_ENTRIES]GdtEntry = [_]GdtEntry{
    // Null descriptor
    makeEntry(0, 0, NULL_SEGMENT, NULL_FLAGS),

    // Kernel Code
    makeEntry(0, 0xFFFFF, KERNEL_SEGMENT_CODE, PAGING_32_BIT),

    // Kernel Data
    makeEntry(0, 0xFFFFF, KERNEL_SEGMENT_DATA, PAGING_32_BIT),

    // User Code
    makeEntry(0, 0xFFFFF, USER_SEGMENT_CODE, PAGING_32_BIT),

    // User Data
    makeEntry(0, 0xFFFFF, USER_SEGMENT_DATA, PAGING_32_BIT),

    // Fill in TSS at runtime
    makeEntry(0, 0, NULL_SEGMENT, NULL_FLAGS),
};

/// The GDT pointer that the CPU is loaded with that contains the base address of the GDT and the
/// size.
var gdt_ptr: GdtPtr = GdtPtr{
    .limit = TABLE_SIZE,
    .base = undefined,
};

/// The task state segment entry.
var tss: TtsEntry = TtsEntry{
    .prev_tss = 0,
    .esp0 = 0,
    .ss0 = u32(KERNEL_DATA_OFFSET),
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
    .io_permissions_base_offset = u16(@sizeOf(TtsEntry)),
};

///
/// Make a GDT entry.
///
/// Arguments:
///     IN base: u32          - The linear address where the segment begins.
///     IN limit: u20         - The maximum addressable unit whether it is 1B units or page units.
///     IN access: AccessBits - The access bits for the descriptor.
///     IN flags: FlagBits    - The flag bits for the descriptor.
///
/// Return: GdtEntry
///     A new GDT entry with the give access and flag bits set with the base at 0x00000000 and
///     limit at 0xFFFFF.
///
fn makeEntry(base: u32, limit: u20, access: AccessBits, flags: FlagBits) GdtEntry {
    return GdtEntry{
        .limit_low = @truncate(u16, limit),
        .base_low = @truncate(u24, base),
        .access = AccessBits{
            .accessed = access.accessed,
            .read_write = access.read_write,
            .direction_conforming = access.direction_conforming,
            .executable = access.executable,
            .descriptor = access.descriptor,
            .privilege = access.privilege,
            .present = access.present,
        },
        .limit_high = @truncate(u4, limit >> 16),
        .flags = FlagBits{
            .reserved_zero = flags.reserved_zero,
            .is_64_bit = flags.is_64_bit,
            .is_32_bit = flags.is_32_bit,
            .granularity = flags.granularity,
        },
        .base_high = @truncate(u8, base >> 24),
    };
}

///
/// Set the stack pointer in the TSS entry.
///
/// Arguments:
///     IN esp0: u32 - The stack pointer.
///
pub fn setTssStack(esp0: u32) void {
    tss.esp0 = esp0;
}

///
/// Initialise the Global Descriptor table.
///
pub fn init() void {
    log.logInfo("Init gdt\n");
    // Initiate TSS
    gdt_entries[TSS_INDEX] = makeEntry(@intCast(u32, @ptrToInt(&tss)), @sizeOf(TtsEntry) - 1, TSS_SEGMENT, NULL_FLAGS);

    // Set the base address where all the GDT entries are.
    gdt_ptr.base = @intCast(u32, @ptrToInt(&gdt_entries[0]));

    // Load the GDT
    arch.lgdt(&gdt_ptr);

    // Load the TSS
    arch.ltr(TSS_OFFSET);

    log.logInfo("Done\n");

    if (build_options.rt_test) runtimeTests();
}

fn mock_lgdt(ptr: *const GdtPtr) void {
    expectEqual(TABLE_SIZE, ptr.limit);
    expectEqual(@intCast(u32, @ptrToInt(&gdt_entries[0])), ptr.base);
}

test "GDT entries" {
    expectEqual(u32(1), @sizeOf(AccessBits));
    expectEqual(u32(1), @sizeOf(FlagBits));
    expectEqual(u32(8), @sizeOf(GdtEntry));
    expectEqual(u32(104), @sizeOf(TtsEntry));
    expectEqual(u32(6), @sizeOf(GdtPtr));

    const null_entry = gdt_entries[NULL_INDEX];
    expectEqual(u64(0), @bitCast(u64, null_entry));

    const kernel_code_entry = gdt_entries[KERNEL_CODE_INDEX];
    expectEqual(u64(0xCF9A000000FFFF), @bitCast(u64, kernel_code_entry));

    const kernel_data_entry = gdt_entries[KERNEL_DATA_INDEX];
    expectEqual(u64(0xCF92000000FFFF), @bitCast(u64, kernel_data_entry));

    const user_code_entry = gdt_entries[USER_CODE_INDEX];
    expectEqual(u64(0xCFFA000000FFFF), @bitCast(u64, user_code_entry));

    const user_data_entry = gdt_entries[USER_DATA_INDEX];
    expectEqual(u64(0xCFF2000000FFFF), @bitCast(u64, user_data_entry));

    const tss_entry = gdt_entries[TSS_INDEX];
    expectEqual(u64(0), @bitCast(u64, tss_entry));

    expectEqual(TABLE_SIZE, gdt_ptr.limit);

    expectEqual(u32(0), tss.prev_tss);
    expectEqual(u32(0), tss.esp0);
    expectEqual(u32(KERNEL_DATA_OFFSET), tss.ss0);
    expectEqual(u32(0), tss.esp1);
    expectEqual(u32(0), tss.ss1);
    expectEqual(u32(0), tss.esp2);
    expectEqual(u32(0), tss.ss2);
    expectEqual(u32(0), tss.cr3);
    expectEqual(u32(0), tss.eip);
    expectEqual(u32(0), tss.eflags);
    expectEqual(u32(0), tss.eax);
    expectEqual(u32(0), tss.ecx);
    expectEqual(u32(0), tss.edx);
    expectEqual(u32(0), tss.ebx);
    expectEqual(u32(0), tss.esp);
    expectEqual(u32(0), tss.ebp);
    expectEqual(u32(0), tss.esi);
    expectEqual(u32(0), tss.edi);
    expectEqual(u32(0), tss.es);
    expectEqual(u32(0), tss.cs);
    expectEqual(u32(0), tss.ss);
    expectEqual(u32(0), tss.ds);
    expectEqual(u32(0), tss.fs);
    expectEqual(u32(0), tss.gs);
    expectEqual(u32(0), tss.ldtr);
    expectEqual(u16(0), tss.trap);

    // Size of TtsEntry will fit in a u16 as 104 < 65535 (2^16)
    expectEqual(u16(@sizeOf(TtsEntry)), tss.io_permissions_base_offset);
}

test "makeEntry NULL" {
    const actual = makeEntry(u32(0), u32(0), NULL_SEGMENT, NULL_FLAGS);

    const expected = u64(0);
    expectEqual(expected, @bitCast(u64, actual));
}

test "makeEntry alternating bit pattern" {
    const alt_access = AccessBits{
        .accessed = 1,
        .read_write = 0,
        .direction_conforming = 1,
        .executable = 0,
        .descriptor = 1,
        .privilege = 0b10,
        .present = 0,
    };

    expectEqual(u8(0b01010101), @bitCast(u8, alt_access));

    const alt_flag = FlagBits{
        .reserved_zero = 1,
        .is_64_bit = 0,
        .is_32_bit = 1,
        .granularity = 0,
    };

    expectEqual(u4(0b0101), @bitCast(u4, alt_flag));

    const actual = makeEntry(u32(0b01010101010101010101010101010101), u20(0b01010101010101010101), alt_access, alt_flag);

    const expected = u64(0b0101010101010101010101010101010101010101010101010101010101010101);
    expectEqual(expected, @bitCast(u64, actual));
}

test "setTssStack" {
    // Pre-testing
    expectEqual(u32(0), tss.prev_tss);
    expectEqual(u32(0), tss.esp0);
    expectEqual(u32(KERNEL_DATA_OFFSET), tss.ss0);
    expectEqual(u32(0), tss.esp1);
    expectEqual(u32(0), tss.ss1);
    expectEqual(u32(0), tss.esp2);
    expectEqual(u32(0), tss.ss2);
    expectEqual(u32(0), tss.cr3);
    expectEqual(u32(0), tss.eip);
    expectEqual(u32(0), tss.eflags);
    expectEqual(u32(0), tss.eax);
    expectEqual(u32(0), tss.ecx);
    expectEqual(u32(0), tss.edx);
    expectEqual(u32(0), tss.ebx);
    expectEqual(u32(0), tss.esp);
    expectEqual(u32(0), tss.ebp);
    expectEqual(u32(0), tss.esi);
    expectEqual(u32(0), tss.edi);
    expectEqual(u32(0), tss.es);
    expectEqual(u32(0), tss.cs);
    expectEqual(u32(0), tss.ss);
    expectEqual(u32(0), tss.ds);
    expectEqual(u32(0), tss.fs);
    expectEqual(u32(0), tss.gs);
    expectEqual(u32(0), tss.ldtr);
    expectEqual(u16(0), tss.trap);
    expectEqual(u16(@sizeOf(TtsEntry)), tss.io_permissions_base_offset);

    // Call function
    setTssStack(u32(100));

    // Post-testing
    expectEqual(u32(0), tss.prev_tss);
    expectEqual(u32(100), tss.esp0);
    expectEqual(u32(KERNEL_DATA_OFFSET), tss.ss0);
    expectEqual(u32(0), tss.esp1);
    expectEqual(u32(0), tss.ss1);
    expectEqual(u32(0), tss.esp2);
    expectEqual(u32(0), tss.ss2);
    expectEqual(u32(0), tss.cr3);
    expectEqual(u32(0), tss.eip);
    expectEqual(u32(0), tss.eflags);
    expectEqual(u32(0), tss.eax);
    expectEqual(u32(0), tss.ecx);
    expectEqual(u32(0), tss.edx);
    expectEqual(u32(0), tss.ebx);
    expectEqual(u32(0), tss.esp);
    expectEqual(u32(0), tss.ebp);
    expectEqual(u32(0), tss.esi);
    expectEqual(u32(0), tss.edi);
    expectEqual(u32(0), tss.es);
    expectEqual(u32(0), tss.cs);
    expectEqual(u32(0), tss.ss);
    expectEqual(u32(0), tss.ds);
    expectEqual(u32(0), tss.fs);
    expectEqual(u32(0), tss.gs);
    expectEqual(u32(0), tss.ldtr);
    expectEqual(u16(0), tss.trap);
    expectEqual(u16(@sizeOf(TtsEntry)), tss.io_permissions_base_offset);

    // Clean up
    setTssStack(u32(0));

    expectEqual(u32(0), tss.prev_tss);
    expectEqual(u32(0), tss.esp0);
    expectEqual(u32(KERNEL_DATA_OFFSET), tss.ss0);
    expectEqual(u32(0), tss.esp1);
    expectEqual(u32(0), tss.ss1);
    expectEqual(u32(0), tss.esp2);
    expectEqual(u32(0), tss.ss2);
    expectEqual(u32(0), tss.cr3);
    expectEqual(u32(0), tss.eip);
    expectEqual(u32(0), tss.eflags);
    expectEqual(u32(0), tss.eax);
    expectEqual(u32(0), tss.ecx);
    expectEqual(u32(0), tss.edx);
    expectEqual(u32(0), tss.ebx);
    expectEqual(u32(0), tss.esp);
    expectEqual(u32(0), tss.ebp);
    expectEqual(u32(0), tss.esi);
    expectEqual(u32(0), tss.edi);
    expectEqual(u32(0), tss.es);
    expectEqual(u32(0), tss.cs);
    expectEqual(u32(0), tss.ss);
    expectEqual(u32(0), tss.ds);
    expectEqual(u32(0), tss.fs);
    expectEqual(u32(0), tss.gs);
    expectEqual(u32(0), tss.ldtr);
    expectEqual(u16(0), tss.trap);
    expectEqual(u16(@sizeOf(TtsEntry)), tss.io_permissions_base_offset);
}

test "init" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("ltr", TSS_OFFSET);

    arch.addConsumeFunction("lgdt", mock_lgdt);

    // Call function
    init();

    // Post testing
    const tss_entry = gdt_entries[TSS_INDEX];
    const tss_limit = @sizeOf(TtsEntry) - 1;
    const tss_addr = @ptrToInt(&tss);

    var expected = u64(0);
    expected |= u64(@truncate(u16, tss_limit));
    expected |= u64(@truncate(u24, tss_addr)) << 16;
    expected |= u64(0x89) << (16 + 24);
    expected |= u64(@truncate(u4, tss_limit >> 16)) << (16 + 24 + 8);
    // Flags are zero
    expected |= u64(@truncate(u8, tss_addr >> 24)) << (16 + 24 + 8 + 4 + 4);

    expectEqual(expected, @bitCast(u64, tss_entry));

    // Reset
    gdt_ptr.base = 0;
    gdt_entries[TSS_INDEX] = makeEntry(0, 0, NULL_SEGMENT, NULL_FLAGS);
}

///
/// Check that the GDT table was loaded properly by getting the previously loaded table and
/// compare the limit and base address.
///
fn rt_loadedGDTSuccess() void {
    const loaded_gdt = arch.sgdt();
    expect(gdt_ptr.limit == loaded_gdt.limit);
    expect(gdt_ptr.base == loaded_gdt.base);
}

///
/// Run all the runtime tests.
///
fn runtimeTests() void {
    rt_loadedGDTSuccess();
    log.logInfo("GDT: Tested loading GDT\n");
}
