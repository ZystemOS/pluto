const std = @import("std");
const gdt_common = @import("../common/gdt.zig");

/// The TSS entry structure
pub const Tss = packed struct {
    /// Pointer to the previous TSS entry
    prev_tss: u16 = 0,
    reserved1: u16 = 0,

    /// Ring 0 32 bit stack pointer.
    esp0: u32 = 0,

    /// Ring 0 32 bit stack pointer.
    ss0: u16 = gdt_common.KERNEL_DATA_OFFSET,
    reserved2: u16 = 0,

    /// Ring 1 32 bit stack pointer.
    esp1: u32 = 0,

    /// Ring 1 32 bit stack pointer.
    ss1: u16 = 0,
    reserved3: u16 = 0,

    /// Ring 2 32 bit stack pointer.
    esp2: u32 = 0,

    /// Ring 2 32 bit stack pointer.
    ss2: u16 = 0,
    reserved4: u16 = 0,

    /// The CR3 control register 3.
    cr3: u32 = 0,

    /// 32 bit instruction pointer.
    eip: u32 = 0,

    /// 32 bit flags register.
    eflags: u32 = 0,

    /// 32 bit accumulator register.
    eax: u32 = 0,

    /// 32 bit counter register.
    ecx: u32 = 0,

    /// 32 bit data register.
    edx: u32 = 0,

    /// 32 bit base register.
    ebx: u32 = 0,

    /// 32 bit stack pointer register.
    esp: u32 = 0,

    /// 32 bit base pointer register.
    ebp: u32 = 0,

    /// 32 bit source register.
    esi: u32 = 0,

    /// 32 bit destination register.
    edi: u32 = 0,

    /// The extra segment.
    es: u16 = 0,
    reserved5: u16 = 0,

    /// The code segment.
    cs: u16 = 0,
    reserved6: u16 = 0,

    /// The stack segment.
    ss: u16 = 0,
    reserved7: u16 = 0,

    /// The data segment.
    ds: u16 = 0,
    reserved8: u16 = 0,

    /// A extra segment FS.
    fs: u16 = 0,
    reserved9: u16 = 0,

    /// A extra segment GS.
    gs: u16 = 0,
    reserved10: u16 = 0,

    /// The local descriptor table register.
    ldtr: u16 = 0,
    reserved11: u16 = 0,

    /// ?
    trap: u16 = 0,

    /// A pointer to a I/O port bitmap for the current task which specifies individual ports the program should have access to.
    io_permissions_base_offset: u16 = @sizeOf(Tss),
};

// Check the sizes of the packet structs.
comptime {
    std.debug.assert(@sizeOf(Tss) == 104);
}

/// The main task state segment entry.
pub const tss_entry: Tss = Tss{};
