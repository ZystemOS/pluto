const build_options = @import("build_options");
const mock_path = build_options.mock_path;
const builtin = @import("builtin");
const is_test = builtin.is_test;
const std = @import("std");
const log = std.log.scoped(.vmm);
const bitmap = @import("bitmap.zig");
const pmm = @import("pmm.zig");
const mem = @import("mem.zig");
const tty = @import("tty.zig");
const panic = @import("panic.zig").panic;
const arch = if (is_test) @import(mock_path ++ "arch_mock.zig") else @import("arch.zig").internals;
const Allocator = std.mem.Allocator;

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
        ///     IN/OUT allocator: Allocator - The allocator to use when mapping, if required
        ///     IN spec: Payload - The payload to pass to the mapper
        ///
        /// Error: AllocatorError || MapperError
        ///     The causes depend on the mapper used
        ///
        mapFn: fn (virtual_start: usize, virtual_end: usize, physical_start: usize, physical_end: usize, attrs: Attributes, allocator: *Allocator, spec: Payload) (Allocator.Error || MapperError)!void,

        ///
        /// Unmap a region (can span more than one block) of virtual memory from its physical memory. After a call to this function, the memory should not be accessible without error.
        ///
        /// Arguments:
        ///     IN virtual_start: usize - The start of the virtual region to unmap
        ///     IN virtual_end: usize - The end of the virtual region to unmap
        ///     IN spec: Payload - The payload to pass to the mapper
        ///
        /// Error: AllocatorError || MapperError
        ///     The causes depend on the mapper used
        ///
        unmapFn: fn (virtual_start: usize, virtual_end: usize, spec: Payload) (Allocator.Error || MapperError)!void,
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

    /// Not enough virtual space in the VMM
    OutOfMemory,
};

/// The boot-time offset that the virtual addresses are from the physical addresses
/// This is the start of the memory owned by the kernel and so is where the kernel VMM starts
extern var KERNEL_ADDR_OFFSET: *u32;

