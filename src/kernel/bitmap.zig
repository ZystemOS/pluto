const std = @import("std");
const builtin = @import("builtin");
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
        pub const IndexType = std.meta.IntType(.unsigned, std.math.log2(std.math.ceilPowerOfTwo(u16, std.meta.bitCount(BitmapType)) catch unreachable));

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
                self.bitmap |= self.indexToBit(idx);
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
                self.bitmap &= ~self.indexToBit(idx);
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
        fn indexToBit(self: *const Self, idx: IndexType) BitmapType {
            return @as(BitmapType, 1) << idx;
        }

        ///
        /// Find a number of contiguous free entries and set them.
        ///
        /// Arguments:
        ///     IN/OUT self: *Self - The bitmap to modify.
        ///     IN num: usize - The number of entries to set.
        ///
        /// Return: ?IndexType
        ///     The first entry set or null if there weren't enough contiguous entries.
        ///
        pub fn setContiguous(self: *Self, num: usize) ?IndexType {
            if (num > self.num_free_entries) {
                return null;
            }

            var count: usize = 0;
            var start: ?IndexType = null;

            var bit: IndexType = 0;
            while (true) {
                const entry = bit;
                if (entry >= NUM_ENTRIES) {
                    return null;
                }
                if ((self.bitmap & @as(BitmapType, 1) << bit) != 0) {
                    // This is a one so clear the progress
                    count = 0;
                    start = null;
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
            return (self.bitmap & self.indexToBit(idx)) != 0;
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
        pub const IndexType = std.meta.IntType(.unsigned, std.math.log2(std.math.ceilPowerOfTwo(u16, std.meta.bitCount(BitmapType)) catch unreachable));

        num_bitmaps: usize,
        num_entries: usize,
        bitmaps: []BitmapType,
        num_free_entries: usize,
        allocator: *std.mem.Allocator,

        ///
        /// Create an instance of this bitmap type.
        ///
        /// Arguments:
        ///     IN num_entries: usize - The number of entries that the bitmap created will have.
        ///         The number of BitmapType required to store this many entries will be allocated and each will be zeroed.
        ///     IN allocator: *std.mem.Allocator - The allocator to use when allocating the BitmapTypes required.
        ///
        /// Return: Self.
        ///     The bitmap instance.
        ///
        /// Error: std.mem.Allocator.Error
        ///     OutOfMemory: There isn't enough memory available to allocate the required number of BitmapType.
        ///
        pub fn init(num_entries: usize, allocator: *std.mem.Allocator) !Self {
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
                const bit = self.indexToBit(idx);
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
                const bit = self.indexToBit(idx);
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
        fn indexToBit(self: *const Self, idx: usize) BitmapType {
            return @as(BitmapType, 1) << @intCast(IndexType, idx % ENTRIES_PER_BITMAP);
        }

        ///
        /// Find a number of contiguous free entries and set them.
        ///
        /// Arguments:
        ///     IN/OUT self: *Self - The bitmap to modify.
        ///     IN num: usize - The number of entries to set.
        ///
        /// Return: ?usize
        ///     The first entry set or null if there weren't enough contiguous entries.
        ///
        pub fn setContiguous(self: *Self, num: usize) ?usize {
            if (num > self.num_free_entries) {
                return null;
            }

            var count: usize = 0;
            var start: ?usize = null;
            for (self.bitmaps) |bmp, i| {
                var bit: IndexType = 0;
                while (true) {
                    const entry = bit + i * ENTRIES_PER_BITMAP;
                    if (entry >= self.num_entries) {
                        return null;
                    }
                    if ((bmp & @as(BitmapType, 1) << bit) != 0) {
                        // This is a one so clear the progress
                        count = 0;
                        start = null;
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
                    var i: usize = 0;
                    while (i < num) : (i += 1) {
                        // Can't fail as the entry was found to be free
                        self.setEntry(start_entry + i) catch unreachable;
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
            return (self.bitmaps[idx / ENTRIES_PER_BITMAP] & self.indexToBit(idx)) != 0;
        }
    };
}

test "Comptime setEntry" {
    var bmp = ComptimeBitmap(u32).init();
    testing.expectEqual(@as(u32, 32), bmp.num_free_entries);

    bmp.setEntry(0);
    testing.expectEqual(@as(u32, 1), bmp.bitmap);
    testing.expectEqual(@as(u32, 31), bmp.num_free_entries);

    bmp.setEntry(1);
    testing.expectEqual(@as(u32, 3), bmp.bitmap);
    testing.expectEqual(@as(u32, 30), bmp.num_free_entries);

    // Repeat setting entry 1 to make sure state doesn't change
    bmp.setEntry(1);
    testing.expectEqual(@as(u32, 3), bmp.bitmap);
    testing.expectEqual(@as(u32, 30), bmp.num_free_entries);
}

test "Comptime clearEntry" {
    var bmp = ComptimeBitmap(u32).init();
    testing.expectEqual(@as(u32, 32), bmp.num_free_entries);

    bmp.setEntry(0);
    testing.expectEqual(@as(u32, 31), bmp.num_free_entries);
    bmp.setEntry(1);
    testing.expectEqual(@as(u32, 30), bmp.num_free_entries);
    testing.expectEqual(@as(u32, 3), bmp.bitmap);
    bmp.clearEntry(0);
    testing.expectEqual(@as(u32, 31), bmp.num_free_entries);
    testing.expectEqual(@as(u32, 2), bmp.bitmap);

    // Repeat to make sure state doesn't change
    bmp.clearEntry(0);
    testing.expectEqual(@as(u32, 31), bmp.num_free_entries);
    testing.expectEqual(@as(u32, 2), bmp.bitmap);

    // Try clearing an unset entry to make sure state doesn't change
    bmp.clearEntry(2);
    testing.expectEqual(@as(u32, 31), bmp.num_free_entries);
    testing.expectEqual(@as(u32, 2), bmp.bitmap);
}

test "Comptime setFirstFree" {
    var bmp = ComptimeBitmap(u32).init();

    // Allocate the first entry
    testing.expectEqual(bmp.setFirstFree() orelse unreachable, 0);
    testing.expectEqual(bmp.bitmap, 1);

    // Allocate the second entry
    testing.expectEqual(bmp.setFirstFree() orelse unreachable, 1);
    testing.expectEqual(bmp.bitmap, 3);

    // Make all but the MSB occupied and try to allocate it
    bmp.bitmap = ComptimeBitmap(u32).BITMAP_FULL & ~@as(u32, 1 << (ComptimeBitmap(u32).NUM_ENTRIES - 1));
    bmp.num_free_entries = 1;
    testing.expectEqual(bmp.setFirstFree() orelse unreachable, ComptimeBitmap(u32).NUM_ENTRIES - 1);
    testing.expectEqual(bmp.bitmap, ComptimeBitmap(u32).BITMAP_FULL);

    // We should no longer be able to allocate any entries
    testing.expectEqual(bmp.setFirstFree(), null);
    testing.expectEqual(bmp.bitmap, ComptimeBitmap(u32).BITMAP_FULL);
}

test "Comptime isSet" {
    var bmp = ComptimeBitmap(u32).init();

    bmp.bitmap = 1;
    // Make sure that only the set entry is considered set
    testing.expect(bmp.isSet(0));
    var i: usize = 1;
    while (i < ComptimeBitmap(u32).NUM_ENTRIES) : (i += 1) {
        testing.expect(!bmp.isSet(@truncate(ComptimeBitmap(u32).IndexType, i)));
    }

    bmp.bitmap = 3;
    testing.expect(bmp.isSet(0));
    testing.expect(bmp.isSet(1));
    i = 2;
    while (i < ComptimeBitmap(u32).NUM_ENTRIES) : (i += 1) {
        testing.expect(!bmp.isSet(@truncate(ComptimeBitmap(u32).IndexType, i)));
    }

    bmp.bitmap = 11;
    testing.expect(bmp.isSet(0));
    testing.expect(bmp.isSet(1));
    testing.expect(!bmp.isSet(2));
    testing.expect(bmp.isSet(3));
    i = 4;
    while (i < ComptimeBitmap(u32).NUM_ENTRIES) : (i += 1) {
        testing.expect(!bmp.isSet(@truncate(ComptimeBitmap(u32).IndexType, i)));
    }
}

test "Comptime indexToBit" {
    var bmp = ComptimeBitmap(u8).init();
    testing.expectEqual(bmp.indexToBit(0), 1);
    testing.expectEqual(bmp.indexToBit(1), 2);
    testing.expectEqual(bmp.indexToBit(2), 4);
    testing.expectEqual(bmp.indexToBit(3), 8);
    testing.expectEqual(bmp.indexToBit(4), 16);
    testing.expectEqual(bmp.indexToBit(5), 32);
    testing.expectEqual(bmp.indexToBit(6), 64);
    testing.expectEqual(bmp.indexToBit(7), 128);
}

test "Comptime setContiguous" {
    var bmp = ComptimeBitmap(u15).init();
    // Test trying to set more entries than the bitmap has
    testing.expectEqual(bmp.setContiguous(ComptimeBitmap(u15).NUM_ENTRIES + 1), null);
    // All entries should still be free
    testing.expectEqual(bmp.num_free_entries, ComptimeBitmap(u15).NUM_ENTRIES);
    testing.expectEqual(bmp.setContiguous(3) orelse unreachable, 0);
    testing.expectEqual(bmp.setContiguous(4) orelse unreachable, 3);
    // 0b0000.0000.0111.1111
    bmp.bitmap |= 0x200;
    // 0b0000.0010.0111.1111
    testing.expectEqual(bmp.setContiguous(3) orelse unreachable, 10);
    // 0b0001.1110.0111.1111
    testing.expectEqual(bmp.setContiguous(5), null);
    testing.expectEqual(bmp.setContiguous(2), 7);
    // 0b001.1111.1111.1111
    // Test trying to set beyond the end of the bitmaps
    testing.expectEqual(bmp.setContiguous(3), null);
    testing.expectEqual(bmp.setContiguous(2), 13);
}

test "setEntry" {
    var bmp = try Bitmap(u32).init(31, std.testing.allocator);
    defer bmp.deinit();
    testing.expectEqual(@as(u32, 31), bmp.num_free_entries);

    try bmp.setEntry(0);
    testing.expectEqual(@as(u32, 1), bmp.bitmaps[0]);
    testing.expectEqual(@as(u32, 30), bmp.num_free_entries);

    try bmp.setEntry(1);
    testing.expectEqual(@as(u32, 3), bmp.bitmaps[0]);
    testing.expectEqual(@as(u32, 29), bmp.num_free_entries);

    // Repeat setting entry 1 to make sure state doesn't change
    try bmp.setEntry(1);
    testing.expectEqual(@as(u32, 3), bmp.bitmaps[0]);
    testing.expectEqual(@as(u32, 29), bmp.num_free_entries);

    testing.expectError(Bitmap(u32).BitmapError.OutOfBounds, bmp.setEntry(31));
    testing.expectEqual(@as(u32, 29), bmp.num_free_entries);
}

test "clearEntry" {
    var bmp = try Bitmap(u32).init(32, std.testing.allocator);
    defer bmp.deinit();
    testing.expectEqual(@as(u32, 32), bmp.num_free_entries);

    try bmp.setEntry(0);
    testing.expectEqual(@as(u32, 31), bmp.num_free_entries);
    try bmp.setEntry(1);
    testing.expectEqual(@as(u32, 30), bmp.num_free_entries);
    testing.expectEqual(@as(u32, 3), bmp.bitmaps[0]);
    try bmp.clearEntry(0);
    testing.expectEqual(@as(u32, 31), bmp.num_free_entries);
    testing.expectEqual(@as(u32, 2), bmp.bitmaps[0]);

    // Repeat to make sure state doesn't change
    try bmp.clearEntry(0);
    testing.expectEqual(@as(u32, 31), bmp.num_free_entries);
    testing.expectEqual(@as(u32, 2), bmp.bitmaps[0]);

    // Try clearing an unset entry to make sure state doesn't change
    try bmp.clearEntry(2);
    testing.expectEqual(@as(u32, 31), bmp.num_free_entries);
    testing.expectEqual(@as(u32, 2), bmp.bitmaps[0]);

    testing.expectError(Bitmap(u32).BitmapError.OutOfBounds, bmp.clearEntry(32));
}

test "setFirstFree multiple bitmaps" {
    var bmp = try Bitmap(u8).init(9, std.testing.allocator);
    defer bmp.deinit();

    // Allocate the first entry
    testing.expectEqual(bmp.setFirstFree() orelse unreachable, 0);
    testing.expectEqual(bmp.bitmaps[0], 1);

    // Allocate the second entry
    testing.expectEqual(bmp.setFirstFree() orelse unreachable, 1);
    testing.expectEqual(bmp.bitmaps[0], 3);

    // Allocate the entirety of the first bitmap
    var entry: u32 = 2;
    var expected: u8 = 7;
    while (entry < Bitmap(u8).ENTRIES_PER_BITMAP) {
        testing.expectEqual(bmp.setFirstFree() orelse unreachable, entry);
        testing.expectEqual(bmp.bitmaps[0], expected);
        if (entry + 1 < Bitmap(u8).ENTRIES_PER_BITMAP) {
            entry += 1;
            expected = expected * 2 + 1;
        } else {
            break;
        }
    }

    // Try allocating an entry in the next bitmap
    testing.expectEqual(bmp.setFirstFree() orelse unreachable, Bitmap(u8).ENTRIES_PER_BITMAP);
    testing.expectEqual(bmp.bitmaps[0], Bitmap(u8).BITMAP_FULL);
    testing.expectEqual(bmp.bitmaps[1], 1);

    // We should no longer be able to allocate any entries
    testing.expectEqual(bmp.setFirstFree(), null);
    testing.expectEqual(bmp.bitmaps[0], Bitmap(u8).BITMAP_FULL);
    testing.expectEqual(bmp.bitmaps[1], 1);
}

test "setFirstFree" {
    var bmp = try Bitmap(u32).init(32, std.testing.allocator);
    defer bmp.deinit();

    // Allocate the first entry
    testing.expectEqual(bmp.setFirstFree() orelse unreachable, 0);
    testing.expectEqual(bmp.bitmaps[0], 1);

    // Allocate the second entry
    testing.expectEqual(bmp.setFirstFree() orelse unreachable, 1);
    testing.expectEqual(bmp.bitmaps[0], 3);

    // Make all but the MSB occupied and try to allocate it
    bmp.bitmaps[0] = Bitmap(u32).BITMAP_FULL & ~@as(u32, 1 << (Bitmap(u32).ENTRIES_PER_BITMAP - 1));
    testing.expectEqual(bmp.setFirstFree() orelse unreachable, Bitmap(u32).ENTRIES_PER_BITMAP - 1);
    testing.expectEqual(bmp.bitmaps[0], Bitmap(u32).BITMAP_FULL);

    // We should no longer be able to allocate any entries
    testing.expectEqual(bmp.setFirstFree(), null);
    testing.expectEqual(bmp.bitmaps[0], Bitmap(u32).BITMAP_FULL);
}

test "isSet" {
    var bmp = try Bitmap(u32).init(32, std.testing.allocator);
    defer bmp.deinit();

    bmp.bitmaps[0] = 1;
    // Make sure that only the set entry is considered set
    testing.expect(try bmp.isSet(0));
    var i: u32 = 1;
    while (i < bmp.num_entries) : (i += 1) {
        testing.expect(!try bmp.isSet(i));
    }

    bmp.bitmaps[0] = 3;
    testing.expect(try bmp.isSet(0));
    testing.expect(try bmp.isSet(1));
    i = 2;
    while (i < bmp.num_entries) : (i += 1) {
        testing.expect(!try bmp.isSet(i));
    }

    bmp.bitmaps[0] = 11;
    testing.expect(try bmp.isSet(0));
    testing.expect(try bmp.isSet(1));
    testing.expect(!try bmp.isSet(2));
    testing.expect(try bmp.isSet(3));
    i = 4;
    while (i < bmp.num_entries) : (i += 1) {
        testing.expect(!try bmp.isSet(i));
    }

    testing.expectError(Bitmap(u32).BitmapError.OutOfBounds, bmp.isSet(33));
}

test "indexToBit" {
    var bmp = try Bitmap(u8).init(10, std.testing.allocator);
    defer bmp.deinit();
    testing.expectEqual(bmp.indexToBit(0), 1);
    testing.expectEqual(bmp.indexToBit(1), 2);
    testing.expectEqual(bmp.indexToBit(2), 4);
    testing.expectEqual(bmp.indexToBit(3), 8);
    testing.expectEqual(bmp.indexToBit(4), 16);
    testing.expectEqual(bmp.indexToBit(5), 32);
    testing.expectEqual(bmp.indexToBit(6), 64);
    testing.expectEqual(bmp.indexToBit(7), 128);
    testing.expectEqual(bmp.indexToBit(8), 1);
    testing.expectEqual(bmp.indexToBit(9), 2);
}

test "setContiguous" {
    var bmp = try Bitmap(u4).init(15, std.testing.allocator);
    defer bmp.deinit();
    // Test trying to set more entries than the bitmap has
    testing.expectEqual(bmp.setContiguous(bmp.num_entries + 1), null);
    // All entries should still be free
    testing.expectEqual(bmp.num_free_entries, bmp.num_entries);

    testing.expectEqual(bmp.setContiguous(3) orelse unreachable, 0);
    testing.expectEqual(bmp.setContiguous(4) orelse unreachable, 3);
    // 0b0000.0000.0111.1111
    bmp.bitmaps[2] |= 2;
    // 0b0000.0010.0111.1111
    testing.expectEqual(bmp.setContiguous(3) orelse unreachable, 10);
    // 0b0001.1110.0111.1111
    testing.expectEqual(bmp.setContiguous(5), null);
    testing.expectEqual(bmp.setContiguous(2), 7);
    // 0b001.1111.1111.1111
    // Test trying to set beyond the end of the bitmaps
    testing.expectEqual(bmp.setContiguous(3), null);
    testing.expectEqual(bmp.setContiguous(2), 13);
}
