const std = @import("std");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const vmm = @import("../../../vmm.zig");
const mem = @import("../../../mem.zig");

/// An entry within a page table. References a single page.
/// Bit 0: Present. Set if present in physical memory.
///        When not set, all remaining 31 bits are ignored and available for use.
/// Bit 1: Writeable. Set if writeable.
/// Bit 2: User. Set if accessible by user mode.
/// Bit 3: Write through. Set if write-through caching is enabled.
/// Bit 4: Cache disabled. Set if caching is disabled for this page.
/// Bit 5: Accessed. Set by the CPU when the page is accessed. Not cleared by CPU.
/// Bit 6: Dirty. Set by the CPU when the page has been written to. Not cleared by the CPU.
/// Bit 7: Zero.
/// Bit 8: Global. Set if the cached address for this page shouldn't be updated when cr3 is changed.
/// Bits 9-11: Ignored and available for use by the kernel.
/// Bits 12-(M-1): The 4KB aligned physical address mapped to this page.
/// Bits M-51: Reserved
/// Bits 51-63: Ignored.
/// Where M is the maximum physical address length, this is usually 40.
const EntryType = u64;

/// The table of page map level 4 entries.
pub const PageMapLevel4 = packed struct {
    entries: [ENTRIES_PER_TABLE]EntryType,
};

/// The table of directory pointer table entries.
const DirectoryPointerTable = packed struct {
    entries: [ENTRIES_PER_TABLE]EntryType,
};

/// The table of directory entries.
const Directory = packed struct {
    entries: [ENTRIES_PER_TABLE]EntryType,
};

/// The table of table entries.
const Table = packed struct {
    entries: [ENTRIES_PER_TABLE]EntryType,
};

/// Each table has 512 entries
const ENTRIES_PER_TABLE: u64 = PAGE_SIZE_4KB / @sizeOf(u64);

// Bit masks for setting and clearing attributes.
const ENTRY_PRESENT: u64 = 0x1;
const ENTRY_WRITABLE: u64 = 0x2;
const ENTRY_USER: u64 = 0x4;
const ENTRY_WRITE_THROUGH: u64 = 0x8;
const ENTRY_CACHE_DISABLED: u64 = 0x10;
const ENTRY_ACCESSED: u64 = 0x20;
const ENTRY_ZERO: u64 = 0x40;
const ENTRY_MEMORY_TYPE: u64 = 0x80;

/// The mask for the physical address in the page entry.
const FRAME_MASK: u64 = 0x000FFFFFFFFFF000;

/// The 4KB page size in bytes.
pub const PAGE_SIZE_4KB: usize = 0x1000;

/// The 2MB page size in bytes.
const PAGE_SIZE_2MB: usize = PAGE_SIZE_4KB * 512;

/// The 1GB page size in bytes.
const PAGE_SIZE_1GB: usize = PAGE_SIZE_2MB * 512;

/// The 512GB page size in bytes.
const PAGE_SIZE_512GB: usize = PAGE_SIZE_1GB * 512;

// Check the packed structs are the correct size.
comptime {
    std.debug.assert(ENTRIES_PER_TABLE == 512);
    std.debug.assert(@sizeOf(Table) == PAGE_SIZE_4KB);
    std.debug.assert(@sizeOf(Directory) == PAGE_SIZE_4KB);
    std.debug.assert(@sizeOf(DirectoryPointerTable) == PAGE_SIZE_4KB);
    std.debug.assert(@sizeOf(PageMapLevel4) == PAGE_SIZE_4KB);
}

/// The kernels root page table: Page Map Level 4.
pub var kernel_pml4: PageMapLevel4 align(PAGE_SIZE_4KB) = .{
    .entries = [_]EntryType{0} ** ENTRIES_PER_TABLE,
};

///
/// Get the 9 bit page map level 4 address part out of the virtual address.
///
/// Arguments:
///     IN virt: u64 - The virtual address.
///
/// Return: u64
///     The page map level 4 address, bits 47:39 (inclusive).
///
fn virtToPML4EntryIdx(virt: u64) callconv(.Inline) u64 {
    return virt >> 39 & 0x1FF;
}

///
/// Get the 9 bit page directory pointer table address part out of the virtual address.
///
/// Arguments:
///     IN virt: u64 - The virtual address.
///
/// Return: u64
///     The page directory pointer table address, bits 38:30 (inclusive).
///
fn virtToPDPTEntryIdx(virt: u64) callconv(.Inline) u64 {
    return virt >> 30 & 0x1FF;
}

