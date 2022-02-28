const std = @import("std");
const builtin = std.builtin;
const testing = std.testing;
const Allocator = std.mem.Allocator;

///
/// A comptime bitmap that uses a specific type to store the entries. No allocators needed.
///
/// Arguments:
///     IN BitmapType: type - The integer type to use to store entries.
///
/// Return: type.
///     The bitmap type created.
///
pub fn ComptimeBitmap(comptime BitmapType: type) type {
    return struct {
        const Self = @This();

        /// The number of entries that one bitmap type can hold. Evaluates to the number of bits the type has
        pub const NUM_ENTRIES: usize = std.meta.bitCount(BitmapType);

        /// The value that a full bitmap will have
        pub const BITMAP_FULL = std.math.maxInt(BitmapType);

        /// The type of an index into a bitmap entry. The smallest integer needed to represent all bit positions in the bitmap entry type
        pub const IndexType = std.meta.Int(.unsigned, std.math.log2(std.math.ceilPowerOfTwo(u16, std.meta.bitCount(BitmapType)) catch unreachable));

        bitmap: BitmapType,
        num_free_entries: BitmapType,

        ///
        /// Create an instance of this bitmap type.
        ///
        /// Return: Self.
        ///     The bitmap instance.
        ///
        pub fn init() Self {
            return .{
                .bitmap = 0,
                .num_free_entries = NUM_ENTRIES,
            };
        }

        ///
        /// Set an entry within a bitmap as occupied.
        ///
        /// Arguments:
        ///     IN/OUT self: *Self - The bitmap to modify.
        ///     IN idx: IndexType - The index within the bitmap to set.
        ///
        pub fn setEntry(self: *Self, idx: IndexType) void {
            if (!self.isSet(idx)) {
                self.bitmap |= indexToBit(idx);
                self.num_free_entries -= 1;
            }
        }

        ///
        /// Set an entry within a bitmap as unoccupied.
        ///
        /// Arguments:
        ///     IN/OUT self: *Self - The bitmap to modify.
        ///     IN idx: IndexType - The index within the bitmap to clear.
        ///
        pub fn clearEntry(self: *Self, idx: IndexType) void {
            if (self.isSet(idx)) {
                self.bitmap &= ~indexToBit(idx);
                self.num_free_entries += 1;
            }
        }

        ///
        /// Convert a global bitmap index into the bit corresponding to an entry within a single BitmapType.
        ///
        /// Arguments:
        ///     IN self: *const Self - The bitmap to use.
        ///     IN idx: IndexType - The index into all of the bitmaps entries.
        ///
        /// Return: BitmapType.
        ///     The bit corresponding to that index but within a single BitmapType.
        ///
        fn indexToBit(idx: IndexType) BitmapType {
            return @as(BitmapType, 1) << idx;
        }

        ///
        /// Find a number of contiguous free entries and set them.
        ///
        /// Arguments:
        ///     IN/OUT self: *Self - The bitmap to modify.
        ///     IN num: usize - The number of entries to set.
        ///     IN from: ?IndexType - The entry number to start allocate from or null if it can start anywhere
        ///
        /// Return: ?IndexType
        ///     The first entry set or null if there weren't enough contiguous entries.
        ///     If `from` was not null and any entry between `from` and `from` + num is set then null is returned.
        ///
        pub fn setContiguous(self: *Self, num: usize, from: ?IndexType) ?IndexType {
            if (num > self.num_free_entries) {
                return null;
            }

            var count: usize = 0;
            var start: ?IndexType = null;

            var bit = from orelse 0;
            while (true) {
                const entry = bit;
                if (entry >= NUM_ENTRIES) {
                    return null;
                }
                if ((self.bitmap & @as(BitmapType, 1) << bit) != 0) {
                    // This is a one so clear the progress
                    count = 0;
                    start = null;
                    // If the caller requested the allocation to start from
                    // a specific entry and it failed then return null
                    if (from) |_| {
                        return null;
                    }
                } else {
                    // It's a zero so increment the count
                    count += 1;
                    if (start == null) {
                        // Start of the contiguous zeroes
                        start = entry;
                    }
                    if (count == num) {
                        // Reached the desired number
                        break;
                    }
                }
                // Avoiding overflow by checking if bit is less than the max - 1
                if (bit < NUM_ENTRIES - 1) {
                    bit += 1;
                } else {
                    break;
                }
            }

            if (count == num) {
                if (start) |start_entry| {
                    var i: IndexType = 0;
                    while (i < num) : (i += 1) {
                        self.setEntry(start_entry + i);
                    }
                    return start_entry;
                }
            }
            return null;
        }

        ///
        /// Set the first free entry within the bitmaps as occupied.
        ///
        /// Return: ?IndexType.
        ///     The index within all bitmaps that was set or null if there wasn't one free.
        ///     0 .. NUM_ENTRIES - 1 if in the first bitmap, NUM_ENTRIES .. NUM_ENTRIES * 2 - 1 if in the second etc.
        ///
        pub fn setFirstFree(self: *Self) ?IndexType {
            if (self.num_free_entries == 0 or self.bitmap == BITMAP_FULL) {
                std.debug.assert(self.num_free_entries == 0 and self.bitmap == BITMAP_FULL);
                return null;
            }
            const bit = @truncate(IndexType, @ctz(BitmapType, ~self.bitmap));
            self.setEntry(bit);
            return bit;
        }

        ///
        /// Check if an entry is set.
        ///
        /// Arguments:
        ///     IN self: *const Self - The bitmap to check.
        ///     IN idx: usize - The entry to check.
        ///
        /// Return: bool.
        ///     True if the entry is set, else false.
        ///
        pub fn isSet(self: *const Self, idx: IndexType) bool {
            return (self.bitmap & indexToBit(idx)) != 0;
        }
    };
}