/// The virtual memory manager associated with the kernel address space
pub var kernel_vmm: VirtualMemoryManager(arch.VmmPayload) = undefined;

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
        allocator: *Allocator,

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
        ///     IN/OUT allocator: *Allocator - The allocator to use when allocating and freeing regions
        ///     IN mapper: Mapper - The mapper to use when allocating and freeing regions
        ///     IN payload: Payload - The payload data to be passed to the mapper
        ///
        /// Return: Self
        ///     The manager constructed
        ///
        /// Error: Allocator.Error
        ///     error.OutOfMemory - The allocator cannot allocate the memory required
        ///
        pub fn init(start: usize, end: usize, allocator: *Allocator, mapper: Mapper(Payload), payload: Payload) Allocator.Error!Self {
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
        /// Copy this VMM. Changes to one copy will not affect the other
        ///
        /// Arguments:
        ///     IN self: *Self - The VMM to copy
        ///
        /// Error: Allocator.Error
        ///     OutOfMemory - There wasn't enough memory for copying
        ///
        /// Return: Self
        ///     The copy
        ///
        pub fn copy(self: *const Self) Allocator.Error!Self {
            var clone = Self{
                .bmp = try self.bmp.clone(),
                .start = self.start,
                .end = self.end,
                .allocator = self.allocator,
                .allocations = std.hash_map.AutoHashMap(usize, Allocation).init(self.allocator),
                .mapper = self.mapper,
                .payload = self.payload,
            };
            var it = self.allocations.iterator();
            while (it.next()) |entry| {
                var list = std.ArrayList(usize).init(self.allocator);
                for (entry.value.physical.items) |block| {
                    _ = try list.append(block);
                }
                _ = try clone.allocations.put(entry.key, Allocation{ .physical = list });
            }
            return clone;
        }

        ///
        /// Free the internal state of the VMM. It is unusable afterwards
        ///
        /// Arguments:
        ///     IN self: *Self - The VMM to deinitialise
        ///
        pub fn deinit(self: *Self) void {
            self.bmp.deinit();
            var it = self.allocations.iterator();
            while (it.next()) |entry| {
                entry.value.physical.deinit();
            }
            self.allocations.deinit();
        }

        ///
        /// Find the physical address that a given virtual address is mapped to.
        ///
        /// Arguments:
        ///     IN self: *const Self - The VMM to check for mappings in
        ///     IN virt: usize - The virtual address to find the physical address for
        ///
        /// Return: usize
        ///     The physical address that the virtual address is mapped to
        ///
        /// Error: VmmError
        ///     VmmError.NotAllocated - The virtual address hasn't been mapped within the VMM
        ///
        pub fn virtToPhys(self: *const Self, virt: usize) VmmError!usize {
            var it = self.allocations.iterator();
            while (it.next()) |entry| {
                const vaddr = entry.key;

                const allocation = entry.value;
                // If this allocation range covers the virtual address then figure out the corresponding physical block
                if (vaddr <= virt and vaddr + (allocation.physical.items.len * BLOCK_SIZE) > virt) {
                    const block_number = (virt - vaddr) / BLOCK_SIZE;
                    const block_offset = (virt - vaddr) % BLOCK_SIZE;
                    return allocation.physical.items[block_number] + block_offset;
                }
            }
            return VmmError.NotAllocated;
        }

        ///
        /// Find the virtual address that a given physical address is mapped to.
        ///
        /// Arguments:
        ///     IN self: *const Self - The VMM to check for mappings in
        ///     IN phys: usize - The physical address to find the virtual address for
        ///
        /// Return: usize
        ///     The virtual address that the physical address is mapped to
        ///
        /// Error: VmmError
        ///     VmmError.NotAllocated - The physical address hasn't been mapped within the VMM
        ///
        pub fn physToVirt(self: *const Self, phys: usize) VmmError!usize {
            var it = self.allocations.iterator();
            while (it.next()) |entry| {
                const vaddr = entry.key;
                const allocation = entry.value;

                for (allocation.physical.items) |block, i| {
                    if (block <= phys and block + BLOCK_SIZE > phys) {
                        const block_addr = vaddr + i * BLOCK_SIZE;
                        const block_offset = phys % BLOCK_SIZE;
                        return block_addr + block_offset;
                    }
                }
            }
            return VmmError.NotAllocated;
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
            return self.bmp.isSet((virt - self.start) / BLOCK_SIZE);
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
        /// Error: VmmError || Bitmap(u32).BitmapError || Allocator.Error || MapperError
        ///     VmmError.AlreadyAllocated - The virtual address has already been allocated
        ///     VmmError.PhysicalAlreadyAllocated - The physical address has already been allocated
        ///     VmmError.PhysicalVirtualMismatch - The physical region and virtual region are of different sizes
        ///     VmmError.InvalidVirtAddresses - The start virtual address is greater than the end address
        ///     VmmError.InvalidPhysicalAddresses - The start physical address is greater than the end address
        ///     Bitmap.BitmapError.OutOfBounds - The physical or virtual addresses are out of bounds
        ///     Allocator.Error.OutOfMemory - Allocating the required memory failed
        ///     MapperError.* - The causes depend on the mapper used
        ///
        pub fn set(self: *Self, virtual: mem.Range, physical: ?mem.Range, attrs: Attributes) (VmmError || bitmap.Bitmap(u32).BitmapError || Allocator.Error || MapperError)!void {
            var virt = virtual.start;
            while (virt < virtual.end) : (virt += BLOCK_SIZE) {
                if (try self.isSet(virt)) {
                    return VmmError.AlreadyAllocated;
                }
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
                var phys = p.start;
                while (phys < p.end) : (phys += BLOCK_SIZE) {
                    try pmm.setAddr(phys);
                    try phys_list.append(phys);
                }
            }

            // Do this before mapping as the mapper may depend on the allocation being tracked
            _ = try self.allocations.put(virtual.start, Allocation{ .physical = phys_list });

            if (physical) |p| {
                try self.mapper.mapFn(virtual.start, virtual.end, p.start, p.end, attrs, self.allocator, self.payload);
            }
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
        /// Error: Allocator.Error
        ///     error.OutOfMemory: The required amount of memory couldn't be allocated
        ///
        pub fn alloc(self: *Self, num: usize, attrs: Attributes) Allocator.Error!?usize {
            if (num == 0) {
                return null;
            }
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
                        self.mapper.mapFn(vaddr, vaddr + BLOCK_SIZE, addr, addr + BLOCK_SIZE, attrs, self.allocator, self.payload) catch |e| {
                            panic(@errorReturnTrace(), "Failed to map virtual memory: {X}\n", .{e});
                        };
                        vaddr += BLOCK_SIZE;
                    }
                    _ = try self.allocations.put(vaddr_start, Allocation{ .physical = block_list });
                    return vaddr_start;
                }
            }
            return null;
        }

        ///
        /// Copy data from an address in a virtual memory manager to an address in another virtual memory manager
        ///
        /// Arguments:
        ///     IN self: *Self - One of the VMMs to copy between. This should be the currently active VMM
        ///     IN other: *Self - The second of the VMMs to copy between
        ///     IN data: []u8 - The being copied from or written to (depending on `from`). Must be mapped within the VMM being copied from/to
        ///     IN address: usize - The address within `other` that is to be copied from or to
        ///     IN from: bool - Whether the date should be copied from `self` to `other, or the other way around
        ///
        /// Error: VmmError || pmm.PmmError || Allocator.Error
        ///     VmmError.NotAllocated - Some or all of the destination isn't mapped
        ///     VmmError.OutOfMemory - There wasn't enough space in the VMM to use for temporary mapping
        ///     Bitmap(u32).Error.OutOfBounds - The address given is outside of the memory managed
        ///     Allocator.Error.OutOfMemory - There wasn't enough memory available to fulfill the request
        ///
        pub fn copyData(self: *Self, other: *const Self, data: []u8, address: usize, from: bool) (bitmap.Bitmap(usize).BitmapError || VmmError || Allocator.Error)!void {
            if (data.len == 0) {
                return;
            }
            const start_addr = std.mem.alignBackward(address, BLOCK_SIZE);
            const end_addr = std.mem.alignForward(address + data.len, BLOCK_SIZE);
            if (end_addr >= other.end or start_addr < other.start)
                return bitmap.Bitmap(usize).BitmapError.OutOfBounds;
            // Find physical blocks for the address
            var blocks = std.ArrayList(usize).init(self.allocator);
            defer blocks.deinit();
            var it = other.allocations.iterator();
            while (it.next()) |allocation| {
                const virtual = allocation.key;
                const physical = allocation.value.physical.items;
                if (start_addr >= virtual and virtual + physical.len * BLOCK_SIZE >= end_addr) {
                    const first_block_idx = (start_addr - virtual) / BLOCK_SIZE;
                    const last_block_idx = (end_addr - virtual) / BLOCK_SIZE;

                    try blocks.appendSlice(physical[first_block_idx..last_block_idx]);
                }
            }
            // Make sure the address is actually mapped in the destination VMM
            if (blocks.items.len == 0) {
                return VmmError.NotAllocated;
            }

            // Map them into self for some vaddr so they can be accessed from this VMM
            if (self.bmp.setContiguous(blocks.items.len)) |entry| {
                const v_start = entry * BLOCK_SIZE + self.start;
                defer {
                    // Unmap virtual blocks from self so they can be used in the future
                    var v = v_start;
                    while (v < v_start + blocks.items.len * BLOCK_SIZE) : (v += BLOCK_SIZE) {
                        // Cannot be out of bounds as it has been set above
                        self.bmp.clearEntry((v - self.start) / BLOCK_SIZE) catch unreachable;
                    }
                }
                for (blocks.items) |block, i| {
                    const v = v_start + i * BLOCK_SIZE;
                    const v_end = v + BLOCK_SIZE;
                    const p = block;
                    const p_end = p + BLOCK_SIZE;
                    self.mapper.mapFn(v, v_end, p, p_end, .{ .kernel = true, .writable = true, .cachable = true }, self.allocator, self.payload) catch |e| {
                        // If we fail to map one of the blocks then attempt to free all previously mapped
                        if (i > 0) {
                            self.mapper.unmapFn(v_start, v_end, self.payload) catch |e2| {
                                // If we can't unmap then just panic
                                panic(@errorReturnTrace(), "Failed to unmap region 0x{X} -> 0x{X}: {}\n", .{ v_start, v_end, e2 });
                            };
                        }
                        panic(@errorReturnTrace(), "Failed to map vrutal region 0x{X} -> 0x{X} to 0x{X} -> 0x{X}: {}\n", .{ v, v_end, p, p_end, e });
                    };
                }
                // Copy to vaddr from above
                const align_offset = address - start_addr;
                var data_copy = @intToPtr([*]u8, v_start + align_offset)[0..data.len];
                if (from) {
                    std.mem.copy(u8, data_copy, data);
                } else {
                    std.mem.copy(u8, data, data_copy);
                }
            } else {
                return VmmError.OutOfMemory;
            }
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
                const allocation = self.allocations.get(vaddr).?;
                const physical = allocation.physical;
                defer physical.deinit();
                const num_physical_allocations = physical.items.len;
                for (physical.items) |block, i| {
                    // Clear the address space entry and free the physical memory
                    try self.bmp.clearEntry(entry + i);
                    pmm.free(block) catch |e| {
                        panic(@errorReturnTrace(), "Failed to free PMM reserved memory at 0x{X}: {}\n", .{ block * BLOCK_SIZE, e });
                    };
                }
                // Unmap the entire range
                const region_start = vaddr;
                const region_end = vaddr + (num_physical_allocations * BLOCK_SIZE);
                self.mapper.unmapFn(region_start, region_end, self.payload) catch |e| {
                    panic(@errorReturnTrace(), "Failed to unmap VMM reserved memory from 0x{X} to 0x{X}: {}\n", .{ region_start, region_end, e });
                };
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
///     IN/OUT allocator: *Allocator - The allocator to use when needing to allocate memory
///
/// Return: VirtualMemoryManager
///     The virtual memory manager created with all reserved virtual regions allocated
///
/// Error: Allocator.Error
///     error.OutOfMemory - The allocator cannot allocate the memory required
///
pub fn init(mem_profile: *const mem.MemProfile, allocator: *Allocator) Allocator.Error!*VirtualMemoryManager(arch.VmmPayload) {
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});

    kernel_vmm = try VirtualMemoryManager(arch.VmmPayload).init(@ptrToInt(&KERNEL_ADDR_OFFSET), 0xFFFFFFFF, allocator, arch.VMM_MAPPER, arch.KERNEL_VMM_PAYLOAD);

    // Map all the reserved virtual addresses.
    for (mem_profile.virtual_reserved) |entry| {
        const virtual = mem.Range{
            .start = std.mem.alignBackward(entry.virtual.start, BLOCK_SIZE),
            .end = std.mem.alignForward(entry.virtual.end, BLOCK_SIZE),
        };
        const physical: ?mem.Range = if (entry.physical) |phys|
            mem.Range{
                .start = std.mem.alignBackward(phys.start, BLOCK_SIZE),
                .end = std.mem.alignForward(phys.end, BLOCK_SIZE),
            }
        else
            null;
        kernel_vmm.set(virtual, physical, .{ .kernel = true, .writable = true, .cachable = true }) catch |e| switch (e) {
            VmmError.AlreadyAllocated => {},
            else => panic(@errorReturnTrace(), "Failed mapping region in VMM {X}: {}\n", .{ entry, e }),
        };
    }

    return &kernel_vmm;
}

