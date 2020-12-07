const std = @import("std");
const builtin = @import("builtin");
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expect = std.testing.expect;
const log = std.log.scoped(.fat32);
const AutoHashMap = std.AutoHashMap;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const vfs = @import("vfs.zig");
const mem = @import("../mem.zig");
const CodePage = @import("../code_page/code_page.zig").CodePage;
const mkfat32 = @import("../../../mkfat32.zig");

/// The boot record for FAT32. This is use for parsing the initial boot sector to extract the
/// relevant information for todays FAT32.
const BootRecord = struct {
    /// The jump bytes that begin the boot code. This will jump over the FAT32 header.
    jmp: [3]u8,

    /// The OEM name. This is a 8 character string padded by spaces.
    oem: [8]u8,

    /// The number of bytes per sector.
    bytes_per_sector: u16,

    /// The number of sectors per cluster.
    sectors_per_cluster: u8,

    /// The number of reserved sectors at the beginning of the image. This is where the fat
    /// header, FSInfo and FAT is stored.
    reserved_sectors: u16,

    /// The number of FAT's.
    fat_count: u8,

    /// The size in bytes of the root directory. This is only used by FAT12 and FAT16, so is
    /// always 0 for FAT32.
    root_directory_size: u16,

    /// The total number of sectors. This is only used for FAT12 and FAT16, so is always 0 for
    /// FAT32.
    total_sectors_12_16: u16,

    /// The media type. This is used to identify the type of media.
    media_descriptor_type: u8,

    /// The total number of sectors of the FAT. This is only used for FAT12 and FAT16, so
    /// always 0 for FAT32.
    sectors_per_fat_12_16: u16,

    /// The number of sectors per track.
    sectors_per_track: u16,

    /// The number of heads.
    head_count: u16,

    /// The number of hidden sectors.
    hidden_sectors: u32,

    /// The total number of sectors for FAT32.
    total_sectors: u32,

    /// The number of sectors the FAT takes up for FAT32.
    sectors_per_fat: u32,

    /// Mirror flags.
    mirror_flags: u16,

    /// The version.
    version_number: u16,

    /// The start cluster of the root directory.
    root_directory_cluster: u32,

    /// The sector where is the FS information sector is located. A value of 0x0000 or 0xFFFF
    /// indicates that there isn't a FSInfo structure.
    fsinfo_sector: u16,

    /// The sector for the backup boot record where the first 3 sectors are copied. A value of
    /// 0x000 or 0xFFFF indicate there is no backup.
    backup_boot_sector: u16,

    /// Reserved. All zero.
    reserved0: [12]u8,

    /// The physical drive number.
    drive_number: u8,

    /// Reserved. All zero.
    reserved1: u8,

    /// The extended boot signature.
    signature: u8,

    /// The serial number of the FAT image at format. This is a function of the current
    /// timestamp of creation.
    serial_number: u32,

    /// The partitioned volume label. This is a 11 character string padded by spaces.
    volume_label: [11]u8,

    /// The file system type. This is a 8 character string padded by spaces. For FAT32, this is
    /// 'FAT32   '
    filesystem_type: [8]u8,

    // We are ignoring the boot code as we don't need to parse this.
};

/// The FSInfo block. This is used for parsing the initial sector to extract the relevant
/// information: number_free_clusters and next_free_cluster.
const FSInfo = struct {
    /// The lead signature: 0x41615252
    lead_signature: u32,

    /// Reserved bytes
    reserved0: [480]u8,

    /// The middle or struct signature: 0x61417272
    struct_signature: u32,

    /// The number of free clusters in the image
    number_free_clusters: u32,

    /// The next available free cluster that can be allocated for writing to.
    next_free_cluster: u32,

    /// Reserved bytes
    reserved1: [12]u8,

    /// The tail signature: 0xAA550000
    tail_signature: u32,
};

/// A long name entry. This is part of a fill long name block, but each entry is 32 bytes long.
/// Entries are ordered backwards. The file name is encoded as a wide UTF16 characters.
const LongName = struct {
    /// The order in the long entry sequence. If OR'ed with 0x40, then this is the last entry.
    order: u8,

    /// The first 5 wide characters in the block.
    first: [5]u16,

    /// The attributes from the short name block so will always be 0x0F as this identifies as a
    /// long entry.
    attribute: u8 = 0x0F,

    /// Always 0x00, other values are reserved. 0x00 Means this is a sub-component of the long name
    /// entry, i.e. there are multiple blocks that make up the long entry.
    long_entry_type: u8 = 0x00,

    /// The check sum of the 11 character short file name that goes along with this long name.
    check_sum: u8,

    /// The next 6 wide characters in the block.
    second: [6]u16,

    /// Must be zero, as this is an artifact from the short name entry to be compatible with
    /// systems that don't support long name entries.
    zero: u16 = 0x0000,

    /// The last 2 wide characters in the block.
    third: [2]u16,

    /// This is the error set for std.unicode.Utf16LeIterator.
    const Error = error{
        UnexpectedSecondSurrogateHalf,
        ExpectedSecondSurrogateHalf,
        DanglingSurrogateHalf,
    };

    ///
    /// Given a long name entry part, get the name associated with this where the UFT16 encoded
    /// characters are converted to UTF8. This will exclude the NULL terminator. If an error
    /// occurs, then should fail the long name parsing, or be treated as an orphan file.
    ///
    /// Arguments:
    ///     IN self: *const LongName - The long name entry to get the name from.
    ///     IN buff: []u8            - A buffer to copy the name into.
    ///
    /// Return: u32
    ///     The index into the buffer where the last character was stored.
    ///
    /// Error: std.unicode.Utf16LeIterator
    ///     An error when parsing the wide UFT16 characters in the long name.
    ///
    pub fn getName(self: *const LongName, buff: []u8) Error!u32 {
        // No error can happen when encoding to UFT8 as will be getting valid code points from the
        // UTF16 iterator
        var index: u8 = 0;
        var f_i = std.unicode.Utf16LeIterator.init(self.first[0..]);
        while (try f_i.nextCodepoint()) |code_point| {
            // long names are null terminated, so return
            if (code_point == 0) {
                return index;
            }
            index += std.unicode.utf8Encode(code_point, buff[index..]) catch unreachable;
        }
        var s_i = std.unicode.Utf16LeIterator.init(self.second[0..]);
        while (try s_i.nextCodepoint()) |code_point| {
            // long names are null terminated, so return
            if (code_point == 0) {
                return index;
            }
            index += std.unicode.utf8Encode(code_point, buff[index..]) catch unreachable;
        }
        var t_i = std.unicode.Utf16LeIterator.init(self.third[0..]);
        while (try t_i.nextCodepoint()) |code_point| {
            // long names are null terminated, so return
            if (code_point == 0) {
                return index;
            }
            index += std.unicode.utf8Encode(code_point, buff[index..]) catch unreachable;
        }
        return index;
    }
};

/// A short name entry. This is the standard FAT32 file/directory entry. Each entry is 32 bytes
/// long. The file name is encoded in code page 437. When creating a short name, this will be in
/// ASCII as there isn't enough support in the std lib for unicode uppercase. But when parsing,
/// will decode proper code page 437 characters.
const ShortName = struct {
    /// The short name. All uppercase encoded in code page 437.
    name: [8]u8,

    /// The extension of the file. All uppercase encoded in code page 437.
    extension: [3]u8,

    /// The file attributes. See Attributes for the options. The upper 2 bits are reserved.
    attributes: u8,

    /// Reserved for Windows NT.
    reserved: u8 = 0x00,

    /// The 10th of a second part of the time created. The granularity of time created is 2
    /// seconds, so this can range from 0-199.
    time_created_tenth: u8,

    /// The time of creation.
    time_created: u16,

    /// The date of creation.
    date_created: u16,

    /// The date of last read or write.
    date_last_access: u16,

    /// The higher word of the entries first cluster.
    cluster_high: u16,

    /// Time of last modification.
    time_last_modification: u16,

    /// Date of last modification.
    date_last_modification: u16,

    /// The lower word of the entries first cluster.
    cluster_low: u16,

    /// The real file size in bytes.
    size: u32,

    /// The file attributes
    const Attributes = enum(u8) {
        /// A normal read/write file, not hidden, not a system file, don't backup.
        None = 0x00,

        /// Read only, can't write to the file.
        ReadOnly = 0x01,

        /// A normal directory listing won't show this. Can still access this as a normal file.
        Hidden = 0x02,

        /// An operating system file.
        System = 0x04,

        /// The real volume ID. There should only be one of these and in the root directory. The
        /// cluster should be set to 0.
        VolumeID = 0x08,

        /// A directory, not a file.
        Directory = 0x10,

        /// Indicates that a file/directory is to be achieved/backed up but backup utilities.
        Archive = 0x20,
    };

    ///
    /// Get the short name from the entry. This will be encoded in UFT8. This will also include a
    /// '.' between the name and extension and ignore trailing spaces.
    ///
    /// Arguments:
    ///     IN self: *const ShortName - The short name entry to get the name from.
    ///     IN buff: []u8             - A buffer to copy the UTF8 encoded name.
    ///
    /// Return: u32
    ///     The index into the buffer where the last character was stored.
    ///
    pub fn getName(self: *const ShortName, buff: []u8) u32 {
        var index: u8 = 0;
        for (self.name) |char| {
            if (char != ' ') {
                // 0x05 is actually 0xE5
                if (char == 0x05) {
                    const utf16 = CodePage.toWideChar(.CP437, 0xE5);
                    // The code page will return a valid character so the encode won't error
                    index += std.unicode.utf8Encode(utf16, buff[index..]) catch unreachable;
                } else {
                    const utf16 = CodePage.toWideChar(.CP437, char);
                    // The code page will return a valid character so the encode won't error
                    index += std.unicode.utf8Encode(utf16, buff[index..]) catch unreachable;
                }
            } else {
                break;
            }
        }
        if (!self.isDir()) {
            buff[index] = '.';
            index += 1;
            for (self.extension) |char| {
                if (char != ' ') {
                    const utf16 = CodePage.toWideChar(.CP437, char);
                    // The code page will return a valid character so the encode won't error
                    index += std.unicode.utf8Encode(utf16, buff[index..]) catch unreachable;
                } else {
                    break;
                }
            }
        }
        return index;
    }

    ///
    /// Get the original short file name without encoding into UTF8.
    ///
    /// Arguments:
    ///     IN self: *const ShortName - The short name entry to get the SFN name from.
    ///
    /// Return: [11]u8
    ///     The original 11 characters of the short name entry.
    ///
    pub fn getSFNName(self: *const ShortName) [11]u8 {
        var name: [11]u8 = [_]u8{' '} ** 11;
        std.mem.copy(u8, name[0..], self.name[0..]);
        std.mem.copy(u8, name[8..], self.extension[0..]);
        return name;
    }

    ///
    /// Check the attributes and check if the entry is a directory.
    ///
    /// Arguments:
    ///     IN self: *const ShortName - The short name entry to get if this is a directory.
    ///
    /// Return: bool
    ///     Whether the file is a directory or not.
    ///
    pub fn isDir(self: *const ShortName) bool {
        return self.attributes & @enumToInt(ShortName.Attributes.Directory) == @enumToInt(ShortName.Attributes.Directory);
    }

    ///
    /// Get the full first cluster number by combining the upper and lower parts of the cluster
    /// number.
    ///
    /// Arguments:
    ///     IN self: *const ShortName - The short name entry to get the cluster from.
    ///
    /// Return: u32
    ///     The first cluster of the file.
    ///
    pub fn getCluster(self: *const ShortName) u32 {
        return @as(u32, self.cluster_high) << 16 | self.cluster_low;
    }

    ///
    /// Calculate the check sum for the long name entry.
    ///
    /// Arguments:
    ///     IN self: *const ShortName - The short entry to calculate the check sum for.
    ///
    /// Return: u8
    ///     The check sum.
    ///
    pub fn calcCheckSum(self: *const ShortName) u8 {
        var check_sum: u8 = 0;
        // This is dumb, the check sum relies on the wrap around >:(
        for (self.name) |char| {
            check_sum = (check_sum << 7) +% (check_sum >> 1) +% char;
        }
        for (self.extension) |char| {
            check_sum = (check_sum << 7) +% (check_sum >> 1) +% char;
        }
        return check_sum;
    }
};

/// A complete FAT entry. This includes a list of long entries and one short entry.
const FatDirEntry = struct {
    /// The list of long entries. This will be in reverse order.
    long_entry: []LongName,

    /// The short entry.
    short_entry: ShortName,
};

/// The FAT32 configuration for modern FAT32. This so to remove the redundant FAT12/16
/// aspect of the boot sector.
const FATConfig = struct {
    /// The number of bytes per sector. This will be normally 512, but will depend on the
    /// hardware.
    bytes_per_sector: u16,

    /// The number of sectors per cluster. This will depend on the size of the disk.
    sectors_per_cluster: u8,

    /// The number of reserved sectors at the beginning of the filesystem. This is normally
    /// 32 sectors.
    reserved_sectors: u16,

    /// The number of hidden sectors. This is relevant for partitioned disks.
    hidden_sectors: u32,

    /// The total number of sectors of the filesystem.
    total_sectors: u32,

    /// The number of sectors that are occupied by the FAT.
    sectors_per_fat: u32,

    /// The cluster number of the root directory.
    root_directory_cluster: u32,

    /// The sector of the FSInfo sector.
    fsinfo_sector: u16,

    /// The sector number of the backup sector.
    backup_boot_sector: u16,

    /// If the filesystem has a FSInfo block.
    has_fs_info: bool,

    /// The number of free clusters on the disk. Will be 0xFFFFFFFF is unknown.
    number_free_clusters: u32,

    /// The next free cluster to start looking for when allocating a new cluster for a
    /// file. Will be 0xFFFFFFFF is unknown.
    next_free_cluster: u32,

    /// The end marker when reading the cluster chain. This will be in range from
    /// 0x0FFFFFF8 - 0x0FFFFFFF
    cluster_end_marker: u32,

    ///
    /// Convert a cluster to the corresponding sector from the filesystem's configuration.
    ///
    /// Arguments:
    ///     IN self: *const FATConfig - The FAT32 configuration.
    ///     IN cluster: u32           - The cluster number to convert.
    ///
    /// Return: u32
    ///     The sector number.
    ///
    pub fn clusterToSector(self: *const FATConfig, cluster: u32) u32 {
        // FAT count will be 2 as this is checked in the init function
        return (self.sectors_per_fat * 2) + self.reserved_sectors + ((cluster - 2) * self.sectors_per_cluster);
    }
};

///
/// Initialise a struct from bytes.
/// TODO: Once packed structs are good to go, then use std.mem.bytesAsValue.
///
/// Arguments:
///     IN comptime Type: type - The struct type to initialise
///     IN bytes: []const u8   - The bytes to initialise the struct with.
///
/// Return: Type
///     The struct initialised with the bytes.
///
fn initStruct(comptime Type: type, bytes: []const u8) Type {
    var ret: Type = undefined;
    comptime var index = 0;
    inline for (std.meta.fields(Type)) |item| {
        switch (item.field_type) {
            u8 => @field(ret, item.name) = bytes[index],
            u16 => @field(ret, item.name) = std.mem.bytesAsSlice(u16, bytes[index .. index + 2])[0],
            u32 => @field(ret, item.name) = std.mem.bytesAsSlice(u32, bytes[index .. index + 4])[0],
            else => {
                switch (@typeInfo(item.field_type)) {
                    .Array => |info| switch (info.child) {
                        u8 => {
                            comptime var i = 0;
                            inline while (i < info.len) : (i += 1) {
                                @field(ret, item.name)[i] = bytes[index + i];
                            }
                        },
                        u16 => {
                            comptime var i = 0;
                            inline while (i < info.len) : (i += 1) {
                                @field(ret, item.name)[i] = std.mem.bytesAsSlice(u16, bytes[index + (i * 2) .. index + 2 + (i * 2)])[0];
                            }
                        },
                        else => @compileError("Unexpected field type: " ++ @typeName(info.child)),
                    },
                    else => @compileError("Unexpected field type: " ++ @typeName(item.field_type)),
                }
            },
        }
        index += @sizeOf(item.field_type);
    }

    return ret;
}