///
/// A bitmap that uses a specific type to store the entries.
///
/// Arguments:
///     IN BitmapType: type - The integer type to use to store entries.
///
/// Return: type.
///     The bitmap type created.
///
pub fn Bitmap(comptime BitmapType: type) type {
    return struct {
        /// The possible errors thrown by bitmap functions
        pub const BitmapError = error{
            /// The address given was outside the region covered by a bitmap
            OutOfBounds,
        };

        const Self = @This();

        /// The number of entries that one bitmap type can hold. Evaluates to the number of bits the type has
        pub const ENTRIES_PER_BITMAP: usize = std.meta.bitCount(BitmapType);

        /// The value that a full bitmap will have
        pub const BITMAP_FULL = std.math.maxInt(BitmapType);

        /// The type of an index into a bitmap entry. The smallest integer needed to represent all bit positions in the bitmap entry type
        pub const IndexType = std.meta.Int(.unsigned, std.math.log2(std.math.ceilPowerOfTwo(u16, std.meta.bitCount(BitmapType)) catch unreachable));

        num_bitmaps: usize,
        num_entries: usize,
        bitmaps: []BitmapType,
        num_free_entries: usize,
        allocator: Allocator,

        ///
        /// Create an instance of this bitmap type.
        ///
        /// Arguments:
        ///     IN num_entries: usize - The number of entries that the bitmap created will have.
        ///         The number of BitmapType required to store this many entries will be allocated and each will be zeroed.
        ///     IN allocator: Allocator - The allocator to use when allocating the BitmapTypes required.
        ///
        /// Return: Self.
        ///     The bitmap instance.
        ///
        /// Error: Allocator.Error
        ///     OutOfMemory: There isn't enough memory available to allocate the required number of BitmapType.
        ///
        pub fn init(num_entries: usize, allocator: Allocator) !Self {
            const num = std.mem.alignForward(num_entries, ENTRIES_PER_BITMAP) / ENTRIES_PER_BITMAP;
            const self = Self{
                .num_bitmaps = num,
                .num_entries = num_entries,
                .bitmaps = try allocator.alloc(BitmapType, num),
                .num_free_entries = num_entries,
                .allocator = allocator,
            };
            for (self.bitmaps) |*bmp| {
                bmp.* = 0;
            }
            return self;
        }

        ///
        /// Clone this bitmap.
        ///
        /// Arguments:
        ///     IN self: *Self - The bitmap to clone.
        ///
        /// Return: Self
        ///     The cloned bitmap
        ///
        /// Error: Allocator.Error
        ///     OutOfMemory: There isn't enough memory available to allocate the required number of BitmapType.
        ///
        pub fn clone(self: *const Self) Allocator.Error!Self {
            var copy = try init(self.num_entries, self.allocator);
            var i: usize = 0;
            while (i < copy.num_entries) : (i += 1) {
                if (self.isSet(i) catch unreachable) {
                    copy.setEntry(i) catch unreachable;
                }
            }
            return copy;
        }

        ///
        /// Free the memory occupied by this bitmap's internal state. It will become unusable afterwards.
        ///
        /// Arguments:
        ///     IN self: *Self - The bitmap that should be deinitialised
        ///
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.bitmaps);
        }

        ///
        /// Set an entry within a bitmap as occupied.
        ///
        /// Arguments:
        ///     IN/OUT self: *Self - The bitmap to modify.
        ///     IN idx: usize - The index within the bitmap to set.
        ///
        /// Error: BitmapError.
        ///     OutOfBounds: The index given is out of bounds.
        ///
        pub fn setEntry(self: *Self, idx: usize) BitmapError!void {
            if (idx >= self.num_entries) {
                return BitmapError.OutOfBounds;
            }
            if (!try self.isSet(idx)) {
                const bit = indexToBit(idx);
                self.bitmaps[idx / ENTRIES_PER_BITMAP] |= bit;
                self.num_free_entries -= 1;
            }
        }

        ///
        /// Set an entry within a bitmap as unoccupied.
        ///
        /// Arguments:
        ///     IN/OUT self: *Self - The bitmap to modify.
        ///     IN idx: usize - The index within the bitmap to clear.
        ///
        /// Error: BitmapError.
        ///     OutOfBounds: The index given is out of bounds.
        ///
        pub fn clearEntry(self: *Self, idx: usize) BitmapError!void {
            if (idx >= self.num_entries) {
                return BitmapError.OutOfBounds;
            }
            if (try self.isSet(idx)) {
                const bit = indexToBit(idx);
                self.bitmaps[idx / ENTRIES_PER_BITMAP] &= ~bit;
                self.num_free_entries += 1;
            }
        }

        ///
        /// Convert a global bitmap index into the bit corresponding to an entry within a single BitmapType.
        ///
        /// Arguments:
        ///     IN self: *const Self - The bitmap to use.
        ///     IN idx: usize - The index into all of the bitmaps entries.
        ///
        /// Return: BitmapType.
        ///     The bit corresponding to that index but within a single BitmapType.
        ///
        fn indexToBit(idx: usize) BitmapType {
            return @as(BitmapType, 1) << @intCast(IndexType, idx % ENTRIES_PER_BITMAP);
        }

        ///
        /// Find a number of contiguous free entries and set them.
        ///
        /// Arguments:
        ///     IN/OUT self: *Self - The bitmap to modify.
        ///     IN num: usize - The number of entries to set.
        ///     IN from: ?usize - The entry number to allocate from or null if it can start anywhere
        ///
        /// Return: ?usize
        ///     The first entry set or null if there weren't enough contiguous entries.
        ///     If `from` was not null and any entry between `from` and `from` + num is set then null is returned.
        ///
        pub fn setContiguous(self: *Self, num: usize, from: ?usize) ?usize {
            if (num > self.num_free_entries) {
                return null;
            }

            var count: usize = 0;
            var start: ?usize = from;
            var i: usize = if (from) |f| f / ENTRIES_PER_BITMAP else 0;
            var bit: IndexType = if (from) |f| @truncate(IndexType, f % ENTRIES_PER_BITMAP) else 0;
            while (i < self.bitmaps.len) : ({
                i += 1;
                bit = 0;
            }) {
                var bmp = self.bitmaps[i];
                while (true) {
                    const entry = bit + i * ENTRIES_PER_BITMAP;
                    if (entry >= self.num_entries) {
                        return null;
                    }
                    if ((bmp & @as(BitmapType, 1) << bit) != 0) {
                        // This is a one so clear the progress
                        count = 0;
                        start = null;
                        // If the caller requested the allocation to start from
                        // a specific entry and it failed then return null
                        if (from) |_| {
                            return null;
                        }
                    } else {
                        // It's a zero so increment the count
                        count += 1;
                        if (start == null) {
                            // Start of the contiguous zeroes
                            start = entry;
                        }
                        if (count == num) {
                            // Reached the desired number
                            break;
                        }
                    }
                    // Avoiding overflow by checking if bit is less than the max - 1
                    if (bit < ENTRIES_PER_BITMAP - 1) {
                        bit += 1;
                    } else {
                        // Reached the end of the bitmap
                        break;
                    }
                }
                if (count == num) {
                    break;
                }
            }

            if (count == num) {
                if (start) |start_entry| {
                    var j: usize = 0;
                    while (j < num) : (j += 1) {
                        // Can't fail as the entry was found to be free
                        self.setEntry(start_entry + j) catch unreachable;
                    }
                    return start_entry;
                }
            }
            return null;
        }

        ///
        /// Set the first free entry within the bitmaps as occupied.
        ///
        /// Return: ?usize.
        ///     The index within all bitmaps that was set or null if there wasn't one free.
        ///     0 .. ENTRIES_PER_BITMAP - 1 if in the first bitmap, ENTRIES_PER_BITMAP .. ENTRIES_PER_BITMAP * 2 - 1 if in the second etc.
        ///
        pub fn setFirstFree(self: *Self) ?usize {
            if (self.num_free_entries == 0) {
                return null;
            }
            for (self.bitmaps) |*bmp, i| {
                if (bmp.* == BITMAP_FULL) {
                    continue;
                }
                const bit = @truncate(IndexType, @ctz(BitmapType, ~bmp.*));
                const idx = bit + i * ENTRIES_PER_BITMAP;
                // Failing here means that the index is outside of the bitmap, so there are no free entries
                self.setEntry(idx) catch return null;
                return idx;
            }
            return null;
        }

        ///
        /// Check if an entry is set.
        ///
        /// Arguments:
        ///     IN self: *const Self - The bitmap to check.
        ///     IN idx: usize - The entry to check.
        ///
        /// Return: bool.
        ///     True if the entry is set, else false.
        ///
        /// Error: BitmapError.
        ///     OutOfBounds: The index given is out of bounds.
        ///
        pub fn isSet(self: *const Self, idx: usize) BitmapError!bool {
            if (idx >= self.num_entries) {
                return BitmapError.OutOfBounds;
            }
            return (self.bitmaps[idx / ENTRIES_PER_BITMAP] & indexToBit(idx)) != 0;
        }
    };
}

