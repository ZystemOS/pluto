const build_options = @import("build_options");
const mock_path = build_options.mock_path;
const builtin = @import("builtin");
const is_test = builtin.is_test;
const std = @import("std");
const bitmap = @import("bitmap.zig");
const pmm = @import("pmm.zig");
const mem = if (is_test) @import(mock_path ++ "mem_mock.zig") else @import("mem.zig");
const tty = @import("tty.zig");
const panic = @import("panic.zig").panic;
const arch = @import("arch.zig").internals;

/// Attributes for a virtual memory allocation
pub const Attributes = struct {
    /// Whether this memory belongs to the kernel and can therefore not be accessed in user mode
    kernel: bool,

    /// If this memory can be written to
    writable: bool,

    /// If this memory can be cached. Memory mapped to a device shouldn't, for example
    cachable: bool,
};

/// All data that must be remembered for a virtual memory allocation
const Allocation = struct {
    /// The physical blocks of memory associated with this allocation
    physical: std.ArrayList(usize),
};

/// The size of each allocatable block, the same as the physical memory manager's block size
pub const BLOCK_SIZE: usize = pmm.BLOCK_SIZE;

pub const MapperError = error{
    InvalidVirtualAddress,
    InvalidPhysicalAddress,
    AddressMismatch,
    MisalignedVirtualAddress,
    MisalignedPhysicalAddress,
    NotMapped,
};

///
/// Returns a container that can map and unmap virtual memory to physical memory.
/// The mapper can pass some payload data when mapping an unmapping, which is of type `Payload`. This can be anything that the underlying mapper needs to carry out the mapping process.
/// For x86, it would be the page directory that is being mapped within. An architecture or other mapper can specify the data it needs when mapping by specifying this type.
///
/// Arguments:
///     IN comptime Payload: type - The type of the VMM-specific payload to pass when mapping and unmapping
///
/// Return: type
///     The Mapper type constructed.
///
pub fn Mapper(comptime Payload: type) type {
    return struct {
        ///
        /// Map a region (can span more than one block) of virtual memory to physical memory. After a call to this function, the memory should be present the next time it is accessed.
        /// The attributes given must be obeyed when possible.
        ///
        /// Arguments:
        ///     IN virtual_start: usize - The start of the virtual memory to map
        ///     IN virtual_end: usize - The end of the virtual memory to map
        ///     IN physical_start: usize - The start of the physical memory to map to
        ///     IN physical_end: usize - The end of the physical memory to map to
        ///     IN attrs: Attributes - The attributes to apply to this region of memory
        ///     IN/OUT allocator: std.mem.Allocator - The allocator to use when mapping, if required
        ///     IN spec: Payload - The payload to pass to the mapper
        ///
        /// Error: std.mem.AllocatorError || MapperError
        ///     The causes depend on the mapper used
        ///
        mapFn: fn (virtual_start: usize, virtual_end: usize, physical_start: usize, physical_end: usize, attrs: Attributes, allocator: *std.mem.Allocator, spec: Payload) (std.mem.Allocator.Error || MapperError)!void,

        ///
        /// Unmap a region (can span more than one block) of virtual memory from its physical memory. After a call to this function, the memory should not be accessible without error.
        ///
        /// Arguments:
        ///     IN virtual_start: usize - The start of the virtual region to unmap
        ///     IN virtual_end: usize - The end of the virtual region to unmap
        ///     IN spec: Payload - The payload to pass to the mapper
        ///
        /// Error: std.mem.AllocatorError || MapperError
        ///     The causes depend on the mapper used
        ///
        unmapFn: fn (virtual_start: usize, virtual_end: usize, spec: Payload) (std.mem.Allocator.Error || MapperError)!void,
    };
}