///
/// Get the 9 bit page directory address part out of the virtual address.
///
/// Arguments:
///     IN virt: u64 - The virtual address.
///
/// Return: u64
///     The page directory address, bits 29:21 (inclusive).
///
fn virtToPDEntryIdx(virt: u64) callconv(.Inline) u64 {
    return virt >> 21 & 0x1FF;
}

///
/// Get the 9 bit page table address part out of the virtual address.
///
/// Arguments:
///     IN virt: u64 - The virtual address.
///
/// Return: u64
///     The page table address, bits 20:12 (inclusive).
///
fn virtToPTEntryIdx(virt: u64) callconv(.Inline) u64 {
    return virt >> 12 & 0x1FF;
}

///
/// Get the physical/frame address out of a page entry. Currently this is a 40 bit address, will
/// need to check the CPUID 0x80000008 as this is hardcoded to 40 bits.
///
/// Arguments:
///     IN entry: u64 - The page entry to get the frame from.
///
/// Return: u64
///     The physical address. This will point to the next page entry in the chain.
///
fn getFrame(entry: u64) callconv(.Inline) u64 {
    return entry & FRAME_MASK;
}

///
/// Set the physical/frame address of a page entry. Currently this is a 40 bit address, will
/// need to check the CPUID 0x80000008 as this is hardcoded to 40 bits.
/// This assumes the address is aligned to the page boundary.
///
/// Arguments:
///     IN entry: *u64    - The page entry to set the frame to.
///     IN phys_addr: u64 - The address to set the entry.
///
fn setFrame(entry: *u64, phys_addr: u64) callconv(.Inline) void {
    std.debug.assert(std.mem.isAligned(phys_addr, PAGE_SIZE_4KB));
    entry.* |= phys_addr & FRAME_MASK;
}

///
/// Set the bit(s) associated with an attribute.
///
/// Arguments:
///     entry: *u64 - The entry to modify.
///     attr: u64   - The bits corresponding to the attribute to set.
///
fn setAttribute(entry: *align(1) u64, attr: u64) callconv(.Inline) void {
    entry.* |= attr;
}

///
/// Clear the bit(s) associated with an attribute.
///
/// Arguments:
///     entry: *u64 - The entry to modify.
///     attr: u64   - The bits corresponding to the attribute to clear.
///
fn clearAttribute(entry: *align(1) u64, attr: u64) callconv(.Inline) void {
    entry.* &= ~attr;
}

///
/// Check if the entry has an attribute.
///
/// Arguments:
///     entry: u64 - The entry to check.
///     attr: u64  - The bits corresponding to the attribute to check.
///
/// Return: bool
///     The entry has the attribute.
///
fn hasAttribute(entry: u64, attr: u64) callconv(.Inline) bool {
    return entry & attr == attr;
}

///
/// Set or clear the attributes from the VMM attributes to the page entry attributes.
///
/// Arguments:
///     IN entry: *align(1) u64  - The entry to set or clear attributes.
///     IN attrs: vmm.Attributes - The VMM attributes.
///
fn setAllAttributes(entry: *align(1) u64, attrs: vmm.Attributes) void {
    if (attrs.writable) {
        setAttribute(entry, ENTRY_WRITABLE);
    } else {
        clearAttribute(entry, ENTRY_WRITABLE);
    }

    if (attrs.kernel) {
        clearAttribute(entry, ENTRY_USER);
    } else {
        setAttribute(entry, ENTRY_USER);
    }

    if (attrs.cachable) {
        clearAttribute(entry, ENTRY_CACHE_DISABLED);
    } else {
        setAttribute(entry, ENTRY_CACHE_DISABLED);
    }
}

///
/// Get the table pointer from the entry frame. Valid types are DirectoryPointerTable, Directory
/// and Table.
///
/// Arguments:
///     IN comptime TableType: type - The type of the table to convert the frame to.
///     IN entry: u64               - The entry to get the frame address.
///
/// Return: *TableType
///     The pointer to the table from the entry frame.
///
/// Error: vmm.MapperError
///     vmm.MapperError.NotMapped - If the entry is not mapped.
///
fn getTableFromEntry(comptime TableType: type, entry: u64) vmm.MapperError!*TableType {
    if (TableType != DirectoryPointerTable and TableType != Directory and TableType != Table) {
        @compileError("Not valid type: " ++ @typeName(TableType));
    }
    if (hasAttribute(entry, ENTRY_PRESENT)) {
        const table_virt_addr = mem.physToVirt(getFrame(entry));
        return @intToPtr(*TableType, table_virt_addr);
    } else {
        return vmm.MapperError.NotMapped;
    }
}