test "Comptime setEntry" {
    var bmp = ComptimeBitmap(u32).init();
    try testing.expectEqual(@as(u32, 32), bmp.num_free_entries);

    bmp.setEntry(0);
    try testing.expectEqual(@as(u32, 1), bmp.bitmap);
    try testing.expectEqual(@as(u32, 31), bmp.num_free_entries);

    bmp.setEntry(1);
    try testing.expectEqual(@as(u32, 3), bmp.bitmap);
    try testing.expectEqual(@as(u32, 30), bmp.num_free_entries);

    // Repeat setting entry 1 to make sure state doesn't change
    bmp.setEntry(1);
    try testing.expectEqual(@as(u32, 3), bmp.bitmap);
    try testing.expectEqual(@as(u32, 30), bmp.num_free_entries);
}

test "Comptime clearEntry" {
    var bmp = ComptimeBitmap(u32).init();
    try testing.expectEqual(@as(u32, 32), bmp.num_free_entries);

    bmp.setEntry(0);
    try testing.expectEqual(@as(u32, 31), bmp.num_free_entries);
    bmp.setEntry(1);
    try testing.expectEqual(@as(u32, 30), bmp.num_free_entries);
    try testing.expectEqual(@as(u32, 3), bmp.bitmap);
    bmp.clearEntry(0);
    try testing.expectEqual(@as(u32, 31), bmp.num_free_entries);
    try testing.expectEqual(@as(u32, 2), bmp.bitmap);

    // Repeat to make sure state doesn't change
    bmp.clearEntry(0);
    try testing.expectEqual(@as(u32, 31), bmp.num_free_entries);
    try testing.expectEqual(@as(u32, 2), bmp.bitmap);

    // Try clearing an unset entry to make sure state doesn't change
    bmp.clearEntry(2);
    try testing.expectEqual(@as(u32, 31), bmp.num_free_entries);
    try testing.expectEqual(@as(u32, 2), bmp.bitmap);
}