test "virtToPhys" {
    const num_entries = 512;
    var vmm = try testInit(num_entries);
    defer testDeinit(&vmm);

    const vstart = vmm.start + BLOCK_SIZE;
    const vend = vstart + BLOCK_SIZE * 3;
    const pstart = BLOCK_SIZE * 20;
    const pend = BLOCK_SIZE * 23;

    // Set the physical and virtual back to front to complicate the mappings a bit
    try vmm.set(.{ .start = vstart, .end = vstart + BLOCK_SIZE }, mem.Range{ .start = pstart + BLOCK_SIZE * 2, .end = pend }, .{ .kernel = true, .writable = true, .cachable = true });
    try vmm.set(.{ .start = vstart + BLOCK_SIZE, .end = vend }, mem.Range{ .start = pstart, .end = pstart + BLOCK_SIZE * 2 }, .{ .kernel = true, .writable = true, .cachable = true });

    std.testing.expectEqual(pstart + BLOCK_SIZE * 2, try vmm.virtToPhys(vstart));
    std.testing.expectEqual(pstart + BLOCK_SIZE * 2 + 29, (try vmm.virtToPhys(vstart + 29)));
    std.testing.expectEqual(pstart + 29, (try vmm.virtToPhys(vstart + BLOCK_SIZE + 29)));

    std.testing.expectError(VmmError.NotAllocated, vmm.virtToPhys(vstart - 1));
    std.testing.expectError(VmmError.NotAllocated, vmm.virtToPhys(vend));
    std.testing.expectError(VmmError.NotAllocated, vmm.virtToPhys(vend + 1));
}