///
/// A convenient function for returning the error types for reading, writing and seeking a stream.
///
/// Arguments:
///     IN comptime StreamType: type - The stream to get the error set from.
///
/// Return: type
///     The Error set for reading, writing and seeking the stream.
///
fn ErrorSet(comptime StreamType: type) type {
    const ReadError = switch (@typeInfo(StreamType)) {
        .Pointer => |p| p.child.ReadError,
        else => StreamType.ReadError,
    };

    const WriteError = switch (@typeInfo(StreamType)) {
        .Pointer => |p| p.child.WriteError,
        else => StreamType.WriteError,
    };

    const SeekError = switch (@typeInfo(StreamType)) {
        .Pointer => |p| p.child.SeekError,
        else => StreamType.SeekError,
    };

    return ReadError || WriteError || SeekError;
}

///
/// FAT32 filesystem.
///
/// Arguments:
///     IN comptime StreamType: type - The type of the stream to be used as the underlying device.
///
/// Return: type
///     The FAT32 filesystem that depends on the stream type.
///
pub fn Fat32FS(comptime StreamType: type) type {
    return struct {
        /// The underlying virtual filesystem
        fs: *vfs.FileSystem,

        /// An allocator for allocating memory for FAT32 operations.
        allocator: *Allocator,

        /// The root node of the FAT32 filesystem.
        root_node: RootNode,

        /// The configuration for the FAT32 filesystem.
        fat_config: FATConfig,

        /// A mapping of opened files so can easily retrieved opened files for reading, writing and
        /// closing.
        opened_files: AutoHashMap(*const vfs.Node, *OpenedInfo),

        /// The underlying hardware device that the FAT32 filesystem will be operating on. This could
        /// be a ramdisk, hard drive, memory stick...
        stream: StreamType,

        /// See vfs.FileSystem.instance
        instance: usize,

        /// The root node struct for storing the root of the filesystem.
        const RootNode = struct {
            /// The VFS node of the root directory.
            node: *vfs.Node,

            /// The cluster number for the root directory.
            cluster: u32,
        };

        /// The struct for storing the data needed for an opened file or directory.
        const OpenedInfo = struct {
            /// The cluster number of the file or directory.
            cluster: u32,

            /// The real size of the file. This will be zero for directories.
            size: u32,
        };

        /// The error set for the FAT32 filesystem.
        const Error = error{
            /// If the boot sector doesn't have the 0xAA55 signature as the last word. This would
            /// indicate this is not a valid boot sector.
            BadMBRMagic,

            /// An unexpected filesystem type. The filesystem type must be FAT32.
            BadFSType,

            /// An unexpected media descriptor other than 0xF8.
            BadMedia,

            /// An unexpected extended BIOS block signature other than 0x29.
            BadSignature,

            /// An unexpected FAT32 configuration. This will be if there are values set in the boot
            /// sector that are unexpected for FAT32.
            BadFat32,

            /// An unexpected FAT count. There should only be 2 tables.
            BadFATCount,

            /// An unexpected flags. Should be set to mirror which is zero.
            NotMirror,

            /// An unexpected root cluster number. Should be 2.
            BadRootCluster,

            /// When reading from the stream, if the read count is less than the expected read,
            /// then there is a bad read.
            BadRead,

            /// When creating a new FAT32 entry, if the name doesn't match the specification.
            InvalidName,
        };

        /// The internal self struct
        const Fat32Self = @This();

        // Can't directly access the fields of a pointer type, idk if this is a bug?

        /// The errors that can occur when reading from the stream.
        const ReadError = switch (@typeInfo(StreamType)) {
            .Pointer => |p| p.child.ReadError,
            else => StreamType.ReadError,
        };

        /// The errors that can occur when writing to the stream.
        const WriteError = switch (@typeInfo(StreamType)) {
            .Pointer => |p| p.child.WriteError,
            else => StreamType.WriteError,
        };

        /// The errors that can occur when seeking the stream.
        const SeekError = switch (@typeInfo(StreamType)) {
            .Pointer => |p| p.child.SeekError,
            else => StreamType.SeekError,
        };

        /// The errors that can occur when getting the seek position of the stream.
        const GetPosError = switch (@typeInfo(StreamType)) {
            .Pointer => |p| p.child.GetPosError,
            else => StreamType.GetPosError,
        };

        /// An iterator for looping over the cluster chain in the FAT.
        const ClusterChainIterator = struct {
            /// The allocator used for allocating the initial FAT array, then to free in deinit.
            allocator: *Allocator,

            /// The current cluster value.
            cluster: u32,

            /// The configuration for this FAT instance. Used for converting clusters to sectors
            /// and seeking to the correct location to read the next cluster value.
            fat_config: FATConfig,

            /// The underlying stream to read the FAT.
            stream: StreamType,

            /// The cached FAT.
            fat: []u32,

            /// The offset into the FAT. If the next cluster is outside the cached FAT, then will
            /// need to read a new part of the FAT.
            table_offset: u32,

            /// The offset used when reading part of a cluster. This will range from 0 to
            /// bytes_per_sector * sectors_per_cluster.
            cluster_offset: u32,

            /// The iterators self.
            const ClusterChainIteratorSelf = @This();

            ///
            /// Check if we need to advance the cluster value and in turn check if the new cluster
            /// is within the cached FAT.
            ///
            /// Arguments:
            ///     IN self: *ClusterChainIteratorSelf - Iterator self.
            ///
            /// Error: Fat32Self.Error || ReadError || SeekError
            ///     Fat32Self.Error - If reading the stream didn't fill the cache FAT array.
            ///     ReadError       - If there is an error reading from the stream.
            ///     SeekError       - If there is an error seeking the stream.
            ///
            fn checkRead(self: *ClusterChainIteratorSelf) (Fat32Self.Error || ReadError || SeekError)!void {
                if (self.cluster_offset >= self.fat_config.bytes_per_sector * self.fat_config.sectors_per_cluster) {
                    self.cluster = self.fat[self.cluster - self.table_offset];
                    self.cluster_offset = 0;
                    // If we are at the end, break
                    if ((self.cluster & 0x0FFFFFFF) >= self.fat_config.cluster_end_marker) {
                        return;
                    }
                    // This will also allow for forwards and backwards iteration of the FAT
                    const table_offset = self.cluster / self.fat.len;
                    if (table_offset != self.table_offset) {
                        self.table_offset = table_offset;
                        try self.stream.seekableStream().seekTo((self.fat_config.reserved_sectors + self.table_offset) * self.fat_config.bytes_per_sector);
                        const read_count = try self.stream.reader().readAll(std.mem.sliceAsBytes(self.fat));
                        if (read_count != self.fat.len * @sizeOf(u32)) {
                            return Fat32Self.Error.BadRead;
                        }
                    }
                }
            }

            ///
            /// Iterate the cluster chain of FAT32. This will follow the FAT chain reading the data
            /// into the buffer provided where the cluster is pointing to. This will read the
            /// entire clusters data into the buffer. If the buffer is full or the end of the
            /// cluster chain is reached, then will return null else will return the end index into
            /// the buffer to next read into. Currently, this will be the bytes per cluster and
            /// only buffers aligned to bytes per cluster will work.
            ///
            /// Arguments:
            ///     IN self: *ClusterChainIteratorSelf - Self iterator.
            ///     IN buff: []u8                      - The buffer to read the data into.
            ///
            /// Return: ?usize
            ///     The end index into the buffer where the next read should start. If returned
            ///     null, then the buffer is full or the end of the cluster chain is reached.
            ///
            /// Error: Fat32Self.Error || ReadError || SeekError
            ///     Fat32Self.Error - (BadRead) If the buffer isn't aligned to the bytes per cluster boundary.
            ///     ReadError       - If there is an error reading from the stream.
            ///     SeekError       - If there is an error seeking the stream.
            ///
            pub fn read(self: *ClusterChainIteratorSelf, buff: []u8) (Fat32Self.Error || ReadError || SeekError)!?usize {
                // FAT32 is really FAT28, so the top 4 bits are not used, so mask them out
                if (buff.len != 0 and self.cluster != 0 and (self.cluster & 0x0FFFFFFF) < self.fat_config.cluster_end_marker and buff.len > 0) {
                    // Seek to the sector where the cluster is
                    const sector = self.fat_config.clusterToSector(self.cluster);
                    try self.stream.seekableStream().seekTo(sector * self.fat_config.bytes_per_sector + self.cluster_offset);

                    const read_len = std.math.min(buff.len, self.fat_config.bytes_per_sector * self.fat_config.sectors_per_cluster);
                    self.cluster_offset += read_len;

                    // Read the cluster
                    // TODO: Maybe cache bytes per cluster block, then can read into a buffer that isn't aligned to 512 bytes.
                    //       So would read from the cache rather than the stream itself.
                    const read_count = try self.stream.reader().readAll(buff[0..read_len]);
                    if (read_count != read_len) {
                        return Fat32Self.Error.BadRead;
                    }

                    // Increment the cluster
                    // Check if we need to read another part of the FAT
                    try self.checkRead();
                    return read_len;
                }

                return null;
            }

            ///
            /// Deinitialise the cluster chain iterator.
            ///
            /// Arguments:
            ///     IN self: *ClusterChainIteratorSelf - Iterator self.
            ///
            ///
            pub fn deinit(self: *const ClusterChainIteratorSelf) void {
                self.allocator.free(self.fat);
            }

            ///
            /// Initialise a cluster chain iterator.
            ///
            /// Arguments:
            ///     IN allocator: *Allocator - The allocator for allocating a FAT cache.
            ///     IN fat_config: FATConfig - The FAT configuration.
            ///     IN cluster: u32          - The first cluster to start reading from.
            ///     IN stream: StreamType    - The underlying stream.
            ///
            /// Return: ClusterChainIteratorSelf
            ///     A cluster chain iterator.
            ///
            /// Error: Allocator.Error || Fat32Self.Error || ReadError || SeekError
            ///     Allocator.Error - If there is an error allocating the initial FAT cache.
            ///     Fat32Self.Error - If reading the stream didn't fill the cache FAT array.
            ///     ReadError       - If there is an error reading from the stream.
            ///     SeekError       - If there is an error seeking the stream.
            ///
            pub fn init(allocator: *Allocator, fat_config: FATConfig, cluster: u32, stream: StreamType) (Allocator.Error || Fat32Self.Error || ReadError || SeekError)!ClusterChainIteratorSelf {
                // Create a bytes per sector sized cache of the FAT.
                var fat = try allocator.alloc(u32, fat_config.bytes_per_sector / @sizeOf(u32));
                errdefer allocator.free(fat);

                // FAT32 has u32 entries so need to divide
                const table_offset = cluster / (fat_config.bytes_per_sector / @sizeOf(u32));

                // Seek to the FAT
                // The FAT is just after the reserved sectors + the index
                try stream.seekableStream().seekTo((fat_config.reserved_sectors + table_offset) * fat_config.bytes_per_sector);
                const read_count = try stream.reader().readAll(std.mem.sliceAsBytes(fat));
                if (read_count != fat.len * @sizeOf(u32)) {
                    return Fat32Self.Error.BadRead;
                }

                return ClusterChainIteratorSelf{
                    .allocator = allocator,
                    .cluster = cluster,
                    .fat_config = fat_config,
                    .stream = stream,
                    .fat = fat,
                    .table_offset = table_offset,
                    .cluster_offset = 0,
                };
            }
        };

        /// An iterator for looping over the directory structure of FAT32.
        const EntryIterator = struct {
            /// An allocator for memory stuff
            allocator: *Allocator,

            /// A cache of the current cluster. This wil be read from the cluster chain iterator.
            cluster_block: []u8,

            /// The current index into the cluster block.
            index: u32,

            /// The cluster chain iterator to read the next custer when needed.
            cluster_chain: ClusterChainIterator,

            /// The entry iterator self.
            const EntryIteratorSelf = @This();

            /// The entry returned from 'next()'.
            pub const Entry = struct {
                /// The allocator used to allocate fields of this entry. Also used to free these
                /// entries in the 'deinit()' function.
                allocator: *Allocator,

                /// The long name for the entry. This maybe null as not all entry have a long name
                /// part, just a short name.
                long_name: ?[]const u8,

                /// The short name struct.
                short_name: ShortName,

                ///
                /// Free the entry.
                ///
                /// Arguments:
                ///     IN self: *Entry - The entry self to free.
                ///
                ///
                pub fn deinit(self: *const Entry) void {
                    if (self.long_name) |name| {
                        self.allocator.free(name);
                    }
                }
            };

            /// The error set for the entry iterator.
            const EntryItError = error{
                /// If the long entry is invalid, so ignore it and use the short name only.
                Orphan,

                /// If reading the cluster chain and reach the end unexpectedly.
                EndClusterChain,
            };

            ///
            /// Check if the next entry will be outside the cluster block cache. If so, read the
            /// next cluster and update the index to 0.
            ///
            /// Arguments:
            ///     IN self: *EntryIteratorSelf - Iterator self.
            ///
            /// Error: Fat32Self.Error || ReadError || SeekError || EntryItError
            ///     Fat32Self.Error       - Error reading the cluster chain if the buffer isn't aligned.
            ///     ReadError             - Error reading from the stream in the cluster iterator.
            ///     SeekError             - Error seeking the stream in the cluster iterator.
            ///     error.EndClusterChain - Reading the next cluster and reach the end unexpectedly.
            ///
            fn checkRead(self: *EntryIteratorSelf) (Fat32Self.Error || ReadError || SeekError || EntryItError)!void {
                if (self.index >= self.cluster_block.len) {
                    // Read the next block
                    var index: u32 = 0;
                    while (try self.cluster_chain.read(self.cluster_block[index..])) |next_index| {
                        index += next_index;
                    }
                    // Didn't read so at end of cluster chain
                    // TODO: This relies on that cluster chain iterator will return full cluster bytes
                    //       Currently this is the case, but when changed will need to update this to
                    //       include partially full cluster block cache, with an index.
                    if (index < self.cluster_block.len) {
                        return EntryItError.EndClusterChain;
                    }
                    // Reset the index
                    self.index = 0;
                }
            }

            ///
            /// A helper function for reading a entry. This is used for catching orphaned long
            /// entries and ignoring them so this shouldn't be called directly.
            ///
            /// Arguments:
            ///     IN self: *EntryIteratorSelf - Iterator self.
            ///
            /// Return: ?Entry
            ///     The FAT entry. Will return null if there are no more entries for the directory.
            ///
            /// Error: Allocator.Error || Fat32Self.Error || ReadError || SeekError || EntryItError
            ///     Allocator.Error - Error allocating memory for fields in the return entry.
            ///     Fat32Self.Error - Error reading the cluster chain if the buffer isn't aligned.
            ///     ReadError       - Error reading from the underlying stream.
            ///     SeekError       - Error seeking the underlying stream.
            ///     error.Orphan    - If there is a long entry without a short name entry or the
            ///                       check sum in the long entry is incorrect with the associated
            ///                       short entry or the long entry is missing entry parts.
            ///     error.EndClusterChain - Reading the next cluster and reach the end unexpectedly.
            ///
            fn nextImp(self: *EntryIteratorSelf) (Allocator.Error || Fat32Self.Error || ReadError || SeekError || LongName.Error || EntryItError)!?Entry {
                // Do we need to read the next block
                try self.checkRead();

                // Ignore deleted files
                while (self.cluster_block[self.index] == 0xE5) : ({
                    self.index += 32;
                    try self.checkRead();
                }) {}

                // Are we at the end of all entries
                if (self.cluster_block[self.index] != 0x00) {
                    // The long name if there is one
                    var long_name: ?[]u8 = null;
                    errdefer if (long_name) |name| self.allocator.free(name);
                    var long_entries: ?[]LongName = null;
                    defer if (long_entries) |entries| self.allocator.free(entries);

                    // If attribute is 0x0F, then is a long file name and
                    if (self.cluster_block[self.index] & 0x40 == 0x40 and self.cluster_block[self.index + 11] == 0x0F) {
                        // How many entries do we have, the first byte of the order. This starts at 1 not 0
                        var long_entry_count = self.cluster_block[self.index] & ~@as(u32, 0x40);
                        // Allocate a buffer for the long name. 13 for the 13 characters in the long entry
                        // * 3 as long names are u16 chars so when converted to u8, there could be 3 u8 to encode a u16 (UTF16 -> UTF8)
                        long_name = try self.allocator.alloc(u8, 13 * 3 * long_entry_count);
                        // For convenience
                        var long_name_temp = long_name.?;
                        var long_name_index: u32 = 0;
                        long_entries = try self.allocator.alloc(LongName, long_entry_count);

                        // Iterate through the long name entries
                        while (long_entry_count > 0) : ({
                            self.index += 32;
                            long_entry_count -= 1;
                            try self.checkRead();
                        }) {
                            // Parse the long entry
                            long_entries.?[long_entry_count - 1] = initStruct(LongName, self.cluster_block[self.index..]);
                            // Check the order of the long entry as it could be broken
                            if ((long_entries.?[long_entry_count - 1].order & ~@as(u32, 0x40)) != long_entry_count) {
                                // A broken long entry
                                self.index += 32;
                                return EntryItError.Orphan;
                            }
                        }

                        // Parse the name
                        for (long_entries.?) |entry| {
                            long_name_index += try entry.getName(long_name_temp[long_name_index..]);
                        }

                        long_name = long_name_temp[0..long_name_index];
                    }

                    // Make sure we have a short name part, if not then it is a orphan
                    // Easy check for the attributes as 0x0F is invalid and a long name part
                    // So if we have one, then this is a long entry not short entry as expected
                    // Also make are we are not at the end
                    if (self.cluster_block[self.index] != 0x00 and self.cluster_block[self.index + 11] == 0x0F) {
                        // This will be an invalid short name
                        self.index += 32;
                        return EntryItError.Orphan;
                    }

                    // Parse the short entry
                    // We need all parts of the short name, not just the name
                    const short_entry = initStruct(ShortName, self.cluster_block[self.index..]);
                    // Check the check sum
                    if (long_entries) |entries| {
                        for (entries) |entry| {
                            if (entry.check_sum != short_entry.calcCheckSum()) {
                                return EntryItError.Orphan;
                            }
                        }
                    }

                    // Increment for the next entry
                    self.index += 32;

                    return Entry{
                        .allocator = self.allocator,
                        .long_name = long_name,
                        .short_name = short_entry,
                    };
                }

                return null;
            }

            ///
            /// Get the next entry in the iterator. Will return null when at the end. This will
            /// ignore orphaned long entries.
            ///
            /// Arguments:
            ///     IN self: *EntryIteratorSelf - Iterator self.
            ///
            /// Return: ?Entry
            ///     The FAT entry. Will return null if there are no more entries for the directory.
            ///     The entry must be free using the deinit() function.
            ///
            /// Error: Allocator.Error || Fat32Self.Error || ReadError || SeekError
            ///     Allocator.Error - Error allocating memory for fields in the return entry.
            ///     Fat32Self.Error - Error reading the cluster chain if the buffer isn't aligned.
            ///     ReadError       - Error reading from the underlying stream.
            ///     SeekError       - Error seeking the underlying stream.
            ///
            pub fn next(self: *EntryIteratorSelf) (Allocator.Error || Fat32Self.Error || ReadError || SeekError || LongName.Error)!?Entry {
                // If there is a orphan file, then just get the next one
                // If we hit the end of the cluster chain, return null
                while (true) {
                    if (self.nextImp()) |n| {
                        return n;
                    } else |e| switch (e) {
                        error.Orphan => continue,
                        error.EndClusterChain => return null,
                        else => return @errSetCast(Allocator.Error || Fat32Self.Error || ReadError || SeekError || LongName.Error, e),
                    }
                }
            }

            ///
            /// Destroy the entry iterator freeing any memory.
            ///
            /// Arguments:
            ///     IN self: *EntryIteratorSelf - Iterator self.
            ///
            pub fn deinit(self: *const EntryIteratorSelf) void {
                self.allocator.free(self.cluster_block);
                self.cluster_chain.deinit();
            }

            ///
            /// Initialise a directory entry iterator to looping over the FAT entries. This uses
            /// the cluster chain iterator.
            ///
            /// Arguments:
            ///     IN allocator: *Allocator - The allocator for allocating a cluster block cache.
            ///     IN fat_config: FATConfig - The FAT configuration.
            ///     IN cluster: u32          - The first cluster to start reading from.
            ///     IN stream: StreamType    - The underlying stream.
            ///
            /// Return: EntryIteratorSelf
            ///     The entry iterator.
            ///
            /// Error: Allocator.Error || Fat32Self.Error || ReadError || SeekError
            ///     Allocator.Error - Error allocating memory for fields in the return entry.
            ///     Fat32Self.Error - Error reading the cluster chain if the buffer isn't aligned.
            ///     ReadError       - Error reading from the underlying stream.
            ///     SeekError       - Error seeking the underlying stream.
            ///
            pub fn init(allocator: *Allocator, fat_config: FATConfig, cluster: u32, stream: StreamType) (Allocator.Error || Fat32Self.Error || ReadError || SeekError)!EntryIteratorSelf {
                var cluster_block = try allocator.alloc(u8, fat_config.bytes_per_sector * fat_config.sectors_per_cluster);
                errdefer allocator.free(cluster_block);
                var it = try ClusterChainIterator.init(allocator, fat_config, cluster, stream);
                errdefer it.deinit();
                var index: u32 = 0;
                while (try it.read(cluster_block[index..])) |next_index| {
                    index += next_index;
                }
                return EntryIteratorSelf{
                    .allocator = allocator,
                    .cluster_block = cluster_block,
                    .index = 0,
                    .cluster_chain = it,
                };
            }
        };

        /// See vfs.FileSystem.getRootNode
        fn getRootNode(fs: *const vfs.FileSystem) *const vfs.DirNode {
            const self = @fieldParentPtr(Fat32Self, "instance", fs.instance);
            return &self.root_node.node.Dir;
        }

        /// See vfs.FileSystem.closeFile
        fn close(fs: *const vfs.FileSystem, node: *const vfs.Node) void {
            const self = @fieldParentPtr(Fat32Self, "instance", fs.instance);
            // As close can't error, if provided with a invalid Node that isn't opened or try to close
            // the same file twice, will just do nothing.
            if (self.opened_files.remove(node)) |entry_node| {
                self.allocator.destroy(entry_node.value);
            }
        }

        /// See vfs.FileSystem.read
        fn read(fs: *const vfs.FileSystem, node: *const vfs.FileNode, buffer: []u8) (Allocator.Error || vfs.Error)!usize {
            const self = @fieldParentPtr(Fat32Self, "instance", fs.instance);
            const cast_node = @ptrCast(*const vfs.Node, node);
            const opened_node = self.opened_files.get(cast_node) orelse return vfs.Error.NotOpened;
            const size = std.math.min(buffer.len, opened_node.size);
            // TODO: Future PR
            return 0;
        }

        /// See vfs.FileSystem.write
        fn write(fs: *const vfs.FileSystem, node: *const vfs.FileNode, bytes: []const u8) (Allocator.Error || vfs.Error)!usize {
            const self = @fieldParentPtr(Fat32Self, "instance", fs.instance);
            const cast_node = @ptrCast(*const vfs.Node, node);
            const opened_node = self.opened_files.get(cast_node) orelse return vfs.Error.NotOpened;
            // TODO: Future PR
            return 0;
        }

        /// See vfs.FileSystem.open
        fn open(fs: *const vfs.FileSystem, dir: *const vfs.DirNode, name: []const u8, flags: vfs.OpenFlags, open_args: vfs.OpenArgs) (Allocator.Error || vfs.Error)!*vfs.Node {
            return switch (flags) {
                .NO_CREATION => openImpl(fs, dir, name),
                .CREATE_DIR, .CREATE_FILE, .CREATE_SYMLINK => createFileOrDirOrSymlink(fs, dir, name, flags, open_args),
            };
        }

        ///
        /// Helper function for creating the correct *Node
        ///
        /// Arguments:
        ///     IN self: *Fat32Self        - Self, needed for the allocator and underlying filesystem
        ///     IN cluster: u32            - When creating a file, the cluster the file is at.
        ///     IN size: u32               - When creating a file, the size of the file is at.
        ///     IN flags: vfs.OpenFlags    - The open flags for deciding on the Node type.
        ///     IN open_args: vfs.OpenArgs - The open arguments when creating a symlink.
        ///
        /// Return: *vfs.Node
        ///     The VFS Node
        ///
        /// Error: Allocator.Error || vfs.Error
        ///     Allocator.Error           - Not enough memory for allocating the Node
        ///     vfs.Error.NoSymlinkTarget - See vfs.Error.NoSymlinkTarget.
        ///
        fn createNode(self: *Fat32Self, cluster: u32, size: u32, flags: vfs.OpenFlags, open_args: vfs.OpenArgs) (Allocator.Error || vfs.Error)!*vfs.Node {
            var node = try self.allocator.create(vfs.Node);
            errdefer self.allocator.destroy(node);
            node.* = switch (flags) {
                .CREATE_DIR => .{ .Dir = .{ .fs = self.fs, .mount = null } },
                .CREATE_FILE => .{ .File = .{ .fs = self.fs } },
                .CREATE_SYMLINK => if (open_args.symlink_target) |target|
                    .{ .Symlink = target }
                else
                    return vfs.Error.NoSymlinkTarget,
                .NO_CREATION => unreachable,
            };

            // Create the opened info struct
            var opened_info = try self.allocator.create(OpenedInfo);
            errdefer self.allocator.destroy(opened_info);
            opened_info.* = .{
                .cluster = cluster,
                .size = size,
            };

            try self.opened_files.put(node, opened_info);
            return node;
        }

        ///
        /// A helper function for getting the cluster from an opened directory node.
        ///
        /// Arguments:
        ///     IN self: *const Fat32Self  - Self, used to get the opened nodes.
        ///     IN dir: *const vfs.DirNode - The directory node to get the cluster for.
        ///
        /// Return: u32
        ///     The cluster number for the directory node.
        ///
        /// Error: vfs.Error
        ///     error.NotOpened - If directory node isn't opened.
        ///
        fn getDirCluster(self: *Fat32Self, dir: *const vfs.DirNode) vfs.Error!u32 {
            return if (std.meta.eql(dir, self.fs.getRootNode(self.fs))) self.root_node.cluster else brk: {
                const parent = self.opened_files.get(@ptrCast(*const vfs.Node, dir)) orelse return vfs.Error.NotOpened;
                // Cluster 0 means is the root directory cluster
                break :brk if (parent.cluster == 0) self.fat_config.root_directory_cluster else parent.cluster;
            };
        }

        ///
        /// The helper function for opening a file/folder, no creation.
        ///
        /// Arguments:
        ///     IN fs: *const vfs.FileSystem - The underlying filesystem.
        ///     IN dir: *const vfs.DirNode   - The parent directory.
        ///     IN name: []const u8          - The name of the file/folder to open.
        ///
        /// Return: *vfs.Node
        ///     The VFS Node for the opened file/folder.
        ///
        /// Error: Allocator.Error || vfs.Error
        ///     Allocator.Error           - Not enough memory for allocating memory
        ///     vfs.Error.NoSuchFileOrDir - Error if the file/folder doesn't exist.
        ///     vfs.Error.Unexpected      - An error occurred whilst reading the file system, this
        ///                                 can be caused by a parsing error or errors on reading
        ///                                 or seeking the underlying stream. If this occurs, then
        ///                                 the real error is printed using `log.err`.
        ///
        fn openImpl(fs: *const vfs.FileSystem, dir: *const vfs.DirNode, name: []const u8) (Allocator.Error || vfs.Error)!*vfs.Node {
            const self = @fieldParentPtr(Fat32Self, "instance", fs.instance);
            // TODO: Cache the files in this dir, so when opening, don't have to iterator the directory every time

            // Iterate over the directory and find the file/folder
            const cluster = try self.getDirCluster(dir);
            var it = EntryIterator.init(self.allocator, self.fat_config, cluster, self.stream) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.err("Error initialising the entry iterator. Error: {}\n", .{e});
                    return vfs.Error.Unexpected;
                },
            };
            defer it.deinit();
            while (it.next() catch |e| switch (e) {
                error.OutOfMemory => return vfs.Error.IsAFile,
                else => {
                    log.err("Error initialising the entry iterator. Error: {}\n", .{e});
                    return vfs.Error.Unexpected;
                },
            }) |entry| {
                defer entry.deinit();
                // File name compare is case insensitive
                var match: bool = brk: {
                    if (entry.long_name) |long_name| {
                        if (std.ascii.eqlIgnoreCase(name, long_name)) {
                            break :brk true;
                        }
                    }
                    var short_buff: [33]u8 = undefined;
                    const s_end = entry.short_name.getName(short_buff[0..]);
                    if (std.ascii.eqlIgnoreCase(name, short_buff[0..s_end])) {
                        break :brk true;
                    }
                    break :brk false;
                };

                if (match) {
                    const open_type = if (entry.short_name.isDir()) vfs.OpenFlags.CREATE_DIR else vfs.OpenFlags.CREATE_FILE;
                    return self.createNode(entry.short_name.getCluster(), entry.short_name.size, open_type, .{});
                }
            }
            return vfs.Error.NoSuchFileOrDir;
        }

        ///
        /// Helper function for creating a file, folder or symlink.
        ///
        /// Arguments:
        ///     IN fs: *const vfs.FileSystem - The underlying filesystem.
        ///     IN dir: *const vfs.DirNode   - The parent directory.
        ///     IN name: []const u8          - The name of the file/folder to open.
        ///     IN flags: vfs.OpenFlags      - The open flags for if creating a file/folder/symlink.
        ///     IN open_args: vfs.OpenArgs   - The open arguments if creating a symlink.
        ///
        /// Return: *vfs.Node
        ///     The VFS Node for the opened/created file/folder.
        ///
        /// Error: Allocator.Error || ReadError || SeekError || vfs.Error
        ///     Allocator.Error           - Not enough memory for allocating memory
        ///     ReadError                 - Errors when reading the stream.
        ///     SeekError                 - Errors when seeking the stream.
        ///     vfs.Error.NoSuchFileOrDir - Error if creating a symlink and no target is provided.
        ///
        fn createFileOrDirOrSymlink(fs: *const vfs.FileSystem, dir: *const vfs.DirNode, name: []const u8, flags: vfs.OpenFlags, open_args: vfs.OpenArgs) (Allocator.Error || ReadError || SeekError || vfs.Error)!*vfs.Node {
            const self = @fieldParentPtr(Fat32Self, "instance", fs.instance);

            // TODO: Future PR
            return vfs.Error.NoSuchFileOrDir;
        }

        ///
        /// Deinitialise this file system. This frees the root node, virtual filesystem and self.
        /// This asserts that there are no open files left.
        ///
        /// Arguments:
        ///     IN self: *Fat32Self - Self to free.
        ///
        pub fn destroy(self: *Fat32Self) void {
            // Make sure we have closed all files
            // TODO: Should this deinit close any open files instead?
            std.debug.assert(self.opened_files.count() == 0);
            self.opened_files.deinit();
            self.allocator.destroy(self.root_node.node);
            self.allocator.destroy(self.fs);
            self.allocator.destroy(self);
        }

        ///
        /// Initialise a FAT32 filesystem.
        ///
        /// Arguments:
        ///     IN allocator: *Allocator - Allocate memory.
        ///     IN stream: StreamType    - The underlying stream that the filesystem will sit on.
        ///
        /// Return: *Fat32
        ///     The pointer to a FAT32 filesystem.
        ///
        /// Error: Allocator.Error || ReadError || SeekError || Fat32Self.Error
        ///     Allocator.Error - If there is no more memory. Any memory allocated will be freed.
        ///     ReadError       - If there is an error reading from the stream.
        ///     SeekError       - If there si an error seeking the stream.
        ///     Fat32Self.Error - If there is an error when parsing the stream to set up a fAT32
        ///                       filesystem. See Error for the list of possible errors.
        ///
        pub fn create(allocator: *Allocator, stream: StreamType) (Allocator.Error || ReadError || SeekError || Fat32Self.Error)!*Fat32Self {
            log.debug("Init\n", .{});
            defer log.debug("Done\n", .{});
            // We need to get the root directory sector. For this we need to read the boot sector.
            var boot_sector_raw = try allocator.alloc(u8, 512);
            defer allocator.free(boot_sector_raw);

            const seek_stream = stream.seekableStream();
            const read_stream = stream.reader();

            // Ensure we are the beginning
            try seek_stream.seekTo(0);
            const read_count = try read_stream.readAll(boot_sector_raw[0..]);
            if (read_count != 512) {
                return Error.BadRead;
            }

            // Check the boot signature
            if (boot_sector_raw[510] != 0x55 or boot_sector_raw[511] != 0xAA) {
                return Error.BadMBRMagic;
            }

            // Parse the boot sector to extract the relevant information
            const boot_sector = initStruct(BootRecord, boot_sector_raw[0..90]);

            // Make sure the root cluster isn't 0 or 1
            if (boot_sector.root_directory_cluster < 2) {
                return Error.BadRootCluster;
            }

            // Make sure we have 2 FATs as this is common for FAT32, and we are going to not accept more or less FATs
            if (boot_sector.fat_count != 2) {
                return Error.BadFATCount;
            }

            // Make sure the FATs are mirrored (flags = 0x0)
            if (boot_sector.mirror_flags != 0x00) {
                return Error.NotMirror;
            }

            // Only accept fixed disks, no floppies
            if (boot_sector.media_descriptor_type != 0xF8) {
                return Error.BadMedia;
            }

            // Make sure the parts there were used for FAT12/16 are zero
            if (boot_sector.root_directory_size != 0 or boot_sector.sectors_per_fat_12_16 != 0 or boot_sector.total_sectors_12_16 != 0) {
                return Error.BadFat32;
            }

            // Check the signature
            if (boot_sector.signature != 0x29) {
                return Error.BadSignature;
            }

            // Check the filesystem type
            if (!std.mem.eql(u8, "FAT32   ", boot_sector.filesystem_type[0..])) {
                return Error.BadFSType;
            }

            // Read the FSInfo block
            // 0xFFFFFFFF is for unknown sizes
            var number_free_clusters: u32 = 0xFFFFFFFF;
            var next_free_cluster: u32 = 0xFFFFFFFF;
            var has_fs_info = false;
            if (boot_sector.fsinfo_sector != 0x0000 and boot_sector.fsinfo_sector != 0xFFFF) {
                var fs_info_raw = try allocator.alloc(u8, 512);
                defer allocator.free(fs_info_raw);
                try seek_stream.seekTo(boot_sector.fsinfo_sector * boot_sector.bytes_per_sector);
                const fs_read_count = try read_stream.readAll(fs_info_raw[0..]);
                if (fs_read_count != 512) {
                    return Error.BadRead;
                }

                const fs_info = initStruct(FSInfo, fs_info_raw[0..]);
                // Check the signatures
                if (fs_info.lead_signature == 0x41615252 and fs_info.struct_signature == 0x61417272 and fs_info.tail_signature == 0xAA550000) {
                    // It should be range checked at least to make sure it is <= volume cluster count.
                    const usable_sectors = boot_sector.total_sectors - boot_sector.reserved_sectors - (boot_sector.fat_count * boot_sector.sectors_per_fat);
                    const usable_clusters = @divFloor(usable_sectors, boot_sector.sectors_per_cluster) - 1;
                    if (usable_clusters >= fs_info.number_free_clusters) {
                        number_free_clusters = fs_info.number_free_clusters;
                    }
                    next_free_cluster = fs_info.next_free_cluster;
                    has_fs_info = true;
                }
            }

            // Figure out the end marker used in the cluster chain by reading the FAT
            // FAT is just after the reserved sectors +4 as it is the second entry of u32 entries
            try seek_stream.seekTo(boot_sector.reserved_sectors * boot_sector.bytes_per_sector + 4);
            var end_marker_raw: [4]u8 = undefined;
            const fat_read_count = try read_stream.readAll(end_marker_raw[0..]);
            if (fat_read_count != 4) {
                return Error.BadRead;
            }
            const cluster_end_marker = std.mem.bytesAsSlice(u32, end_marker_raw[0..])[0] & 0x0FFFFFFF;

            // Have performed the checks, create the filesystem
            const fs = try allocator.create(vfs.FileSystem);
            errdefer allocator.destroy(fs);
            const root_node = try allocator.create(vfs.Node);
            errdefer allocator.destroy(root_node);
            const fat32_fs = try allocator.create(Fat32Self);
            errdefer allocator.destroy(fat32_fs);

            // Record the relevant information
            const fat_config = FATConfig{
                .bytes_per_sector = boot_sector.bytes_per_sector,
                .sectors_per_cluster = boot_sector.sectors_per_cluster,
                .reserved_sectors = boot_sector.reserved_sectors,
                .hidden_sectors = boot_sector.hidden_sectors,
                .total_sectors = boot_sector.total_sectors,
                .sectors_per_fat = boot_sector.sectors_per_fat,
                .root_directory_cluster = boot_sector.root_directory_cluster,
                .fsinfo_sector = boot_sector.fsinfo_sector,
                .backup_boot_sector = boot_sector.backup_boot_sector,
                .has_fs_info = has_fs_info,
                .number_free_clusters = number_free_clusters,
                .next_free_cluster = next_free_cluster,
                .cluster_end_marker = cluster_end_marker,
            };

            fat32_fs.* = .{
                .fs = fs,
                .allocator = allocator,
                .instance = 32,
                .root_node = .{
                    .node = root_node,
                    .cluster = fat_config.root_directory_cluster,
                },
                .fat_config = fat_config,
                .stream = stream,
                .opened_files = AutoHashMap(*const vfs.Node, *OpenedInfo).init(allocator),
            };

            root_node.* = .{
                .Dir = .{
                    .fs = fs,
                    .mount = null,
                },
            };

            fs.* = .{
                .open = open,
                .close = close,
                .read = read,
                .write = write,
                .instance = &fat32_fs.instance,
                .getRootNode = getRootNode,
            };

            return fat32_fs;
        }
    };
}