test "Comptime setFirstFree" {
    var bmp = ComptimeBitmap(u32).init();

    // Allocate the first entry
    try testing.expectEqual(bmp.setFirstFree() orelse unreachable, 0);
    try testing.expectEqual(bmp.bitmap, 1);

    // Allocate the second entry
    try testing.expectEqual(bmp.setFirstFree() orelse unreachable, 1);
    try testing.expectEqual(bmp.bitmap, 3);

    // Make all but the MSB occupied and try to allocate it
    bmp.bitmap = ComptimeBitmap(u32).BITMAP_FULL & ~@as(u32, 1 << (ComptimeBitmap(u32).NUM_ENTRIES - 1));
    bmp.num_free_entries = 1;
    try testing.expectEqual(bmp.setFirstFree() orelse unreachable, ComptimeBitmap(u32).NUM_ENTRIES - 1);
    try testing.expectEqual(bmp.bitmap, ComptimeBitmap(u32).BITMAP_FULL);

    // We should no longer be able to allocate any entries
    try testing.expectEqual(bmp.setFirstFree(), null);
    try testing.expectEqual(bmp.bitmap, ComptimeBitmap(u32).BITMAP_FULL);
}

test "Comptime isSet" {
    var bmp = ComptimeBitmap(u32).init();

    bmp.bitmap = 1;
    // Make sure that only the set entry is considered set
    try testing.expect(bmp.isSet(0));
    var i: usize = 1;
    while (i < ComptimeBitmap(u32).NUM_ENTRIES) : (i += 1) {
        try testing.expect(!bmp.isSet(@truncate(ComptimeBitmap(u32).IndexType, i)));
    }

    bmp.bitmap = 3;
    try testing.expect(bmp.isSet(0));
    try testing.expect(bmp.isSet(1));
    i = 2;
    while (i < ComptimeBitmap(u32).NUM_ENTRIES) : (i += 1) {
        try testing.expect(!bmp.isSet(@truncate(ComptimeBitmap(u32).IndexType, i)));
    }

    bmp.bitmap = 11;
    try testing.expect(bmp.isSet(0));
    try testing.expect(bmp.isSet(1));
    try testing.expect(!bmp.isSet(2));
    try testing.expect(bmp.isSet(3));
    i = 4;
    while (i < ComptimeBitmap(u32).NUM_ENTRIES) : (i += 1) {
        try testing.expect(!bmp.isSet(@truncate(ComptimeBitmap(u32).IndexType, i)));
    }
}