test "physToVirt" {
    const num_entries = 512;
    var vmm = try testInit(num_entries);
    defer testDeinit(&vmm);

    const vstart = vmm.start + BLOCK_SIZE;
    const vend = vstart + BLOCK_SIZE * 3;
    const pstart = BLOCK_SIZE * 20;
    const pend = BLOCK_SIZE * 23;

    // Set the physical and virtual back to front to complicate the mappings a bit
    try vmm.set(.{ .start = vstart, .end = vstart + BLOCK_SIZE }, mem.Range{ .start = pstart + BLOCK_SIZE * 2, .end = pend }, .{ .kernel = true, .writable = true, .cachable = true });
    try vmm.set(.{ .start = vstart + BLOCK_SIZE, .end = vend }, mem.Range{ .start = pstart, .end = pstart + BLOCK_SIZE * 2 }, .{ .kernel = true, .writable = true, .cachable = true });

    std.testing.expectEqual(vstart, try vmm.physToVirt(pstart + BLOCK_SIZE * 2));
    std.testing.expectEqual(vstart + 29, (try vmm.physToVirt(pstart + BLOCK_SIZE * 2 + 29)));
    std.testing.expectEqual(vstart + BLOCK_SIZE + 29, (try vmm.physToVirt(pstart + 29)));

    std.testing.expectError(VmmError.NotAllocated, vmm.physToVirt(pstart - 1));
    std.testing.expectError(VmmError.NotAllocated, vmm.physToVirt(pend));
    std.testing.expectError(VmmError.NotAllocated, vmm.physToVirt(pend + 1));
}

