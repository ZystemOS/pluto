const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

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
        pub const ENTRIES_PER_BITMAP: u32 = std.meta.bitCount(BitmapType);

        /// The value that a full bitmap will have
        pub const BITMAP_FULL = std.math.maxInt(BitmapType);

        /// The type of an index into a bitmap entry. The smallest integer needed to represent all bit positions in the bitmap entry type
        pub const IndexType = @Type(builtin.TypeInfo{ .Int = builtin.TypeInfo.Int{ .is_signed = false, .bits = std.math.log2(std.meta.bitCount(BitmapType)) } });

        num_bitmaps: u32,
        num_entries: u32,
        bitmaps: []BitmapType,
        num_free_entries: u32,

        ///
        /// Create an instance of this bitmap type.
        ///
        /// Arguments:
        ///     IN num_entries: u32 - The number of entries that the bitmap created will have.
        ///         The number of BitmapType required to store this many entries will be allocated and each will be zeroed.
        ///     IN allocator: *std.mem.Allocator - The allocator to use when allocating the BitmapTypes required.
        ///
        /// Return: Self.
        ///     The bitmap instance.
        ///
        /// Error: std.mem.Allocator.Error
        ///     OutOfMemory: There isn't enough memory available to allocate the required number of BitmapType.
        ///
        pub fn init(num_entries: u32, allocator: *std.mem.Allocator) !Self {
            const num = @floatToInt(u32, @ceil(@intToFloat(f32, num_entries) / @intToFloat(f32, ENTRIES_PER_BITMAP)));
            const self = Self{
                .num_bitmaps = num,
                .num_entries = num_entries,
                .bitmaps = try allocator.alloc(BitmapType, num),
                .num_free_entries = num_entries,
            };
            for (self.bitmaps) |*bmp| {
                bmp.* = 0;
            }
            return self;
        }

        ///
        /// Set an entry within a bitmap as occupied.
        ///
        /// Arguments:
        ///     INOUT self: *Self - The bitmap to modify.
        ///     IN idx: BitmapIndex - The index within the bitmap to set.
        ///
        /// Error: BitmapError.
        ///     OutOfBounds: The index given is out of bounds.
        ///
        pub fn setEntry(self: *Self, idx: u32) BitmapError!void {
            if (idx >= self.num_entries) return BitmapError.OutOfBounds;
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
        ///     INOUT self: *Self - The bitmap to modify.
        ///     IN idx: BitmapIndex - The index within the bitmap to clear.
        ///
        /// Error: BitmapError.
        ///     OutOfBounds: The index given is out of bounds.
        ///
        pub fn clearEntry(self: *Self, idx: u32) BitmapError!void {
            if (idx >= self.num_entries) return BitmapError.OutOfBounds;
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
        ///     IN self: *Self - The bitmap to use.
        ///     IN idx: u32 - The index into all of the bitmap's entries.
        ///
        /// Return: BitmapType.
        ///     The bit corresponding to that index but within a single BitmapType.
        ///
        fn indexToBit(self: *Self, idx: u32) BitmapType {
            return @as(BitmapType, 1) << @intCast(IndexType, idx % ENTRIES_PER_BITMAP);
        }

        ///
        /// Set the first free entry within the bitmaps as occupied.
        ///
        /// Return: ?u32.
        ///     The index within all bitmaps that was set or null if there wasn't one free.
        ///     0 .. ENTRIES_PER_BITMAP - 1 if in the first bitmap, ENTRIES_PER_BITMAP .. ENTRIES_PER_BITMAP * 2 - 1 if in the second etc.
        ///
        pub fn setFirstFree(self: *Self) ?u32 {
            if (self.num_free_entries == 0) return null;
            for (self.bitmaps) |*bmp, i| {
                if (bmp.* == BITMAP_FULL)
                    continue;
                const bit = @truncate(IndexType, @ctz(BitmapType, ~bmp.*));
                const idx = bit + @intCast(u32, i) * ENTRIES_PER_BITMAP;
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
        ///     IN self: *Bitmap - The bitmap to check.
        ///     IN idx: u32 - The entry to check.
        ///
        /// Return: bool.
        ///     True if the entry is set, else false.
        ///
        /// Error: BitmapError.
        ///     OutOfBounds: The index given is out of bounds.
        ///
        pub fn isSet(self: *Self, idx: u32) BitmapError!bool {
            if (idx >= self.num_entries) return BitmapError.OutOfBounds;
            return (self.bitmaps[idx / ENTRIES_PER_BITMAP] & self.indexToBit(idx)) != 0;
        }
    };
}

test "setEntry" {
    var bmp = try Bitmap(u32).init(31, std.heap.page_allocator);
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
    var bmp = try Bitmap(u32).init(32, std.heap.page_allocator);
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
    var bmp = try Bitmap(u8).init(9, std.heap.page_allocator);

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
    var bmp = try Bitmap(u32).init(32, std.heap.page_allocator);

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
    var bmp = try Bitmap(u32).init(32, std.heap.page_allocator);

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
    var bmp = try Bitmap(u8).init(10, std.heap.page_allocator);
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