test "Comptime indexToBit" {
    const Type = ComptimeBitmap(u8);
    try testing.expectEqual(Type.indexToBit(0), 1);
    try testing.expectEqual(Type.indexToBit(1), 2);
    try testing.expectEqual(Type.indexToBit(2), 4);
    try testing.expectEqual(Type.indexToBit(3), 8);
    try testing.expectEqual(Type.indexToBit(4), 16);
    try testing.expectEqual(Type.indexToBit(5), 32);
    try testing.expectEqual(Type.indexToBit(6), 64);
    try testing.expectEqual(Type.indexToBit(7), 128);
}

test "Comptime setContiguous" {
    var bmp = ComptimeBitmap(u16).init();
    // Test trying to set more entries than the bitmap has
    try testing.expectEqual(bmp.setContiguous(bmp.num_free_entries + 1, null), null);
    try testing.expectEqual(bmp.setContiguous(bmp.num_free_entries + 1, 1), null);
    // All entries should still be free
    try testing.expectEqual(bmp.num_free_entries, 16);
    try testing.expectEqual(bmp.bitmap, 0b0000000000000000);

    try testing.expectEqual(bmp.setContiguous(3, 0) orelse unreachable, 0);
    try testing.expectEqual(bmp.bitmap, 0b0000000000000111);

    // Test setting from top
    try testing.expectEqual(bmp.setContiguous(2, 14) orelse unreachable, 14);
    try testing.expectEqual(bmp.bitmap, 0b1100000000000111);

    try testing.expectEqual(bmp.setContiguous(3, 12), null);
    try testing.expectEqual(bmp.bitmap, 0b1100000000000111);

    try testing.expectEqual(bmp.setContiguous(3, null) orelse unreachable, 3);
    try testing.expectEqual(bmp.bitmap, 0b1100000000111111);

    // Test setting beyond the what is available
    try testing.expectEqual(bmp.setContiguous(9, null), null);
    try testing.expectEqual(bmp.bitmap, 0b1100000000111111);

    try testing.expectEqual(bmp.setContiguous(8, null) orelse unreachable, 6);
    try testing.expectEqual(bmp.bitmap, 0b1111111111111111);

    // No more are possible
    try testing.expectEqual(bmp.setContiguous(1, null), null);
    try testing.expectEqual(bmp.bitmap, 0b1111111111111111);

    try testing.expectEqual(bmp.setContiguous(1, 0), null);
    try testing.expectEqual(bmp.bitmap, 0b1111111111111111);
}