test "alloc and free" {
    const num_entries = 512;
    var vmm = try testInit(num_entries);
    defer testDeinit(&vmm);
    var allocations = test_allocations.?;
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
            try virtual_allocations.append(result.?);
        }

        // Make sure that the entries are set or not depending on the allocation success
        var vaddr = vmm.start + entry * BLOCK_SIZE;
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
    defer testDeinit(&vmm);

    const vstart = vmm.start + BLOCK_SIZE * 37;
    const vend = vmm.start + BLOCK_SIZE * 46;
    const pstart = BLOCK_SIZE * 37 + 123;
    const pend = BLOCK_SIZE * 46 + 123;
    const attrs = Attributes{ .kernel = true, .writable = true, .cachable = true };
    try vmm.set(.{ .start = vstart, .end = vend }, mem.Range{ .start = pstart, .end = pend }, attrs);
    // Make sure it put the correct address in the map
    std.testing.expect(vmm.allocations.get(vstart) != null);

    var allocations = test_allocations.?;
    // The entries before the virtual start shouldn't be set
    var vaddr = vmm.start;
    while (vaddr < vstart) : (vaddr += BLOCK_SIZE) {
        std.testing.expect(!(try allocations.isSet((vaddr - vmm.start) / BLOCK_SIZE)));
    }
    // The entries up until the virtual end should be set
    while (vaddr < vend) : (vaddr += BLOCK_SIZE) {
        std.testing.expect(try allocations.isSet((vaddr - vmm.start) / BLOCK_SIZE));
    }
    // The entries after the virtual end should not be set
    while (vaddr < vmm.end) : (vaddr += BLOCK_SIZE) {
        std.testing.expect(!(try allocations.isSet((vaddr - vmm.start) / BLOCK_SIZE)));
    }
}