///
/// Helper function for calculating the next address in the sequence.
/// This is used as Integer overflow can occur at the end of the address space so if this occurs
/// then 0xFFFFFFFF_FFFFF000 is returned. This is the last mappable address.
///
/// Arguments:
///     IN end: u64   - The end address to test minimum with the proposed next address.
///     IN start: u64 - The start address.
///     IN add: u64   - The alignment to add to the start address to get the next proposed address.
///
/// Return: u64
///     The next address.
///
fn addMin(end: u64, start: u64, add: u64) u64 {
    const try_add = std.math.add(u64, start, add) catch 0xFFFFFFFF_FFFFF000;
    return std.math.min(end, try_add);
}

///
/// Map a 4KB aligned virtual address to a physical address. The addresses are assumed to be
/// aligned to 4KB.
///
/// Arguments:
///     IN virtual_addr: u64          - The virtual address to map, this will be a 4KB entry.
///     IN physical_addr: u64         - The physical address to map, this will be a 4KB entry.
///     IN attrs: vmm.Attributes      - The attributes for the mapping.
///     IN allocator: *Allocator      - The allocator to allocate a new page table entry if needed.
///     IN page_table: *PageMapLevel4 - The root page map table.
///
/// Error: Allocator.Error || vmm.MapperError
///     Allocator.Error - Error allocating a new page mapping entry.
///     vmm.MapperError - Part of the address range is already mapped.
///
fn mapEntry(virtual_addr: u64, physical_addr: u64, attrs: vmm.Attributes, allocator: *Allocator, page_table: *PageMapLevel4) (Allocator.Error || vmm.MapperError)!void {
    std.debug.assert(std.mem.isAligned(virtual_addr, PAGE_SIZE_4KB));
    std.debug.assert(std.mem.isAligned(physical_addr, PAGE_SIZE_4KB));
    const pml4_part = virtToPML4EntryIdx(virtual_addr);
    const pdpt_part = virtToPDPTEntryIdx(virtual_addr);
    const pd_part = virtToPDEntryIdx(virtual_addr);
    const pt_part = virtToPTEntryIdx(virtual_addr);

    const pdpt = getTableFromEntry(DirectoryPointerTable, page_table.entries[pml4_part]) catch brk: {
        // Allocate one
        var new_pml4_entry: u64 = 0;
        const pdpt = &(try allocator.alignedAlloc(DirectoryPointerTable, PAGE_SIZE_4KB, 1))[0];
        @memset(@ptrCast([*]u8, pdpt), 0, @sizeOf(DirectoryPointerTable));
        const phys_addr = mem.virtToPhys(@ptrToInt(pdpt));
        setFrame(&new_pml4_entry, phys_addr);
        setAttribute(&new_pml4_entry, ENTRY_PRESENT);
        setAllAttributes(&new_pml4_entry, attrs);
        page_table.entries[pml4_part] = new_pml4_entry;
        break :brk pdpt;
    };

    const pd = getTableFromEntry(Directory, pdpt.entries[pdpt_part]) catch brk: {
        // Allocate one
        var new_pdpt_entry: u64 = 0;
        const pd = &(try allocator.alignedAlloc(Directory, PAGE_SIZE_4KB, 1))[0];
        @memset(@ptrCast([*]u8, pd), 0, @sizeOf(Directory));
        const phys_addr = mem.virtToPhys(@ptrToInt(pd));
        setFrame(&new_pdpt_entry, phys_addr);
        setAttribute(&new_pdpt_entry, ENTRY_PRESENT);
        setAllAttributes(&new_pdpt_entry, attrs);
        pdpt.entries[pdpt_part] = new_pdpt_entry;
        break :brk pd;
    };

    const pt = getTableFromEntry(Table, pd.entries[pd_part]) catch brk: {
        // Allocate one
        var new_pd_entry: u64 = 0;
        const pt = &(try allocator.alignedAlloc(Table, PAGE_SIZE_4KB, 1))[0];
        @memset(@ptrCast([*]u8, pt), 0, @sizeOf(Table));
        const phys_addr = mem.virtToPhys(@ptrToInt(pt));
        setFrame(&new_pd_entry, phys_addr);
        setAttribute(&new_pd_entry, ENTRY_PRESENT);
        setAllAttributes(&new_pd_entry, attrs);
        pd.entries[pd_part] = new_pd_entry;
        break :brk pt;
    };

    var new_pt_entry: u64 = 0;
    setFrame(&new_pt_entry, physical_addr);
    setAttribute(&new_pt_entry, ENTRY_PRESENT);
    setAllAttributes(&new_pt_entry, attrs);

    pt.entries[pt_part] = new_pt_entry;
}