test "setEntry" {
    var bmp = try Bitmap(u32).init(31, std.testing.allocator);
    defer bmp.deinit();
    try testing.expectEqual(@as(u32, 31), bmp.num_free_entries);

    try bmp.setEntry(0);
    try testing.expectEqual(@as(u32, 1), bmp.bitmaps[0]);
    try testing.expectEqual(@as(u32, 30), bmp.num_free_entries);

    try bmp.setEntry(1);
    try testing.expectEqual(@as(u32, 3), bmp.bitmaps[0]);
    try testing.expectEqual(@as(u32, 29), bmp.num_free_entries);

    // Repeat setting entry 1 to make sure state doesn't change
    try bmp.setEntry(1);
    try testing.expectEqual(@as(u32, 3), bmp.bitmaps[0]);
    try testing.expectEqual(@as(u32, 29), bmp.num_free_entries);

    try testing.expectError(Bitmap(u32).BitmapError.OutOfBounds, bmp.setEntry(31));
    try testing.expectEqual(@as(u32, 29), bmp.num_free_entries);
}

test "clearEntry" {
    var bmp = try Bitmap(u32).init(32, std.testing.allocator);
    defer bmp.deinit();
    try testing.expectEqual(@as(u32, 32), bmp.num_free_entries);

    try bmp.setEntry(0);
    try testing.expectEqual(@as(u32, 31), bmp.num_free_entries);
    try bmp.setEntry(1);
    try testing.expectEqual(@as(u32, 30), bmp.num_free_entries);
    try testing.expectEqual(@as(u32, 3), bmp.bitmaps[0]);
    try bmp.clearEntry(0);
    try testing.expectEqual(@as(u32, 31), bmp.num_free_entries);
    try testing.expectEqual(@as(u32, 2), bmp.bitmaps[0]);

    // Repeat to make sure state doesn't change
    try bmp.clearEntry(0);
    try testing.expectEqual(@as(u32, 31), bmp.num_free_entries);
    try testing.expectEqual(@as(u32, 2), bmp.bitmaps[0]);

    // Try clearing an unset entry to make sure state doesn't change
    try bmp.clearEntry(2);
    try testing.expectEqual(@as(u32, 31), bmp.num_free_entries);
    try testing.expectEqual(@as(u32, 2), bmp.bitmaps[0]);

    try testing.expectError(Bitmap(u32).BitmapError.OutOfBounds, bmp.clearEntry(32));
}