///
/// Initialise a FAT32 filesystem. This will take a stream that conforms to the reader(), writer(),
/// and seekableStream() interfaces. For example, FixedBufferStream or File. A pointer to this is
/// allowed. This will allow the use of different devices such as Hard drives or RAM disks to have
/// a FAT32 filesystem abstraction. We assume the FAT32 will be the only filesystem present and no
/// partition schemes are present. So will expect a valid boot sector.
///
/// Arguments:
///     IN allocator: *Allocator - An allocator.
///     IN stream: anytype       - A stream this is used to read and seek a raw disk or memory to
///                                be parsed as a FAT32 filesystem. E.g. a FixedBufferStream.
///
/// Return: *Fat32FS(@TypeOf(stream))
///     A pointer to a FAT32 filesystem.
///
/// Error: Allocator.Error || Fat32FS(@TypeOf(stream)).Error
///     Allocator.Error - If there isn't enough memory to create the filesystem.
///
pub fn initialiseFAT32(allocator: *Allocator, stream: anytype) (Allocator.Error || ErrorSet(@TypeOf(stream)) || Fat32FS(@TypeOf(stream)).Error)!*Fat32FS(@TypeOf(stream)) {
    return Fat32FS(@TypeOf(stream)).create(allocator, stream);
}

/// The test buffer for the test filesystem stream.
var test_stream_buff = [_]u8{0} ** if (builtin.is_test) 34090496 else 0;

