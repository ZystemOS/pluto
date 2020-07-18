// Can't do: TODO: https://github.com/SamTebbs33/pluto/issues/77
//const src_gdt = @import("arch").gdt;
const src_gdt = @import("../../../src/kernel/arch/x86/gdt.zig");

const mock_framework = @import("mock_framework.zig");
pub const initTest = mock_framework.initTest;
pub const freeTest = mock_framework.freeTest;
pub const addTestParams = mock_framework.addTestParams;
pub const addConsumeFunction = mock_framework.addConsumeFunction;
pub const addRepeatFunction = mock_framework.addRepeatFunction;

const AccessBits = packed struct {
    accessed: u1,
    read_write: u1,
    direction_conforming: u1,
    executable: u1,
    descriptor: u1,
    privilege: u2,
    present: u1,
};

const FlagBits = packed struct {
    reserved_zero: u1,
    is_64_bit: u1,
    is_32_bit: u1,
    granularity: u1,
};

const GdtEntry = packed struct {
    limit_low: u16,
    base_low: u24,
    access: AccessBits,
    limit_high: u4,
    flags: FlagBits,
    base_high: u8,
};

const Tss = packed struct {
    prev_tss: u32,
    esp0: u32,
    ss0: u32,
    esp1: u32,
    ss1: u32,
    esp2: u32,
    ss2: u32,
    cr3: u32,
    eip: u32,
    eflags: u32,
    eax: u32,
    ecx: u32,
    edx: u32,
    ebx: u32,
    esp: u32,
    ebp: u32,
    esi: u32,
    edi: u32,
    es: u32,
    cs: u32,
    ss: u32,
    ds: u32,
    fs: u32,
    gs: u32,
    ldtr: u32,
    trap: u16,
    io_permissions_base_offset: u16,
};

// Need to use the type from the source file so that types match
pub const GdtPtr = src_gdt.GdtPtr;

const NUMBER_OF_ENTRIES: u16 = 0x06;

const TABLE_SIZE: u16 = @sizeOf(GdtEntry) * NUMBER_OF_ENTRIES - 1;

const NULL_INDEX: u16 = 0x00;
const KERNEL_CODE_INDEX: u16 = 0x01;
const KERNEL_DATA_INDEX: u16 = 0x02;
const USER_CODE_INDEX: u16 = 0x03;
const USER_DATA_INDEX: u16 = 0x04;
const TSS_INDEX: u16 = 0x05;

const NULL_SEGMENT: AccessBits = AccessBits{
    .accessed = 0,
    .read_write = 0,
    .direction_conforming = 0,
    .executable = 0,
    .descriptor = 0,
    .privilege = 0,
    .present = 0,
};

const KERNEL_SEGMENT_CODE: AccessBits = AccessBits{
    .accessed = 0,
    .read_write = 1,
    .direction_conforming = 0,
    .executable = 1,
    .descriptor = 1,
    .privilege = 0,
    .present = 1,
};

const KERNEL_SEGMENT_DATA: AccessBits = AccessBits{
    .accessed = 0,
    .read_write = 1,
    .direction_conforming = 0,
    .executable = 0,
    .descriptor = 1,
    .privilege = 0,
    .present = 1,
};

const USER_SEGMENT_CODE: AccessBits = AccessBits{
    .accessed = 0,
    .read_write = 1,
    .direction_conforming = 0,
    .executable = 1,
    .descriptor = 1,
    .privilege = 3,
    .present = 1,
};

const USER_SEGMENT_DATA: AccessBits = AccessBits{
    .accessed = 0,
    .read_write = 1,
    .direction_conforming = 0,
    .executable = 0,
    .descriptor = 1,
    .privilege = 3,
    .present = 1,
};

const TSS_SEGMENT: AccessBits = AccessBits{
    .accessed = 1,
    .read_write = 0,
    .direction_conforming = 0,
    .executable = 1,
    .descriptor = 0,
    .privilege = 0,
    .present = 1,
};

const NULL_FLAGS: FlagBits = FlagBits{
    .reserved_zero = 0,
    .is_64_bit = 0,
    .is_32_bit = 0,
    .granularity = 0,
};

const PAGING_32_BIT: FlagBits = FlagBits{
    .reserved_zero = 0,
    .is_64_bit = 0,
    .is_32_bit = 1,
    .granularity = 1,
};

pub const NULL_OFFSET: u16 = 0x00;
pub const KERNEL_CODE_OFFSET: u16 = 0x08;
pub const KERNEL_DATA_OFFSET: u16 = 0x10;
pub const USER_CODE_OFFSET: u16 = 0x18;
pub const USER_DATA_OFFSET: u16 = 0x20;
pub const TSS_OFFSET: u16 = 0x28;

pub fn init() void {
    return mock_framework.performAction("init", void);
}