test "setFirstFree multiple bitmaps" {
    var bmp = try Bitmap(u8).init(9, std.testing.allocator);
    defer bmp.deinit();

    // Allocate the first entry
    try testing.expectEqual(bmp.setFirstFree() orelse unreachable, 0);
    try testing.expectEqual(bmp.bitmaps[0], 1);

    // Allocate the second entry
    try testing.expectEqual(bmp.setFirstFree() orelse unreachable, 1);
    try testing.expectEqual(bmp.bitmaps[0], 3);

    // Allocate the entirety of the first bitmap
    var entry: u32 = 2;
    var expected: u8 = 7;
    while (entry < Bitmap(u8).ENTRIES_PER_BITMAP) {
        try testing.expectEqual(bmp.setFirstFree() orelse unreachable, entry);
        try testing.expectEqual(bmp.bitmaps[0], expected);
        if (entry + 1 < Bitmap(u8).ENTRIES_PER_BITMAP) {
            entry += 1;
            expected = expected * 2 + 1;
        } else {
            break;
        }
    }

    // Try allocating an entry in the next bitmap
    try testing.expectEqual(bmp.setFirstFree() orelse unreachable, Bitmap(u8).ENTRIES_PER_BITMAP);
    try testing.expectEqual(bmp.bitmaps[0], Bitmap(u8).BITMAP_FULL);
    try testing.expectEqual(bmp.bitmaps[1], 1);

    // We should no longer be able to allocate any entries
    try testing.expectEqual(bmp.setFirstFree(), null);
    try testing.expectEqual(bmp.bitmaps[0], Bitmap(u8).BITMAP_FULL);
    try testing.expectEqual(bmp.bitmaps[1], 1);
}

test "setFirstFree" {
    var bmp = try Bitmap(u32).init(32, std.testing.allocator);
    defer bmp.deinit();

    // Allocate the first entry
    try testing.expectEqual(bmp.setFirstFree() orelse unreachable, 0);
    try testing.expectEqual(bmp.bitmaps[0], 1);

    // Allocate the second entry
    try testing.expectEqual(bmp.setFirstFree() orelse unreachable, 1);
    try testing.expectEqual(bmp.bitmaps[0], 3);

    // Make all but the MSB occupied and try to allocate it
    bmp.bitmaps[0] = Bitmap(u32).BITMAP_FULL & ~@as(u32, 1 << (Bitmap(u32).ENTRIES_PER_BITMAP - 1));
    try testing.expectEqual(bmp.setFirstFree() orelse unreachable, Bitmap(u32).ENTRIES_PER_BITMAP - 1);
    try testing.expectEqual(bmp.bitmaps[0], Bitmap(u32).BITMAP_FULL);

    // We should no longer be able to allocate any entries
    try testing.expectEqual(bmp.setFirstFree(), null);
    try testing.expectEqual(bmp.bitmaps[0], Bitmap(u32).BITMAP_FULL);
}

