const std = @import("std");
const log = std.log.scoped(.mbr);
const Allocator = std.mem.Allocator;
const fs_common = @import("filesystem_common.zig");
const expectError = std.testing.expectError;

/// The first sector of a drive containing 
const MBR = packed struct {
    /// The boot code
    bootstrap: [440]u8,

    /// Optional disk ID. This is unique for disks plugged into the PC.
    unique_disk_id: u32,

    /// Optional read only flag. Normally 0x000 but 0x5A5A to indicate read only.
    read_only: u16 = 0x000,

    /// The first partition structure.
    partition_1: Partition,

    /// The second partition structure.
    partition_2: Partition,

    /// The third partition structure.
    partition_3: Partition,

    /// The fourth partition structure.
    partition_4: Partition,

    /// The boot sector signature (0xAA55)
    boot_signature: u16,
};

/// The configuration of the MBR partition scheme after parsing the bytes off the disk.
const MBRConfig = struct {
    /// The array of the 4 partitions.
    partitions: [4]Partition,
};

/// The partition information structure.
pub const Partition = packed struct {
    /// If bit 7 (0x80) is set, then it is an active partition and/or bootable
    drive_attributes: u8,

    /// The CHS (cylinder, head, sector) start address (u24).
    chs_address_start1: u8,
    chs_address_start2: u8,
    chs_address_start3: u8,

    /// The type of the partition. (There is a long list online for reference.)
    partition_type: u8,

    /// The CHS (cylinder, head, sector) end address (u24).
    chs_address_end1: u8,
    chs_address_end2: u8,
    chs_address_end3: u8,

    /// The start LBA (linear block address) of the partition.
    lba_start: u32,

    /// The number of sectors of the partition.
    number_of_sectors: u32,
};

// Check the sizes of the packed structs are packed.
comptime {
    std.debug.assert(@sizeOf(MBR) == 512);
    std.debug.assert(@sizeOf(Partition) == 16);
}

/// The sector size of the drive. Unfortunately MBR assumes 512 bytes.
const SECTOR_SIZE: u32 = 512;

///
/// A partition stream type based on the MBR stream type. This stream is limited to the bounds of
/// the stream. This stream is a reader(), writer() and seekableStream(). When getting the steam
/// position, the functions will return the relative position from 0 to the length of the stream.
///
/// Arguments:
///     IN comptime ParentStreamType: type - The type of the parent stream. This will be from the
///                                          MBR stream.
///
/// Return: type
///     The partition stream type.
///
pub fn PartitionStream(comptime ParentStreamType: type) type {
    return struct {

        /// The parent stream this the partition is acting on. This would be the MBR stream.
        parent_stream: ParentStreamType,

        /// The position in the parent stream in bytes. This is bounded by start_pos and end_pos.
        pos: u64,

        /// The start position in bytes of the partition in the parent stream.
        start_pos: u64,

        /// The end position in bytes of the partition in the parent stream.
        end_pos: u64,

        /// Self reference for this stream.
        const Self = @This();

        /// Standard stream read error.
        pub const ReadError = fs_common.GetReadError(ParentStreamType);

        /// Standard stream write error.
        pub const WriteError = fs_common.GetWriteError(ParentStreamType);

        /// Standard stream seek error.
        pub const SeekError = fs_common.GetSeekError(ParentStreamType) || error{PastEnd};

        /// Standard stream get stream position error.
        pub const GetSeekPosError = fs_common.GetGetSeekPosError(ParentStreamType);

        /// Standard reader type.
        pub const Reader = std.io.Reader(*Self, ReadError, read);

        /// Standard writer type.
        pub const Writer = std.io.Writer(*Self, WriteError, write);

        /// Standard seekable stream type.
        pub const SeekableStream = std.io.SeekableStream(
            *Self,
            SeekError,
            GetSeekPosError,
            seekTo,
            seekBy,
            getPos,
            getEndPos,
        );

        /// Standard read function.
        fn read(self: *Self, dest: []u8) ReadError!usize {
            return self.parent_stream.reader().read(dest);
        }

        /// Standard write function.
        fn write(self: *Self, bytes: []const u8) WriteError!usize {
            return self.parent_stream.writer().write(bytes);
        }

        /// Standard seekTo function.
        fn seekTo(self: *Self, new_pos: u64) SeekError!void {
            const relative_new_pos = new_pos + self.start_pos;
            if (relative_new_pos > self.end_pos) {
                return SeekError.PastEnd;
            }
            try self.parent_stream.seekableStream().seekTo(relative_new_pos);
        }

        /// Standard seekBy function.
        fn seekBy(self: *Self, amount: i64) SeekError!void {
            if (amount < 0) {
                // Guaranteed to fit as going i64 => u64
                const abs_amount = std.math.absCast(amount);
                if (abs_amount > self.start_pos) {
                    try self.parent_stream.seekableStream().seekBy(0);
                    self.pos = self.start_pos;
                } else {
                    try self.parent_stream.seekableStream().seekBy(amount);
                    self.pos -= abs_amount;
                }
            } else {
                if (amount > self.end_pos - self.pos) {
                    try self.parent_stream.seekableStream().seekBy(@intCast(i64, self.end_pos - self.pos));
                    self.pos = self.end_pos;
                } else {
                    try self.parent_stream.seekableStream().seekBy(amount);
                    self.pos += @intCast(u64, amount);
                }
            }
        }

        /// Standard getEndPos function.
        fn getEndPos(self: *Self) GetSeekPosError!u64 {
            return self.end_pos - self.start_pos;
        }

        /// Standard getPos function.
        fn getPos(self: *Self) GetSeekPosError!u64 {
            return self.pos - self.start_pos;
        }

        /// Standard reader function.
        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }

        /// Standard writer function.
        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        /// Standard seekableStream function.
        pub fn seekableStream(self: *Self) SeekableStream {
            return .{ .context = self };
        }
    };
}

