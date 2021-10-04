const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const log = std.log.scoped(.x86_gdt);
const builtin = std.builtin;
const is_test = builtin.is_test;
const panic = @import("../../panic.zig").panic;
const build_options = @import("build_options");
const arch = if (is_test) @import("../../../../test/mock/kernel/arch_mock.zig") else @import("arch.zig");

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
const Tss = packed struct {
    /// Pointer to the previous TSS entry
    prev_tss: u16,
    reserved1: u16,

    /// Ring 0 32 bit stack pointer.
    esp0: u32,

    /// Ring 0 32 bit stack pointer.
    ss0: u16,
    reserved2: u16,

    /// Ring 1 32 bit stack pointer.
    esp1: u32,

    /// Ring 1 32 bit stack pointer.
    ss1: u16,
    reserved3: u16,

    /// Ring 2 32 bit stack pointer.
    esp2: u32,

    /// Ring 2 32 bit stack pointer.
    ss2: u16,
    reserved4: u16,

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
    es: u16,
    reserved5: u16,

    /// The code segment.
    cs: u16,
    reserved6: u16,

    /// The stack segment.
    ss: u16,
    reserved7: u16,

    /// The data segment.
    ds: u16,
    reserved8: u16,

    /// A extra segment FS.
    fs: u16,
    reserved9: u16,

    /// A extra segment GS.
    gs: u16,
    reserved10: u16,

    /// The local descriptor table register.
    ldtr: u16,
    reserved11: u16,

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

/// The total number of entries in the GDT including: null, kernel code, kernel data, user code,
/// user data and the TSS.
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
var gdt_entries: [NUMBER_OF_ENTRIES]GdtEntry = init: {
    var gdt_entries_temp: [NUMBER_OF_ENTRIES]GdtEntry = undefined;

    // Null descriptor
    gdt_entries_temp[0] = makeGdtEntry(0, 0, NULL_SEGMENT, NULL_FLAGS);

    // Kernel code descriptor
    gdt_entries_temp[1] = makeGdtEntry(0, 0xFFFFF, KERNEL_SEGMENT_CODE, PAGING_32_BIT);

    // Kernel data descriptor
    gdt_entries_temp[2] = makeGdtEntry(0, 0xFFFFF, KERNEL_SEGMENT_DATA, PAGING_32_BIT);

    // User code descriptor
    gdt_entries_temp[3] = makeGdtEntry(0, 0xFFFFF, USER_SEGMENT_CODE, PAGING_32_BIT);

    // User data descriptor
    gdt_entries_temp[4] = makeGdtEntry(0, 0xFFFFF, USER_SEGMENT_DATA, PAGING_32_BIT);

    // TSS descriptor, one each for each processor
    // Will initialise the TSS at runtime
    gdt_entries_temp[5] = makeGdtEntry(0, 0, NULL_SEGMENT, NULL_FLAGS);
    break :init gdt_entries_temp;
};

/// The GDT pointer that the CPU is loaded with that contains the base address of the GDT and the
/// size.
var gdt_ptr: GdtPtr = GdtPtr{
    .limit = TABLE_SIZE,
    .base = undefined,
};

/// The main task state segment entry.
pub var main_tss_entry: Tss = init: {
    var tss_temp = std.mem.zeroes(Tss);
    tss_temp.ss0 = KERNEL_DATA_OFFSET;
    tss_temp.io_permissions_base_offset = @sizeOf(Tss);
    break :init tss_temp;
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
fn makeGdtEntry(base: u32, limit: u20, access: AccessBits, flags: FlagBits) GdtEntry {
    return .{
        .limit_low = @truncate(u16, limit),
        .base_low = @truncate(u24, base),
        .access = .{
            .accessed = access.accessed,
            .read_write = access.read_write,
            .direction_conforming = access.direction_conforming,
            .executable = access.executable,
            .descriptor = access.descriptor,
            .privilege = access.privilege,
            .present = access.present,
        },
        .limit_high = @truncate(u4, limit >> 16),
        .flags = .{
            .reserved_zero = flags.reserved_zero,
            .is_64_bit = flags.is_64_bit,
            .is_32_bit = flags.is_32_bit,
            .granularity = flags.granularity,
        },
        .base_high = @truncate(u8, base >> 24),
    };
}

///
/// Initialise the Global Descriptor table.
///
pub fn init() void {
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});
    // Initiate TSS
    gdt_entries[TSS_INDEX] = makeGdtEntry(@ptrToInt(&main_tss_entry), @sizeOf(Tss) - 1, TSS_SEGMENT, NULL_FLAGS);

    // Set the base address where all the GDT entries are.
    gdt_ptr.base = @ptrToInt(&gdt_entries[0]);

    // Load the GDT
    arch.lgdt(&gdt_ptr) catch |e| panic(@errorReturnTrace(), "Failed to set the GDT: {}", .{e});

    // Load the TSS
    arch.ltr(TSS_OFFSET);

    switch (build_options.test_mode) {
        .Initialisation => runtimeTests(),
        else => {},
    }
}