/// Errors that can be returned by VMM functions
pub const VmmError = error{
    /// A memory region expected to be allocated wasn't
    NotAllocated,

    /// A memory region expected to not be allocated was
    AlreadyAllocated,

    /// A physical memory region expected to not be allocated was
    PhysicalAlreadyAllocated,

    /// A physical region of memory isn't of the same size as a virtual region
    PhysicalVirtualMismatch,

    /// Virtual addresses are invalid
    InvalidVirtAddresses,

    /// Physical addresses are invalid
    InvalidPhysAddresses,
};

/// The boot-time offset that the virtual addresses are from the physical addresses
/// This is the start of the memory owned by the kernel and so is where the kernel VMM starts
extern var KERNEL_ADDR_OFFSET: *u32;

///
/// Construct a virtual memory manager to keep track of allocated and free virtual memory regions within a certain space
///
/// Arguments:
///     IN comptime Payload: type - The type of the payload to pass to the mapper
///
/// Return: type
///     The constructed type
///
pub fn VirtualMemoryManager(comptime Payload: type) type {
    return struct {
        /// The bitmap that keeps track of allocated and free regions
        bmp: bitmap.Bitmap(usize),

        /// The start of the memory to be tracked
        start: usize,

        /// The end of the memory to be tracked
        end: usize,

        /// The allocator to use when allocating and freeing regions
        allocator: *std.mem.Allocator,

        /// All allocations that have been made with this manager
        allocations: std.hash_map.AutoHashMap(usize, Allocation),

        /// The mapper to use when allocating and freeing regions
        mapper: Mapper(Payload),

        /// The payload to pass to the mapper functions
        payload: Payload,

        const Self = @This();

        ///
        /// Initialise a virtual memory manager
        ///
        /// Arguments:
        ///     IN start: usize - The start of the memory region to manage
        ///     IN end: usize - The end of the memory region to manage. Must be greater than the start
        ///     IN/OUT allocator: *std.mem.Allocator - The allocator to use when allocating and freeing regions
        ///     IN mapper: Mapper - The mapper to use when allocating and freeing regions
        ///     IN payload: Payload - The payload data to be passed to the mapper
        ///
        /// Return: Self
        ///     The manager constructed
        ///
        /// Error: std.mem.Allocator.Error
        ///     std.mem.Allocator.Error.OutOfMemory - The allocator cannot allocate the memory required
        ///
        pub fn init(start: usize, end: usize, allocator: *std.mem.Allocator, mapper: Mapper(Payload), payload: Payload) std.mem.Allocator.Error!Self {
            const size = end - start;
            var bmp = try bitmap.Bitmap(usize).init(std.mem.alignForward(size, pmm.BLOCK_SIZE) / pmm.BLOCK_SIZE, allocator);
            return Self{
                .bmp = bmp,
                .start = start,
                .end = end,
                .allocator = allocator,
                .allocations = std.hash_map.AutoHashMap(usize, Allocation).init(allocator),
                .mapper = mapper,
                .payload = payload,
            };
        }

        ///
        /// Check if a virtual memory address has been set
        ///
        /// Arguments:
        ///     IN self: *Self - The manager to check
        ///     IN virt: usize - The virtual memory address to check
        ///
        /// Return: bool
        ///     Whether the address is set
        ///
        /// Error: pmm.PmmError
        ///     Bitmap(u32).Error.OutOfBounds - The address given is outside of the memory managed
        ///
        pub fn isSet(self: *const Self, virt: usize) bitmap.Bitmap(u32).BitmapError!bool {
            return try self.bmp.isSet((virt - self.start) / BLOCK_SIZE);
        }

        ///
        /// Map a region (can span more than one block) of virtual memory to a specific region of memory
        ///
        /// Arguments:
        ///     IN/OUT self: *Self - The manager to modify
        ///     IN virtual: mem.Range - The virtual region to set
        ///     IN physical: ?mem.Range - The physical region to map to or null if only the virtual region is to be set
        ///     IN attrs: Attributes - The attributes to apply to the memory regions
        ///
        /// Error: VmmError || Bitmap(u32).BitmapError || std.mem.Allocator.Error || MapperError
        ///     VmmError.AlreadyAllocated - The virtual address has already been allocated
        ///     VmmError.PhysicalAlreadyAllocated - The physical address has already been allocated
        ///     VmmError.PhysicalVirtualMismatch - The physical region and virtual region are of different sizes
        ///     VmmError.InvalidVirtAddresses - The start virtual address is greater than the end address
        ///     VmmError.InvalidPhysicalAddresses - The start physical address is greater than the end address
        ///     Bitmap.BitmapError.OutOfBounds - The physical or virtual addresses are out of bounds
        ///     std.mem.Allocator.Error.OutOfMemory - Allocating the required memory failed
        ///     MapperError.* - The causes depend on the mapper used
        ///
        pub fn set(self: *Self, virtual: mem.Range, physical: ?mem.Range, attrs: Attributes) (VmmError || bitmap.Bitmap(u32).BitmapError || std.mem.Allocator.Error || MapperError)!void {
            var virt = virtual.start;
            while (virt < virtual.end) : (virt += BLOCK_SIZE) {
                if (try self.isSet(virt))
                    return VmmError.AlreadyAllocated;
            }
            if (virtual.start > virtual.end) {
                return VmmError.InvalidVirtAddresses;
            }

            if (physical) |p| {
                if (virtual.end - virtual.start != p.end - p.start) {
                    return VmmError.PhysicalVirtualMismatch;
                }
                if (p.start > p.end) {
                    return VmmError.InvalidPhysAddresses;
                }
                var phys = p.start;
                while (phys < p.end) : (phys += BLOCK_SIZE) {
                    if (try pmm.isSet(phys)) {
                        return VmmError.PhysicalAlreadyAllocated;
                    }
                }
            }

            var phys_list = std.ArrayList(usize).init(self.allocator);

            virt = virtual.start;
            while (virt < virtual.end) : (virt += BLOCK_SIZE) {
                try self.bmp.setEntry((virt - self.start) / BLOCK_SIZE);
            }

            if (physical) |p| {
                try self.mapper.mapFn(virtual.start, virtual.end, p.start, p.end, attrs, self.allocator, self.payload);

                var phys = p.start;
                while (phys < p.end) : (phys += BLOCK_SIZE) {
                    try pmm.setAddr(phys);
                    try phys_list.append(phys);
                }
            }
            _ = try self.allocations.put(virtual.start, Allocation{ .physical = phys_list });
        }

        ///
        /// Allocate a number of contiguous blocks of virtual memory
        ///
        /// Arguments:
        ///     IN/OUT self: *Self - The manager to allocate for
        ///     IN num: usize - The number of blocks to allocate
        ///     IN attrs: Attributes - The attributes to apply to the mapped memory
        ///
        /// Return: ?usize
        ///     The address at the start of the allocated region, or null if no region could be allocated due to a lack of contiguous blocks.
        ///
        /// Error: std.mem.Allocator.Error
        ///     std.mem.AllocatorError.OutOfMemory: The required amount of memory couldn't be allocated
        ///
        pub fn alloc(self: *Self, num: usize, attrs: Attributes) std.mem.Allocator.Error!?usize {
            if (num == 0)
                return null;
            // Ensure that there is both enough physical and virtual address space free
            if (pmm.blocksFree() >= num and self.bmp.num_free_entries >= num) {
                // The virtual address space must be contiguous
                if (self.bmp.setContiguous(num)) |entry| {
                    var block_list = std.ArrayList(usize).init(self.allocator);
                    try block_list.ensureCapacity(num);

                    var i: usize = 0;
                    const vaddr_start = self.start + entry * BLOCK_SIZE;
                    var vaddr = vaddr_start;
                    // Map the blocks to physical memory
                    while (i < num) : (i += 1) {
                        const addr = pmm.alloc() orelse unreachable;
                        try block_list.append(addr);
                        // The map function failing isn't the caller's responsibility so panic as it shouldn't happen
                        self.mapper.mapFn(vaddr, vaddr + BLOCK_SIZE, addr, addr + BLOCK_SIZE, attrs, self.allocator, self.payload) catch |e| panic(@errorReturnTrace(), "Failed to map virtual memory: {}\n", .{e});
                        vaddr += BLOCK_SIZE;
                    }
                    _ = try self.allocations.put(vaddr_start, Allocation{ .physical = block_list });
                    return vaddr_start;
                }
            }
            return null;
        }

        ///
        /// Free a previous allocation
        ///
        /// Arguments:
        ///     IN/OUT self: *Self - The manager to free within
        ///     IN vaddr: usize - The start of the allocation to free. This should be the address returned from a prior `alloc` call
        ///
        /// Error: Bitmap.BitmapError || VmmError
        ///     VmmError.NotAllocated - This address hasn't been allocated yet
        ///     Bitmap.BitmapError.OutOfBounds - The address is out of the manager's bounds
        ///
        pub fn free(self: *Self, vaddr: usize) (bitmap.Bitmap(u32).BitmapError || VmmError)!void {
            const entry = (vaddr - self.start) / BLOCK_SIZE;
            if (try self.bmp.isSet(entry)) {
                // There will be an allocation associated with this virtual address
                const allocation = self.allocations.get(vaddr) orelse unreachable;
                const physical = allocation.physical;
                defer physical.deinit();
                const num_physical_allocations = physical.items.len;
                for (physical.items) |block, i| {
                    // Clear the address space entry and free the physical memory
                    try self.bmp.clearEntry(entry + i);
                    pmm.free(block) catch |e| panic(@errorReturnTrace(), "Failed to free PMM reserved memory at 0x{X}: {}\n", .{ block * BLOCK_SIZE, e });
                }
                // Unmap the entire range
                const region_start = entry * BLOCK_SIZE;
                const region_end = (entry + num_physical_allocations) * BLOCK_SIZE;
                self.mapper.unmapFn(region_start, region_end, self.payload) catch |e| panic(@errorReturnTrace(), "Failed to unmap VMM reserved memory from 0x{X} to 0x{X}: {}\n", .{ region_start, region_end, e });
                // The allocation is freed so remove from the map
                self.allocations.removeAssertDiscard(vaddr);
            } else {
                return VmmError.NotAllocated;
            }
        }
    };
}