///
/// Read the test files and write them to the test FAT32 filesystem.
///
/// Arguments:
///     IN comptime StreamType: type     - The stream type.
///     IN fat32fs: *Fat32FS(StreamType) - The test filesystem.
///
/// Error: Allocator.Error || ErrorSet(StreamType) || vfs.Error || std.fs.File.OpenError || std.fs.File.ReadError
///     Allocator.Error       - Error when allocating memory for reading the file content.
///     ErrorSet(StreamType)  - Error when writing to the test filesystem.
///     vfs.Error             - Error with VFS operations.
///     std.fs.File.OpenError - Error when opening the test files.
///     std.fs.File.ReadError - Error when reading the test files.
///
fn testWriteTestFiles(comptime StreamType: type, fat32fs: *Fat32FS(StreamType)) (Allocator.Error || ErrorSet(StreamType) || vfs.Error || std.fs.File.OpenError || std.fs.File.ReadError)!void {
    vfs.setRoot(fat32fs.root_node.node);

    const test_path_prefix = "test/fat32";
    const files = &[_][]const u8{
        "/....leading_dots.txt",
        "/[nope].txt",
        "/A_verY_Long_File_namE_With_normal_Extension.tXt",
        "/dot.in.file.txt",
        "/file.long_ext",
        "/file.t x t",
        "/insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long.txt",
        "/large_file2.txt",
        "/nope.[x]",
        "/s  p  a  c  e  s.txt",
        "/short.txt",
        "/Sma.ll.txt",
        "/UTF16.€xt",
        "/UTF16€.txt",
    };

    inline for (files) |file| {
        // Open the test file
        const test_file = try std.fs.cwd().openFile(test_path_prefix ++ file, .{});
        defer test_file.close();

        // Read the content
        const test_file_content = try test_file.readToEndAlloc(std.testing.allocator, 0xFFFF);
        defer std.testing.allocator.free(test_file_content);

        // TODO: Once the write PR is complete, then write the files
        // // Open the test file to the FAT32 filesystem
        // const f1 = try vfs.openFile(file, .CREATE_FILE);
        // defer f1.close();

        // // Write the content
        // const written = try f1.write(test_file_content);
        // if (written != test_file_content.len) {
        //     @panic("Written not the same for content length");
        // }
    }
}

test "LongName.getName" {
    {
        const lfn = LongName{
            .order = 0x00,
            .first = [5]u16{ '1', '2', '3', '4', '5' },
            .check_sum = 0x00,
            .second = [6]u16{ '1', '2', '3', 0x0000, 0xFFFF, 0xFFFF },
            .third = [2]u16{ 0xFFFF, 0xFFFF },
        };

        // 2 * 13 u16's
        var buff: [26]u8 = undefined;
        const end = try lfn.getName(buff[0..]);
        expectEqualSlices(u8, "12345123", buff[0..end]);
    }
    {
        const lfn = LongName{
            .order = 0x00,
            .first = [5]u16{ 0x20AC, '1', 0x20AC, '2', 0x0000 },
            .check_sum = 0x00,
            .second = [6]u16{ 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF },
            .third = [2]u16{ 0xFFFF, 0xFFFF },
        };

        // 2 * 13 u16's
        var buff: [26]u8 = undefined;
        const end = try lfn.getName(buff[0..]);
        expectEqualSlices(u8, "€1€2", buff[0..end]);
    }
    {
        const lfn = LongName{
            .order = 0x00,
            .first = [5]u16{ '1', '1', '1', '1', '1' },
            .check_sum = 0x00,
            .second = [6]u16{ '1', '1', '1', '1', '1', '1' },
            .third = [2]u16{ '1', 0xD801 },
        };

        // 2 * 13 u16's
        var buff: [26]u8 = undefined;
        expectError(error.DanglingSurrogateHalf, lfn.getName(buff[0..]));
    }
    {
        const lfn = LongName{
            .order = 0x00,
            .first = [5]u16{ 0xD987, '1', 0xFFFF, 0xFFFF, 0xFFFF },
            .check_sum = 0x00,
            .second = [6]u16{ 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF },
            .third = [2]u16{ 0xFFFF, 0xFFFF },
        };

        // 2 * 13 u16's
        var buff: [26]u8 = undefined;
        expectError(error.ExpectedSecondSurrogateHalf, lfn.getName(buff[0..]));
    }
    {
        const lfn = LongName{
            .order = 0x00,
            .first = [5]u16{ 0xDD87, '1', 0xFFFF, 0xFFFF, 0xFFFF },
            .check_sum = 0x00,
            .second = [6]u16{ 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF },
            .third = [2]u16{ 0xFFFF, 0xFFFF },
        };

        // 2 * 13 u16's
        var buff: [26]u8 = undefined;
        expectError(error.UnexpectedSecondSurrogateHalf, lfn.getName(buff[0..]));
    }
}