fn mock_lgdt(ptr: *const GdtPtr) anyerror!void {
    try expectEqual(TABLE_SIZE, ptr.limit);
    try expectEqual(@ptrToInt(&gdt_entries[0]), ptr.base);
}

test "GDT entries" {
    try expectEqual(@as(u32, 1), @sizeOf(AccessBits));
    try expectEqual(@as(u32, 1), @sizeOf(FlagBits));
    try expectEqual(@as(u32, 8), @sizeOf(GdtEntry));
    try expectEqual(@as(u32, 104), @sizeOf(Tss));
    try expectEqual(@as(u32, 6), @sizeOf(GdtPtr));

    const null_entry = gdt_entries[NULL_INDEX];
    try expectEqual(@as(u64, 0), @bitCast(u64, null_entry));

    const kernel_code_entry = gdt_entries[KERNEL_CODE_INDEX];
    try expectEqual(@as(u64, 0xCF9A000000FFFF), @bitCast(u64, kernel_code_entry));

    const kernel_data_entry = gdt_entries[KERNEL_DATA_INDEX];
    try expectEqual(@as(u64, 0xCF92000000FFFF), @bitCast(u64, kernel_data_entry));

    const user_code_entry = gdt_entries[USER_CODE_INDEX];
    try expectEqual(@as(u64, 0xCFFA000000FFFF), @bitCast(u64, user_code_entry));

    const user_data_entry = gdt_entries[USER_DATA_INDEX];
    try expectEqual(@as(u64, 0xCFF2000000FFFF), @bitCast(u64, user_data_entry));

    const tss_entry = gdt_entries[TSS_INDEX];
    try expectEqual(@as(u64, 0), @bitCast(u64, tss_entry));

    try expectEqual(TABLE_SIZE, gdt_ptr.limit);

    try expectEqual(@as(u32, 0), main_tss_entry.prev_tss);
    try expectEqual(@as(u32, 0), main_tss_entry.esp0);
    try expectEqual(@as(u32, KERNEL_DATA_OFFSET), main_tss_entry.ss0);
    try expectEqual(@as(u32, 0), main_tss_entry.esp1);
    try expectEqual(@as(u32, 0), main_tss_entry.ss1);
    try expectEqual(@as(u32, 0), main_tss_entry.esp2);
    try expectEqual(@as(u32, 0), main_tss_entry.ss2);
    try expectEqual(@as(u32, 0), main_tss_entry.cr3);
    try expectEqual(@as(u32, 0), main_tss_entry.eip);
    try expectEqual(@as(u32, 0), main_tss_entry.eflags);
    try expectEqual(@as(u32, 0), main_tss_entry.eax);
    try expectEqual(@as(u32, 0), main_tss_entry.ecx);
    try expectEqual(@as(u32, 0), main_tss_entry.edx);
    try expectEqual(@as(u32, 0), main_tss_entry.ebx);
    try expectEqual(@as(u32, 0), main_tss_entry.esp);
    try expectEqual(@as(u32, 0), main_tss_entry.ebp);
    try expectEqual(@as(u32, 0), main_tss_entry.esi);
    try expectEqual(@as(u32, 0), main_tss_entry.edi);
    try expectEqual(@as(u32, 0), main_tss_entry.es);
    try expectEqual(@as(u32, 0), main_tss_entry.cs);
    try expectEqual(@as(u32, 0), main_tss_entry.ss);
    try expectEqual(@as(u32, 0), main_tss_entry.ds);
    try expectEqual(@as(u32, 0), main_tss_entry.fs);
    try expectEqual(@as(u32, 0), main_tss_entry.gs);
    try expectEqual(@as(u32, 0), main_tss_entry.ldtr);
    try expectEqual(@as(u16, 0), main_tss_entry.trap);

    // Size of Tss will fit in a u16 as 104 < 65535 (2^16)
    try expectEqual(@as(u16, @sizeOf(Tss)), main_tss_entry.io_permissions_base_offset);
}