///
/// Unmap an address range from start to end from the Page Table.
///
/// Arguments:
///     IN virt_start: u64    - The start virtual address.
///     IN virt_end: u64      - The end virtual address.
///     IN page_table: *Table - The Page Table to unmap from.
///
/// Error: vmm.MapperError
///     vmm.MapperError - The range or part of it is not mapped.
///
fn unmapPTEntry(virt_start: u64, virt_end: u64, page_table: *Table) vmm.MapperError!void {
    var virt_addr = virt_start;
    var virt_next = addMin(virt_end, std.mem.alignBackward(virt_addr, PAGE_SIZE_4KB), PAGE_SIZE_4KB);
    var pt_part = virtToPTEntryIdx(virt_addr);
    while (virt_addr < virt_end) : ({
        virt_addr = virt_next;
        virt_next = addMin(virt_end, virt_next, PAGE_SIZE_4KB);
        pt_part += 1;
    }) {
        const pt_entry = &page_table.entries[pt_part];
        clearAttribute(pt_entry, ENTRY_PRESENT);
    }
}

///
/// Unmap a the address range from start to end from the Page Directory.
///
/// Arguments:
///     IN virt_start: u64        - The start virtual address.
///     IN virt_end: u64          - The end virtual address.
///     IN allocator: *Allocator  - The allocator used to allocate the Page Table.
///     IN page_table: *Directory - The Page Directory to unmap from.
///
/// Error: vmm.MapperError
///     vmm.MapperError - The range or part of it is not mapped.
///
fn unmapPDEntry(virt_start: u64, virt_end: u64, allocator: *Allocator, page_table: *Directory) vmm.MapperError!void {
    var virt_addr = virt_start;
    var virt_next = addMin(virt_end, std.mem.alignBackward(virt_addr, PAGE_SIZE_2MB), PAGE_SIZE_2MB);
    var pd_part = virtToPDEntryIdx(virt_addr);
    while (virt_addr < virt_end) : ({
        virt_addr = virt_next;
        virt_next = addMin(virt_end, virt_next, PAGE_SIZE_2MB);
        pd_part += 1;
    }) {
        const pd_entry = &page_table.entries[pd_part];
        const pt = try getTableFromEntry(Table, pd_entry.*);
        try unmapPTEntry(virt_addr, virt_next, pt);
        if (std.mem.isAligned(virt_addr, PAGE_SIZE_2MB) and virt_next - virt_addr >= PAGE_SIZE_2MB - PAGE_SIZE_4KB) {
            const frame = getFrame(pd_entry.*);
            const ptr = @intToPtr([*]Table, frame)[0..1];
            allocator.free(ptr);
            // Clear everything
            pd_entry.* = 0;
        }
    }
}

///
/// Unmap an address range from start to end from the Page Directory Pointer Table.
///
/// Arguments:
///     IN virt_start: u64                    - The start virtual address.
///     IN virt_end: u64                      - The end virtual address.
///     IN allocator: *Allocator              - The allocator used to allocate the Page Table.
///     IN page_table: *DirectoryPointerTable - The Page Directory Pointer Table to unmap from.
///
/// Error: vmm.MapperError
///     vmm.MapperError - The range or part of it is not mapped.
///
fn unmapPDPTEntry(virt_start: u64, virt_end: u64, allocator: *Allocator, page_table: *DirectoryPointerTable) vmm.MapperError!void {
    var virt_addr = virt_start;
    var virt_next = addMin(virt_end, std.mem.alignBackward(virt_addr, PAGE_SIZE_1GB), PAGE_SIZE_1GB);
    var pdpt_part = virtToPDPTEntryIdx(virt_addr);
    while (virt_addr < virt_end) : ({
        virt_addr = virt_next;
        virt_next = addMin(virt_end, virt_next, PAGE_SIZE_1GB);
        pdpt_part += 1;
    }) {
        const pdpt_entry = &page_table.entries[pdpt_part];
        const pd = try getTableFromEntry(Directory, pdpt_entry.*);
        try unmapPDEntry(virt_addr, virt_next, allocator, pd);
        if (std.mem.isAligned(virt_addr, PAGE_SIZE_1GB) and virt_next - virt_addr >= PAGE_SIZE_1GB - PAGE_SIZE_4KB) {
            const frame = getFrame(pdpt_entry.*);
            const ptr = @intToPtr([*]Directory, frame)[0..1];
            allocator.free(ptr);
            // Clear everything
            pdpt_entry.* = 0;
        }
    }
}