test "copy" {
    const num_entries = 512;
    var vmm = try testInit(num_entries);
    defer testDeinit(&vmm);

    const attrs = .{ .kernel = true, .cachable = true, .writable = true };
    const alloc0 = (try vmm.alloc(24, attrs)).?;

    var mirrored = try vmm.copy();
    defer mirrored.deinit();
    std.testing.expectEqual(vmm.bmp.num_free_entries, mirrored.bmp.num_free_entries);
    std.testing.expectEqual(vmm.start, mirrored.start);
    std.testing.expectEqual(vmm.end, mirrored.end);
    std.testing.expectEqual(vmm.allocations.count(), mirrored.allocations.count());
    var it = vmm.allocations.iterator();
    while (it.next()) |next| {
        for (mirrored.allocations.get(next.key).?.physical.items) |block, i| {
            std.testing.expectEqual(block, vmm.allocations.get(next.key).?.physical.items[i]);
        }
    }
    std.testing.expectEqual(vmm.mapper, mirrored.mapper);
    std.testing.expectEqual(vmm.payload, mirrored.payload);

    // Allocating in the new VMM shouldn't allocate in the mirrored one
    const alloc1 = (try mirrored.alloc(3, attrs)).?;
    std.testing.expectEqual(vmm.allocations.count() + 1, mirrored.allocations.count());
    std.testing.expectEqual(vmm.bmp.num_free_entries - 3, mirrored.bmp.num_free_entries);
    std.testing.expectError(VmmError.NotAllocated, vmm.virtToPhys(alloc1));

    // And vice-versa
    const alloc2 = (try vmm.alloc(3, attrs)).?;
    const alloc3 = (try vmm.alloc(1, attrs)).?;
    const alloc4 = (try vmm.alloc(1, attrs)).?;
    std.testing.expectEqual(vmm.allocations.count() - 2, mirrored.allocations.count());
    std.testing.expectEqual(vmm.bmp.num_free_entries + 2, mirrored.bmp.num_free_entries);
    std.testing.expectError(VmmError.NotAllocated, mirrored.virtToPhys(alloc3));
    std.testing.expectError(VmmError.NotAllocated, mirrored.virtToPhys(alloc4));
}

test "copyData" {
    var vmm = try testInit(100);
    defer testDeinit(&vmm);
    const alloc1_blocks = 1;
    const alloc = (try vmm.alloc(alloc1_blocks, .{ .kernel = true, .writable = true, .cachable = true })) orelse unreachable;
    var vmm2 = try VirtualMemoryManager(u8).init(vmm.start, vmm.end, std.testing.allocator, test_mapper, 39);
    defer vmm2.deinit();
    var vmm_free_entries = vmm.bmp.num_free_entries;
    var vmm2_free_entries = vmm2.bmp.num_free_entries;

    var buff: [4]u8 = [4]u8{ 10, 11, 12, 13 };
    try vmm2.copyData(&vmm, buff[0..buff.len], alloc, true);

    // Make sure they are the same
    var buff2 = @intToPtr([*]u8, alloc)[0..buff.len];
    std.testing.expectEqualSlices(u8, buff[0..buff.len], buff2);
    std.testing.expectEqual(vmm_free_entries, vmm.bmp.num_free_entries);
    std.testing.expectEqual(vmm2_free_entries, vmm2.bmp.num_free_entries);

    try vmm2.copyData(&vmm, buff2, alloc, false);
    std.testing.expectEqualSlices(u8, buff[0..buff.len], buff2);
    std.testing.expectEqual(vmm_free_entries, vmm.bmp.num_free_entries);
    std.testing.expectEqual(vmm2_free_entries, vmm2.bmp.num_free_entries);

    // Test NotAllocated
    std.testing.expectError(VmmError.NotAllocated, vmm2.copyData(&vmm, buff[0..buff.len], alloc + alloc1_blocks * BLOCK_SIZE, true));
    std.testing.expectEqual(vmm_free_entries, vmm.bmp.num_free_entries);
    std.testing.expectEqual(vmm2_free_entries, vmm2.bmp.num_free_entries);

    // Test Bitmap.Error.OutOfBounds
    std.testing.expectError(bitmap.Bitmap(usize).BitmapError.OutOfBounds, vmm2.copyData(&vmm, buff[0..buff.len], vmm.end, true));
    std.testing.expectError(bitmap.Bitmap(usize).BitmapError.OutOfBounds, vmm.copyData(&vmm2, buff[0..buff.len], vmm2.end, true));
    std.testing.expectEqual(vmm_free_entries, vmm.bmp.num_free_entries);
    std.testing.expectEqual(vmm2_free_entries, vmm2.bmp.num_free_entries);
}

var test_allocations: ?*bitmap.Bitmap(u64) = null;
var test_mapper = Mapper(u8){ .mapFn = testMap, .unmapFn = testUnmap };
var test_vmm: VirtualMemoryManager(u8) = undefined;