test "isSet" {
    var bmp = try Bitmap(u32).init(32, std.testing.allocator);
    defer bmp.deinit();

    bmp.bitmaps[0] = 1;
    // Make sure that only the set entry is considered set
    try testing.expect(try bmp.isSet(0));
    var i: u32 = 1;
    while (i < bmp.num_entries) : (i += 1) {
        try testing.expect(!try bmp.isSet(i));
    }

    bmp.bitmaps[0] = 3;
    try testing.expect(try bmp.isSet(0));
    try testing.expect(try bmp.isSet(1));
    i = 2;
    while (i < bmp.num_entries) : (i += 1) {
        try testing.expect(!try bmp.isSet(i));
    }

    bmp.bitmaps[0] = 11;
    try testing.expect(try bmp.isSet(0));
    try testing.expect(try bmp.isSet(1));
    try testing.expect(!try bmp.isSet(2));
    try testing.expect(try bmp.isSet(3));
    i = 4;
    while (i < bmp.num_entries) : (i += 1) {
        try testing.expect(!try bmp.isSet(i));
    }

    try testing.expectError(Bitmap(u32).BitmapError.OutOfBounds, bmp.isSet(33));
}

test "indexToBit" {
    const Type = Bitmap(u8);
    var bmp = try Type.init(10, std.testing.allocator);
    defer bmp.deinit();
    try testing.expectEqual(Type.indexToBit(0), 1);
    try testing.expectEqual(Type.indexToBit(1), 2);
    try testing.expectEqual(Type.indexToBit(2), 4);
    try testing.expectEqual(Type.indexToBit(3), 8);
    try testing.expectEqual(Type.indexToBit(4), 16);
    try testing.expectEqual(Type.indexToBit(5), 32);
    try testing.expectEqual(Type.indexToBit(6), 64);
    try testing.expectEqual(Type.indexToBit(7), 128);
    try testing.expectEqual(Type.indexToBit(8), 1);
    try testing.expectEqual(Type.indexToBit(9), 2);
}

fn testCheckBitmaps(bmp: Bitmap(u4), b1: u4, b2: u4, b3: u4, b4: u4) !void {
    try testing.expectEqual(@as(u4, b1), bmp.bitmaps[0]);
    try testing.expectEqual(@as(u4, b2), bmp.bitmaps[1]);
    try testing.expectEqual(@as(u4, b3), bmp.bitmaps[2]);
    try testing.expectEqual(@as(u4, b4), bmp.bitmaps[3]);
}

test "setContiguous" {
    var bmp = try Bitmap(u4).init(16, std.testing.allocator);
    defer bmp.deinit();
    // Test trying to set more entries than the bitmap has
    try testing.expectEqual(bmp.setContiguous(bmp.num_entries + 1, null), null);
    try testing.expectEqual(bmp.setContiguous(bmp.num_entries + 1, 1), null);
    // All entries should still be free
    try testing.expectEqual(bmp.num_free_entries, bmp.num_entries);
    try testCheckBitmaps(bmp, 0, 0, 0, 0);

    try testing.expectEqual(bmp.setContiguous(3, 0) orelse unreachable, 0);
    try testCheckBitmaps(bmp, 0b0111, 0, 0, 0);

    // Test setting from top
    try testing.expectEqual(bmp.setContiguous(2, 14) orelse unreachable, 14);
    try testCheckBitmaps(bmp, 0b0111, 0, 0, 0b1100);

    try testing.expectEqual(bmp.setContiguous(3, 12), null);
    try testCheckBitmaps(bmp, 0b0111, 0, 0, 0b1100);

    try testing.expectEqual(bmp.setContiguous(3, null) orelse unreachable, 3);
    try testCheckBitmaps(bmp, 0b1111, 0b0011, 0, 0b1100);

    // Test setting beyond the what is available
    try testing.expectEqual(bmp.setContiguous(9, null), null);
    try testCheckBitmaps(bmp, 0b1111, 0b0011, 0, 0b1100);

    try testing.expectEqual(bmp.setContiguous(8, null) orelse unreachable, 6);
    try testCheckBitmaps(bmp, 0b1111, 0b1111, 0b1111, 0b1111);

    // No more are possible
    try testing.expectEqual(bmp.setContiguous(1, null), null);
    try testCheckBitmaps(bmp, 0b1111, 0b1111, 0b1111, 0b1111);

    try testing.expectEqual(bmp.setContiguous(1, 0), null);
    try testCheckBitmaps(bmp, 0b1111, 0b1111, 0b1111, 0b1111);
}