test "ShortName.getName - File" {
    {
        const sfn = ShortName{
            .name = "12345678".*,
            .extension = "123".*,
            .attributes = 0x00,
            .time_created_tenth = 0x00,
            .time_created = 0x0000,
            .date_created = 0x0000,
            .date_last_access = 0x0000,
            .cluster_high = 0x0000,
            .time_last_modification = 0x0000,
            .date_last_modification = 0x0000,
            .cluster_low = 0x0000,
            .size = 0x00000000,
        };
        var name: [12]u8 = undefined;
        const name_end = sfn.getName(name[0..]);
        expectEqualSlices(u8, "12345678.123", name[0..name_end]);
    }
    {
        const sfn = ShortName{
            .name = "12345   ".*,
            .extension = "123".*,
            .attributes = 0x00,
            .time_created_tenth = 0x00,
            .time_created = 0x0000,
            .date_created = 0x0000,
            .date_last_access = 0x0000,
            .cluster_high = 0x0000,
            .time_last_modification = 0x0000,
            .date_last_modification = 0x0000,
            .cluster_low = 0x0000,
            .size = 0x00000000,
        };
        var name: [12]u8 = undefined;
        const name_end = sfn.getName(name[0..]);
        expectEqualSlices(u8, "12345.123", name[0..name_end]);
    }
    {
        const sfn = ShortName{
            .name = "12345   ".*,
            .extension = "1  ".*,
            .attributes = 0x00,
            .time_created_tenth = 0x00,
            .time_created = 0x0000,
            .date_created = 0x0000,
            .date_last_access = 0x0000,
            .cluster_high = 0x0000,
            .time_last_modification = 0x0000,
            .date_last_modification = 0x0000,
            .cluster_low = 0x0000,
            .size = 0x00000000,
        };
        var name: [12]u8 = undefined;
        const name_end = sfn.getName(name[0..]);
        expectEqualSlices(u8, "12345.1", name[0..name_end]);
    }
    {
        const sfn = ShortName{
            .name = "\u{05}2345   ".*,
            .extension = "1  ".*,
            .attributes = 0x00,
            .time_created_tenth = 0x00,
            .time_created = 0x0000,
            .date_created = 0x0000,
            .date_last_access = 0x0000,
            .cluster_high = 0x0000,
            .time_last_modification = 0x0000,
            .date_last_modification = 0x0000,
            .cluster_low = 0x0000,
            .size = 0x00000000,
        };
        var name: [12]u8 = undefined;
        const name_end = sfn.getName(name[0..]);
        expectEqualSlices(u8, "σ2345.1", name[0..name_end]);
    }
    {
        const sfn = ShortName{
            .name = [_]u8{ 0x90, 0xA0 } ++ "345   ".*,
            .extension = "1  ".*,
            .attributes = 0x00,
            .time_created_tenth = 0x00,
            .time_created = 0x0000,
            .date_created = 0x0000,
            .date_last_access = 0x0000,
            .cluster_high = 0x0000,
            .time_last_modification = 0x0000,
            .date_last_modification = 0x0000,
            .cluster_low = 0x0000,
            .size = 0x00000000,
        };
        var name: [12]u8 = undefined;
        const name_end = sfn.getName(name[0..]);
        expectEqualSlices(u8, "Éá345.1", name[0..name_end]);
    }
    {
        const sfn = ShortName{
            .name = "12345   ".*,
            .extension = "1".* ++ [_]u8{0xB0} ++ " ".*,
            .attributes = 0x00,
            .time_created_tenth = 0x00,
            .time_created = 0x0000,
            .date_created = 0x0000,
            .date_last_access = 0x0000,
            .cluster_high = 0x0000,
            .time_last_modification = 0x0000,
            .date_last_modification = 0x0000,
            .cluster_low = 0x0000,
            .size = 0x00000000,
        };
        var name: [12]u8 = undefined;
        const name_end = sfn.getName(name[0..]);
        expectEqualSlices(u8, "12345.1░", name[0..name_end]);
    }
}

test "ShortName.getName - Dir" {
    {
        const sfn = ShortName{
            .name = "12345678".*,
            .extension = "   ".*,
            .attributes = @enumToInt(ShortName.Attributes.Directory),
            .time_created_tenth = 0x00,
            .time_created = 0x0000,
            .date_created = 0x0000,
            .date_last_access = 0x0000,
            .cluster_high = 0x0000,
            .time_last_modification = 0x0000,
            .date_last_modification = 0x0000,
            .cluster_low = 0x0000,
            .size = 0x00000000,
        };
        var name: [12]u8 = undefined;
        const name_end = sfn.getName(name[0..]);
        expectEqualSlices(u8, "12345678", name[0..name_end]);
    }
    {
        const sfn = ShortName{
            .name = "12345   ".*,
            .extension = "   ".*,
            .attributes = @enumToInt(ShortName.Attributes.Directory),
            .time_created_tenth = 0x00,
            .time_created = 0x0000,
            .date_created = 0x0000,
            .date_last_access = 0x0000,
            .cluster_high = 0x0000,
            .time_last_modification = 0x0000,
            .date_last_modification = 0x0000,
            .cluster_low = 0x0000,
            .size = 0x00000000,
        };
        var name: [12]u8 = undefined;
        const name_end = sfn.getName(name[0..]);
        expectEqualSlices(u8, "12345", name[0..name_end]);
    }
    {
        const sfn = ShortName{
            .name = "\u{05}2345   ".*,
            .extension = "   ".*,
            .attributes = @enumToInt(ShortName.Attributes.Directory),
            .time_created_tenth = 0x00,
            .time_created = 0x0000,
            .date_created = 0x0000,
            .date_last_access = 0x0000,
            .cluster_high = 0x0000,
            .time_last_modification = 0x0000,
            .date_last_modification = 0x0000,
            .cluster_low = 0x0000,
            .size = 0x00000000,
        };
        var name: [12]u8 = undefined;
        const name_end = sfn.getName(name[0..]);
        expectEqualSlices(u8, "σ2345", name[0..name_end]);
    }
    {
        const sfn = ShortName{
            .name = "12345   ".*,
            .extension = "123".*,
            .attributes = @enumToInt(ShortName.Attributes.Directory),
            .time_created_tenth = 0x00,
            .time_created = 0x0000,
            .date_created = 0x0000,
            .date_last_access = 0x0000,
            .cluster_high = 0x0000,
            .time_last_modification = 0x0000,
            .date_last_modification = 0x0000,
            .cluster_low = 0x0000,
            .size = 0x00000000,
        };
        var name: [12]u8 = undefined;
        const name_end = sfn.getName(name[0..]);
        expectEqualSlices(u8, "12345", name[0..name_end]);
    }
}

test "ShortName.getSFNName" {
    const sfn = ShortName{
        .name = [_]u8{ 0x05, 0xAA } ++ "345   ".*,
        .extension = "1  ".*,
        .attributes = 0x00,
        .time_created_tenth = 0x00,
        .time_created = 0x0000,
        .date_created = 0x0000,
        .date_last_access = 0x0000,
        .cluster_high = 0x0000,
        .time_last_modification = 0x0000,
        .date_last_modification = 0x0000,
        .cluster_low = 0x0000,
        .size = 0x00000000,
    };
    const name = sfn.getSFNName();
    const expected = [_]u8{ 0x05, 0xAA } ++ "345   1  ";
    expectEqualSlices(u8, expected, name[0..]);
}

test "ShortName.isDir" {
    {
        const sfn = ShortName{
            .name = "12345678".*,
            .extension = "123".*,
            .attributes = @enumToInt(ShortName.Attributes.Directory),
            .time_created_tenth = 0x00,
            .time_created = 0x0000,
            .date_created = 0x0000,
            .date_last_access = 0x0000,
            .cluster_high = 0x0000,
            .time_last_modification = 0x0000,
            .date_last_modification = 0x0000,
            .cluster_low = 0x0000,
            .size = 0x00000000,
        };

        expect(sfn.isDir());
    }
    {
        const sfn = ShortName{
            .name = "12345678".*,
            .extension = "123".*,
            .attributes = @enumToInt(ShortName.Attributes.None),
            .time_created_tenth = 0x00,
            .time_created = 0x0000,
            .date_created = 0x0000,
            .date_last_access = 0x0000,
            .cluster_high = 0x0000,
            .time_last_modification = 0x0000,
            .date_last_modification = 0x0000,
            .cluster_low = 0x0000,
            .size = 0x00000000,
        };

        expect(!sfn.isDir());
    }
}

test "ShortName.getCluster" {
    const sfn = ShortName{
        .name = "12345678".*,
        .extension = "123".*,
        .attributes = @enumToInt(ShortName.Attributes.None),
        .time_created_tenth = 0x00,
        .time_created = 0x0000,
        .date_created = 0x0000,
        .date_last_access = 0x0000,
        .cluster_high = 0xABCD,
        .time_last_modification = 0x0000,
        .date_last_modification = 0x0000,
        .cluster_low = 0x1234,
        .size = 0x00000000,
    };

    expectEqual(sfn.getCluster(), 0xABCD1234);
}

test "ShortName.calcCheckSum" {
    const sfn = ShortName{
        .name = "12345678".*,
        .extension = "123".*,
        .attributes = @enumToInt(ShortName.Attributes.None),
        .time_created_tenth = 0x00,
        .time_created = 0x0000,
        .date_created = 0x0000,
        .date_last_access = 0x0000,
        .cluster_high = 0xABCD,
        .time_last_modification = 0x0000,
        .date_last_modification = 0x0000,
        .cluster_low = 0x1234,
        .size = 0x00000000,
    };

    expectEqual(sfn.calcCheckSum(), 0x7A);
}

test "Fat32FS initialise test files" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy();

    // Write the test files
    try testWriteTestFiles(@TypeOf(stream), test_fs);

    // Open the known good image to compare to
    const golden_image = try std.fs.cwd().openFile("test/fat32/golden_image.img", .{});
    defer golden_image.close();

    const golden_content = try golden_image.readToEndAlloc(std.testing.allocator, 34090496);
    defer std.testing.allocator.free(golden_content);

    expectEqualSlices(u8, test_stream_buff[0..], golden_content);
}

test "Fat32FS.getRootNode" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy();

    expectEqual(test_fs.fs.getRootNode(test_fs.fs), &test_fs.root_node.node.Dir);
    expectEqual(test_fs.root_node.cluster, 2);
    expectEqual(test_fs.fat_config.root_directory_cluster, 2);
}

test "Fat32FS.read" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy();

    // TODO: Once the read PR is done
}

test "Fat32FS.write" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy();

    // TODO: Once the write PR is done
}

test "Fat32FS.open - no create" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy();

    // Temporary add hand built files to open
    // Once write PR is done, then can test real files
    var entry_buff = [_]u8{
        // Long entry 3
        0x43, 0x6E, 0x00, 0x67, 0x00, 0x6E, 0x00, 0x61, 0x00, 0x6D, 0x00, 0x0F, 0x00, 0x6E, 0x65, 0x00,
        0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
        // Long entry 2
        0x02, 0x6E, 0x00, 0x67, 0x00, 0x76, 0x00, 0x65, 0x00, 0x72, 0x00, 0x0F, 0x00, 0x6E, 0x79, 0x00,
        0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x00, 0x00, 0x6F, 0x00, 0x6F, 0x00,
        // Long entry 1
        0x01, 0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x0F, 0x00, 0x6E, 0x6F, 0x00,
        0x6E, 0x00, 0x67, 0x00, 0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x00, 0x00, 0x6F, 0x00, 0x6F, 0x00,
        // Short entry
        0x4C, 0x4F, 0x4F, 0x4F, 0x4F, 0x4F, 0x7E, 0x31, 0x54, 0x58, 0x54, 0x00, 0x18, 0xA0, 0x68, 0xA9,
        0xFE, 0x50, 0x00, 0x00, 0x00, 0x00, 0x6E, 0xA9, 0xFE, 0x50, 0x08, 0x00, 0x13, 0x00, 0x00, 0x00,
        // Long entry 2
        0x42, 0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00, 0x00, 0x00, 0x0F, 0x00, 0xE9, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
        // Long entry 1
        0x01, 0x72, 0x00, 0x61, 0x00, 0x6D, 0x00, 0x64, 0x00, 0x69, 0x00, 0x0F, 0x00, 0xE9, 0x73, 0x00,
        0x6B, 0x00, 0x5F, 0x00, 0x74, 0x00, 0x65, 0x00, 0x73, 0x00, 0x00, 0x00, 0x74, 0x00, 0x31, 0x00,
        // Short entry
        0x52, 0x41, 0x4D, 0x44, 0x49, 0x53, 0x7E, 0x31, 0x54, 0x58, 0x54, 0x00, 0x18, 0x34, 0x47, 0x76,
        0xF9, 0x50, 0x00, 0x00, 0x00, 0x00, 0x48, 0x76, 0xF9, 0x50, 0x03, 0x00, 0x10, 0x00, 0x00, 0x00,
    };

    // Goto root dir and write a long and short entry
    const sector = test_fs.fat_config.clusterToSector(test_fs.root_node.cluster);
    try test_fs.stream.seekableStream().seekTo(sector * test_fs.fat_config.bytes_per_sector);
    try test_fs.stream.writer().writeAll(entry_buff[0..]);

    vfs.setRoot(test_fs.root_node.node);

    const file = try vfs.openFile("/ramdisk_test1.txt", .NO_CREATION);
    defer file.close();

    expect(test_fs.opened_files.contains(@ptrCast(*const vfs.Node, file)));
    const opened_info = test_fs.opened_files.get(@ptrCast(*const vfs.Node, file)).?;
    expectEqual(opened_info.cluster, 3);
    expectEqual(opened_info.size, 16);
}

test "Fat32FS.open - create file" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy();

    // TODO: Once the open and write PR is done
}

test "Fat32FS.open - create directory" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy();

    // TODO: Once the open and write PR is done
}

test "Fat32FS.open - create symlink" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy();

    // TODO: Once the open and write PR is done
}

test "Fat32FS.init no error" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy();
}

test "Fat32FS.init errors" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    // BadMBRMagic
    test_stream_buff[510] = 0x00;
    expectError(error.BadMBRMagic, initialiseFAT32(std.testing.allocator, stream));
    test_stream_buff[510] = 0x55;

    test_stream_buff[511] = 0x00;
    expectError(error.BadMBRMagic, initialiseFAT32(std.testing.allocator, stream));
    test_stream_buff[511] = 0xAA;

    // BadRootCluster
    // Little endian, so just eed to set the upper bytes
    test_stream_buff[44] = 0;
    expectError(error.BadRootCluster, initialiseFAT32(std.testing.allocator, stream));

    test_stream_buff[44] = 1;
    expectError(error.BadRootCluster, initialiseFAT32(std.testing.allocator, stream));
    test_stream_buff[44] = 2;

    // BadFATCount
    test_stream_buff[16] = 0;
    expectError(error.BadFATCount, initialiseFAT32(std.testing.allocator, stream));

    test_stream_buff[16] = 1;
    expectError(error.BadFATCount, initialiseFAT32(std.testing.allocator, stream));

    test_stream_buff[16] = 10;
    expectError(error.BadFATCount, initialiseFAT32(std.testing.allocator, stream));
    test_stream_buff[16] = 2;

    // NotMirror
    test_stream_buff[40] = 1;
    expectError(error.NotMirror, initialiseFAT32(std.testing.allocator, stream));

    test_stream_buff[40] = 10;
    expectError(error.NotMirror, initialiseFAT32(std.testing.allocator, stream));
    test_stream_buff[40] = 0;

    // BadMedia
    test_stream_buff[21] = 0xF0;
    expectError(error.BadMedia, initialiseFAT32(std.testing.allocator, stream));
    test_stream_buff[21] = 0xF8;

    // BadFat32
    test_stream_buff[17] = 10;
    expectError(error.BadFat32, initialiseFAT32(std.testing.allocator, stream));
    test_stream_buff[17] = 0;

    test_stream_buff[19] = 10;
    expectError(error.BadFat32, initialiseFAT32(std.testing.allocator, stream));
    test_stream_buff[19] = 0;

    test_stream_buff[22] = 10;
    expectError(error.BadFat32, initialiseFAT32(std.testing.allocator, stream));
    test_stream_buff[22] = 0;

    // BadSignature
    test_stream_buff[66] = 0x28;
    expectError(error.BadSignature, initialiseFAT32(std.testing.allocator, stream));
    test_stream_buff[66] = 0x29;

    // BadFSType
    // Change from FAT32 to FAT16
    test_stream_buff[85] = '1';
    test_stream_buff[86] = '6';
    expectError(error.BadFSType, initialiseFAT32(std.testing.allocator, stream));
    test_stream_buff[85] = '3';
    test_stream_buff[86] = '2';

    // Test the bad reads
    // Boot sector
    expectError(error.BadRead, initialiseFAT32(std.testing.allocator, &std.io.fixedBufferStream(test_stream_buff[0..510])));
    // FSInfo (we have one)
    expectError(error.BadRead, initialiseFAT32(std.testing.allocator, &std.io.fixedBufferStream(test_stream_buff[0 .. 512 + 100])));
    // FAT
    expectError(error.BadRead, initialiseFAT32(std.testing.allocator, &std.io.fixedBufferStream(test_stream_buff[0 .. (32 * 512 + 4) + 1])));
}

