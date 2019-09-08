const std = @import("std");
const panic = @import("../../kmain.zig").panic;
const arch = @import("../../arch.zig").internals;
const isr = @import("isr.zig");
const assert = std.debug.assert;
const MemProfile = @import("../../mem.zig").MemProfile;
const testing = @import("std").testing;
const expectEqual = testing.expectEqual;
const expect = testing.expect;

extern var KERNEL_ADDR_OFFSET: *u32;

const ENTRIES_PER_DIRECTORY = 1024;

const PAGE_SIZE_4MB = 0x400000;
const PAGE_SIZE = PAGE_SIZE_4MB;
const PAGE_SIZE_4KB = PAGE_SIZE_4MB / 1024;
const PAGES_PER_DIR_ENTRY = PAGE_SIZE_4MB / PAGE_SIZE;
const PAGES_PER_DIR = ENTRIES_PER_DIRECTORY * PAGES_PER_DIR_ENTRY;
const PHYS_ADDR_OFFSET = 22;
const PhysAddr = u10;

const DirectoryEntry = u32;

const ENTRY_PRESENT = 0x1;
const ENTRY_WRITABLE = 0x2;
const ENTRY_USER = 0x4;
const ENTRY_WRITE_THROUGH = 0x8;
const ENTRY_CACHE_DISABLED = 0x10;
const ENTRY_ACCESSED = 0x20;
const ENTRY_ZERO = 0x40;
const ENTRY_4MB_PAGES = 0x80;
const ENTRY_IGNORED = 0x100;
const ENTRY_AVAILABLE = 0xE00;
const ENTRY_PAGE_ADDR = 0xFFC00000;

const Directory = packed struct {
    entries: [ENTRIES_PER_DIRECTORY]DirectoryEntry,
};

const PagingError = error {
    InvalidPhysAddresses,
    InvalidVirtAddresses,
    PhysicalVirtualMismatch,
    UnalignedPhysAddresses,
    UnalignedVirtAddresses,
};

///
/// Map a page directory entry, setting the present, size, writable, write-through and physical address bits.
/// Clears the user and cache disabled bits. Entry should be zero'ed.
///
/// Arguments:
///     OUT entry: *DirectoryEntry - Unaligned directory entry
///     IN virt_addr: u32 - The virtual address being mapped
///     IN phys_addr: u32 - The physical address at which to start mapping
///     IN allocator: *Allocator - The allocator to use to map any tables needed
///
fn mapDirEntry(entry: *align(1) DirectoryEntry, virt_addr: u32, phys_addr: u32, allocator: *std.mem.Allocator) void {
    entry.* |= ENTRY_PRESENT;
    entry.* |= ENTRY_WRITABLE;
    entry.* &= ~u32(ENTRY_USER);
    entry.* |= ENTRY_WRITE_THROUGH;
    entry.* &= ~u32(ENTRY_CACHE_DISABLED);
    entry.* |= ENTRY_4MB_PAGES;
    entry.* |= ENTRY_PAGE_ADDR & phys_addr;
}

///
/// Map a page directory. The addresses passed must be page size aligned and be the same distance apart.
///
/// Arguments:
///     OUT entry: *Directory - The directory to map
///     IN phys_start: u32 - The physical address at which to start mapping
///     IN phys_end: u32 - The physical address at which to stop mapping
///     IN virt_start: u32 - The virtual address at which to start mapping
///     IN virt_end: u32 - The virtual address at which to stop mapping
///     IN allocator: *Allocator - The allocator to use to map any tables needed
///
fn mapDir(dir: *Directory, phys_start: u32, phys_end: u32, virt_start: u32, virt_end: u32, allocator: *std.mem.Allocator) PagingError!void {
    if (phys_start > phys_end) {
        return PagingError.InvalidPhysAddresses;
    }
    if (virt_start > virt_end) {
        return PagingError.InvalidVirtAddresses;
    }
    if (phys_end - phys_start != virt_end - virt_start) {
        return PagingError.PhysicalVirtualMismatch;
    }
    if (!isAligned(phys_start, PAGE_SIZE) or !isAligned(phys_end, PAGE_SIZE)) {
        return PagingError.UnalignedPhysAddresses;
    }
    if (!isAligned(virt_start, PAGE_SIZE) or !isAligned(virt_end, PAGE_SIZE)) {
        return PagingError.UnalignedVirtAddresses;
    }

    var virt_addr = virt_start;
    var phys_addr = phys_start;
    var page = virt_addr / PAGE_SIZE_4KB;
    var entry_idx = virt_addr / PAGE_SIZE;
    while (entry_idx < ENTRIES_PER_DIRECTORY and virt_addr < virt_end) {
        mapDirEntry(&dir.entries[entry_idx], virt_addr, phys_addr, allocator);
        phys_addr += PAGE_SIZE;
        virt_addr += PAGE_SIZE;
        entry_idx += 1;
    }
}