///
/// The MBR partition scheme type.
///
/// Arguments:
///     IN comptime StreamType: type - The underlying stream type the MBR scheme sits on. This can
///                                    be a disk driver stream or a fixed buffer stream.
///
/// Return: type
///     The MBR partition type.
///
pub fn MBRPartition(comptime StreamType: type) type {
    return struct {
        /// The parsed configuration of the MBR partition scheme. This will be the caches
        /// information from the boot sector.
        mbr_config: MBRConfig,

        /// The underlying stream
        stream: StreamType,

        /// The error set for the MBR partition table.
        const Error = error{
            /// If the boot sector doesn't have the 0xAA55 signature as the last word. This would
            /// indicate this is not a valid boot sector.
            BadMBRMagic,

            /// When reading from the stream, if the read count is less than the expected read,
            /// then there is a bad read.
            BadRead,

            /// The partition isn't active.
            NotActivePartition,

            /// The partition type is unknown.
            UnknownPartitionType,

            /// The drive is set to read only.
            ReadOnly,
        };

        /// The internal self struct
        const MBRSelf = @This();

        ///
        /// Get a bounded stream that represents the partition given.
        ///
        /// Arguments:
        ///     IN self: *MBRSelf    - The MBR partition structure.
        ///     IN partition_num: u2 - The partition number to get the stream for.
        ///
        /// Return: PartitionStream(StreamType)
        ///     The partition stream.
        ///
        /// Error: Error
        ///     Error.NotActivePartition - The partition requested is not active.
        ///
        pub fn getPartitionStream(self: *MBRSelf, partition_num: u2) Error!PartitionStream(StreamType) {
            if (self.mbr_config.partitions[partition_num].drive_attributes & 0x80 != 0x80) {
                return Error.NotActivePartition;
            }

            const part_info = self.mbr_config.partitions[partition_num];
            if (part_info.partition_type == 0) {
                return Error.UnknownPartitionType;
            }

            return PartitionStream(StreamType){
                .parent_stream = self.stream,
                .pos = part_info.lba_start * SECTOR_SIZE,
                .start_pos = part_info.lba_start * SECTOR_SIZE,
                .end_pos = (part_info.lba_start + part_info.number_of_sectors) * SECTOR_SIZE,
            };
        }

        ///
        /// Initialise a MBR partition scheme from a stream that represents a disk. This will
        /// will assume the MBR partition boot sector is not set as read only.
        ///
        /// Arguments:
        ///     IN allocator: *Allocator - The allocator used for creating a buffer for the boot sector.
        ///     IN stream: StreamType    - The stream to initialise from. This will need to represent a disk.
        ///
        /// Return: MBRSelf
        ///     The MBR partition scheme that wraps the stream.
        ///
        /// Error: Allocator.Error || Error || StreamType.SeekError || StreamType.ReadError
        ///     Allocator.Error      - Error allocating 512 byte buffer for the boot sector.
        ///     Error                - Error parsing the boot sector.
        ///     StreamType.SeekError - Error reading from the stream.
        ///     StreamType.ReadError - Error seeking the stream.
        ///
        pub fn init(allocator: *Allocator, stream: StreamType) (Allocator.Error || Error || fs_common.GetSeekError(StreamType) || fs_common.GetReadError(StreamType))!MBRSelf {
            log.debug("Init\n", .{});
            defer log.debug("Done\n", .{});

            var boot_sector_raw = try allocator.alloc(u8, 512);
            defer allocator.free(boot_sector_raw);

            const seek_stream = stream.seekableStream();
            const read_stream = stream.reader();

            try seek_stream.seekTo(0);
            const read_count = try read_stream.readAll(boot_sector_raw[0..]);
            if (read_count != 512) {
                return Error.BadRead;
            }

            // Check the boot signature
            if (boot_sector_raw[510] != 0x55 or boot_sector_raw[511] != 0xAA) {
                return Error.BadMBRMagic;
            }

            const mbr_parsed = std.mem.bytesAsValue(MBR, boot_sector_raw[0..512]);

            // Check if the dick is read only
            if (mbr_parsed.read_only == 0x5A5A) {
                return Error.ReadOnly;
            }

            return MBRSelf{
                .mbr_config = .{
                    .partitions = [4]Partition{ mbr_parsed.partition_1, mbr_parsed.partition_2, mbr_parsed.partition_3, mbr_parsed.partition_4 },
                },
                .stream = stream,
            };
        }
    };
}