test "Fat32FS.init memory" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    const allocations: usize = 5;
    var i: usize = 0;
    while (i < allocations) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, i);

        expectError(error.OutOfMemory, initialiseFAT32(&fa.allocator, stream));
    }
}

test "Fat32FS.init FATConfig expected" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy();

    // This is the default config that should be produced from mkfat32.Fat32
    const expected = FATConfig{
        .bytes_per_sector = 512,
        .sectors_per_cluster = 1,
        .reserved_sectors = 32,
        .hidden_sectors = 0,
        .total_sectors = 66583,
        .sectors_per_fat = 513,
        .root_directory_cluster = 2,
        .fsinfo_sector = 1,
        .backup_boot_sector = 6,
        .has_fs_info = true,
        .number_free_clusters = 65524,
        .next_free_cluster = 2,
        .cluster_end_marker = 0x0FFFFFFF,
    };

    expectEqual(expected, test_fs.fat_config);
}

test "Fat32FS.init FATConfig mix FSInfo" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    // No FSInfo
    {
        // Force no FSInfo
        test_stream_buff[48] = 0x00;

        var test_fs = try initialiseFAT32(std.testing.allocator, stream);
        defer test_fs.destroy();

        // This is the default config that should be produced from mkfat32.Fat32
        const expected = FATConfig{
            .bytes_per_sector = 512,
            .sectors_per_cluster = 1,
            .reserved_sectors = 32,
            .hidden_sectors = 0,
            .total_sectors = 66583,
            .sectors_per_fat = 513,
            .root_directory_cluster = 2,
            .fsinfo_sector = 0,
            .backup_boot_sector = 6,
            .has_fs_info = false,
            .number_free_clusters = 0xFFFFFFFF,
            .next_free_cluster = 0xFFFFFFFF,
            .cluster_end_marker = 0x0FFFFFFF,
        };

        expectEqual(expected, test_fs.fat_config);
        test_stream_buff[48] = 0x01;
    }

    // Bad Signatures
    {
        // Corrupt a signature
        test_stream_buff[512] = 0xAA;

        var test_fs = try initialiseFAT32(std.testing.allocator, stream);
        defer test_fs.destroy();

        // This is the default config that should be produced from mkfat32.Fat32
        const expected = FATConfig{
            .bytes_per_sector = 512,
            .sectors_per_cluster = 1,
            .reserved_sectors = 32,
            .hidden_sectors = 0,
            .total_sectors = 66583,
            .sectors_per_fat = 513,
            .root_directory_cluster = 2,
            .fsinfo_sector = 1,
            .backup_boot_sector = 6,
            .has_fs_info = false,
            .number_free_clusters = 0xFFFFFFFF,
            .next_free_cluster = 0xFFFFFFFF,
            .cluster_end_marker = 0x0FFFFFFF,
        };

        expectEqual(expected, test_fs.fat_config);
        test_stream_buff[512] = 0x52;
    }

    // Bad number_free_clusters
    {
        // Make is massive
        test_stream_buff[512 + 4 + 480 + 4] = 0xAA;
        test_stream_buff[512 + 4 + 480 + 5] = 0xBB;
        test_stream_buff[512 + 4 + 480 + 6] = 0xCC;
        test_stream_buff[512 + 4 + 480 + 7] = 0xDD;

        var test_fs = try initialiseFAT32(std.testing.allocator, stream);
        defer test_fs.destroy();

        // This is the default config that should be produced from mkfat32.Fat32
        const expected = FATConfig{
            .bytes_per_sector = 512,
            .sectors_per_cluster = 1,
            .reserved_sectors = 32,
            .hidden_sectors = 0,
            .total_sectors = 66583,
            .sectors_per_fat = 513,
            .root_directory_cluster = 2,
            .fsinfo_sector = 1,
            .backup_boot_sector = 6,
            .has_fs_info = true,
            .number_free_clusters = 0xFFFFFFFF,
            .next_free_cluster = 2,
            .cluster_end_marker = 0x0FFFFFFF,
        };

        expectEqual(expected, test_fs.fat_config);
        test_stream_buff[512 + 4 + 480 + 4] = 0xF4;
        test_stream_buff[512 + 4 + 480 + 5] = 0xFF;
        test_stream_buff[512 + 4 + 480 + 6] = 0x00;
        test_stream_buff[512 + 4 + 480 + 7] = 0x00;
    }
}

test "ClusterChainIterator.checkRead - Within cluster, within FAT" {
    // The undefined values are not used in checkRead
    const fat_config = FATConfig{
        .bytes_per_sector = 16,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = undefined,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = undefined,
    };
    var buff_stream = [_]u8{};
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    // First 2 are for other purposed and not needed, the third is the first real FAT entry
    var fat = [_]u32{ 0x0FFFFFFF, 0xFFFFFFF8, 0xFFFFFFFF, 0x00000000 };
    var it = Fat32FS(@TypeOf(stream)).ClusterChainIterator{
        .allocator = undefined,
        .cluster = 2,
        .fat_config = fat_config,
        .stream = stream,
        .fat = fat[0..],
        .table_offset = 0,
        .cluster_offset = 0,
    };

    try it.checkRead();

    // Nothing changed
    expectEqual(it.cluster, 2);
    expectEqual(it.cluster_offset, 0);
    expectEqual(it.table_offset, 0);
    expectEqualSlices(u32, it.fat, fat[0..]);
}

test "ClusterChainIterator.checkRead - Multiple clusters, within FAT" {
    // The undefined values are not used in checkRead
    // The value won't be valid FAT32 values, but this doesn't matter in this context so can make the stream buffer smaller
    const fat_config = FATConfig{
        .bytes_per_sector = 16,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = undefined,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = undefined,
    };
    var buff_stream = [_]u8{};
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    // First 2 are for other purposed and not needed, the third is the first real FAT entry
    var fat = [_]u32{ 0x0FFFFFFF, 0xFFFFFFF8, 0x00000003, 0xFFFFFFFF };
    var it = Fat32FS(@TypeOf(stream)).ClusterChainIterator{
        .allocator = undefined,
        .cluster = 2,
        .fat_config = fat_config,
        .stream = stream,
        .fat = fat[0..],
        .table_offset = 0,
        .cluster_offset = 16,
    };

    // This will update the next cluster to read from
    try it.checkRead();

    // Updated the cluster only
    expectEqual(it.cluster, 3);
    expectEqual(it.cluster_offset, 0);
    expectEqual(it.table_offset, 0);
    expectEqualSlices(u32, it.fat, fat[0..]);
}