///
/// Initialise the main system virtual memory manager covering 4GB. Maps in the kernel code and reserved virtual memory
///
/// Arguments:
///     IN mem_profile: *const mem.MemProfile - The system's memory profile. This is used to find the kernel code region and boot modules
///     IN/OUT allocator: *std.mem.Allocator - The allocator to use when needing to allocate memory
///
/// Return: VirtualMemoryManager
///     The virtual memory manager created with all reserved virtual regions allocated
///
/// Error: std.mem.Allocator.Error
///     std.mem.Allocator.Error.OutOfMemory - The allocator cannot allocate the memory required
///
pub fn init(mem_profile: *const mem.MemProfile, allocator: *std.mem.Allocator) std.mem.Allocator.Error!VirtualMemoryManager(arch.VmmPayload) {
    std.log.info(.tty, "Init\n", .{});
    defer std.log.info(.tty, "Done\n", .{});

    var vmm = try VirtualMemoryManager(arch.VmmPayload).init(@ptrToInt(&KERNEL_ADDR_OFFSET), 0xFFFFFFFF, allocator, arch.VMM_MAPPER, arch.KERNEL_VMM_PAYLOAD);

    // Map in kernel
    // Calculate start and end of mapping
    const v_start = std.mem.alignBackward(@ptrToInt(mem_profile.vaddr_start), BLOCK_SIZE);
    const v_end = std.mem.alignForward(@ptrToInt(mem_profile.vaddr_end) + mem.FIXED_ALLOC_SIZE, BLOCK_SIZE);
    const p_start = std.mem.alignBackward(@ptrToInt(mem_profile.physaddr_start), BLOCK_SIZE);
    const p_end = std.mem.alignForward(@ptrToInt(mem_profile.physaddr_end) + mem.FIXED_ALLOC_SIZE, BLOCK_SIZE);
    vmm.set(.{ .start = v_start, .end = v_end }, mem.Range{ .start = p_start, .end = p_end }, .{ .kernel = true, .writable = false, .cachable = true }) catch |e| panic(@errorReturnTrace(), "Failed mapping kernel code in VMM: {}", .{e});

    for (mem_profile.virtual_reserved) |entry| {
        const virtual = mem.Range{ .start = std.mem.alignBackward(entry.virtual.start, BLOCK_SIZE), .end = std.mem.alignForward(entry.virtual.end, BLOCK_SIZE) };
        const physical: ?mem.Range = if (entry.physical) |phys| mem.Range{ .start = std.mem.alignBackward(phys.start, BLOCK_SIZE), .end = std.mem.alignForward(phys.end, BLOCK_SIZE) } else null;
        vmm.set(virtual, physical, .{ .kernel = true, .writable = true, .cachable = true }) catch |e| switch (e) {
            VmmError.AlreadyAllocated => {},
            else => panic(@errorReturnTrace(), "Failed mapping region in VMM {}: {}\n", .{ entry, e }),
        };
    }

    switch (build_options.test_mode) {
        .Initialisation => runtimeTests(arch.VmmPayload, vmm, mem_profile),
        else => {},
    }
    return vmm;
}