test "makeGdtEntry NULL" {
    const actual = makeGdtEntry(0, 0, NULL_SEGMENT, NULL_FLAGS);

    const expected: u64 = 0;
    try expectEqual(expected, @bitCast(u64, actual));
}

test "makeGdtEntry alternating bit pattern" {
    const alt_access = AccessBits{
        .accessed = 1,
        .read_write = 0,
        .direction_conforming = 1,
        .executable = 0,
        .descriptor = 1,
        .privilege = 0b10,
        .present = 0,
    };

    try expectEqual(@as(u8, 0b01010101), @bitCast(u8, alt_access));

    const alt_flag = FlagBits{
        .reserved_zero = 1,
        .is_64_bit = 0,
        .is_32_bit = 1,
        .granularity = 0,
    };

    try expectEqual(@as(u4, 0b0101), @bitCast(u4, alt_flag));

    const actual = makeGdtEntry(0b01010101010101010101010101010101, 0b01010101010101010101, alt_access, alt_flag);

    const expected: u64 = 0b0101010101010101010101010101010101010101010101010101010101010101;
    try expectEqual(expected, @bitCast(u64, actual));
}

test "init" {
    // Set up
    arch.initTest();
    defer arch.freeTest();

    arch.addTestParams("ltr", .{TSS_OFFSET});

    arch.addConsumeFunction("lgdt", mock_lgdt);

    // Call function
    init();

    // Post testing
    const tss_entry = gdt_entries[TSS_INDEX];
    const tss_limit = @sizeOf(Tss) - 1;
    const tss_addr = @ptrToInt(&main_tss_entry);

    var expected: u64 = 0;
    expected |= @as(u64, @truncate(u16, tss_limit));
    expected |= @as(u64, @truncate(u24, tss_addr)) << 16;
    expected |= @as(u64, 0x89) << (16 + 24);
    expected |= @as(u64, @truncate(u4, tss_limit >> 16)) << (16 + 24 + 8);
    // Flags are zero
    expected |= @as(u64, @truncate(u8, tss_addr >> 24)) << (16 + 24 + 8 + 4 + 4);

    try expectEqual(expected, @bitCast(u64, tss_entry));

    // Reset
    gdt_ptr.base = 0;
    gdt_entries[TSS_INDEX] = makeGdtEntry(0, 0, NULL_SEGMENT, NULL_FLAGS);
}

///
/// Check that the GDT table was loaded properly by getting the previously loaded table and
/// compare the limit and base address.
///
fn rt_loadedGDTSuccess() void {
    const loaded_gdt = arch.sgdt();
    if (gdt_ptr.limit != loaded_gdt.limit) {
        panic(@errorReturnTrace(), "FAILURE: GDT not loaded properly: 0x{X} != 0x{X}\n", .{ gdt_ptr.limit, loaded_gdt.limit });
    }
    if (gdt_ptr.base != loaded_gdt.base) {
        panic(@errorReturnTrace(), "FAILURE: GDT not loaded properly: 0x{X} != {X}\n", .{ gdt_ptr.base, loaded_gdt.base });
    }
    log.info("Tested loading GDT\n", .{});
}

///
/// Run all the runtime tests.
///
pub fn runtimeTests() void {
    rt_loadedGDTSuccess();
}