test "ClusterChainIterator.checkRead - Multiple clusters, outside FAT" {
    // The undefined values are not used in checkRead
    // The value won't be valid FAT32 values, but this doesn't matter in this context so can make the stream buffer smaller
    const fat_config = FATConfig{
        .bytes_per_sector = 16,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    // Set the stream to all FF which represents the end of a FAT chain
    var buff_stream = [_]u8{
        // First 4 FAT (little endian)
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x04, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Second 4 FAT. This is where it will seek to
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    // First 2 are for other purposed and not needed, the third is the first real FAT entry
    var fat = [_]u32{ 0x0FFFFFFF, 0xFFFFFFF8, 0x00000004, 0xFFFFFFFF };
    var expected_fat = [_]u32{ 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF };
    var it = Fat32FS(@TypeOf(stream)).ClusterChainIterator{
        .allocator = undefined,
        .cluster = 2,
        .fat_config = fat_config,
        .stream = stream,
        .fat = fat[0..],
        .table_offset = 0,
        .cluster_offset = 16,
    };

    // This will read the next cluster and read a new FAT cache
    try it.checkRead();

    // Updated the cluster and table offset
    expectEqual(it.cluster, 4);
    expectEqual(it.cluster_offset, 0);
    expectEqual(it.table_offset, 1);
    expectEqualSlices(u32, it.fat, expected_fat[0..]);
}

test "ClusterChainIterator.read - end of buffer" {
    var stream = &std.io.fixedBufferStream(&[_]u8{});
    var it = Fat32FS(@TypeOf(stream)).ClusterChainIterator{
        .allocator = undefined,
        .cluster = undefined,
        .fat_config = undefined,
        .stream = undefined,
        .fat = undefined,
        .table_offset = undefined,
        .cluster_offset = undefined,
    };
    const actual = try it.read(&[_]u8{});
    expectEqual(actual, null);
}

test "ClusterChainIterator.read - cluster 0" {
    var stream = &std.io.fixedBufferStream(&[_]u8{});
    var it = Fat32FS(@TypeOf(stream)).ClusterChainIterator{
        .allocator = undefined,
        .cluster = 0,
        .fat_config = undefined,
        .stream = undefined,
        .fat = undefined,
        .table_offset = undefined,
        .cluster_offset = undefined,
    };
    var buff: [128]u8 = undefined;
    const actual = try it.read(buff[0..]);
    expectEqual(actual, null);
}

test "ClusterChainIterator.read - end of cluster chain" {
    // The undefined values are not used in read
    const end_cluster: u32 = 0x0FFFFFFF;
    const fat_config = FATConfig{
        .bytes_per_sector = undefined,
        .sectors_per_cluster = undefined,
        .reserved_sectors = undefined,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = undefined,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = end_cluster,
    };
    var stream = &std.io.fixedBufferStream(&[_]u8{});
    var it = Fat32FS(@TypeOf(stream)).ClusterChainIterator{
        .allocator = undefined,
        .cluster = end_cluster,
        .fat_config = fat_config,
        .stream = undefined,
        .fat = undefined,
        .table_offset = undefined,
        .cluster_offset = undefined,
    };
    var buff: [128]u8 = undefined;
    const actual = try it.read(buff[0..]);
    expectEqual(actual, null);
}

test "ClusterChainIterator.read - BadRead" {
    // The undefined values are not used in read
    const fat_config = FATConfig{
        .bytes_per_sector = 512,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    var stream_buff: [1024]u8 = undefined;
    var stream = &std.io.fixedBufferStream(stream_buff[0..]);
    var it = Fat32FS(@TypeOf(stream)).ClusterChainIterator{
        .allocator = undefined,
        .cluster = 2,
        .fat_config = fat_config,
        .stream = stream,
        .fat = undefined,
        .table_offset = 0,
        .cluster_offset = 0,
    };
    // Buffer is too small
    var buff: [128]u8 = undefined;
    expectError(error.BadRead, it.read(buff[0..]));
}

test "ClusterChainIterator.read - success" {
    // The undefined values are not used in checkRead
    // The value won't be valid FAT32 values, but this doesn't matter in this context so can make the stream buffer smaller
    const fat_config = FATConfig{
        .bytes_per_sector = 16,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };

    var buff_stream = [_]u8{
        // FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region
        'a',  'b',  'c',  'd',
        '1',  '2',  '3',  '4',
        'A',  'B',  'C',  'D',
        '!',  '"',  '$',  '%',
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    // First 2 are for other purposed and not needed, the third is the first real FAT entry
    var fat = [_]u32{ 0x0FFFFFFF, 0xFFFFFFF8, 0xFFFFFFFF, 0xFFFFFFFF };
    var expected_fat = [_]u32{ 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF };
    var it = Fat32FS(@TypeOf(stream)).ClusterChainIterator{
        .allocator = undefined,
        .cluster = 2,
        .fat_config = fat_config,
        .stream = stream,
        .fat = fat[0..],
        .table_offset = 0,
        .cluster_offset = 0,
    };

    var buff: [16]u8 = undefined;
    const read = try it.read(buff[0..]);

    expectEqual(read, 16);
    expectEqualSlices(u8, buff[0..], "abcd1234ABCD!\"$%");
    expectEqual(it.table_offset, 0);
    expectEqual(it.cluster_offset, 0);
    expectEqual(it.cluster, 0xFFFFFFFF);
}

test "ClusterChainIterator.init - free on BadRead" {
    const fat_config = FATConfig{
        .bytes_per_sector = 16,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = undefined,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    var stream = &std.io.fixedBufferStream(&[_]u8{});
    expectError(error.BadRead, Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(std.testing.allocator, fat_config, 2, stream));
}

test "ClusterChainIterator.init - free on OutOfMemory" {
    const fat_config = FATConfig{
        .bytes_per_sector = 16,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    var buff_stream = [_]u8{
        // FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region
        'a',  'b',  'c',  'd',
        '1',  '2',  '3',  '4',
        'A',  'B',  'C',  'D',
        '!',  '"',  '$',  '%',
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    const allocations: usize = 1;

    var i: usize = 0;
    while (i < allocations) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, i);
        expectError(error.OutOfMemory, Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(&fa.allocator, fat_config, 2, stream));
    }
}

test "ClusterChainIterator.init - success and good read" {
    const fat_config = FATConfig{
        .bytes_per_sector = 16,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    var buff_stream = [_]u8{
        // FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region
        'a',  'b',  'c',  'd',
        '1',  '2',  '3',  '4',
        'A',  'B',  'C',  'D',
        '!',  '"',  '$',  '%',
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var it = try Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(std.testing.allocator, fat_config, 2, stream);
    defer it.deinit();

    var buff: [16]u8 = undefined;
    // If orelse, then 'expectEqual(read, 16);' will fail
    const read = (try it.read(buff[0..])) orelse 0;

    expectEqual(read, 16);
    expectEqualSlices(u8, buff[0..], "abcd1234ABCD!\"$%");
    expectEqual(it.table_offset, 0);
    expectEqual(it.cluster_offset, 0);
    expectEqual(it.cluster, 0xFFFFFFFF);

    const expect_null = try it.read(buff[read..]);
    expectEqual(expect_null, null);
}

test "EntryIterator.checkRead - inside cluster block" {
    const fat_config = FATConfig{
        .bytes_per_sector = 16,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    var buff_stream = [_]u8{
        // FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x04, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region cluster 1
        'a',  'b',  'c',  'd',
        '1',  '2',  '3',  '4',
        'A',  'B',  'C',  'D',
        '!',  '"',  '$',  '%',
        // Data region cluster 2
        'e',  'f',  'g',  'h',
        '5',  '6',  '7',  '8',
        'E',  'F',  'G',  'H',
        '^',  '&',  '*',  '(',
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var cluster_chain = try Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(std.testing.allocator, fat_config, 2, stream);
    defer cluster_chain.deinit();

    var buff: [16]u8 = undefined;
    std.mem.copy(u8, buff[0..], buff_stream[32..48]);
    var it = Fat32FS(@TypeOf(cluster_chain.stream)).EntryIterator{
        .allocator = undefined,
        .cluster_block = buff[0..],
        .index = 0,
        .cluster_chain = cluster_chain,
    };

    expectEqualSlices(u8, it.cluster_block, "abcd1234ABCD!\"$%");
    try it.checkRead();
    // nothing changed
    expectEqualSlices(u8, it.cluster_block, "abcd1234ABCD!\"$%");
}

test "EntryIterator.checkRead - read new cluster" {
    const fat_config = FATConfig{
        .bytes_per_sector = 16,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    var buff_stream = [_]u8{
        // FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region cluster 1
        'a',  'b',  'c',  'd',
        '1',  '2',  '3',  '4',
        'A',  'B',  'C',  'D',
        '!',  '"',  '$',  '%',
        // Data region cluster 2
        'e',  'f',  'g',  'h',
        '5',  '6',  '7',  '8',
        'E',  'F',  'G',  'H',
        '^',  '&',  '*',  '(',
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var cluster_chain = try Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(std.testing.allocator, fat_config, 2, stream);
    defer cluster_chain.deinit();

    var buff: [16]u8 = undefined;
    _ = try cluster_chain.read(buff[0..]);

    var it = Fat32FS(@TypeOf(cluster_chain.stream)).EntryIterator{
        .allocator = undefined,
        .cluster_block = buff[0..],
        .index = 16,
        .cluster_chain = cluster_chain,
    };

    expectEqualSlices(u8, it.cluster_block, "abcd1234ABCD!\"$%");
    try it.checkRead();
    expectEqualSlices(u8, it.cluster_block, "efgh5678EFGH^&*(");
    expectEqual(it.index, 0);
}

test "EntryIterator.checkRead - end of cluster chain" {
    const fat_config = FATConfig{
        .bytes_per_sector = 16,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    var buff_stream = [_]u8{
        // FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region cluster 1
        'a',  'b',  'c',  'd',
        '1',  '2',  '3',  '4',
        'A',  'B',  'C',  'D',
        '!',  '"',  '$',  '%',
        // Data region cluster 2
        'e',  'f',  'g',  'h',
        '5',  '6',  '7',  '8',
        'E',  'F',  'G',  'H',
        '^',  '&',  '*',  '(',
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var cluster_chain = try Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(std.testing.allocator, fat_config, 2, stream);
    defer cluster_chain.deinit();

    var buff: [16]u8 = undefined;
    _ = try cluster_chain.read(buff[0..]);

    var it = Fat32FS(@TypeOf(cluster_chain.stream)).EntryIterator{
        .allocator = undefined,
        .cluster_block = buff[0..],
        .index = 16,
        .cluster_chain = cluster_chain,
    };

    expectEqualSlices(u8, it.cluster_block, "abcd1234ABCD!\"$%");
    expectError(error.EndClusterChain, it.checkRead());
}

test "EntryIterator.nextImp - end of entries" {
    const fat_config = FATConfig{
        .bytes_per_sector = 32,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    var buff_stream = [_]u8{
        // FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region cluster 1
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        // Data region cluster 2
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var cluster_chain = try Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(std.testing.allocator, fat_config, 2, stream);
    defer cluster_chain.deinit();

    var buff: [32]u8 = undefined;
    _ = try cluster_chain.read(buff[0..]);

    var it = Fat32FS(@TypeOf(cluster_chain.stream)).EntryIterator{
        .allocator = undefined,
        .cluster_block = buff[0..],
        .index = 0,
        .cluster_chain = cluster_chain,
    };

    const actual = try it.nextImp();
    expectEqual(actual, null);
}

test "EntryIterator.nextImp - just deleted files" {
    const fat_config = FATConfig{
        .bytes_per_sector = 32,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    // These deleted files are taken from a real FAT32 implementation. There is one deleted file for cluster 2
    // This will also read the next cluster chain.
    var buff_stream = [_]u8{
        // FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region cluster 1
        0xE5, 0x41, 0x4D, 0x44,
        0x49, 0x53, 0x7E, 0x32,
        0x54, 0x58, 0x54, 0x00,
        0x18, 0x34, 0x47, 0x76,
        0xF9, 0x50, 0x00, 0x00,
        0x00, 0x00, 0x48, 0x76,
        0xF9, 0x50, 0x04, 0x00,
        0x24, 0x00, 0x00, 0x00,
        // Data region cluster 2
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var cluster_chain = try Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(std.testing.allocator, fat_config, 2, stream);
    defer cluster_chain.deinit();

    var buff: [32]u8 = undefined;
    _ = try cluster_chain.read(buff[0..]);

    var it = Fat32FS(@TypeOf(cluster_chain.stream)).EntryIterator{
        .allocator = undefined,
        .cluster_block = buff[0..],
        .index = 0,
        .cluster_chain = cluster_chain,
    };

    const actual = try it.nextImp();
    expectEqual(actual, null);
}

test "EntryIterator.nextImp - short name only" {
    const fat_config = FATConfig{
        .bytes_per_sector = 32,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    // This short name files are taken from a real FAT32 implementation.
    // This will also read the next cluster chain.
    var buff_stream = [_]u8{
        // FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region cluster 1
        0x42, 0x53, 0x48, 0x4F,
        0x52, 0x54, 0x20, 0x20,
        0x54, 0x58, 0x54, 0x00,
        0x10, 0xA0, 0x68, 0xA9,
        0xFE, 0x50, 0x00, 0x00,
        0x00, 0x00, 0x6E, 0xA9,
        0xFE, 0x50, 0x04, 0x00,
        0x13, 0x00, 0x00, 0x00,
        // Data region cluster 2
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var cluster_chain = try Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(std.testing.allocator, fat_config, 2, stream);
    defer cluster_chain.deinit();

    var buff: [32]u8 = undefined;
    _ = try cluster_chain.read(buff[0..]);

    var it = Fat32FS(@TypeOf(cluster_chain.stream)).EntryIterator{
        .allocator = undefined,
        .cluster_block = buff[0..],
        .index = 0,
        .cluster_chain = cluster_chain,
    };

    const actual = (try it.nextImp()) orelse return error.TestFail;
    defer actual.deinit();
    expectEqualSlices(u8, actual.short_name.getSFNName()[0..], "BSHORT  TXT");
    expectEqual(actual.long_name, null);
}

test "EntryIterator.nextImp - long name only" {
    const fat_config = FATConfig{
        .bytes_per_sector = 32,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    // This short name files are taken from a real FAT32 implementation.
    // This will also read the next cluster chain.
    // FAT 2 long then blank
    // FAT 4 2 long entries, no associated short
    var buff_stream = [_]u8{
        // FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0x05, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0x05, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region cluster 1
        0x41, 0x42, 0x00, 0x73,
        0x00, 0x68, 0x00, 0x6F,
        0x00, 0x72, 0x00, 0x0F,
        0x00, 0xA8, 0x74, 0x00,
        0x2E, 0x00, 0x74, 0x00,
        0x78, 0x00, 0x74, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region cluster 2
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        // Data region cluster 3
        0x41, 0x42, 0x00, 0x73,
        0x00, 0x68, 0x00, 0x6F,
        0x00, 0x72, 0x00, 0x0F,
        0x00, 0xA8, 0x74, 0x00,
        0x2E, 0x00, 0x74, 0x00,
        0x78, 0x00, 0x74, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region cluster 4
        0x41, 0x42, 0x00, 0x73,
        0x00, 0x68, 0x00, 0x6F,
        0x00, 0x72, 0x00, 0x0F,
        0x00, 0xA8, 0x74, 0x00,
        0x2E, 0x00, 0x74, 0x00,
        0x78, 0x00, 0x74, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
    };
    // FAT 2 test
    {
        var stream = &std.io.fixedBufferStream(buff_stream[0..]);
        var cluster_chain = try Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(std.testing.allocator, fat_config, 2, stream);
        defer cluster_chain.deinit();

        var buff: [32]u8 = undefined;
        _ = try cluster_chain.read(buff[0..]);

        var it = Fat32FS(@TypeOf(cluster_chain.stream)).EntryIterator{
            .allocator = std.testing.allocator,
            .cluster_block = buff[0..],
            .index = 0,
            .cluster_chain = cluster_chain,
        };

        expectError(error.Orphan, it.nextImp());
    }

    // FAT 4 test
    {
        var stream = &std.io.fixedBufferStream(buff_stream[0..]);
        var cluster_chain = try Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(std.testing.allocator, fat_config, 4, stream);
        defer cluster_chain.deinit();

        var buff: [32]u8 = undefined;
        _ = try cluster_chain.read(buff[0..]);

        var it = Fat32FS(@TypeOf(cluster_chain.stream)).EntryIterator{
            .allocator = std.testing.allocator,
            .cluster_block = buff[0..],
            .index = 0,
            .cluster_chain = cluster_chain,
        };

        expectError(error.Orphan, it.nextImp());
    }
}

test "EntryIterator.nextImp - long name, incorrect check sum" {
    const fat_config = FATConfig{
        .bytes_per_sector = 32,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    // Values taken from a real FAT32 implementation
    // In data region cluster 1, row 4 column 2,
    // this has changed from the valid 0xA8 to a invalid 0x55 check sum
    var buff_stream = [_]u8{
        // FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region cluster 1
        0x41, 0x42, 0x00, 0x73,
        0x00, 0x68, 0x00, 0x6F,
        0x00, 0x72, 0x00, 0x0F,
        0x00, 0x55, 0x74, 0x00,
        0x2E, 0x00, 0x74, 0x00,
        0x78, 0x00, 0x74, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region cluster 2
        0x42, 0x53, 0x48, 0x4F,
        0x52, 0x54, 0x20, 0x20,
        0x54, 0x58, 0x54, 0x00,
        0x10, 0xA0, 0x68, 0xA9,
        0xFE, 0x50, 0x00, 0x00,
        0x00, 0x00, 0x6E, 0xA9,
        0xFE, 0x50, 0x04, 0x00,
        0x13, 0x00, 0x00, 0x00,
        // Data region cluster 3
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var cluster_chain = try Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(std.testing.allocator, fat_config, 2, stream);
    defer cluster_chain.deinit();

    var buff: [32]u8 = undefined;
    _ = try cluster_chain.read(buff[0..]);

    var it = Fat32FS(@TypeOf(cluster_chain.stream)).EntryIterator{
        .allocator = std.testing.allocator,
        .cluster_block = buff[0..],
        .index = 0,
        .cluster_chain = cluster_chain,
    };

    expectError(error.Orphan, it.nextImp());
}

test "EntryIterator.nextImp - long name missing entry" {
    // 0x43
    // 0x01
    // missing 0x02
    const fat_config = FATConfig{
        .bytes_per_sector = 32,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    // Values taken from a real FAT32 implementation
    // In data region cluster 1, row 4 column 2,
    // this has changed from the valid 0xA8 to a invalid 0x55 check sum
    var buff_stream = [_]u8{
        // FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region cluster 1
        0x43, 0x6E, 0x00, 0x67,
        0x00, 0x6E, 0x00, 0x61,
        0x00, 0x6D, 0x00, 0x0F,
        0x00, 0x6E, 0x65, 0x00,
        0x2E, 0x00, 0x74, 0x00,
        0x78, 0x00, 0x74, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region cluster 2
        0x01, 0x6C, 0x00, 0x6F,
        0x00, 0x6F, 0x00, 0x6F,
        0x00, 0x6F, 0x00, 0x0F,
        0x00, 0x6E, 0x6F, 0x00,
        0x6E, 0x00, 0x67, 0x00,
        0x6C, 0x00, 0x6F, 0x00,
        0x6F, 0x00, 0x00, 0x00,
        0x6F, 0x00, 0x6F, 0x00,
        // Data region cluster 3
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var cluster_chain = try Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(std.testing.allocator, fat_config, 2, stream);
    defer cluster_chain.deinit();

    var buff: [32]u8 = undefined;
    _ = try cluster_chain.read(buff[0..]);

    var it = Fat32FS(@TypeOf(cluster_chain.stream)).EntryIterator{
        .allocator = std.testing.allocator,
        .cluster_block = buff[0..],
        .index = 0,
        .cluster_chain = cluster_chain,
    };

    expectError(error.Orphan, it.nextImp());
}

test "EntryIterator.nextImp - valid short and long entry" {
    const fat_config = FATConfig{
        .bytes_per_sector = 32,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    // Values taken from a real FAT32 implementation
    var buff_stream = [_]u8{
        // FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region cluster 1
        0x43, 0x6E, 0x00, 0x67,
        0x00, 0x6E, 0x00, 0x61,
        0x00, 0x6D, 0x00, 0x0F,
        0x00, 0x6E, 0x65, 0x00,
        0x2E, 0x00, 0x74, 0x00,
        0x78, 0x00, 0x74, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region cluster 2
        0x02, 0x6E, 0x00, 0x67,
        0x00, 0x76, 0x00, 0x65,
        0x00, 0x72, 0x00, 0x0F,
        0x00, 0x6E, 0x79, 0x00,
        0x6C, 0x00, 0x6F, 0x00,
        0x6F, 0x00, 0x6F, 0x00,
        0x6F, 0x00, 0x00, 0x00,
        0x6F, 0x00, 0x6F, 0x00,
        // Data region cluster 3
        0x01, 0x6C, 0x00, 0x6F,
        0x00, 0x6F, 0x00, 0x6F,
        0x00, 0x6F, 0x00, 0x0F,
        0x00, 0x6E, 0x6F, 0x00,
        0x6E, 0x00, 0x67, 0x00,
        0x6C, 0x00, 0x6F, 0x00,
        0x6F, 0x00, 0x00, 0x00,
        0x6F, 0x00, 0x6F, 0x00,
        // Data region cluster 4
        0x4C, 0x4F, 0x4F, 0x4F,
        0x4F, 0x4F, 0x7E, 0x31,
        0x54, 0x58, 0x54, 0x00,
        0x18, 0xA0, 0x68, 0xA9,
        0xFE, 0x50, 0x00, 0x00,
        0x00, 0x00, 0x6E, 0xA9,
        0xFE, 0x50, 0x08, 0x00,
        0x13, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var cluster_chain = try Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(std.testing.allocator, fat_config, 2, stream);
    defer cluster_chain.deinit();

    var buff: [32]u8 = undefined;
    _ = try cluster_chain.read(buff[0..]);

    var it = Fat32FS(@TypeOf(cluster_chain.stream)).EntryIterator{
        .allocator = std.testing.allocator,
        .cluster_block = buff[0..],
        .index = 0,
        .cluster_chain = cluster_chain,
    };

    const actual = (try it.nextImp()) orelse return error.TestFail;
    defer actual.deinit();
    expectEqualSlices(u8, actual.short_name.getSFNName()[0..], "LOOOOO~1TXT");
    expectEqualSlices(u8, actual.long_name.?, "looooongloooongveryloooooongname.txt");
}

test "EntryIterator.next - skips orphan long entry" {
    const fat_config = FATConfig{
        .bytes_per_sector = 32,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    // Values taken from a real FAT32 implementation
    var buff_stream = [_]u8{
        // FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00,
        0x06, 0x00, 0x00, 0x00,
        0x07, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00,
        0x06, 0x00, 0x00, 0x00,
        0x07, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region cluster 1
        0x43, 0x6E, 0x00, 0x67,
        0x00, 0x6E, 0x00, 0x61,
        0x00, 0x6D, 0x00, 0x0F,
        0x00, 0x6E, 0x65, 0x00,
        0x2E, 0x00, 0x74, 0x00,
        0x78, 0x00, 0x74, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Missing 0x02
        // Data region cluster 2
        0x01, 0x6C, 0x00, 0x6F,
        0x00, 0x6F, 0x00, 0x6F,
        0x00, 0x6F, 0x00, 0x0F,
        0x00, 0x6E, 0x6F, 0x00,
        0x6E, 0x00, 0x67, 0x00,
        0x6C, 0x00, 0x6F, 0x00,
        0x6F, 0x00, 0x00, 0x00,
        0x6F, 0x00, 0x6F, 0x00,
        // Data region cluster 3
        0x4C, 0x4F, 0x4F, 0x4F,
        0x4F, 0x4F, 0x7E, 0x31,
        0x54, 0x58, 0x54, 0x00,
        0x18, 0xA0, 0x68, 0xA9,
        0xFE, 0x50, 0x00, 0x00,
        0x00, 0x00, 0x6E, 0xA9,
        0xFE, 0x50, 0x08, 0x00,
        0x13, 0x00, 0x00, 0x00,
        // Data region cluster 4
        0x42, 0x2E, 0x00, 0x74,
        0x00, 0x78, 0x00, 0x74,
        0x00, 0x00, 0x00, 0x0F,
        0x00, 0xE9, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region cluster 5
        0x01, 0x72, 0x00, 0x61,
        0x00, 0x6D, 0x00, 0x64,
        0x00, 0x69, 0x00, 0x0F,
        0x00, 0xE9, 0x73, 0x00,
        0x6B, 0x00, 0x5F, 0x00,
        0x74, 0x00, 0x65, 0x00,
        0x73, 0x00, 0x00, 0x00,
        0x74, 0x00, 0x31, 0x00,
        // Data region cluster 6
        0x52, 0x41, 0x4D, 0x44,
        0x49, 0x53, 0x7E, 0x31,
        0x54, 0x58, 0x54, 0x00,
        0x18, 0x34, 0x47, 0x76,
        0xF9, 0x50, 0x00, 0x00,
        0x00, 0x00, 0x48, 0x76,
        0xF9, 0x50, 0x03, 0x00,
        0x10, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var cluster_chain = try Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(std.testing.allocator, fat_config, 2, stream);
    defer cluster_chain.deinit();

    var buff: [32]u8 = undefined;
    _ = try cluster_chain.read(buff[0..]);

    var it = Fat32FS(@TypeOf(cluster_chain.stream)).EntryIterator{
        .allocator = std.testing.allocator,
        .cluster_block = buff[0..],
        .index = 0,
        .cluster_chain = cluster_chain,
    };

    const actual1 = (try it.next()) orelse return error.TestFail;
    defer actual1.deinit();
    expectEqualSlices(u8, actual1.short_name.getSFNName()[0..], "LOOOOO~1TXT");
    expectEqual(actual1.long_name, null);

    const actual2 = (try it.next()) orelse return error.TestFail;
    defer actual2.deinit();
    expectEqualSlices(u8, actual2.short_name.getSFNName()[0..], "RAMDIS~1TXT");
    expectEqualSlices(u8, actual2.long_name.?, "ramdisk_test1.txt");

    expectEqual(try it.next(), null);
}

test "EntryIterator.init - free on OutOfMemory" {
    const fat_config = FATConfig{
        .bytes_per_sector = 16,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    var buff_stream = [_]u8{
        // FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region
        'a',  'b',  'c',  'd',
        '1',  '2',  '3',  '4',
        'A',  'B',  'C',  'D',
        '!',  '"',  '$',  '%',
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    const allocations: usize = 2;

    var i: usize = 0;
    while (i < allocations) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, i);
        expectError(error.OutOfMemory, Fat32FS(@TypeOf(stream)).EntryIterator.init(&fa.allocator, fat_config, 2, stream));
    }
}

test "EntryIterator.init - free on BadRead" {
    const fat_config = FATConfig{
        .bytes_per_sector = 16,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = undefined,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    var buff_stream = [_]u8{
        // FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F,
        0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        // Data region (too short)
        'a',  'b',  'c',  'd',
        '1',  '2',  '3',  '4',
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    expectError(error.BadRead, Fat32FS(@TypeOf(stream)).EntryIterator.init(std.testing.allocator, fat_config, 2, stream));
}

test "Fat32FS.getDirCluster - root dir" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy();

    var test_node_1 = try test_fs.createNode(3, 16, .CREATE_FILE, .{});
    defer test_node_1.File.close();

    const actual = try test_fs.getDirCluster(&test_fs.root_node.node.Dir);
    expectEqual(actual, 2);
}

test "Fat32FS.getDirCluster - sub dir" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy();

    var test_node_1 = try test_fs.createNode(5, 0, .CREATE_DIR, .{});
    defer {
        const elem = test_fs.opened_files.remove(test_node_1).?.value;
        std.testing.allocator.destroy(elem);
        std.testing.allocator.destroy(test_node_1);
    }

    const actual = try test_fs.getDirCluster(&test_node_1.Dir);
    expectEqual(actual, 5);
}

test "Fat32FS.getDirCluster - not opened dir" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy();

    var test_node_1 = try test_fs.createNode(5, 0, .CREATE_DIR, .{});
    const elem = test_fs.opened_files.remove(test_node_1).?.value;
    std.testing.allocator.destroy(elem);

    expectError(error.NotOpened, test_fs.getDirCluster(&test_node_1.Dir));
    std.testing.allocator.destroy(test_node_1);
}

test "Fat32FS.openImpl - entry iterator failed init" {
    // Will need to fail the 8th allocation
    const allocations: usize = 8;
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, allocations);
    const allocator = &fa.allocator;

    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(allocator, stream);
    defer test_fs.destroy();

    var test_node_1 = try test_fs.createNode(5, 0, .CREATE_DIR, .{});
    defer {
        const elem = test_fs.opened_files.remove(test_node_1).?.value;
        allocator.destroy(elem);
        allocator.destroy(test_node_1);
    }

    expectError(error.OutOfMemory, Fat32FS(@TypeOf(stream)).openImpl(test_fs.fs, &test_node_1.Dir, "file.txt"));
}

test "Fat32FS.openImpl - entry iterator failed next" {
    // Will need to fail the 10th allocation
    const allocations: usize = 10;
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, allocations);
    const allocator = &fa.allocator;

    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(allocator, stream);
    defer test_fs.destroy();

    var entry_buff = [_]u8{
        // Long entry 3
        0x43, 0x6E, 0x00, 0x67, 0x00, 0x6E, 0x00, 0x61, 0x00, 0x6D, 0x00, 0x0F, 0x00, 0x6E, 0x65, 0x00,
        0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
        // Long entry 2
        0x02, 0x6E, 0x00, 0x67, 0x00, 0x76, 0x00, 0x65, 0x00, 0x72, 0x00, 0x0F, 0x00, 0x6E, 0x79, 0x00,
        0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x00, 0x00, 0x6F, 0x00, 0x6F, 0x00,
        // Long entry 1
        0x01, 0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x0F, 0x00, 0x6E, 0x6F, 0x00,
        0x6E, 0x00, 0x67, 0x00, 0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x00, 0x00, 0x6F, 0x00, 0x6F, 0x00,
        // Short entry
        0x4C, 0x4F, 0x4F, 0x4F, 0x4F, 0x4F, 0x7E, 0x31, 0x54, 0x58, 0x54, 0x00, 0x18, 0xA0, 0x68, 0xA9,
        0xFE, 0x50, 0x00, 0x00, 0x00, 0x00, 0x6E, 0xA9, 0xFE, 0x50, 0x08, 0x00, 0x13, 0x00, 0x00, 0x00,
        // Long entry 2
        0x42, 0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00, 0x00, 0x00, 0x0F, 0x00, 0xE9, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
        // Long entry 1
        0x01, 0x72, 0x00, 0x61, 0x00, 0x6D, 0x00, 0x64, 0x00, 0x69, 0x00, 0x0F, 0x00, 0xE9, 0x73, 0x00,
        0x6B, 0x00, 0x5F, 0x00, 0x74, 0x00, 0x65, 0x00, 0x73, 0x00, 0x00, 0x00, 0x74, 0x00, 0x31, 0x00,
        // Short entry
        0x52, 0x41, 0x4D, 0x44, 0x49, 0x53, 0x7E, 0x31, 0x54, 0x58, 0x54, 0x00, 0x18, 0x34, 0x47, 0x76,
        0xF9, 0x50, 0x00, 0x00, 0x00, 0x00, 0x48, 0x76, 0xF9, 0x50, 0x03, 0x00, 0x10, 0x00, 0x00, 0x00,
    };

    // Goto root dir and write a long and short entry
    const sector = test_fs.fat_config.clusterToSector(test_fs.root_node.cluster);
    try test_fs.stream.seekableStream().seekTo(sector * test_fs.fat_config.bytes_per_sector);
    try test_fs.stream.writer().writeAll(entry_buff[0..]);

    expectError(error.OutOfMemory, Fat32FS(@TypeOf(stream)).openImpl(test_fs.fs, &test_fs.root_node.node.Dir, "looooongloooongveryloooooongname.txt"));
}

test "Fat32FS.openImpl - entry iterator failed 2nd next" {
    // Will need to fail the 11th allocation
    const allocations: usize = 11;
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, allocations);
    const allocator = &fa.allocator;

    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(allocator, stream);
    defer test_fs.destroy();

    var entry_buff = [_]u8{
        // Long entry 3
        0x43, 0x6E, 0x00, 0x67, 0x00, 0x6E, 0x00, 0x61, 0x00, 0x6D, 0x00, 0x0F, 0x00, 0x6E, 0x65, 0x00,
        0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
        // Long entry 2
        0x02, 0x6E, 0x00, 0x67, 0x00, 0x76, 0x00, 0x65, 0x00, 0x72, 0x00, 0x0F, 0x00, 0x6E, 0x79, 0x00,
        0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x00, 0x00, 0x6F, 0x00, 0x6F, 0x00,
        // Long entry 1
        0x01, 0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x0F, 0x00, 0x6E, 0x6F, 0x00,
        0x6E, 0x00, 0x67, 0x00, 0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x00, 0x00, 0x6F, 0x00, 0x6F, 0x00,
        // Short entry
        0x4C, 0x4F, 0x4F, 0x4F, 0x4F, 0x4F, 0x7E, 0x31, 0x54, 0x58, 0x54, 0x00, 0x18, 0xA0, 0x68, 0xA9,
        0xFE, 0x50, 0x00, 0x00, 0x00, 0x00, 0x6E, 0xA9, 0xFE, 0x50, 0x08, 0x00, 0x13, 0x00, 0x00, 0x00,
        // Long entry 2
        0x42, 0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00, 0x00, 0x00, 0x0F, 0x00, 0xE9, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
        // Long entry 1
        0x01, 0x72, 0x00, 0x61, 0x00, 0x6D, 0x00, 0x64, 0x00, 0x69, 0x00, 0x0F, 0x00, 0xE9, 0x73, 0x00,
        0x6B, 0x00, 0x5F, 0x00, 0x74, 0x00, 0x65, 0x00, 0x73, 0x00, 0x00, 0x00, 0x74, 0x00, 0x31, 0x00,
        // Short entry
        0x52, 0x41, 0x4D, 0x44, 0x49, 0x53, 0x7E, 0x31, 0x54, 0x58, 0x54, 0x00, 0x18, 0x34, 0x47, 0x76,
        0xF9, 0x50, 0x00, 0x00, 0x00, 0x00, 0x48, 0x76, 0xF9, 0x50, 0x03, 0x00, 0x10, 0x00, 0x00, 0x00,
    };

    // Goto root dir and write a long and short entry
    const sector = test_fs.fat_config.clusterToSector(test_fs.root_node.cluster);
    try test_fs.stream.seekableStream().seekTo(sector * test_fs.fat_config.bytes_per_sector);
    try test_fs.stream.writer().writeAll(entry_buff[0..]);

    expectError(error.OutOfMemory, Fat32FS(@TypeOf(stream)).openImpl(test_fs.fs, &test_fs.root_node.node.Dir, "ramdisk_test1.txt"));
}

test "Fat32FS.openImpl - match short name" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy();

    var entry_buff = [_]u8{
        // Long entry 3
        0x43, 0x6E, 0x00, 0x67, 0x00, 0x6E, 0x00, 0x61, 0x00, 0x6D, 0x00, 0x0F, 0x00, 0x6E, 0x65, 0x00,
        0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
        // Long entry 2
        0x02, 0x6E, 0x00, 0x67, 0x00, 0x76, 0x00, 0x65, 0x00, 0x72, 0x00, 0x0F, 0x00, 0x6E, 0x79, 0x00,
        0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x00, 0x00, 0x6F, 0x00, 0x6F, 0x00,
        // Long entry 1
        0x01, 0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x0F, 0x00, 0x6E, 0x6F, 0x00,
        0x6E, 0x00, 0x67, 0x00, 0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x00, 0x00, 0x6F, 0x00, 0x6F, 0x00,
        // Short entry
        0x4C, 0x4F, 0x4F, 0x4F, 0x4F, 0x4F, 0x7E, 0x31, 0x54, 0x58, 0x54, 0x00, 0x18, 0xA0, 0x68, 0xA9,
        0xFE, 0x50, 0x00, 0x00, 0x00, 0x00, 0x6E, 0xA9, 0xFE, 0x50, 0x08, 0x00, 0x13, 0x00, 0x00, 0x00,
    };

    // Goto root dir and write a long and short entry
    const sector = test_fs.fat_config.clusterToSector(test_fs.root_node.cluster);
    try test_fs.stream.seekableStream().seekTo(sector * test_fs.fat_config.bytes_per_sector);
    try test_fs.stream.writer().writeAll(entry_buff[0..]);

    const file_node = try Fat32FS(@TypeOf(stream)).openImpl(test_fs.fs, &test_fs.root_node.node.Dir, "LOOOOO~1.TXT");
    defer file_node.File.close();
}

test "Fat32FS.openImpl - match long name" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy();

    var entry_buff = [_]u8{
        // Long entry 3
        0x43, 0x6E, 0x00, 0x67, 0x00, 0x6E, 0x00, 0x61, 0x00, 0x6D, 0x00, 0x0F, 0x00, 0x6E, 0x65, 0x00,
        0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
        // Long entry 2
        0x02, 0x6E, 0x00, 0x67, 0x00, 0x76, 0x00, 0x65, 0x00, 0x72, 0x00, 0x0F, 0x00, 0x6E, 0x79, 0x00,
        0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x00, 0x00, 0x6F, 0x00, 0x6F, 0x00,
        // Long entry 1
        0x01, 0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x0F, 0x00, 0x6E, 0x6F, 0x00,
        0x6E, 0x00, 0x67, 0x00, 0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x00, 0x00, 0x6F, 0x00, 0x6F, 0x00,
        // Short entry
        0x4C, 0x4F, 0x4F, 0x4F, 0x4F, 0x4F, 0x7E, 0x31, 0x54, 0x58, 0x54, 0x00, 0x18, 0xA0, 0x68, 0xA9,
        0xFE, 0x50, 0x00, 0x00, 0x00, 0x00, 0x6E, 0xA9, 0xFE, 0x50, 0x08, 0x00, 0x13, 0x00, 0x00, 0x00,
    };

    // Goto root dir and write a long and short entry
    const sector = test_fs.fat_config.clusterToSector(test_fs.root_node.cluster);
    try test_fs.stream.seekableStream().seekTo(sector * test_fs.fat_config.bytes_per_sector);
    try test_fs.stream.writer().writeAll(entry_buff[0..]);

    const file_node = try Fat32FS(@TypeOf(stream)).openImpl(test_fs.fs, &test_fs.root_node.node.Dir, "looooongloooongveryloooooongname.txt");
    defer file_node.File.close();
}

test "Fat32FS.openImpl - no match" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy();

    var test_node_1 = try test_fs.createNode(5, 0, .CREATE_DIR, .{});
    defer {
        const elem = test_fs.opened_files.remove(test_node_1).?.value;
        std.testing.allocator.destroy(elem);
        std.testing.allocator.destroy(test_node_1);
    }

    expectError(vfs.Error.NoSuchFileOrDir, Fat32FS(@TypeOf(stream)).openImpl(test_fs.fs, &test_node_1.Dir, "file.txt"));
}