test "MBRPartition.getPartitionStream - not active drive attribute" {
    const allocator = std.testing.allocator;
    const stream = &std.io.fixedBufferStream(fs_common.filesystem_bootsector_boot_code[0..]);
    var mbr = try MBRPartition(@TypeOf(stream)).init(allocator, stream);
    expectError(error.NotActivePartition, mbr.getPartitionStream(0));
    expectError(error.NotActivePartition, mbr.getPartitionStream(1));
    expectError(error.NotActivePartition, mbr.getPartitionStream(2));
    expectError(error.NotActivePartition, mbr.getPartitionStream(3));
}

test "MBRPartition.getPartitionStream - no partition type" {
    const allocator = std.testing.allocator;

    const size = 1024 * 1024 * 10;
    var buffer = try allocator.alloc(u8, size);
    defer allocator.free(buffer);

    const stream = &std.io.fixedBufferStream(buffer);
    try @import("makefs.zig").MBRPartition.make(.{ .partition_options = .{ 100, null, null, null }, .image_size = size }, stream);

    var mbr = try MBRPartition(@TypeOf(stream)).init(allocator, stream);

    mbr.mbr_config.partitions[0].partition_type = 0x00;

    expectError(error.UnknownPartitionType, mbr.getPartitionStream(0));
}

test "MBRPartition.getPartitionStream - success" {
    const allocator = std.testing.allocator;

    const size = 1024 * 1024 * 10;
    var buffer = try allocator.alloc(u8, size);
    defer allocator.free(buffer);

    const stream = &std.io.fixedBufferStream(buffer);
    try @import("makefs.zig").MBRPartition.make(.{ .partition_options = .{ 100, null, null, null }, .image_size = size }, stream);

    var mbr = try MBRPartition(@TypeOf(stream)).init(allocator, stream);
    const ps = try mbr.getPartitionStream(0);
    expectError(error.NotActivePartition, mbr.getPartitionStream(1));
    expectError(error.NotActivePartition, mbr.getPartitionStream(2));
    expectError(error.NotActivePartition, mbr.getPartitionStream(3));
}

test "MBRPartition.init - failed alloc" {
    const allocator = std.testing.failing_allocator;
    const stream = &std.io.fixedBufferStream(&[_]u8{});
    expectError(error.OutOfMemory, MBRPartition(@TypeOf(stream)).init(allocator, stream));
}

test "MBRPartition.init - read error" {
    const allocator = std.testing.allocator;
    const stream = &std.io.fixedBufferStream(&[_]u8{});
    expectError(error.BadRead, MBRPartition(@TypeOf(stream)).init(allocator, stream));
}

test "MBRPartition.init - bad boot magic" {
    var cp_bootcode = fs_common.filesystem_bootsector_boot_code;
    cp_bootcode[510] = 0x00;
    cp_bootcode[511] = 0x00;
    const allocator = std.testing.allocator;
    const stream = &std.io.fixedBufferStream(cp_bootcode[0..]);
    expectError(error.BadMBRMagic, MBRPartition(@TypeOf(stream)).init(allocator, stream));
}

test "MBRPartition.init - read only disk" {
    var cp_bootcode = fs_common.filesystem_bootsector_boot_code;
    cp_bootcode[444] = 0x5A;
    cp_bootcode[445] = 0x5A;
    const allocator = std.testing.allocator;
    const stream = &std.io.fixedBufferStream(cp_bootcode[0..]);
    expectError(error.ReadOnly, MBRPartition(@TypeOf(stream)).init(allocator, stream));
}

test "MBRPartition.init - success" {
    const allocator = std.testing.allocator;
    const stream = &std.io.fixedBufferStream(fs_common.filesystem_bootsector_boot_code[0..]);
    const mbr = try MBRPartition(@TypeOf(stream)).init(allocator, stream);
}