test "alloc and free" {
    const num_entries = 512;
    var vmm = try testInit(num_entries);
    var allocations = test_allocations orelse unreachable;
    var virtual_allocations = std.ArrayList(usize).init(std.testing.allocator);
    defer virtual_allocations.deinit();

    var entry: u32 = 0;
    while (entry < num_entries) {
        // Test allocating various numbers of blocks all at once
        // Rather than using a random number generator, just set the number of blocks to allocate based on how many entries have been done so far
        var num_to_alloc: u32 = if (entry > 400) @as(u32, 8) else if (entry > 320) @as(u32, 14) else if (entry > 270) @as(u32, 9) else if (entry > 150) @as(u32, 26) else @as(u32, 1);
        const result = try vmm.alloc(num_to_alloc, .{ .kernel = true, .writable = true, .cachable = true });

        var should_be_set = true;
        if (entry + num_to_alloc > num_entries) {
            // If the number to allocate exceeded the number of entries, then allocation should have failed
            std.testing.expectEqual(@as(?usize, null), result);
            should_be_set = false;
        } else {
            // Else it should have succeeded and allocated the correct address
            std.testing.expectEqual(@as(?usize, vmm.start + entry * BLOCK_SIZE), result);
            try virtual_allocations.append(result orelse unreachable);
        }

        // Make sure that the entries are set or not depending on the allocation success
        var vaddr = entry * BLOCK_SIZE;
        while (vaddr < (entry + num_to_alloc) * BLOCK_SIZE) : (vaddr += BLOCK_SIZE) {
            if (should_be_set) {
                // Allocation succeeded so this address should be set
                std.testing.expect(try vmm.isSet(vaddr));
                // The test mapper should have received this address
                std.testing.expect(try allocations.isSet(vaddr / BLOCK_SIZE));
            } else {
                // Allocation failed as there weren't enough free entries
                if (vaddr >= num_entries * BLOCK_SIZE) {
                    // If this address is beyond the VMM's end address, it should be out of bounds
                    std.testing.expectError(bitmap.Bitmap(u32).BitmapError.OutOfBounds, vmm.isSet(vaddr));
                    std.testing.expectError(bitmap.Bitmap(u64).BitmapError.OutOfBounds, allocations.isSet(vaddr / BLOCK_SIZE));
                } else {
                    // Else it should not be set
                    std.testing.expect(!(try vmm.isSet(vaddr)));
                    // The test mapper should not have received this address
                    std.testing.expect(!(try allocations.isSet(vaddr / BLOCK_SIZE)));
                }
            }
        }
        entry += num_to_alloc;

        // All later entries should not be set
        var later_entry = entry;
        while (later_entry < num_entries) : (later_entry += 1) {
            std.testing.expect(!(try vmm.isSet(vmm.start + later_entry * BLOCK_SIZE)));
            std.testing.expect(!(try pmm.isSet(later_entry * BLOCK_SIZE)));
        }
    }

    // Try freeing all allocations
    for (virtual_allocations.items) |alloc| {
        const alloc_group = vmm.allocations.get(alloc);
        std.testing.expect(alloc_group != null);
        const physical = alloc_group.?.physical;
        // We need to create a copy of the physical allocations since the free call deinits them
        var physical_copy = std.ArrayList(usize).init(std.testing.allocator);
        defer physical_copy.deinit();
        // Make sure they are all reserved in the PMM
        for (physical.items) |phys| {
            std.testing.expect(try pmm.isSet(phys));
            try physical_copy.append(phys);
        }
        vmm.free(alloc) catch unreachable;
        // This virtual allocation should no longer be in the hashmap
        std.testing.expectEqual(vmm.allocations.get(alloc), null);
        std.testing.expect(!try vmm.isSet(alloc));
        // And all its physical blocks should now be free
        for (physical_copy.items) |phys| {
            std.testing.expect(!try pmm.isSet(phys));
        }
    }
}