///
/// Map a virtual address range to a physical address range into the page table.
///
/// Arguments:
///     IN virt_start: u64            - The start virtual address to map.
///     IN virt_end: u64              - The end virtual address to map.
///     IN phys_start: u64            - The start physical address to map.
///     IN phys_end: u64              - The end physical address to map.
///     IN attrs: vmm.Attributes      - The VMM attributes for configuring the page entry.
///     IN allocator: *Allocator      - Used to allocate new page entries if needed.
///     IN page_table: *PageMapLevel4 - The root page table provided by the VMM. This will be the kernel_pml4.
///
/// Error: Allocator.Error || vmm.MapperError
///     Allocator.Error - Error allocating a new page mapping entry.
///     vmm.MapperError - Part of the address range is already mapped.
///     vmm.MapperError - The virtual or physical addresses is not aligned.
///     vmm.MapperError - The virtual or physical addresses is not the same length.
///     vmm.MapperError - The end virtual or physical addresses is larger then the start.
///
pub fn map(virt_start: u64, virt_end: u64, phys_start: u64, phys_end: u64, attrs: vmm.Attributes, allocator: *Allocator, page_table: *PageMapLevel4) (Allocator.Error || vmm.MapperError)!void {
    if (phys_start > phys_end) {
        return vmm.MapperError.InvalidPhysicalAddress;
    }
    if (virt_start > virt_end) {
        return vmm.MapperError.InvalidVirtualAddress;
    }
    if (!std.mem.isAligned(phys_start, PAGE_SIZE_4KB) or !std.mem.isAligned(phys_end, PAGE_SIZE_4KB)) {
        return vmm.MapperError.MisalignedPhysicalAddress;
    }
    if (!std.mem.isAligned(virt_start, PAGE_SIZE_4KB) or !std.mem.isAligned(virt_end, PAGE_SIZE_4KB)) {
        return vmm.MapperError.MisalignedVirtualAddress;
    }
    if (phys_end - phys_start != virt_end - virt_start) {
        return vmm.MapperError.AddressMismatch;
    }
    var virt_addr = virt_start;
    var phys_addr = phys_start;
    var virt_next = addMin(virt_end, std.mem.alignBackward(virt_addr, PAGE_SIZE_4KB), PAGE_SIZE_4KB);
    var phys_next = addMin(phys_end, std.mem.alignBackward(phys_addr, PAGE_SIZE_4KB), PAGE_SIZE_4KB);
    while (virt_addr < virt_end) : ({
        virt_addr = virt_next;
        phys_addr = phys_next;
        virt_next = addMin(virt_end, virt_next, PAGE_SIZE_4KB);
        phys_next = addMin(phys_end, phys_next, PAGE_SIZE_4KB);
    }) {
        try mapEntry(virt_addr, phys_addr, attrs, allocator, page_table);
    }
}

///
/// Unmap a virtual address range from the page table. This will set the freed page entries to 0.
/// This will only free the page entries that are covered by the virtual address range and not
/// check if the entire entry range is empty after freeing. So multiple unmapping of a address
/// address range that cover parts of page entries won't free entries that may result in becoming
/// empty after multiple unmaps.
///
/// TODO: Maybe look into this as this might result in wasted memory over time.
///
/// Arguments:
///     IN virt_start: u64            - The start virtual address to map.
///     IN virt_end: u64              - The end virtual address to map.
///     IN allocator: *Allocator      - Used to free page entries if the entries being cleared covers the entire page table part.
///     IN page_table: *PageMapLevel4 - The root page table provided by the VMM. This will be the kernel_pml4.
///
/// Error: vmm.MapperError
///     vmm.MapperError - Part of the address range is not mapped.
///     vmm.MapperError - The virtual address is not aligned.
///     vmm.MapperError - The virtual address is not the same length.
///     vmm.MapperError - The end virtual address is larger then the start.
///
pub fn unmap(virt_start: u64, virt_end: u64, allocator: *Allocator, page_table: *PageMapLevel4) vmm.MapperError!void {
    if (virt_start > virt_end) {
        return vmm.MapperError.InvalidVirtualAddress;
    }
    if (!std.mem.isAligned(virt_start, PAGE_SIZE_4KB) or !std.mem.isAligned(virt_end, PAGE_SIZE_4KB)) {
        return vmm.MapperError.MisalignedVirtualAddress;
    }
    var virt_addr = virt_start;
    var virt_next = addMin(virt_end, std.mem.alignBackward(virt_addr, PAGE_SIZE_512GB), PAGE_SIZE_512GB);
    var pml4_part = virtToPML4EntryIdx(virt_addr);
    while (virt_addr < virt_end) : ({
        virt_addr = virt_next;
        virt_next = addMin(virt_end, virt_next, PAGE_SIZE_512GB);
        pml4_part += 1;
    }) {
        const pml4_entry = &page_table.entries[pml4_part];
        const pdpt = try getTableFromEntry(DirectoryPointerTable, pml4_entry.*);
        try unmapPDPTEntry(virt_addr, virt_next, allocator, pdpt);
        if (std.mem.isAligned(virt_addr, PAGE_SIZE_512GB) and virt_next - virt_addr >= PAGE_SIZE_512GB - PAGE_SIZE_4KB) {
            const frame = getFrame(pml4_entry.*);
            const ptr = @intToPtr([*]DirectoryPointerTable, frame)[0..1];
            allocator.free(ptr);
            // Clear everything
            pml4_entry.* = 0;
        }
    }
}