/// Round an address up to the previous aligned address
/// The alignment must be a power of 2 and greater than 0.
fn alignBackward(addr: usize, alignment: usize) usize {
    return addr & ~(alignment - 1);
}

/// Given an address and an alignment, return true if the address is a multiple of the alignment
/// The alignment must be a power of 2 and greater than 0.
fn isAligned(addr: usize, alignment: usize) bool {
    return alignBackward(addr, alignment) == addr;
}

fn pageFault(state: *arch.InterruptContext) void {
    @panic("Page fault");
}

///
/// Initialise x86 paging, overwriting any previous paging set up.
///
/// Arguments:
///     IN mem_profile: *const MemProfile - The memory profile of the system and kernel
///     IN allocator: *std.mem.Allocator - The allocator to use
///
pub fn init(mem_profile: *const MemProfile, allocator: *std.mem.Allocator) void {
    // Calculate start and end of mapping
    const v_start = alignBackward(@ptrToInt(mem_profile.vaddr_start), PAGE_SIZE);
    const v_end = std.mem.alignForward(@ptrToInt(mem_profile.vaddr_end) + mem_profile.fixed_alloc_size, PAGE_SIZE);
    const p_start = alignBackward(@ptrToInt(mem_profile.physaddr_start), PAGE_SIZE);
    const p_end = std.mem.alignForward(@ptrToInt(mem_profile.physaddr_end) + mem_profile.fixed_alloc_size, PAGE_SIZE);

    var tmp = allocator.alignedAlloc(Directory, PAGE_SIZE_4KB, 1) catch unreachable;
    var kernel_directory = @ptrCast(*Directory, tmp.ptr);
    @memset(@ptrCast([*]u8, kernel_directory), 0, @sizeOf(Directory));

    mapDir(kernel_directory, p_start, p_end, v_start, v_end, allocator) catch unreachable;
    const dir_physaddr = @ptrToInt(kernel_directory) - @ptrToInt(&KERNEL_ADDR_OFFSET);
    asm volatile ("mov %[addr], %%cr3" :: [addr] "{eax}" (dir_physaddr));
    isr.registerIsr(14, pageFault) catch unreachable;
}

test "isAligned" {
    expect(isAligned(PAGE_SIZE, PAGE_SIZE));
    expect(isAligned(2048, 1024));
    expect(isAligned(0, 512));
    expect(!isAligned(123, 1024));
}

test "alignBackward" {
    expectEqual(alignBackward(PAGE_SIZE, PAGE_SIZE), PAGE_SIZE);
    expectEqual(alignBackward(0, 123), 0);
    expectEqual(alignBackward(1024 + 456, 1024), 1024);
    expectEqual(alignBackward(2048, 1024), 2048);
}

fn checkDirEntry(entry: DirectoryEntry, phys: u32) void {
    expect(entry & ENTRY_WRITABLE != 0);
    expectEqual(entry & ENTRY_USER, 0);
    expect(entry & ENTRY_WRITE_THROUGH != 0);
    expectEqual(entry & ENTRY_CACHE_DISABLED, 0);
    expect(entry & ENTRY_4MB_PAGES != 0);
    expectEqual(entry & ENTRY_PAGE_ADDR, phys);
}

test "mapDirEntry" {
    var direct = std.heap.DirectAllocator.init();
    defer direct.deinit();
    var allocator = &direct.allocator;
    var entry: DirectoryEntry = 0;
    const phys: u32 = PAGE_SIZE * 2;
    const virt: u32 = PAGE_SIZE * 4;
    mapDirEntry(@ptrCast(*align(1) DirectoryEntry, &entry), virt, phys, allocator);
    checkDirEntry(entry, phys);
}

test "mapDir" {
    var direct = std.heap.DirectAllocator.init();
    defer direct.deinit();
    var allocator = &direct.allocator;
    var dir = Directory { .entries = []DirectoryEntry{0} ** ENTRIES_PER_DIRECTORY };
    const phys_start = PAGE_SIZE * 2;
    const virt_start = PAGE_SIZE * 4;
    const phys_end = PAGE_SIZE * 4;
    const virt_end = PAGE_SIZE * 6;
    mapDir(&dir, phys_start, phys_end, virt_start, virt_end, allocator) catch unreachable;
    // Only 2 dir entries should be mapped
    expectEqual(dir.entries[virt_start / PAGE_SIZE - 1], 0);
    checkDirEntry(dir.entries[virt_start / PAGE_SIZE], phys_start);
    checkDirEntry(dir.entries[virt_start / PAGE_SIZE + 1], phys_start + PAGE_SIZE);
    expectEqual(dir.entries[virt_start / PAGE_SIZE + 2], 0);
}