test "set" {
    const num_entries = 512;
    var vmm = try testInit(num_entries);

    const vstart = BLOCK_SIZE * 37;
    const vend = BLOCK_SIZE * 46;
    const pstart = vstart + 123;
    const pend = vend + 123;
    const attrs = Attributes{ .kernel = true, .writable = true, .cachable = true };
    try vmm.set(.{ .start = vstart, .end = vend }, mem.Range{ .start = pstart, .end = pend }, attrs);
    // Make sure it put the correct address in the map
    std.testing.expect(vmm.allocations.get(vstart) != null);

    var allocations = test_allocations orelse unreachable;
    // The entries before the virtual start shouldn't be set
    var vaddr = vmm.start;
    while (vaddr < vstart) : (vaddr += BLOCK_SIZE) {
        std.testing.expect(!(try allocations.isSet(vaddr / BLOCK_SIZE)));
    }
    // The entries up until the virtual end should be set
    while (vaddr < vend) : (vaddr += BLOCK_SIZE) {
        std.testing.expect(try allocations.isSet(vaddr / BLOCK_SIZE));
    }
    // The entries after the virtual end should not be set
    while (vaddr < vmm.end) : (vaddr += BLOCK_SIZE) {
        std.testing.expect(!(try allocations.isSet(vaddr / BLOCK_SIZE)));
    }
}