///
/// Check the page table entries to expected values.
///
/// Arguments:
///     IN page_table: PageMapLevel4 - The page table to check.
///     IN levels: anytype           - The entries to test, this is in the form: `.{ PML4, PDPT, PD, PT }`.
///
fn checkPageTable(page_table: PageMapLevel4, levels: anytype) void {
    for (page_table.entries) |en1, i| {
        if (hasAttribute(en1, ENTRY_PRESENT)) {
            expectEqual(i, levels.@"0");
            expect(hasAttribute(en1, ENTRY_PRESENT));
            expect(hasAttribute(en1, ENTRY_WRITABLE));
            expect(!hasAttribute(en1, ENTRY_CACHE_DISABLED));
            expect(!hasAttribute(en1, ENTRY_USER));

            const frame1 = getFrame(en1);
            const pdpt = @intToPtr(*DirectoryPointerTable, frame1);
            for (pdpt.entries) |en2, j| {
                if (hasAttribute(en2, ENTRY_PRESENT)) {
                    expectEqual(j, levels.@"1");
                    expect(hasAttribute(en2, ENTRY_PRESENT));
                    expect(hasAttribute(en2, ENTRY_WRITABLE));
                    expect(!hasAttribute(en2, ENTRY_CACHE_DISABLED));
                    expect(!hasAttribute(en2, ENTRY_USER));

                    const frame2 = getFrame(en2);
                    const pd = @intToPtr(*Directory, frame2);
                    for (pd.entries) |en3, k| {
                        if (hasAttribute(en3, ENTRY_PRESENT)) {
                            expectEqual(k, levels.@"2");
                            expect(hasAttribute(en3, ENTRY_PRESENT));
                            expect(hasAttribute(en3, ENTRY_WRITABLE));
                            expect(!hasAttribute(en3, ENTRY_CACHE_DISABLED));
                            expect(!hasAttribute(en3, ENTRY_USER));

                            const frame3 = getFrame(en3);
                            const pt = @intToPtr(*Table, frame3);
                            for (pt.entries) |en4, l| {
                                if (hasAttribute(en4, ENTRY_PRESENT)) {
                                    expectEqual(l, levels.@"3");
                                    expect(hasAttribute(en3, ENTRY_PRESENT));
                                    expect(hasAttribute(en3, ENTRY_WRITABLE));
                                    expect(!hasAttribute(en3, ENTRY_CACHE_DISABLED));
                                    expect(!hasAttribute(en3, ENTRY_USER));
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

///
/// Free the entire page table.
///
/// Arguments:
///     IN page_table: *PageMapLevel4 - The page table to free.
///     IN allocator: *Allocator      - The allocator to free from.
///
fn freePageTable(page_table: *PageMapLevel4, allocator: *Allocator) void {
    for (page_table.entries) |*en1| {
        if (hasAttribute(en1.*, ENTRY_PRESENT)) {
            const frame1 = getFrame(en1.*);
            var pdpt = @intToPtr([*]DirectoryPointerTable, frame1)[0..1];
            for (pdpt[0].entries) |*en2| {
                if (hasAttribute(en2.*, ENTRY_PRESENT)) {
                    const frame2 = getFrame(en2.*);
                    var pd = @intToPtr([*]Directory, frame2)[0..1];
                    for (pd[0].entries) |*en3| {
                        if (hasAttribute(en3.*, ENTRY_PRESENT)) {
                            const frame3 = getFrame(en3.*);
                            const pt = @intToPtr([*]Table, frame3)[0..1];
                            allocator.free(pt);
                            en3.* = 0;
                        }
                    }
                    allocator.free(pd);
                    en2.* = 0;
                }
            }
            allocator.free(pdpt);
            en1.* = 0;
        }
    }
}

test "setAttribute and clearAttribute" {
    var val: u64 = 0;
    const attrs = [_]u64{ ENTRY_PRESENT, ENTRY_WRITABLE, ENTRY_USER, ENTRY_WRITE_THROUGH, ENTRY_CACHE_DISABLED, ENTRY_ACCESSED, ENTRY_ZERO, ENTRY_MEMORY_TYPE };

    for (attrs) |attr| {
        const old_val = val;
        setAttribute(&val, attr);
        expectEqual(val, old_val | attr);
    }

    for (attrs) |attr| {
        const old_val = val;
        clearAttribute(&val, attr);
        expectEqual(val, old_val & ~attr);
    }

    expectEqual(val, 0);

    for (attrs) |attr| {
        val |= attr;
    }
    for (attrs) |attr| {
        expect(hasAttribute(val, attr));
    }
}

test "mapEntry" {
    var allocator = std.testing.allocator;
    var page_table: PageMapLevel4 align(PAGE_SIZE_4KB) = .{
        .entries = [_]EntryType{0} ** ENTRIES_PER_TABLE,
    };

    mem.ADDR_OFFSET = 0;

    // This will map to:
    // PML4: 511
    // PDPT: 508
    // PD: 0
    // PT: 0
    try mapEntry(0xFFFFFFFF00000000, 0x0, .{ .kernel = true, .writable = true, .cachable = true }, allocator, &page_table);
    checkPageTable(page_table, .{ 511, 508, 0, 0 });
    freePageTable(&page_table, allocator);

    // This will map to:
    // PML4: 0
    // PDPT: 1
    // PD: 2
    // PT: 3
    try mapEntry(0x40403000, 0x0, .{ .kernel = true, .writable = true, .cachable = true }, allocator, &page_table);
    checkPageTable(page_table, .{ 0, 1, 2, 3 });
    freePageTable(&page_table, allocator);
}

test "map" {
    var allocator = std.testing.allocator;
    var page_table: PageMapLevel4 align(PAGE_SIZE_4KB) = .{
        .entries = [_]EntryType{0} ** ENTRIES_PER_TABLE,
    };

    mem.ADDR_OFFSET = 0;

    // This will map to:
    // PML4: 511
    // PDPT: 511 - 508
    // PD: 0-384
    // PT: 0-511
    try map(0xFFFFFFFF_00000000, 0xFFFFFFFF_F0000000, 0x0, 0xF0000000, .{ .kernel = true, .writable = true, .cachable = true }, allocator, &page_table);

    // This will check the ranges above
    // For Directory, 508-510, all Table entries will be present
    // For Directory entry 511, only Table entries 0-383 will be present
    expect(!hasAttribute(page_table.entries[510], ENTRY_PRESENT));
    expect(hasAttribute(page_table.entries[511], ENTRY_PRESENT));
    const pdpt = @intToPtr(*DirectoryPointerTable, getFrame(page_table.entries[511]));
    expect(!hasAttribute(pdpt.entries[507], ENTRY_PRESENT));
    for (pdpt.entries[508..]) |en1, i| {
        expect(hasAttribute(en1, ENTRY_PRESENT));
        const pd = @intToPtr(*Directory, getFrame(en1));
        expect(hasAttribute(pd.entries[0], ENTRY_PRESENT));
        if (i == 3) {
            for (pd.entries[0..384]) |en2| {
                expect(hasAttribute(en2, ENTRY_PRESENT));
                const pt = @intToPtr(*Table, getFrame(en2));
                for (pt.entries) |en3| {
                    expect(hasAttribute(en3, ENTRY_PRESENT));
                }
            }
            expect(!hasAttribute(pd.entries[384], ENTRY_PRESENT));
        } else {
            for (pd.entries) |en2, j| {
                expect(hasAttribute(en2, ENTRY_PRESENT));
                const pt = @intToPtr(*Table, getFrame(en2));
                for (pt.entries) |en3| {
                    expect(hasAttribute(en3, ENTRY_PRESENT));
                }
            }
        }
    }

    freePageTable(&page_table, allocator);
}

test "map errors" {
    expectError(error.InvalidPhysicalAddress, map(0x0, 0x0, 0x2000, 0x1000, .{ .kernel = true, .writable = true, .cachable = true }, undefined, undefined));
    expectError(error.InvalidVirtualAddress, map(0x2000, 0x1000, 0x0, 0x0, .{ .kernel = true, .writable = true, .cachable = true }, undefined, undefined));
    expectError(error.MisalignedPhysicalAddress, map(0x1000, 0x2000, 0x1111, 0x2000, .{ .kernel = true, .writable = true, .cachable = true }, undefined, undefined));
    expectError(error.MisalignedPhysicalAddress, map(0x1000, 0x2000, 0x1000, 0x2222, .{ .kernel = true, .writable = true, .cachable = true }, undefined, undefined));
    expectError(error.MisalignedVirtualAddress, map(0x1111, 0x2000, 0x1000, 0x2000, .{ .kernel = true, .writable = true, .cachable = true }, undefined, undefined));
    expectError(error.MisalignedVirtualAddress, map(0x1000, 0x2222, 0x1000, 0x2000, .{ .kernel = true, .writable = true, .cachable = true }, undefined, undefined));
    expectError(error.AddressMismatch, map(0x1000, 0x2000, 0x1000, 0x3000, .{ .kernel = true, .writable = true, .cachable = true }, undefined, undefined));
}

test "map unmap" {
    var allocator = std.testing.allocator;
    var page_table: PageMapLevel4 align(PAGE_SIZE_4KB) = .{
        .entries = [_]EntryType{0} ** ENTRIES_PER_TABLE,
    };

    {
        try map(0xFFFFFFFF_00000000, 0xFFFFFFFF_F0000000, 0x0, 0xF0000000, .{ .kernel = true, .writable = true, .cachable = true }, allocator, &page_table);
        try unmap(0xFFFFFFFF_00000000, 0xFFFFFFFF_F0000000, allocator, &page_table);
        // PML4 entry 511 and PDPT entry 511 won't be freed as they are not covered by the freeing range
        const frame1 = getFrame(page_table.entries[511]);
        const ptr1 = @intToPtr([*]DirectoryPointerTable, frame1)[0..1];

        const pdpt = try getTableFromEntry(DirectoryPointerTable, page_table.entries[511]);

        const frame2 = getFrame(pdpt.entries[511]);
        const ptr2 = @intToPtr([*]Directory, frame2)[0..1];

        page_table.entries[511] = 0;
        pdpt.entries[511] = 0;
        allocator.free(ptr1);
        allocator.free(ptr2);
    }
    {
        try map(0xFFFFFFFF_00000000, 0xFFFFFFFF_F0000000, 0x0, 0xF0000000, .{ .kernel = true, .writable = true, .cachable = true }, allocator, &page_table);
        try unmap(0xFFFFFFFF_00000000, 0xFFFFFFFF_10000000, allocator, &page_table);
        try unmap(0xFFFFFFFF_10000000, 0xFFFFFFFF_F0000000, allocator, &page_table);

        // PML4 entry 511 and PDPT entry 508 and 511 won't be freed as they are not covered by the freeing range
        const frame1 = getFrame(page_table.entries[511]);
        const ptr1 = @intToPtr([*]DirectoryPointerTable, frame1)[0..1];

        const pdpt = try getTableFromEntry(DirectoryPointerTable, page_table.entries[511]);

        const frame2 = getFrame(pdpt.entries[511]);
        const ptr2 = @intToPtr([*]Directory, frame2)[0..1];
        const frame3 = getFrame(pdpt.entries[508]);
        const ptr3 = @intToPtr([*]Directory, frame3)[0..1];

        page_table.entries[511] = 0;
        pdpt.entries[508] = 0;
        pdpt.entries[511] = 0;
        allocator.free(ptr1);
        allocator.free(ptr2);
        allocator.free(ptr3);
    }
    {
        try map(0xFFFFFFFF_00000000, 0xFFFFFFFF_FFFFF000, 0x0, 0xFFFFF000, .{ .kernel = true, .writable = true, .cachable = true }, allocator, &page_table);
        try unmap(0xFFFFFFFF_00000000, 0xFFFFFFFF_FFFFF000, allocator, &page_table);

        // PML4 entry 511 and PDPT entry 508 and 511 won't be freed as they are not covered by the freeing range
        const frame1 = getFrame(page_table.entries[511]);
        const ptr1 = @intToPtr([*]DirectoryPointerTable, frame1)[0..1];

        page_table.entries[511] = 0;
        allocator.free(ptr1);
    }
}

test "unmap errors" {
    expectError(error.InvalidVirtualAddress, unmap(0x3000, 0x2000, undefined, undefined));
    expectError(error.MisalignedVirtualAddress, unmap(0x1111, 0x2000, undefined, undefined));
    expectError(error.MisalignedVirtualAddress, unmap(0x1000, 0x2222, undefined, undefined));

    var page_table: PageMapLevel4 align(PAGE_SIZE_4KB) = .{
        .entries = [_]EntryType{0} ** ENTRIES_PER_TABLE,
    };
    expectError(error.NotMapped, unmap(0x1000, 0x2000, undefined, &page_table));
}