///
/// Initialise a virtual memory manager used for testing
///
/// Arguments:
///     IN num_entries: u32 - The number of entries the VMM should track
///
/// Return: VirtualMemoryManager(u8)
///     The VMM constructed
///
/// Error: Allocator.Error
///     OutOfMemory: The allocator couldn't allocate the structures needed
///
fn testInit(num_entries: u32) Allocator.Error!VirtualMemoryManager(u8) {
    if (test_allocations == null) {
        test_allocations = try std.testing.allocator.create(bitmap.Bitmap(u64));
        test_allocations.?.* = try bitmap.Bitmap(u64).init(num_entries, std.testing.allocator);
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
    pmm.init(&mem_profile, std.testing.allocator);
    const test_vaddr_start = @ptrToInt(&(try std.testing.allocator.alloc(u8, num_entries * BLOCK_SIZE))[0]);
    test_vmm = try VirtualMemoryManager(u8).init(test_vaddr_start, test_vaddr_start + num_entries * BLOCK_SIZE, std.testing.allocator, test_mapper, 39);
    return test_vmm;
}

fn testDeinit(vmm: *VirtualMemoryManager(u8)) void {
    vmm.deinit();
    const space = @intToPtr([*]u8, vmm.start)[0 .. vmm.end - vmm.start];
    vmm.allocator.free(space);
    if (test_allocations) |allocs| {
        allocs.deinit();
        std.testing.allocator.destroy(allocs);
        test_allocations = null;
    }
    pmm.deinit();
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
///     IN/OUT allocator: *Allocator - The allocator to use. Ignored
///     IN payload: u8 - The payload value. Expected to be 39
///
fn testMap(vstart: usize, vend: usize, pstart: usize, pend: usize, attrs: Attributes, allocator: *Allocator, payload: u8) (Allocator.Error || MapperError)!void {
    std.testing.expectEqual(@as(u8, 39), payload);
    var vaddr = vstart;
    var allocations = test_allocations.?;
    while (vaddr < vend) : (vaddr += BLOCK_SIZE) {
        allocations.setEntry((vaddr - test_vmm.start) / BLOCK_SIZE) catch unreachable;
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
fn testUnmap(vstart: usize, vend: usize, payload: u8) (Allocator.Error || MapperError)!void {
    std.testing.expectEqual(@as(u8, 39), payload);
    var vaddr = vstart;
    var allocations = test_allocations.?;
    while (vaddr < vend) : (vaddr += BLOCK_SIZE) {
        if (allocations.isSet((vaddr - test_vmm.start) / BLOCK_SIZE) catch unreachable) {
            allocations.clearEntry((vaddr - test_vmm.start) / BLOCK_SIZE) catch unreachable;
        } else {
            return MapperError.NotMapped;
        }
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
pub fn runtimeTests(comptime Payload: type, vmm: *VirtualMemoryManager(Payload), mem_profile: *const mem.MemProfile) void {
    rt_correctMapping(Payload, vmm, mem_profile);
    rt_copyData(vmm);
}

///
/// Test that the correct mappings have been made in the VMM
///
/// Arguments:
///     IN vmm: VirtualMemoryManager(Payload) - The virtual memory manager to test
///     IN mem_profile: *const mem.MemProfile - The mem profile with details about all the memory regions that should be reserved
///
fn rt_correctMapping(comptime Payload: type, vmm: *VirtualMemoryManager(Payload), mem_profile: *const mem.MemProfile) void {
    const v_start = std.mem.alignBackward(@ptrToInt(mem_profile.vaddr_start), BLOCK_SIZE);
    const v_end = std.mem.alignForward(@ptrToInt(mem_profile.vaddr_end), BLOCK_SIZE);

    var vaddr = vmm.start;
    while (vaddr < vmm.end - BLOCK_SIZE) : (vaddr += BLOCK_SIZE) {
        const set = vmm.isSet(vaddr) catch unreachable;
        var should_be_set = false;
        if (vaddr < v_end and vaddr >= v_start) {
            should_be_set = true;
        } else {
            for (mem_profile.virtual_reserved) |entry| {
                if (vaddr >= std.mem.alignBackward(entry.virtual.start, BLOCK_SIZE) and vaddr < std.mem.alignForward(entry.virtual.end, BLOCK_SIZE)) {
                    if (entry.physical) |phys| {
                        const expected_phys = phys.start + (vaddr - entry.virtual.start);
                        if (vmm.virtToPhys(vaddr) catch unreachable != expected_phys) {
                            panic(@errorReturnTrace(), "virtToPhys didn't return the correct physical address for 0x{X} (0x{X})\n", .{ vaddr, vmm.virtToPhys(vaddr) });
                        }
                        if (vmm.physToVirt(expected_phys) catch unreachable != vaddr) {
                            panic(@errorReturnTrace(), "physToVirt didn't return the correct virtual address for 0x{X} (0x{X})\n", .{ expected_phys, vaddr });
                        }
                    }
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
    log.info("Tested allocations\n", .{});
}

///
/// Test copying data to and from another VMM
///
/// Arguments:
///     IN vmm: *VirtualMemoryManager() - The active VMM to test
///
fn rt_copyData(vmm: *VirtualMemoryManager(arch.VmmPayload)) void {
    const expected_free_entries = vmm.bmp.num_free_entries;
    // Mirror the VMM
    var vmm2 = vmm.copy() catch |e| {
        panic(@errorReturnTrace(), "Failed to mirror VMM: {}\n", .{e});
    };

    // Allocate within secondary VMM
    const addr = vmm2.alloc(1, .{ .kernel = true, .cachable = true, .writable = true }) catch |e| {
        panic(@errorReturnTrace(), "Failed to allocate within the secondary VMM in rt_copyData: {}\n", .{e});
    } orelse panic(@errorReturnTrace(), "Failed to get an allocation within the secondary VMM in rt_copyData\n", .{});
    defer vmm2.free(addr) catch |e| {
        panic(@errorReturnTrace(), "Failed to free the allocation in secondary VMM: {}\n", .{e});
    };

    const expected_free_entries2 = vmm2.bmp.num_free_entries;
    const expected_free_pmm_entries = pmm.blocksFree();
    // Try copying to vmm2
    var buff: [6]u8 = [_]u8{ 4, 5, 9, 123, 90, 67 };
    vmm.copyData(&vmm2, buff[0..buff.len], addr, true) catch |e| {
        panic(@errorReturnTrace(), "Failed to copy data to secondary VMM in rt_copyData: {}\n", .{e});
    };
    // Make sure the function cleaned up
    if (vmm.bmp.num_free_entries != expected_free_entries) {
        panic(@errorReturnTrace(), "Expected {} free entries in VMM, but there were {}\n", .{ expected_free_entries, vmm.bmp.num_free_entries });
    }
    if (vmm2.bmp.num_free_entries != expected_free_entries2) {
        panic(@errorReturnTrace(), "Expected {} free entries in the secondary VMM, but there were {}\n", .{ expected_free_entries2, vmm2.bmp.num_free_entries });
    }
    if (pmm.blocksFree() != expected_free_pmm_entries) {
        panic(@errorReturnTrace(), "Expected {} free entries in PMM, but there were {}\n", .{ expected_free_pmm_entries, pmm.blocksFree() });
    }

    // Make sure that the data at the allocated address is correct
    // Since vmm2 is a mirror of vmm, this address should be mapped by the CPU's MMU
    const dest_buff = @intToPtr([*]u8, addr)[0..buff.len];
    if (!std.mem.eql(u8, buff[0..buff.len], dest_buff)) {
        panic(@errorReturnTrace(), "Data copied to vmm2 doesn't have the expected values\n", .{});
    }

    // Now try copying the same buffer from vmm2
    var buff2 = vmm.allocator.alloc(u8, buff.len) catch |e| {
        panic(@errorReturnTrace(), "Failed to allocate a test buffer in rt_copyData: {}\n", .{e});
    };
    vmm.copyData(&vmm2, buff2, addr, false) catch |e| {
        panic(@errorReturnTrace(), "Failed to copy data from secondary VMM in rt_copyData: {}\n", .{e});
    };
    if (!std.mem.eql(u8, buff[0..buff.len], buff2)) {
        panic(@errorReturnTrace(), "Data copied from vmm2 doesn't have the expected values\n", .{});
    }
}