var test_allocations: ?bitmap.Bitmap(u64) = null;
var test_mapper = Mapper(u8){ .mapFn = testMap, .unmapFn = testUnmap };

///
/// Initialise a virtual memory manager used for testing
///
/// Arguments:
///     IN num_entries: u32 - The number of entries the VMM should track
///
/// Return: VirtualMemoryManager(u8)
///     The VMM constructed
///
/// Error: std.mem.Allocator.Error
///     OutOfMemory: The allocator couldn't allocate the structures needed
///
fn testInit(num_entries: u32) std.mem.Allocator.Error!VirtualMemoryManager(u8) {
    if (test_allocations == null) {
        test_allocations = try bitmap.Bitmap(u64).init(num_entries, std.heap.page_allocator);
    } else |allocations| {
        var entry: u32 = 0;
        while (entry < allocations.num_entries) : (entry += 1) {
            allocations.clearEntry(entry) catch unreachable;
        }
    }
    var allocations = test_allocations orelse unreachable;
    const mem_profile = mem.MemProfile{
        .vaddr_end = undefined,
        .vaddr_start = undefined,
        .physaddr_start = undefined,
        .physaddr_end = undefined,
        .mem_kb = num_entries * BLOCK_SIZE / 1024,
        .fixed_allocator = undefined,
        .virtual_reserved = &[_]mem.Map{},
        .physical_reserved = &[_]mem.Range{},
        .modules = &[_]mem.Module{},
    };
    pmm.init(&mem_profile, std.heap.page_allocator);
    return try VirtualMemoryManager(u8).init(0, num_entries * BLOCK_SIZE, std.heap.page_allocator, test_mapper, 39);
}

///
/// A mapping function used when doing unit tests
///
/// Arguments:
///     IN vstart: usize - The start of the virtual region to map
///     IN vend: usize - The end of the virtual region to map
///     IN pstart: usize - The start of the physical region to map
///     IN pend: usize - The end of the physical region to map
///     IN attrs: Attributes - The attributes to map with
///     IN/OUT allocator: *std.mem.Allocator - The allocator to use. Ignored
///     IN payload: u8 - The payload value. Expected to be 39
///
fn testMap(vstart: usize, vend: usize, pstart: usize, pend: usize, attrs: Attributes, allocator: *std.mem.Allocator, payload: u8) (std.mem.Allocator.Error || MapperError)!void {
    std.testing.expectEqual(@as(u8, 39), payload);
    var vaddr = vstart;
    while (vaddr < vend) : (vaddr += BLOCK_SIZE) {
        (test_allocations orelse unreachable).setEntry(vaddr / BLOCK_SIZE) catch unreachable;
    }
}

///
/// An unmapping function used when doing unit tests
///
/// Arguments:
///     IN vstart: usize - The start of the virtual region to unmap
///     IN vend: usize - The end of the virtual region to unmap
///     IN payload: u8 - The payload value. Expected to be 39
///
fn testUnmap(vstart: usize, vend: usize, payload: u8) (std.mem.Allocator.Error || MapperError)!void {
    std.testing.expectEqual(@as(u8, 39), payload);
    var vaddr = vstart;
    while (vaddr < vend) : (vaddr += BLOCK_SIZE) {
        (test_allocations orelse unreachable).clearEntry(vaddr / BLOCK_SIZE) catch unreachable;
    }
}

///
/// Run the runtime tests.
///
/// Arguments:
///     IN comptime Payload: type - The type of the payload passed to the mapper
///     IN vmm: VirtualMemoryManager(Payload) - The virtual memory manager to test
///     IN mem_profile: *const mem.MemProfile - The mem profile with details about all the memory regions that should be reserved
///     IN mb_info: *multiboot.multiboot_info_t - The multiboot info struct that should also be reserved
///
fn runtimeTests(comptime Payload: type, vmm: VirtualMemoryManager(Payload), mem_profile: *const mem.MemProfile) void {
    const v_start = std.mem.alignBackward(@ptrToInt(mem_profile.vaddr_start), BLOCK_SIZE);
    const v_end = std.mem.alignForward(@ptrToInt(mem_profile.vaddr_end) + mem.FIXED_ALLOC_SIZE, BLOCK_SIZE);

    var vaddr = vmm.start;
    while (vaddr < vmm.end - BLOCK_SIZE) : (vaddr += BLOCK_SIZE) {
        const set = vmm.isSet(vaddr) catch unreachable;
        var should_be_set = false;
        if (vaddr < v_end and vaddr >= v_start) {
            should_be_set = true;
        } else {
            for (mem_profile.virtual_reserved) |entry| {
                if (vaddr >= std.mem.alignBackward(entry.virtual.start, BLOCK_SIZE) and vaddr < std.mem.alignForward(entry.virtual.end, BLOCK_SIZE)) {
                    should_be_set = true;
                    break;
                }
            }
        }
        if (set and !should_be_set) {
            panic(@errorReturnTrace(), "An address was set in the VMM when it shouldn't have been: 0x{x}\n", .{vaddr});
        } else if (!set and should_be_set) {
            panic(@errorReturnTrace(), "An address was not set in the VMM when it should have been: 0x{x}\n", .{vaddr});
        }
    }

    std.log.info(.tty, "Tested allocations\n", .{});
}
