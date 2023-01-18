const std = @import("std");
const builtin = std.builtin;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expect = std.testing.expect;
const log = std.log.scoped(.fat32);
const AutoHashMap = std.AutoHashMap;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const arch = @import("../arch.zig").internals;
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
    /// Calculate the check sum for the short name entry.
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
/// Initialise a slice with the values from a struct.
/// TODO: Once packed structs are good to go, then use std.mem.bytesAsValue.
///
/// Arguments:
///     IN comptime Type: type - The type of the struct.
///     IN copy_struct: Type   - The struct to copy from.
///     IN bytes: []u8         - The bytes to copy to.
///
///
fn initBytes(comptime Type: type, copy_struct: Type, bytes: []u8) void {
    comptime var index = 0;
    inline for (std.meta.fields(Type)) |item| {
        switch (item.field_type) {
            u8 => bytes[index] = @field(copy_struct, item.name),
            u16 => std.mem.bytesAsSlice(u16, bytes[index .. index + 2])[0] = @field(copy_struct, item.name),
            u32 => std.mem.bytesAsSlice(u32, bytes[index .. index + 4])[0] = @field(copy_struct, item.name),
            else => {
                switch (@typeInfo(item.field_type)) {
                    .Array => |info| switch (info.child) {
                        u8 => {
                            comptime var i = 0;
                            inline while (i < info.len) : (i += 1) {
                                bytes[index + i] = @field(copy_struct, item.name)[i];
                            }
                        },
                        u16 => {
                            comptime var i = 0;
                            inline while (i < info.len) : (i += 1) {
                                std.mem.bytesAsSlice(u16, bytes[index + (i * 2) .. index + 2 + (i * 2)])[0] = @field(copy_struct, item.name)[i];
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
        allocator: Allocator,

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

        // TODO: Have a FAT cache to not touching disk so much
        //       If then need to read a new part of the FAT, then flush the old one.
        //       Have a pub fn so the user can flush everything.

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

            /// The cluster at which the FAT dir short entry for this node is located.
            entry_cluster: u32,

            /// The offset within the entry_cluster the short entry is located.
            entry_offset: u32,
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

            /// When there is is no more space on the stream for a new entry.
            DiskFull,

            /// When destroying the filesystem, this is returned if there are filles left open.
            FilesStillOpen,
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

        /// An iterator for looping over the cluster chain in the FAT and reading the cluster data.
        const ClusterChainIterator = struct {
            /// The allocator used for allocating the initial FAT array, then to free in deinit.
            allocator: Allocator,

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
                if (buff.len != 0 and self.cluster != 0 and (self.cluster & 0x0FFFFFFF) < self.fat_config.cluster_end_marker) {
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
            ///     IN self: *const ClusterChainIteratorSelf - Iterator self.
            ///
            pub fn deinit(self: *const ClusterChainIteratorSelf) void {
                self.allocator.free(self.fat);
            }

            ///
            /// Initialise a cluster chain iterator.
            ///
            /// Arguments:
            ///     IN allocator: Allocator - The allocator for allocating a FAT cache.
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
            pub fn init(allocator: Allocator, fat_config: FATConfig, cluster: u32, stream: StreamType) (Allocator.Error || Fat32Self.Error || ReadError || SeekError)!ClusterChainIteratorSelf {
                // Create a bytes per sector sized cache of the FAT.
                var fat = try allocator.alloc(u32, fat_config.bytes_per_sector / @sizeOf(u32));
                errdefer allocator.free(fat);

                const table_offset = cluster / fat.len;

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
            allocator: Allocator,

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
                allocator: Allocator,

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

                    // If attribute is 0x0F, then is a long file name
                    if (self.cluster_block[self.index + 11] == 0x0F and self.cluster_block[self.index] & 0x40 == 0x40) {
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
                    if (self.cluster_block[self.index + 11] == 0x0F and self.cluster_block[self.index] != 0x00) {
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
            ///     IN allocator: Allocator - The allocator for allocating a cluster block cache.
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
            pub fn init(allocator: Allocator, fat_config: FATConfig, cluster: u32, stream: StreamType) (Allocator.Error || Fat32Self.Error || ReadError || SeekError)!EntryIteratorSelf {
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

        /// See vfs.FileSystem.close
        fn close(fs: *const vfs.FileSystem, node: *const vfs.Node) void {
            const self = @fieldParentPtr(Fat32Self, "instance", fs.instance);
            // As close can't error, if provided with a invalid Node that isn't opened or try to close
            // the same file twice, will just do nothing.
            if (self.opened_files.fetchRemove(node)) |entry_node| {
                self.allocator.destroy(entry_node.value);
                self.allocator.destroy(node);
            }
        }

        /// See vfs.FileSystem.read
        fn read(fs: *const vfs.FileSystem, node: *const vfs.FileNode, buffer: []u8) (Allocator.Error || vfs.Error)!usize {
            const self = @fieldParentPtr(Fat32Self, "instance", fs.instance);
            const cast_node = @ptrCast(*const vfs.Node, node);
            const opened_node = self.opened_files.get(cast_node) orelse return vfs.Error.NotOpened;
            const size = std.math.min(buffer.len, opened_node.size);

            var it = ClusterChainIterator.init(self.allocator, self.fat_config, opened_node.cluster, self.stream) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.err("Error initialising the cluster chain iterator. Error: {}\n", .{e});
                    return vfs.Error.Unexpected;
                },
            };
            defer it.deinit();
            var index: usize = 0;
            while (it.read(buffer[index..size]) catch |e| {
                log.err("Error reading the cluster chain iterator. Error: {}\n", .{e});
                return vfs.Error.Unexpected;
            }) |next_index| {
                index += next_index;
            }

            return size;
        }

        /// See vfs.FileSystem.write
        fn write(fs: *const vfs.FileSystem, node: *const vfs.FileNode, bytes: []const u8) (Allocator.Error || vfs.Error)!usize {
            const self = @fieldParentPtr(Fat32Self, "instance", fs.instance);
            const cast_node = @ptrCast(*const vfs.Node, node);
            const opened_node = self.opened_files.get(cast_node) orelse return vfs.Error.NotOpened;
            // Short cut if length is less than cluster size, can just write the content directly without modifying the FAT
            if (bytes.len <= self.fat_config.sectors_per_cluster * self.fat_config.bytes_per_sector) {
                const sector = self.fat_config.clusterToSector(opened_node.cluster);
                self.stream.seekableStream().seekTo(sector * self.fat_config.bytes_per_sector) catch return vfs.Error.Unexpected;
                _ = self.stream.writer().writeAll(bytes) catch return vfs.Error.Unexpected;
            } else {
                var to_write: u32 = self.fat_config.sectors_per_cluster * self.fat_config.bytes_per_sector;
                var write_index: u32 = 0;
                var next_free_cluster: u32 = opened_node.cluster;
                if (self.fat_config.has_fs_info) {
                    if (self.fat_config.number_free_clusters < bytes.len / (self.fat_config.sectors_per_cluster * self.fat_config.bytes_per_sector)) {
                        // Not enough free clusters
                        return vfs.Error.Unexpected;
                    }
                }
                while (write_index < bytes.len) : ({
                    write_index = to_write;
                    to_write = std.math.min(bytes.len, write_index + self.fat_config.sectors_per_cluster * self.fat_config.bytes_per_sector);
                    if (write_index < bytes.len) {
                        next_free_cluster = self.findNextFreeCluster(next_free_cluster, next_free_cluster) catch return vfs.Error.Unexpected;
                    }
                }) {
                    const sector = self.fat_config.clusterToSector(next_free_cluster);
                    self.stream.seekableStream().seekTo(sector * self.fat_config.bytes_per_sector) catch return vfs.Error.Unexpected;
                    _ = self.stream.writer().writeAll(bytes[write_index..to_write]) catch return vfs.Error.Unexpected;
                }
            }
            // Update the entry the size for the file.
            const entry_sector = self.fat_config.clusterToSector(opened_node.entry_cluster);
            self.stream.seekableStream().seekTo(entry_sector * self.fat_config.bytes_per_sector + opened_node.entry_offset) catch return vfs.Error.Unexpected;
            self.stream.writer().writeIntLittle(u32, bytes.len) catch return vfs.Error.Unexpected;
            opened_node.size = bytes.len;
            return bytes.len;
        }

        /// See vfs.FileSystem.open
        fn open(fs: *const vfs.FileSystem, dir: *const vfs.DirNode, name: []const u8, flags: vfs.OpenFlags, open_args: vfs.OpenArgs) (Allocator.Error || vfs.Error)!*vfs.Node {
            // Suppress unused var warning
            _ = open_args;
            return switch (flags) {
                .NO_CREATION => openImpl(fs, dir, name),
                .CREATE_FILE => createFileOrDir(fs, dir, name, false),
                .CREATE_DIR => createFileOrDir(fs, dir, name, true),
                // FAT32 doesn't support symlinks
                .CREATE_SYMLINK => vfs.Error.InvalidFlags,
            };
        }

        ///
        /// Helper function for creating the correct *Node. This can only create a FileNode or
        /// DirNode, Symlinks are not supported for FAT32. The arguments are assumed correct: the
        /// cluster points to a free block and the size is correct: zero for directories.
        ///
        /// Arguments:
        ///     IN self: *Fat32Self     - Self, needed for the allocator and underlying filesystem
        ///     IN cluster: u32         - The cluster there the file/directory will be.
        ///     IN size: u32            - The size of the file or 0 for a directory.
        ///     IN entry_cluster: u32   - The cluster where the FAT dir entry is located.
        ///     IN entry_offset: u32    - The offset in the entry_cluster there the entry is located.
        ///     IN flags: vfs.OpenFlags - The open flags for deciding on the Node type.
        ///
        /// Return: *vfs.Node
        ///     The VFS Node
        ///
        /// Error: Allocator.Error || vfs.Error
        ///     Allocator.Error        - Not enough memory for allocating the Node
        ///     vfs.Error.InvalidFlags - Symlinks are not support in FAT32.
        ///
        fn createNode(self: *Fat32Self, cluster: u32, size: u32, entry_cluster: u32, entry_offset: u32, flags: vfs.OpenFlags) (Allocator.Error || vfs.Error)!*vfs.Node {
            var node = try self.allocator.create(vfs.Node);
            errdefer self.allocator.destroy(node);
            node.* = switch (flags) {
                .CREATE_DIR => .{ .Dir = .{ .fs = self.fs, .mount = null } },
                .CREATE_FILE => .{ .File = .{ .fs = self.fs } },
                .CREATE_SYMLINK, .NO_CREATION => return vfs.Error.InvalidFlags,
            };

            // Create the opened info struct
            var opened_info = try self.allocator.create(OpenedInfo);
            errdefer self.allocator.destroy(opened_info);
            opened_info.* = .{
                .cluster = cluster,
                .size = size,
                .entry_cluster = entry_cluster,
                .entry_offset = entry_offset,
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
        fn getDirCluster(self: *const Fat32Self, dir: *const vfs.DirNode) vfs.Error!u32 {
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
            var previous_cluster = cluster;
            var it = EntryIterator.init(self.allocator, self.fat_config, cluster, self.stream) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.err("Error initialising the entry iterator. Error: {}\n", .{e});
                    return vfs.Error.Unexpected;
                },
            };
            defer it.deinit();
            while (it.next() catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.err("Error in next() iterating the entry iterator. Error: {}\n", .{e});
                    return vfs.Error.Unexpected;
                },
            }) |entry| {
                defer entry.deinit();
                if ((it.cluster_chain.cluster & 0x0FFFFFFF) < self.fat_config.cluster_end_marker) {
                    previous_cluster = it.cluster_chain.cluster;
                }

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
                    return self.createNode(entry.short_name.getCluster(), entry.short_name.size, previous_cluster, it.index - 4, open_type);
                }
            }
            return vfs.Error.NoSuchFileOrDir;
        }

        ///
        /// Helper function for finding a free cluster from a given hint. The hint is where to
        /// start looking. This will update the FAT and FSInfo accordingly. If a parent cluster
        /// is provided, then the cluster chan will be updated so the parent cluster will point to
        /// the new cluster.
        ///
        /// Arguments:
        ///     IN self: *Fat32Self     - Self for allocating a free cluster with the current configuration.
        ///     IN cluster_hint: u32    - The cluster hint to start looking.
        ///     IN parent_cluster: ?u32 - The parent cluster to update the cluster chain from. Can
        ///                               be null if creating a new cluster for a file/folder.
        ///
        /// Return: u32
        ///     The next free cluster to use.
        ///
        /// Error: Allocator.Error || ReadError || SeekError || Fat32Self.Error
        ///     Allocator.Error - Not enough memory for allocating memory.
        ///     WriteError      - Error while updating the FAT with the new cluster.
        ///     ReadError       - Error while reading the stream.
        ///     SeekError       - Error while seeking the stream.
        ///     Fat32Self.Error.BadRead  - Error reading the FAT, not aligned to the sector.
        ///     Fat32Self.Error.DiskFull - No free clusters.
        ///
        fn findNextFreeCluster(self: *Fat32Self, cluster_hint: u32, parent_cluster: ?u32) (Allocator.Error || WriteError || ReadError || SeekError || Fat32Self.Error)!u32 {
            var fat_buff = try self.allocator.alloc(u32, self.fat_config.bytes_per_sector / @sizeOf(u32));
            defer self.allocator.free(fat_buff);
            var sector_offset = cluster_hint / fat_buff.len;

            const reader = self.stream.reader();
            const writer = self.stream.writer();
            const seeker = self.stream.seekableStream();

            try seeker.seekTo((self.fat_config.reserved_sectors + sector_offset) * self.fat_config.bytes_per_sector);
            var fat_read = try reader.readAll(std.mem.sliceAsBytes(fat_buff));
            if (fat_read != self.fat_config.bytes_per_sector) {
                return Fat32Self.Error.BadRead;
            }

            // Check for a free cluster by checking the FAT for a 0x00000000 entry (free)
            var cluster = cluster_hint;
            while (fat_buff[cluster - (sector_offset * fat_buff.len)] != 0x00000000) {
                cluster += 1;

                // Check we are still in the FAT buffer, if not, read the next FAT part
                const check_offset = cluster / fat_buff.len;
                if (check_offset > sector_offset) {
                    // Check if the cluster will go outside the FAT
                    if (check_offset >= self.fat_config.sectors_per_fat) {
                        // TODO: Will need to wrap as there maybe free clusters before the hint
                        if (self.fat_config.has_fs_info) {
                            std.debug.assert(self.fat_config.number_free_clusters == 0);
                        }
                        return Fat32Self.Error.DiskFull;
                    }
                    sector_offset = check_offset;
                    try seeker.seekTo((self.fat_config.reserved_sectors + sector_offset) * self.fat_config.bytes_per_sector);
                    fat_read = try reader.readAll(std.mem.sliceAsBytes(fat_buff));
                    if (fat_read != fat_buff.len * @sizeOf(u32)) {
                        return Fat32Self.Error.BadRead;
                    }
                }
            }

            // Update the FAT for the allocated cluster
            if (parent_cluster) |p_cluster| {
                try seeker.seekTo((self.fat_config.reserved_sectors * self.fat_config.bytes_per_sector) + (p_cluster * @sizeOf(u32)));
                try writer.writeIntLittle(u32, cluster);
            }
            try seeker.seekTo((self.fat_config.reserved_sectors * self.fat_config.bytes_per_sector) + (cluster * @sizeOf(u32)));
            try writer.writeIntLittle(u32, self.fat_config.cluster_end_marker);
            // And the backup FAT
            if (parent_cluster) |p_cluster| {
                try seeker.seekTo(((self.fat_config.sectors_per_fat + self.fat_config.reserved_sectors) * self.fat_config.bytes_per_sector) + (p_cluster * @sizeOf(u32)));
                try writer.writeIntLittle(u32, cluster);
            }
            try seeker.seekTo(((self.fat_config.sectors_per_fat + self.fat_config.reserved_sectors) * self.fat_config.bytes_per_sector) + (cluster * @sizeOf(u32)));
            try writer.writeIntLittle(u32, self.fat_config.cluster_end_marker);

            // Update the FSInfo if we have one
            if (self.fat_config.has_fs_info) {
                self.fat_config.next_free_cluster = cluster + 1;
                self.fat_config.number_free_clusters -= 1;
                // write it to disk
                // TODO: Have this cached and flush later to save writes
                //       Have a flush function so the user can flush and flush on deinit
                try seeker.seekTo(self.fat_config.fsinfo_sector * self.fat_config.bytes_per_sector + 488);
                try writer.writeIntLittle(u32, self.fat_config.number_free_clusters);
                try writer.writeIntLittle(u32, self.fat_config.next_free_cluster);
                // And the backup FSInfo
                try seeker.seekTo((self.fat_config.backup_boot_sector + self.fat_config.fsinfo_sector) * self.fat_config.bytes_per_sector + 488);
                try writer.writeIntLittle(u32, self.fat_config.number_free_clusters);
                try writer.writeIntLittle(u32, self.fat_config.next_free_cluster);
            }

            // Have found a free cluster
            return cluster;
        }

        ///
        /// Helper function for creating a file, folder or symlink.
        ///
        /// Arguments:
        ///     IN fs: *const vfs.FileSystem - The underlying filesystem.
        ///     IN dir: *const vfs.DirNode   - The parent directory.
        ///     IN name: []const u8          - The name of the file/folder to open.
        ///     IN is_dir: bool              - If creating a file/folder.
        ///
        /// Return: *vfs.Node
        ///     The VFS Node for the opened/created file/folder.
        ///
        /// Error: Allocator.Error || vfs.Error
        ///     Allocator.Error           - Not enough memory for allocating memory.
        ///     vfs.Error.NoSuchFileOrDir - Error if creating a symlink and no target is provided.
        ///     vfs.Error.Unexpected      - An error occurred whilst reading the file system, this
        ///                                 can be caused by a parsing error or errors on reading
        ///                                 or seeking the underlying stream. If this occurs, then
        ///                                 the real error is printed using `log.err`.
        ///
        fn createFileOrDir(fs: *const vfs.FileSystem, dir: *const vfs.DirNode, name: []const u8, is_dir: bool) (Allocator.Error || vfs.Error)!*vfs.Node {
            const self = @fieldParentPtr(Fat32Self, "instance", fs.instance);

            var files_in_dir = ArrayList([11]u8).init(self.allocator);
            defer files_in_dir.deinit();

            const dir_cluster = try self.getDirCluster(dir);
            var previous_cluster = dir_cluster;
            var previous_index: u32 = 0;
            var it = EntryIterator.init(self.allocator, self.fat_config, dir_cluster, self.stream) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.err("Error initialising the entry iterator. Error: {}\n", .{e});
                    return vfs.Error.Unexpected;
                },
            };
            defer it.deinit();
            while (it.next() catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.err("Error in next() iterating the entry iterator. Error: {}\n", .{e});
                    return vfs.Error.Unexpected;
                },
            }) |entry| {
                defer entry.deinit();
                // Keep track of the last cluster before the end
                previous_index = it.index;
                if ((it.cluster_chain.cluster & 0x0FFFFFFF) < self.fat_config.cluster_end_marker) {
                    previous_cluster = it.cluster_chain.cluster;
                }
                try files_in_dir.append(entry.short_name.getSFNName());
            }

            const existing_files = files_in_dir.toOwnedSlice();
            defer self.allocator.free(existing_files);

            // Find a free cluster
            // The default cluster to start looking for a free cluster
            var cluster_hint: u32 = 2;
            if (self.fat_config.has_fs_info and self.fat_config.next_free_cluster != 0x0FFFFFFF) {
                // Have a next free cluster in the FSInfo, so can use this to start looking
                cluster_hint = self.fat_config.next_free_cluster;
            }
            const free_cluster = self.findNextFreeCluster(cluster_hint, null) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.err("Error finding next cluster. Error: {}\n", .{e});
                    return vfs.Error.Unexpected;
                },
            };

            const dir_attr: ShortName.Attributes = if (is_dir) .Directory else .None;
            const entries = createEntries(self.allocator, name, free_cluster, dir_attr, existing_files) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.err("Error creating short and long entries. Error: {}\n", .{e});
                    return vfs.Error.Unexpected;
                },
            };
            defer self.allocator.free(entries.long_entry);

            // Write the entries to the directory
            const short_offset = self.writeEntries(entries, previous_cluster, free_cluster, previous_index) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.err("Error writing entries to disk. Error: {}\n", .{e});
                    return vfs.Error.Unexpected;
                },
            };

            return self.createNode(free_cluster, 0, short_offset.cluster, short_offset.offset + 28, if (is_dir) .CREATE_DIR else .CREATE_FILE);
        }

        ///
        /// Helper function for creating both long and short entries. This will convert the raw
        /// name to a valid long and short FAT32 name and create the corresponding FAT32 entries.
        /// error.InvalidName will be returned if the raw name cannot be converted to a valid FAT32
        /// name. The caller needs to free the long name entries.
        ///
        /// Arguments:
        ///     IN allocator: Allocator - The allocator for allocating the long entries array.
        ///     IN name: []const u8      - The raw name to be used for creating the file/directory.
        ///     IN cluster: u32          - The cluster where the entry will point to.
        ///     IN attributes: ShortName.Attributes - The attributes of the the entry.
        ///     IN existing_short_names: []const [11]u8 - Existing short names so to resolve short name clashes.
        ///
        /// Return: FatDirEntry
        ///     The full FAT entry ready to be copies to disk, byte by byte.
        ///
        /// Error: Allocator.Error || Fat32Self.Error
        ///     Allocator.Error - Error allocating memory.
        ///     Fat32Self.Error - The name provided cannot be converted to a valid FAT32 name.
        ///
        fn createEntries(allocator: Allocator, name: []const u8, cluster: u32, attributes: ShortName.Attributes, existing_short_names: []const [11]u8) (Allocator.Error || Fat32Self.Error)!FatDirEntry {
            const long_name = try nameToLongName(allocator, name);
            defer allocator.free(long_name);
            const short_name = try longNameToShortName(long_name, existing_short_names);
            const short_entry = createShortNameEntry(short_name, attributes, cluster);
            const long_entry = try createLongNameEntry(allocator, long_name, short_entry.calcCheckSum());
            return FatDirEntry{
                .long_entry = long_entry,
                .short_entry = short_entry,
            };
        }

        ///
        /// Helper for converting a raw file name to a valid FAT32 long file name. The returned
        /// name will need to be freed by the allocator.
        ///
        /// Arguments:
        ///     IN allocator: Allocator - The allocator for creating the FAT32 long file name.
        ///     IN name: []const u8      - The raw file name.
        ///
        /// Return: []const u16
        ///     A valid UTF-16 FAT32 long file name.
        ///
        /// Error: Allocator.Error || Fat32Self.Error
        ///     Allocator.Error             - Error allocating memory.
        ///     Fat32Self.Error.InvalidName - The file name cannot be converted to a valid long name.
        ///
        fn nameToLongName(allocator: Allocator, name: []const u8) (Allocator.Error || Fat32Self.Error)![]const u16 {
            // Allocate a buffer to translate to UFT16. Then length of the UFT8 will be more than enough
            // TODO: Calc the total length and use appendAssumeCapacity
            var utf16_buff = try ArrayList(u16).initCapacity(allocator, name.len);
            defer utf16_buff.deinit();

            // The name is in UTF8, this needs to be conversed to UTF16
            // This also checks for valid UTF8 characters
            const utf8_view = std.unicode.Utf8View.init(name) catch return Fat32Self.Error.InvalidName;
            var utf8_it = utf8_view.iterator();
            // Make sure the code points as valid for the long name
            var ignored_leading = false;
            while (utf8_it.nextCodepoint()) |code_point| {
                // Ignore leading spaces
                if (!ignored_leading and code_point == ' ') {
                    continue;
                }
                ignored_leading = true;
                // If it is larger than 0xFFFF, then it cannot fit in UTF16 so invalid.
                // Can't have control characters (including the DEL key)
                if (code_point > 0xFFFF or code_point < 0x20 or code_point == 0x7F) {
                    return Fat32Self.Error.InvalidName;
                }

                // Check for invalid characters
                const invalid_chars = "\"*/:<>?\\|";
                inline for (invalid_chars) |char| {
                    if (char == code_point) {
                        return Fat32Self.Error.InvalidName;
                    }
                }

                // Valid character
                try utf16_buff.append(@intCast(u16, code_point));
            }

            // Remove trailing spaces and dots
            // And return the name
            const long_name = std.mem.trimRight(u16, utf16_buff.toOwnedSlice(), &[_]u16{ ' ', '.' });
            errdefer allocator.free(long_name);

            // Check the generated name is a valid length
            if (long_name.len > 255) {
                return Fat32Self.Error.InvalidName;
            }
            return long_name;
        }

        ///
        /// Helper function for checking if a u16 long name character can be converted to a valid
        /// OEM u8 character
        ///
        /// Arguments:
        ///     IN char: u16 - The character to check
        ///
        /// Return: ?u8
        ///     The successful converted character or null if is an invalid OEM u8 char.
        ///
        fn isValidSFNChar(char: u16) ?u8 {
            // Ignore spaces
            if (char == 0x20) {
                return null;
            }

            // If not a u8 char or CP437 char, then replace with a _
            if (char > 0x7F) {
                return CodePage.toCodePage(.CP437, char) catch {
                    return null;
                };
            }

            // Check for invalid characters, then replace with a _
            const invalid_chars = "+,;=[]";
            inline for (invalid_chars) |c| {
                if (c == char) {
                    return null;
                }
            }

            return @intCast(u8, char);
        }

        ///
        /// Helper function for converting a valid long name to a short file name. This expects
        /// valid long name, else is undefined for invalid long names. This also checks against
        /// existing short names so there are no clashed within the same directory (appending
        /// ~n to the end of the short name if there is a clash).
        ///
        /// Arguments:
        ///     IN long_name: []const u16         - The long name to convert.
        ///     IN existing_names: []const [11]u8 - The list of existing short names.
        ///
        /// Return: [11]u8
        ///     The converted short name.
        ///
        /// Error: Fat32Self.Error
        ///     Fat32Self.Error.InvalidName - If the directory is fill of the same short file name.
        ///
        fn longNameToShortName(long_name: []const u16, existing_names: []const [11]u8) Fat32Self.Error![11]u8 {
            // Pad with spaces
            var sfn: [11]u8 = [_]u8{' '} ** 11;
            var sfn_i: u8 = 0;
            var is_lossy = false;

            // TODO: Need to convert to upper case first but don't have proper unicode support for this yet

            // Remove leading dots and spaces
            var long_name_start: u32 = 0;
            for (long_name) |char| {
                if (char != '.') {
                    break;
                }
                // If there is, then it is lossy
                long_name_start += 1;
                is_lossy = true;
            }

            // Get the last dot in the string
            const last_dot_index = std.mem.lastIndexOf(u16, long_name[long_name_start..], &[_]u16{'.'});

            for (long_name[long_name_start..]) |char, i| {
                // Break when we reach the max of the short name or the last dot
                if (char == '.') {
                    if (last_dot_index) |index| {
                        if (i == index) {
                            break;
                        }
                    }
                    // Else ignore it, and is lossy
                    is_lossy = true;
                    continue;
                }

                if (sfn_i == 8) {
                    is_lossy = true;
                    break;
                }

                if (isValidSFNChar(char)) |oem_char| {
                    // Valid SFN char, and convert to upper case
                    // TODO: Need proper unicode uppercase
                    sfn[sfn_i] = std.ascii.toUpper(oem_char);
                    sfn_i += 1;
                } else {
                    // Spaces don't need to be replaced, just ignored, but still set the lossy
                    if (char != 0x20) {
                        sfn[sfn_i] = '_';
                        sfn_i += 1;
                    }
                    is_lossy = true;
                }
            }

            // Save the name index
            const name_index = sfn_i;

            // Go to the last dot, if there isn't one, return what we have
            const index = (last_dot_index orelse return sfn) + long_name_start;
            sfn_i = 8;
            // +1 as the index will be on the DOT and we don't need to include it
            for (long_name[index + 1 ..]) |char| {
                // Break when we reach the max of the short name
                if (sfn_i == 11) {
                    is_lossy = true;
                    break;
                }

                if (isValidSFNChar(char)) |oem_char| {
                    // Valid SFN char, and convert to upper case
                    // TODO: Need proper unicode uppercase
                    sfn[sfn_i] = std.ascii.toUpper(oem_char);
                    sfn_i += 1;
                } else {
                    // Spaces don't need to be replaced, just ignored, but still set the lossy
                    if (char != 0x20) {
                        sfn[sfn_i] = '_';
                        sfn_i += 1;
                    }
                    is_lossy = true;
                }
            }

            // 0xE5 is used for a deleted file, but is a valid UTF8 character, so use 0x05 instead
            if (sfn[0] == 0xE5) {
                sfn[0] = 0x05;
            }

            // Is there a collision of file names
            // Find n in ~n in the existing files
            var trail_number: u32 = 0;
            var full_name_match = false;
            for (existing_names) |existing_name| {
                // Only need to check the 8 char file name, not extension
                var i: u8 = 0;
                while (i < 8) : (i += 1) {
                    if (existing_name[i] != sfn[i] and existing_name[i] == '~') {
                        // Read the number and break
                        // -3 as we exclude the extension
                        // +1 as we are at the '~'
                        i += 1;
                        const end_num = std.mem.indexOf(u8, existing_name[0..], " ") orelse existing_name.len - 3;
                        const num = std.fmt.parseInt(u32, existing_name[i..end_num], 10) catch {
                            break;
                        };
                        if (num > trail_number) {
                            trail_number = num;
                        }
                        break;
                    }
                    // Not the same file name
                    if (existing_name[i] != sfn[i] and (!is_lossy or existing_name[i] != '~')) {
                        break;
                    }
                }
                // If match the full name, then need to add trail
                if (i == 8) {
                    full_name_match = true;
                }
            }

            // If there were some losses, then wee need to add a number to the end
            if (is_lossy or full_name_match) {
                // Check if we have the max file names
                if (trail_number == 999999) {
                    return Error.InvalidName;
                }

                // Increase the trail number as this will be the number to append
                trail_number += 1;

                // Format this as a string, can't be more than 6 characters
                var trail_number_str: [6]u8 = undefined;
                const trail_number_str_end = std.fmt.formatIntBuf(trail_number_str[0..], trail_number, 10, .lower, .{});

                // Get the index to put the ~n
                var number_trail_index = if (name_index > 7 - trail_number_str_end) 7 - trail_number_str_end else name_index;
                sfn[number_trail_index] = '~';
                for (trail_number_str[0..trail_number_str_end]) |num_str| {
                    number_trail_index += 1;
                    sfn[number_trail_index] = num_str;
                }
            }

            return sfn;
        }

        ///
        /// Helper function for creating the long name dir entries from the long name. The return
        /// array will need to be freed by the caller. This expects a valid long name else undefined
        /// behavior.
        ///
        /// Arguments:
        ///     IN allocator: Allocator  - The allocator for the long name array
        ///     IN long_name: []const u16 - The valid long name.
        ///     IN check_sum: u8          - The short name check sum for the long entry.
        ///
        /// Return: []LongName
        ///     The list of long name entries read to be written to disk.
        ///
        /// Error: Allocator.Error
        ///     Allocator.Error - Error allocating memory for the long name entries.
        ///
        fn createLongNameEntry(allocator: Allocator, long_name: []const u16, check_sum: u8) Allocator.Error![]LongName {
            // Calculate the number of long entries (round up). LFN are each 13 characters long
            const num_lfn_entries = @intCast(u8, (long_name.len + 12) / 13);

            // Create the long entries
            var lfn_array = try allocator.alloc(LongName, num_lfn_entries);
            errdefer allocator.free(lfn_array);

            // Work backwards because it is easier
            var backwards_index = num_lfn_entries;
            while (backwards_index > 0) : (backwards_index -= 1) {
                // If this is the first entry, then the first bytes starts with 0x40
                const entry_index = num_lfn_entries - backwards_index;
                const order = if (backwards_index == 1) 0x40 | num_lfn_entries else entry_index + 1;
                // Get the working slice of 13 characters
                // NULL terminate and pad with 0xFFFF if less than 13 characters
                const working_name: [13]u16 = blk: {
                    var temp: [13]u16 = [_]u16{0xFFFF} ** 13;
                    const long_name_slice = long_name[(entry_index * 13)..];
                    if (long_name_slice.len < 13) {
                        for (long_name_slice) |char, i| {
                            temp[i] = char;
                        }
                        // NULL terminated
                        temp[long_name_slice.len] = 0x0000;
                    } else {
                        for (temp) |*char, i| {
                            char.* = long_name[(entry_index * 13) + i];
                        }
                    }
                    break :blk temp;
                };

                // Create the entry
                lfn_array[backwards_index - 1] = .{
                    .order = order,
                    .first = working_name[0..5].*,
                    .check_sum = check_sum,
                    .second = working_name[5..11].*,
                    .third = working_name[11..13].*,
                };
            }

            return lfn_array;
        }

        ///
        /// Helper function fro creating a short name entry. This calls the system time to get the
        /// current date and time for the new file/directory. This assumes a valid short name else
        /// undefined behavior.
        ///
        /// Arguments:
        ///     IN name: [11]u8                     - The short name.
        ///     IN attributes: ShortName.Attributes - The attribute for the short name entry.
        ///     IN cluster: u32                     - The cluster where this will point to.
        ///
        /// Return: ShortName
        ///     The short name entry with the current time used.
        ///
        fn createShortNameEntry(name: [11]u8, attributes: ShortName.Attributes, cluster: u32) ShortName {
            const date_time = arch.getDateTime();

            const date = @intCast(u16, date_time.day | date_time.month << 5 | (date_time.year - 1980) << 9);
            const time = @intCast(u16, date_time.second / 2 | date_time.minute << 5 | date_time.hour << 11);

            return .{
                .name = name[0..8].*,
                .extension = name[8..11].*,
                .attributes = @enumToInt(attributes),
                .time_created_tenth = @intCast(u8, (date_time.second % 2) * 100),
                .time_created = time,
                .date_created = date,
                .date_last_access = date,
                .cluster_high = @truncate(u16, cluster >> 16),
                .time_last_modification = time,
                .date_last_modification = date,
                .cluster_low = @truncate(u16, cluster),
                .size = 0x00000000,
            };
        }

        ///
        /// Helper function for writing a new file/folder entry. This will create the new entry
        /// under the provided cluster. If the cluster is full or not big enough the FAT will
        /// be extended and a new cluster will be allocated. This expects valid entries. Inputs
        /// are assumed to be correct.
        ///
        /// Arguments:
        ///     IN self: *Fat32Self            - Self for the current instance of the FAT32 filesystem.
        ///     IN entries: FatDirEntry        - The new entries to be written.
        ///     IN at_cluster: u32             - The cluster to write the entries to.
        ///     IN next_free_cluster_hint: u32 - The next free cluster to be used as a hint to find
        ///                                      new clusters for large entries.
        ///     IN initial_cluster_offset: u32 - The initial offset into the cluster to write to.
        ///
        /// Return: struct{cluster: u32, offset: u32}
        ///     cluster - The cluster at which the short entry is located
        ///     offset  - The offset at which the short entry is located with in the cluster.
        ///
        /// Error: Allocator.Error || WriteError || ReadError || SeekError
        ///     Allocator.Error - Error allocating memory.
        ///     WriteError      - Error writing to the underlying stream.
        ///     ReadError       - Error reading the underlying stream.
        ///     SeekError       - Error seeking the underlying stream.
        ///     Fat32Self.Error - This will relate to allocating a new cluster.
        ///
        fn writeEntries(self: *Fat32Self, entries: FatDirEntry, at_cluster: u32, next_free_cluster_hint: u32, initial_cluster_offset: u32) (Allocator.Error || WriteError || ReadError || SeekError || Fat32Self.Error)!struct { cluster: u32, offset: u32 } {
            // Each entry is 32 bytes short + 32 * long len
            const entries_size_bytes = 32 + (32 * entries.long_entry.len);
            std.debug.assert(at_cluster >= 2);
            // Largest possible entry length
            std.debug.assert(entries_size_bytes <= 32 + (32 * 20));
            // Entries are 32 bytes long, so the offset will need to be aligned to 32 bytes
            std.debug.assert(initial_cluster_offset % 32 == 0);

            const cluster_size = self.fat_config.bytes_per_sector * self.fat_config.sectors_per_cluster;

            // Check free entry
            var index = initial_cluster_offset;

            // The cluster to write to, this can update as if the cluster provided is full, will need to write to the next free cluster
            var write_cluster = at_cluster;

            // At the end of the cluster chain, need to alloc a cluster
            // Overwrite the at_cluster to use the new one
            if (index == cluster_size) {
                write_cluster = try self.findNextFreeCluster(next_free_cluster_hint, write_cluster);
                index = 0;
            }

            // TODO: Once FatDirEntry can be a packed struct, then can write as bytes and not convert
            var write_buff = try self.allocator.alloc(u8, entries_size_bytes);
            defer self.allocator.free(write_buff);
            for (entries.long_entry) |long_entry, i| {
                initBytes(LongName, long_entry, write_buff[(32 * i)..]);
            }
            initBytes(ShortName, entries.short_entry, write_buff[write_buff.len - 32 ..]);

            // Fill the cluster with the entry
            var cluster_offset = index;
            var write_index: u32 = 0;
            var write_next_index = std.math.min(cluster_size - cluster_offset, write_buff.len);
            while (write_index < write_buff.len) : ({
                cluster_offset = 0;
                write_index = write_next_index;
                write_next_index = std.math.min(write_next_index + cluster_size, write_buff.len);
                if (write_index < write_buff.len) {
                    write_cluster = try self.findNextFreeCluster(write_cluster, write_cluster);
                }
            }) {
                const write_sector = self.fat_config.clusterToSector(write_cluster);
                try self.stream.seekableStream().seekTo(write_sector * self.fat_config.bytes_per_sector + cluster_offset);
                try self.stream.writer().writeAll(write_buff[write_index..write_next_index]);
            }

            const ret = .{ .cluster = write_cluster, .offset = (index + write_buff.len - 32) % cluster_size };
            return ret;
        }

        ///
        /// Deinitialise this file system. This frees the root node, virtual filesystem and self.
        /// This asserts that there are no open files left.
        ///
        /// Arguments:
        ///     IN self: *Fat32Self - Self to free.
        ///
        pub fn destroy(self: *Fat32Self) Fat32Self.Error!void {
            // Make sure we have closed all files
            if (self.opened_files.count() != 0) {
                return Fat32Self.Error.FilesStillOpen;
            }
            self.opened_files.deinit();
            self.allocator.destroy(self.root_node.node);
            self.allocator.destroy(self.fs);
            self.allocator.destroy(self);
        }

        ///
        /// Initialise a FAT32 filesystem.
        ///
        /// Arguments:
        ///     IN allocator: Allocator - Allocate memory.
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
        pub fn create(allocator: Allocator, stream: StreamType) (Allocator.Error || ReadError || SeekError || Fat32Self.Error)!*Fat32Self {
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
///     IN allocator: Allocator - An allocator.
///     IN stream: anytype       - A stream this is used to read and seek a raw disk or memory to
///                                be parsed as a FAT32 filesystem. E.g. a FixedBufferStream.
///
/// Return: *Fat32FS(@TypeOf(stream))
///     A pointer to a FAT32 filesystem.
///
/// Error: Allocator.Error || Fat32FS(@TypeOf(stream)).Error
///     Allocator.Error - If there isn't enough memory to create the filesystem.
///
pub fn initialiseFAT32(allocator: Allocator, stream: anytype) (Allocator.Error || ErrorSet(@TypeOf(stream)) || Fat32FS(@TypeOf(stream)).Error)!*Fat32FS(@TypeOf(stream)) {
    return Fat32FS(@TypeOf(stream)).create(allocator, stream);
}

///
/// Create a test FAT32 filesystem. This will use mkfat32 to create the temporary FAT32 then the
/// stream and fat_config will be replaced by the provided ones. Returned will need to be deinit().
/// This will also set the VFS root node so can use the VFS interfaces without manual setup.
///
/// Arguments:
///     IN allocator: Allocator - The allocator to create the FAT32FS
///     IN stream: anytype       - The stream to replace the generated one. This will need to be a
///                                fixed buffer stream.
///     IN fat_config: FATConfig - The config to replace the generated one.
///
/// Return: *Fat32FS(@TypeOf(stream))
///     Teh test FAT32 filesystem
///
/// Error: anyerror
///     Any errors. As this is a test function, it doesn't matter what error is returned, if one
///     does, it fails the test.
///
fn testFAT32FS(allocator: Allocator, stream: anytype, fat_config: FATConfig) anyerror!*Fat32FS(@TypeOf(stream)) {
    var test_file_buf = try std.testing.allocator.alloc(u8, 35 * 512);
    defer allocator.free(test_file_buf);

    var temp_stream = &std.io.fixedBufferStream(test_file_buf[0..]);

    try mkfat32.Fat32.make(.{ .image_size = test_file_buf.len }, temp_stream, true);

    var test_fs = try initialiseFAT32(allocator, temp_stream);
    test_fs.stream = stream;
    test_fs.fat_config = fat_config;

    try vfs.setRoot(test_fs.root_node.node);

    return test_fs;
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
        try expectEqualSlices(u8, "12345123", buff[0..end]);
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
        try expectEqualSlices(u8, "€1€2", buff[0..end]);
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
        try expectError(error.DanglingSurrogateHalf, lfn.getName(buff[0..]));
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
        try expectError(error.ExpectedSecondSurrogateHalf, lfn.getName(buff[0..]));
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
        try expectError(error.UnexpectedSecondSurrogateHalf, lfn.getName(buff[0..]));
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
        try expectEqualSlices(u8, "12345678.123", name[0..name_end]);
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
        try expectEqualSlices(u8, "12345.123", name[0..name_end]);
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
        try expectEqualSlices(u8, "12345.1", name[0..name_end]);
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
        try expectEqualSlices(u8, "σ2345.1", name[0..name_end]);
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
        try expectEqualSlices(u8, "Éá345.1", name[0..name_end]);
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
        try expectEqualSlices(u8, "12345.1░", name[0..name_end]);
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
        try expectEqualSlices(u8, "12345678", name[0..name_end]);
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
        try expectEqualSlices(u8, "12345", name[0..name_end]);
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
        try expectEqualSlices(u8, "σ2345", name[0..name_end]);
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
        try expectEqualSlices(u8, "12345", name[0..name_end]);
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
    try expectEqualSlices(u8, expected, name[0..]);
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

        try expect(sfn.isDir());
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

        try expect(!sfn.isDir());
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

    try expectEqual(sfn.getCluster(), 0xABCD1234);
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

    try expectEqual(sfn.calcCheckSum(), 0x7A);
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
    var fat = [_]u32{ 0x0FFFFFFF, 0xFFFFFFF8, 0x0FFFFFFF, 0x00000000 };
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
    try expectEqual(it.cluster, 2);
    try expectEqual(it.cluster_offset, 0);
    try expectEqual(it.table_offset, 0);
    try expectEqualSlices(u32, it.fat, fat[0..]);
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
    var fat = [_]u32{ 0x0FFFFFFF, 0xFFFFFFF8, 0x00000003, 0x0FFFFFFF };
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
    try expectEqual(it.cluster, 3);
    try expectEqual(it.cluster_offset, 0);
    try expectEqual(it.table_offset, 0);
    try expectEqualSlices(u32, it.fat, fat[0..]);
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x04, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        // Second 4 FAT. This is where it will seek to
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    // First 2 are for other purposed and not needed, the third is the first real FAT entry
    var fat = [_]u32{ 0x0FFFFFFF, 0xFFFFFFF8, 0x00000004, 0x0FFFFFFF };
    var expected_fat = [_]u32{ 0x0FFFFFFF, 0x0FFFFFFF, 0x0FFFFFFF, 0x0FFFFFFF };
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
    try expectEqual(it.cluster, 4);
    try expectEqual(it.cluster_offset, 0);
    try expectEqual(it.table_offset, 1);
    try expectEqualSlices(u32, it.fat, expected_fat[0..]);
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
    try expectEqual(actual, null);
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
    try expectEqual(actual, null);
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
    try expectEqual(actual, null);
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
    try expectError(error.BadRead, it.read(buff[0..]));
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region
        'a',  'b',  'c',  'd',  '1',  '2',  '3',  '4',
        'A',  'B',  'C',  'D',  '!',  '"',  '$',  '%',
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    // First 2 are for other purposed and not needed, the third is the first real FAT entry
    var fat = [_]u32{ 0x0FFFFFFF, 0xFFFFFFF8, 0x0FFFFFFF, 0x0FFFFFFF };
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

    try expectEqual(read, 16);
    try expectEqualSlices(u8, buff[0..], "abcd1234ABCD!\"$%");
    try expectEqual(it.table_offset, 0);
    try expectEqual(it.cluster_offset, 0);
    try expectEqual(it.cluster, 0x0FFFFFFF);
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
    try expectError(error.BadRead, Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(std.testing.allocator, fat_config, 2, stream));
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region
        'a',  'b',  'c',  'd',  '1',  '2',  '3',  '4',
        'A',  'B',  'C',  'D',  '!',  '"',  '$',  '%',
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    const allocations: usize = 1;

    var i: usize = 0;
    while (i < allocations) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, i);
        try expectError(error.OutOfMemory, Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(fa.allocator(), fat_config, 2, stream));
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region
        'a',  'b',  'c',  'd',  '1',  '2',  '3',  '4',
        'A',  'B',  'C',  'D',  '!',  '"',  '$',  '%',
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var it = try Fat32FS(@TypeOf(stream)).ClusterChainIterator.init(std.testing.allocator, fat_config, 2, stream);
    defer it.deinit();

    var buff: [16]u8 = undefined;
    // If orelse, then 'try expectEqual(read, 16);' will fail
    const read = (try it.read(buff[0..])) orelse 0;

    try expectEqual(read, 16);
    try expectEqualSlices(u8, buff[0..], "abcd1234ABCD!\"$%");
    try expectEqual(it.table_offset, 0);
    try expectEqual(it.cluster_offset, 0);
    try expectEqual(it.cluster, 0x0FFFFFFF);

    const expect_null = try it.read(buff[read..]);
    try expectEqual(expect_null, null);
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x04, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region cluster 1
        'a',  'b',  'c',  'd',  '1',  '2',  '3',  '4',
        'A',  'B',  'C',  'D',  '!',  '"',  '$',  '%',
        // Data region cluster 2
        'e',  'f',  'g',  'h',  '5',  '6',  '7',  '8',
        'E',  'F',  'G',  'H',  '^',  '&',  '*',  '(',
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

    try expectEqualSlices(u8, it.cluster_block, "abcd1234ABCD!\"$%");
    try it.checkRead();
    // nothing changed
    try expectEqualSlices(u8, it.cluster_block, "abcd1234ABCD!\"$%");
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region cluster 1
        'a',  'b',  'c',  'd',  '1',  '2',  '3',  '4',
        'A',  'B',  'C',  'D',  '!',  '"',  '$',  '%',
        // Data region cluster 2
        'e',  'f',  'g',  'h',  '5',  '6',  '7',  '8',
        'E',  'F',  'G',  'H',  '^',  '&',  '*',  '(',
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

    try expectEqualSlices(u8, it.cluster_block, "abcd1234ABCD!\"$%");
    try it.checkRead();
    try expectEqualSlices(u8, it.cluster_block, "efgh5678EFGH^&*(");
    try expectEqual(it.index, 0);
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region cluster 1
        'a',  'b',  'c',  'd',  '1',  '2',  '3',  '4',
        'A',  'B',  'C',  'D',  '!',  '"',  '$',  '%',
        // Data region cluster 2
        'e',  'f',  'g',  'h',  '5',  '6',  '7',  '8',
        'E',  'F',  'G',  'H',  '^',  '&',  '*',  '(',
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

    try expectEqualSlices(u8, it.cluster_block, "abcd1234ABCD!\"$%");
    try expectError(error.EndClusterChain, it.checkRead());
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region cluster 1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region cluster 2
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
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
    try expectEqual(actual, null);
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region cluster 1
        0xE5, 0x41, 0x4D, 0x44, 0x49, 0x53, 0x7E, 0x32,
        0x54, 0x58, 0x54, 0x00, 0x18, 0x34, 0x47, 0x76,
        0xF9, 0x50, 0x00, 0x00, 0x00, 0x00, 0x48, 0x76,
        0xF9, 0x50, 0x04, 0x00, 0x24, 0x00, 0x00, 0x00,
        // Data region cluster 2
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
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
    try expectEqual(actual, null);
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region cluster 1
        0x42, 0x53, 0x48, 0x4F, 0x52, 0x54, 0x20, 0x20,
        0x54, 0x58, 0x54, 0x00, 0x10, 0xA0, 0x68, 0xA9,
        0xFE, 0x50, 0x00, 0x00, 0x00, 0x00, 0x6E, 0xA9,
        0xFE, 0x50, 0x04, 0x00, 0x13, 0x00, 0x00, 0x00,
        // Data region cluster 2
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
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
    try expectEqualSlices(u8, actual.short_name.getSFNName()[0..], "BSHORT  TXT");
    try expectEqual(actual.long_name, null);
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region cluster 1
        0x41, 0x42, 0x00, 0x73, 0x00, 0x68, 0x00, 0x6F,
        0x00, 0x72, 0x00, 0x0F, 0x00, 0xA8, 0x74, 0x00,
        0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region cluster 2
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region cluster 3
        0x41, 0x42, 0x00, 0x73, 0x00, 0x68, 0x00, 0x6F,
        0x00, 0x72, 0x00, 0x0F, 0x00, 0xA8, 0x74, 0x00,
        0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region cluster 4
        0x41, 0x42, 0x00, 0x73, 0x00, 0x68, 0x00, 0x6F,
        0x00, 0x72, 0x00, 0x0F, 0x00, 0xA8, 0x74, 0x00,
        0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
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

        try expectError(error.Orphan, it.nextImp());
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

        try expectError(error.Orphan, it.nextImp());
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region cluster 1
        0x41, 0x42, 0x00, 0x73, 0x00, 0x68, 0x00, 0x6F,
        0x00, 0x72, 0x00, 0x0F, 0x00, 0x55, 0x74, 0x00,
        0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region cluster 2
        0x42, 0x53, 0x48, 0x4F, 0x52, 0x54, 0x20, 0x20,
        0x54, 0x58, 0x54, 0x00, 0x10, 0xA0, 0x68, 0xA9,
        0xFE, 0x50, 0x00, 0x00, 0x00, 0x00, 0x6E, 0xA9,
        0xFE, 0x50, 0x04, 0x00, 0x13, 0x00, 0x00, 0x00,
        // Data region cluster 3
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
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

    try expectError(error.Orphan, it.nextImp());
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region cluster 1
        0x43, 0x6E, 0x00, 0x67, 0x00, 0x6E, 0x00, 0x61,
        0x00, 0x6D, 0x00, 0x0F, 0x00, 0x6E, 0x65, 0x00,
        0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region cluster 2
        0x01, 0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F,
        0x00, 0x6F, 0x00, 0x0F, 0x00, 0x6E, 0x6F, 0x00,
        0x6E, 0x00, 0x67, 0x00, 0x6C, 0x00, 0x6F, 0x00,
        0x6F, 0x00, 0x00, 0x00, 0x6F, 0x00, 0x6F, 0x00,
        // Data region cluster 3
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
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

    try expectError(error.Orphan, it.nextImp());
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region cluster 1
        0x43, 0x6E, 0x00, 0x67, 0x00, 0x6E, 0x00, 0x61,
        0x00, 0x6D, 0x00, 0x0F, 0x00, 0x6E, 0x65, 0x00,
        0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region cluster 2
        0x02, 0x6E, 0x00, 0x67, 0x00, 0x76, 0x00, 0x65,
        0x00, 0x72, 0x00, 0x0F, 0x00, 0x6E, 0x79, 0x00,
        0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F, 0x00,
        0x6F, 0x00, 0x00, 0x00, 0x6F, 0x00, 0x6F, 0x00,
        // Data region cluster 3
        0x01, 0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F,
        0x00, 0x6F, 0x00, 0x0F, 0x00, 0x6E, 0x6F, 0x00,
        0x6E, 0x00, 0x67, 0x00, 0x6C, 0x00, 0x6F, 0x00,
        0x6F, 0x00, 0x00, 0x00, 0x6F, 0x00, 0x6F, 0x00,
        // Data region cluster 4
        0x4C, 0x4F, 0x4F, 0x4F, 0x4F, 0x4F, 0x7E, 0x31,
        0x54, 0x58, 0x54, 0x00, 0x18, 0xA0, 0x68, 0xA9,
        0xFE, 0x50, 0x00, 0x00, 0x00, 0x00, 0x6E, 0xA9,
        0xFE, 0x50, 0x08, 0x00, 0x13, 0x00, 0x00, 0x00,
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
    try expectEqualSlices(u8, actual.short_name.getSFNName()[0..], "LOOOOO~1TXT");
    try expectEqualSlices(u8, actual.long_name.?, "looooongloooongveryloooooongname.txt");
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00,
        0x07, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00,
        0x07, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region cluster 1
        0x43, 0x6E, 0x00, 0x67, 0x00, 0x6E, 0x00, 0x61,
        0x00, 0x6D, 0x00, 0x0F, 0x00, 0x6E, 0x65, 0x00,
        0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        // Missing 0x02
        // Data region cluster 2
        0x01, 0x6C, 0x00, 0x6F, 0x00, 0x6F, 0x00, 0x6F,
        0x00, 0x6F, 0x00, 0x0F, 0x00, 0x6E, 0x6F, 0x00,
        0x6E, 0x00, 0x67, 0x00, 0x6C, 0x00, 0x6F, 0x00,
        0x6F, 0x00, 0x00, 0x00, 0x6F, 0x00, 0x6F, 0x00,
        // Data region cluster 3
        0x4C, 0x4F, 0x4F, 0x4F, 0x4F, 0x4F, 0x7E, 0x31,
        0x54, 0x58, 0x54, 0x00, 0x18, 0xA0, 0x68, 0xA9,
        0xFE, 0x50, 0x00, 0x00, 0x00, 0x00, 0x6E, 0xA9,
        0xFE, 0x50, 0x08, 0x00, 0x13, 0x00, 0x00, 0x00,
        // Data region cluster 4
        0x42, 0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74,
        0x00, 0x00, 0x00, 0x0F, 0x00, 0xE9, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region cluster 5
        0x01, 0x72, 0x00, 0x61, 0x00, 0x6D, 0x00, 0x64,
        0x00, 0x69, 0x00, 0x0F, 0x00, 0xE9, 0x73, 0x00,
        0x6B, 0x00, 0x5F, 0x00, 0x74, 0x00, 0x65, 0x00,
        0x73, 0x00, 0x00, 0x00, 0x74, 0x00, 0x31, 0x00,
        // Data region cluster 6
        0x52, 0x41, 0x4D, 0x44, 0x49, 0x53, 0x7E, 0x31,
        0x54, 0x58, 0x54, 0x00, 0x18, 0x34, 0x47, 0x76,
        0xF9, 0x50, 0x00, 0x00, 0x00, 0x00, 0x48, 0x76,
        0xF9, 0x50, 0x03, 0x00, 0x10, 0x00, 0x00, 0x00,
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
    try expectEqualSlices(u8, actual1.short_name.getSFNName()[0..], "LOOOOO~1TXT");
    try expectEqual(actual1.long_name, null);

    const actual2 = (try it.next()) orelse return error.TestFail;
    defer actual2.deinit();
    try expectEqualSlices(u8, actual2.short_name.getSFNName()[0..], "RAMDIS~1TXT");
    try expectEqualSlices(u8, actual2.long_name.?, "ramdisk_test1.txt");

    try expectEqual(try it.next(), null);
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region
        'a',  'b',  'c',  'd',  '1',  '2',  '3',  '4',
        'A',  'B',  'C',  'D',  '!',  '"',  '$',  '%',
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    const allocations: usize = 2;

    var i: usize = 0;
    while (i < allocations) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, i);
        try expectError(error.OutOfMemory, Fat32FS(@TypeOf(stream)).EntryIterator.init(fa.allocator(), fat_config, 2, stream));
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Data region (too short)
        'a',  'b',  'c',  'd',  '1',  '2',  '3',  '4',
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    try expectError(error.BadRead, Fat32FS(@TypeOf(stream)).EntryIterator.init(std.testing.allocator, fat_config, 2, stream));
}

test "Fat32FS.getRootNode" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    try expectEqual(test_fs.fs.getRootNode(test_fs.fs), &test_fs.root_node.node.Dir);
    try expectEqual(test_fs.root_node.cluster, 2);
    try expectEqual(test_fs.fat_config.root_directory_cluster, 2);
}

test "Fat32FS.createNode - dir" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    const dir_node = try test_fs.createNode(3, 0, 0, 0, .CREATE_DIR);
    defer std.testing.allocator.destroy(dir_node);
    try expect(dir_node.isDir());
    try expect(test_fs.opened_files.contains(dir_node));
    const opened_info = test_fs.opened_files.fetchRemove(dir_node).?.value;
    defer std.testing.allocator.destroy(opened_info);
    try expectEqual(opened_info.cluster, 3);
    try expectEqual(opened_info.size, 0);
}

test "Fat32FS.createNode - file" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    const file_node = try test_fs.createNode(4, 16, 0, 0, .CREATE_FILE);
    defer std.testing.allocator.destroy(file_node);
    try expect(file_node.isFile());
    try expect(test_fs.opened_files.contains(file_node));
    const opened_info = test_fs.opened_files.fetchRemove(file_node).?.value;
    defer std.testing.allocator.destroy(opened_info);
    try expectEqual(opened_info.cluster, 4);
    try expectEqual(opened_info.size, 16);
}

test "Fat32FS.createNode - symlink" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    try expectError(error.InvalidFlags, test_fs.createNode(4, 16, 0, 0, .CREATE_SYMLINK));
}

test "Fat32FS.createNode - no create" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    try expectError(error.InvalidFlags, test_fs.createNode(4, 16, 0, 0, .NO_CREATION));
}

test "Fat32FS.createNode - free memory" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    // There 2 allocations
    var allocations: usize = 0;
    while (allocations < 2) : (allocations += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, allocations);
        const allocator = fa.allocator();
        test_fs.allocator = allocator;
        try expectError(error.OutOfMemory, test_fs.createNode(3, 16, 0, 0, .CREATE_FILE));
    }
}

test "Fat32FS.getDirCluster - root dir" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    var test_node_1 = try test_fs.createNode(3, 16, 0, 0, .CREATE_FILE);
    defer test_node_1.File.close();

    const actual = try test_fs.getDirCluster(&test_fs.root_node.node.Dir);
    try expectEqual(actual, 2);
}

test "Fat32FS.getDirCluster - sub dir" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    var test_node_1 = try test_fs.createNode(5, 0, 0, 0, .CREATE_DIR);
    defer test_node_1.Dir.close();

    const actual = try test_fs.getDirCluster(&test_node_1.Dir);
    try expectEqual(actual, 5);
}

test "Fat32FS.getDirCluster - not opened dir" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    var test_node_1 = try test_fs.createNode(5, 0, 0, 0, .CREATE_DIR);
    const elem = test_fs.opened_files.fetchRemove(test_node_1).?.value;
    std.testing.allocator.destroy(elem);

    try expectError(error.NotOpened, test_fs.getDirCluster(&test_node_1.Dir));
    std.testing.allocator.destroy(test_node_1);
}

test "Fat32FS.openImpl - entry iterator failed init" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    var test_node_1 = try test_fs.createNode(5, 0, 0, 0, .CREATE_DIR);
    defer test_node_1.Dir.close();

    var fa = std.testing.FailingAllocator.init(std.testing.allocator, 1);
    const allocator = fa.allocator();
    test_fs.allocator = allocator;

    try expectError(error.OutOfMemory, Fat32FS(@TypeOf(test_fat32_image)).openImpl(test_fs.fs, &test_node_1.Dir, "file.txt"));
}

test "Fat32FS.openImpl - entry iterator failed next" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    var fa = std.testing.FailingAllocator.init(std.testing.allocator, 2);
    const allocator = fa.allocator();
    test_fs.allocator = allocator;

    try expectError(error.OutOfMemory, Fat32FS(@TypeOf(test_fat32_image)).openImpl(test_fs.fs, &test_fs.root_node.node.Dir, "short.txt"));
}

test "Fat32FS.openImpl - entry iterator failed 2nd next" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    var fa = std.testing.FailingAllocator.init(std.testing.allocator, 3);
    const allocator = fa.allocator();
    test_fs.allocator = allocator;

    try expectError(error.OutOfMemory, Fat32FS(@TypeOf(test_fat32_image)).openImpl(test_fs.fs, &test_fs.root_node.node.Dir, "short.txt"));
}

test "Fat32FS.openImpl - match short name" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    const file_node = try Fat32FS(@TypeOf(test_fat32_image)).openImpl(test_fs.fs, &test_fs.root_node.node.Dir, "short.txt");
    defer file_node.File.close();
}

test "Fat32FS.openImpl - match long name" {
    return error.SkipZigTest;
    //const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    //defer test_fat32_image.close();
    //
    //var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    //defer test_fs.destroy() catch unreachable;
    //
    //const file_node = try Fat32FS(@TypeOf(test_fat32_image)).openImpl(test_fs.fs, &test_fs.root_node.node.Dir, "insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long.txt");
}

test "Fat32FS.openImpl - no match" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    var test_node_1 = try test_fs.createNode(5, 0, 0, 0, .CREATE_DIR);
    defer test_node_1.Dir.close();

    try expectError(vfs.Error.NoSuchFileOrDir, Fat32FS(@TypeOf(test_fat32_image)).openImpl(test_fs.fs, &test_node_1.Dir, "file.txt"));
}

test "Fat32FS.open - no create - hand crafted" {
    var test_file_buf = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(test_file_buf);

    var stream = &std.io.fixedBufferStream(test_file_buf[0..]);

    try mkfat32.Fat32.make(.{ .image_size = test_file_buf.len }, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy() catch unreachable;

    var entry_buff = [_]u8{
        // Long entry 3
        0x43, 0x6E, 0x00, 0x67, 0x00, 0x6E, 0x00, 0x61, 0x00, 0x6D, 0x00, 0x0F, 0x00, 0x6E, 0x65, 0x00,
        0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
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
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
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

    try vfs.setRoot(test_fs.root_node.node);

    const file = try vfs.openFile("/ramdisk_test1.txt", .NO_CREATION);
    defer file.close();

    try expect(test_fs.opened_files.contains(@ptrCast(*const vfs.Node, file)));
    const opened_info = test_fs.opened_files.get(@ptrCast(*const vfs.Node, file)).?;
    try expectEqual(opened_info.cluster, 3);
    try expectEqual(opened_info.size, 16);
}

fn testOpenRec(dir_node: *const vfs.DirNode, path: []const u8) anyerror!void {
    var test_files = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer test_files.close();

    var it = test_files.iterate();
    while (try it.next()) |file| {
        if (file.kind == .Directory) {
            var dir_path = try std.testing.allocator.alloc(u8, path.len + file.name.len + 1);
            defer std.testing.allocator.free(dir_path);
            std.mem.copy(u8, dir_path[0..], path);
            dir_path[path.len] = '/';
            std.mem.copy(u8, dir_path[path.len + 1 ..], file.name);
            const new_dir = &(try dir_node.open(file.name, .NO_CREATION, .{})).Dir;
            defer new_dir.close();
            try testOpenRec(new_dir, dir_path);
        } else {
            const open_file = &(try dir_node.open(file.name, .NO_CREATION, .{})).File;
            defer open_file.close();
        }
    }
}

test "Fat32FS.open - no create - all files" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    try vfs.setRoot(test_fs.root_node.node);

    try testOpenRec(&test_fs.root_node.node.Dir, "test/fat32/test_files");
}

test "Fat32FS.open - create file" {
    var test_file_buf = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(test_file_buf);

    var stream = &std.io.fixedBufferStream(test_file_buf[0..]);

    try mkfat32.Fat32.make(.{ .image_size = test_file_buf.len }, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy() catch unreachable;

    try vfs.setRoot(test_fs.root_node.node);

    // Open and close
    const open_file = try vfs.openFile("/fileαfile€file.txt", .CREATE_FILE);
    open_file.close();

    // Can't open it as a dir
    try expectError(error.IsAFile, vfs.openDir("/fileαfile€file.txt", .NO_CREATION));

    // Can we open the same file
    const read_file = try vfs.openFile("/fileαfile€file.txt", .NO_CREATION);
    defer read_file.close();

    // Reads nothing
    var buff = [_]u8{0xAA} ** 512;
    const read = read_file.read(buff[0..]);
    try expectEqual(read, 0);
    try expectEqualSlices(u8, buff[0..], &[_]u8{0xAA} ** 512);
}

test "Fat32FS.open - create directory" {
    var test_file_buf = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(test_file_buf);

    var stream = &std.io.fixedBufferStream(test_file_buf[0..]);

    try mkfat32.Fat32.make(.{ .image_size = test_file_buf.len }, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy() catch unreachable;

    try vfs.setRoot(test_fs.root_node.node);

    // Open and close
    const open_dir = try vfs.openDir("/fileαfile€file", .CREATE_DIR);
    open_dir.close();

    // Can't open it as a file
    try expectError(error.IsADirectory, vfs.openFile("/fileαfile€file", .NO_CREATION));

    const open = try vfs.openDir("/fileαfile€file", .NO_CREATION);
    defer open.close();
}

test "Fat32FS.open - create symlink" {
    var test_file_buf = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(test_file_buf);

    var stream = &std.io.fixedBufferStream(test_file_buf[0..]);

    try mkfat32.Fat32.make(.{ .image_size = test_file_buf.len }, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy() catch unreachable;

    try vfs.setRoot(test_fs.root_node.node);

    try expectError(error.InvalidFlags, vfs.openSymlink("/fileαfile€file.txt", "/file.txt", .CREATE_SYMLINK));
}

test "Fat32FS.open - create nested directories" {
    var test_file_buf = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(test_file_buf);

    var stream = &std.io.fixedBufferStream(test_file_buf[0..]);

    try mkfat32.Fat32.make(.{ .image_size = test_file_buf.len }, stream, true);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy() catch unreachable;

    try vfs.setRoot(test_fs.root_node.node);

    const open1 = try vfs.openDir("/fileαfile€file", .CREATE_DIR);
    defer open1.close();

    const open2 = try vfs.openDir("/fileαfile€file/folder", .CREATE_DIR);
    defer open2.close();

    const open3 = try vfs.openDir("/fileαfile€file/folder/1", .CREATE_DIR);
    defer open3.close();

    const open4 = try vfs.openDir("/fileαfile€file/folder/1/2", .CREATE_DIR);
    defer open4.close();

    const open5 = try vfs.openDir("/fileαfile€file/folder/1/2/3", .CREATE_DIR);
    defer open5.close();

    const open6 = try vfs.openDir("/fileαfile€file/folder/1/2/3/end", .CREATE_DIR);
    defer open6.close();

    const open_dir = try vfs.openDir("/fileαfile€file/folder/1/2/3/end", .NO_CREATION);
    defer open_dir.close();
}

test "Fat32FS.read - not opened" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    // Craft a node
    var node = try std.testing.allocator.create(vfs.Node);
    defer std.testing.allocator.destroy(node);
    node.* = .{ .File = .{ .fs = test_fs.fs } };

    try expectError(error.NotOpened, node.File.read(&[_]u8{}));
}

test "Fat32FS.read - cluster iterator init fail" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    var test_node = try test_fs.createNode(5, 16, 0, 0, .CREATE_FILE);
    defer test_node.File.close();

    var fa = std.testing.FailingAllocator.init(std.testing.allocator, 0);
    const allocator = fa.allocator();
    test_fs.allocator = allocator;

    var buff = [_]u8{0xAA} ** 128;
    try expectError(error.OutOfMemory, test_node.File.read(buff[0..]));
}

test "Fat32FS.read - buffer smaller than file" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    try vfs.setRoot(test_fs.root_node.node);

    const test_node = try vfs.openFile("/short.txt", .NO_CREATION);
    defer test_node.close();

    var buff = [_]u8{0xAA} ** 8;
    const read = try test_node.read(buff[0..]);
    try expectEqualSlices(u8, buff[0..read], "short.tx");
}

test "Fat32FS.read - buffer bigger than file" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    try vfs.setRoot(test_fs.root_node.node);

    const test_node = try vfs.openFile("/short.txt", .NO_CREATION);
    defer test_node.close();

    var buff = [_]u8{0xAA} ** 16;
    const read = try test_node.read(buff[0..]);
    try expectEqualSlices(u8, buff[0..read], "short.txt");
    // The rest should be unchanged
    try expectEqualSlices(u8, buff[read..], &[_]u8{0xAA} ** 7);
}

test "Fat32FS.read - large" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    try vfs.setRoot(test_fs.root_node.node);

    const test_node = try vfs.openFile("/large_file.txt", .NO_CREATION);
    defer test_node.close();

    var buff = [_]u8{0xAA} ** 8450;
    const read = try test_node.read(buff[0..]);
    try expectEqual(read, 8450);

    const large_file_content = @embedFile("../../../test/fat32/test_files/large_file.txt");
    try expectEqualSlices(u8, buff[0..], large_file_content[0..]);
}

fn testReadRec(dir_node: *const vfs.DirNode, path: []const u8, read_big: bool) anyerror!void {
    var test_files = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer test_files.close();

    var it = test_files.iterate();
    while (try it.next()) |file| {
        if (file.kind == .Directory) {
            var dir_path = try std.testing.allocator.alloc(u8, path.len + file.name.len + 1);
            defer std.testing.allocator.free(dir_path);
            std.mem.copy(u8, dir_path[0..], path);
            dir_path[path.len] = '/';
            std.mem.copy(u8, dir_path[path.len + 1 ..], file.name);
            const new_dir = &(try dir_node.open(file.name, .NO_CREATION, .{})).Dir;
            defer new_dir.close();
            try testReadRec(new_dir, dir_path, read_big);
        } else {
            const open_file = &(try dir_node.open(file.name, .NO_CREATION, .{})).File;
            defer open_file.close();

            // Have tested the large file
            if (!read_big and std.mem.eql(u8, file.name, "large_file.txt")) {
                continue;
            } else if (read_big and std.mem.eql(u8, file.name, "large_file.txt")) {
                var buff = [_]u8{0xAA} ** 8450;
                const large_file_content = @embedFile("../../../test/fat32/test_files/large_file.txt");
                const read = try open_file.read(buff[0..]);
                try expectEqualSlices(u8, buff[0..], large_file_content[0..]);
                try expectEqual(read, 8450);
                continue;
            }

            // Big enough
            var buff = [_]u8{0xAA} ** 256;
            const read = try open_file.read(buff[0..]);

            // The file content is the same as the file name
            try expectEqual(file.name.len, read);
            try expectEqualSlices(u8, buff[0..read], file.name[0..]);
        }
    }
}

test "Fat32FS.read - all test files" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    try vfs.setRoot(test_fs.root_node.node);

    // Check we can open all the expected files correctly
    var test_files = try std.fs.cwd().openDir("test/fat32/test_files", .{ .iterate = true });
    defer test_files.close();

    try testReadRec(&test_fs.root_node.node.Dir, "test/fat32/test_files", false);
}

test "Fat32FS.findNextFreeCluster - free on error" {
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
        .has_fs_info = false,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    // Too small
    var fat_buff_stream = [_]u8{
        // FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
    };
    var stream = &std.io.fixedBufferStream(fat_buff_stream[0..]);
    var test_fs = try testFAT32FS(std.testing.allocator, stream, fat_config);
    defer test_fs.destroy() catch unreachable;

    try expectError(error.BadRead, test_fs.findNextFreeCluster(2, null));
}

test "Fat32FS.findNextFreeCluster - alloc cluster in first sector" {
    const fat_config = FATConfig{
        .bytes_per_sector = 32,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 2,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = false,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    // 6th entry is free
    var fat_buff_stream = [_]u8{
        // FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // FAT region 2
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Backup FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Backup FAT region 2
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(fat_buff_stream[0..]);
    var test_fs = try testFAT32FS(std.testing.allocator, stream, fat_config);
    defer test_fs.destroy() catch unreachable;

    const cluster = try test_fs.findNextFreeCluster(2, null);
    try expectEqual(cluster, 6);
    // check the FAT where the update would happen + backup FAT
    try expectEqualSlices(u8, fat_buff_stream[24..28], &[_]u8{ 0xFF, 0xFF, 0xFF, 0x0F });
    try expectEqualSlices(u8, fat_buff_stream[88..92], &[_]u8{ 0xFF, 0xFF, 0xFF, 0x0F });
}

test "Fat32FS.findNextFreeCluster - alloc cluster in second sector" {
    const fat_config = FATConfig{
        .bytes_per_sector = 32,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 2,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = false,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    // 6th entry is free
    var fat_buff_stream = [_]u8{
        // FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // FAT region 2
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Backup FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region 2
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(fat_buff_stream[0..]);
    var test_fs = try testFAT32FS(std.testing.allocator, stream, fat_config);
    defer test_fs.destroy() catch unreachable;

    const cluster = try test_fs.findNextFreeCluster(10, null);
    try expectEqual(cluster, 10);
    // check the FAT where the update would happen + backup FAT
    try expectEqualSlices(u8, fat_buff_stream[40..44], &[_]u8{ 0xFF, 0xFF, 0xFF, 0x0F });
    try expectEqualSlices(u8, fat_buff_stream[104..108], &[_]u8{ 0xFF, 0xFF, 0xFF, 0x0F });
}

test "Fat32FS.findNextFreeCluster - alloc cluster over sector boundary" {
    const fat_config = FATConfig{
        .bytes_per_sector = 32,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 2,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = false,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    // 6th entry is free
    var fat_buff_stream = [_]u8{
        // FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // FAT region 2
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Backup FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // Backup FAT region 2
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(fat_buff_stream[0..]);
    var test_fs = try testFAT32FS(std.testing.allocator, stream, fat_config);
    defer test_fs.destroy() catch unreachable;

    const cluster = try test_fs.findNextFreeCluster(2, null);
    try expectEqual(cluster, 10);
    // check the FAT where the update would happen + backup FAT
    try expectEqualSlices(u8, fat_buff_stream[24..28], &[_]u8{ 0xFF, 0xFF, 0xFF, 0x0F });
    try expectEqualSlices(u8, fat_buff_stream[88..92], &[_]u8{ 0xFF, 0xFF, 0xFF, 0x0F });
}

test "Fat32FS.findNextFreeCluster - no free cluster" {
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
        .has_fs_info = false,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    // 6th entry is free
    var fat_buff_stream = [_]u8{
        // FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        // FAT region 2
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
        0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F,
    };
    var stream = &std.io.fixedBufferStream(fat_buff_stream[0..]);
    var test_fs = try testFAT32FS(std.testing.allocator, stream, fat_config);
    defer test_fs.destroy() catch unreachable;

    try expectError(error.DiskFull, test_fs.findNextFreeCluster(2, null));
}

test "Fat32FS.findNextFreeCluster - updates FSInfo" {
    const fat_config = FATConfig{
        .bytes_per_sector = 512,
        .sectors_per_cluster = 1,
        .reserved_sectors = 2,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 2,
        .root_directory_cluster = undefined,
        .fsinfo_sector = 0,
        .backup_boot_sector = 1,
        .has_fs_info = true,
        .number_free_clusters = 10,
        .next_free_cluster = 6,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    // 6th entry is free
    var buff_stream = [_]u8{0x00} ** 488 ++ [_]u8{
        // FSInfo
        0x0A, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00,
    } ++ [_]u8{0x00} ** 504 ++ [_]u8{
        // Backup FSInfo
        0x0A, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    } ++ [_]u8{
        // FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    } ++ [_]u8{0x00} ** 480 ++ [_]u8{
        // FAT region 2
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    } ++ [_]u8{0x00} ** 480 ++ [_]u8{
        // Backup FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    } ++ [_]u8{0x00} ** 480 ++ [_]u8{
        // Backup FAT region 2
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    } ++ [_]u8{0x00} ** 480;
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var test_fs = try testFAT32FS(std.testing.allocator, stream, fat_config);
    defer test_fs.destroy() catch unreachable;

    const cluster = try test_fs.findNextFreeCluster(2, null);
    try expectEqual(cluster, 6);
    try expectEqual(test_fs.fat_config.number_free_clusters, 9);
    try expectEqual(test_fs.fat_config.next_free_cluster, 7);
    try expectEqual(buff_stream[488], 9);
    try expectEqual(buff_stream[492], 7);
    try expectEqual(buff_stream[1000], 9);
    try expectEqual(buff_stream[1004], 7);
}

test "Fat32FS.findNextFreeCluster - updates cluster chain with parent" {
    const fat_config = FATConfig{
        .bytes_per_sector = 32,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 2,
        .root_directory_cluster = undefined,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = false,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    // 6th entry is free
    var fat_buff_stream = [_]u8{
        // FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // FAT region 2
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Backup FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Backup FAT region 2
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(fat_buff_stream[0..]);
    var test_fs = try testFAT32FS(std.testing.allocator, stream, fat_config);
    defer test_fs.destroy() catch unreachable;

    const cluster = try test_fs.findNextFreeCluster(2, 5);
    try expectEqual(cluster, 6);
    // check the FAT where the update would happen + backup FAT
    try expectEqualSlices(u8, fat_buff_stream[20..28], &[_]u8{ 0x06, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F });
    try expectEqualSlices(u8, fat_buff_stream[84..92], &[_]u8{ 0x06, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F });
}

test "Fat32FS.nameToLongName - name too long" {
    const long_name = [_]u8{'A'} ** 256;
    var stream = &std.io.fixedBufferStream(&[_]u8{});
    try expectError(error.InvalidName, Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, long_name[0..]));
}

test "Fat32FS.nameToLongName - leading spaces" {
    const name_cases = [_][]const u8{
        "  file.txt",
        "            file.txt",
        [_]u8{' '} ** 256 ++ "file.txt",
    };

    var stream = &std.io.fixedBufferStream(&[_]u8{});

    const expected = [_]u16{ 'f', 'i', 'l', 'e', '.', 't', 'x', 't' };

    for (name_cases) |case| {
        const actual = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, case[0..]);
        defer std.testing.allocator.free(actual);
        try expectEqualSlices(u16, expected[0..], actual);
    }
}

test "Fat32FS.nameToLongName - invalid name" {
    const name_cases = [_][]const u8{
        "\"file.txt",
        "*file.txt",
        "/file.txt",
        ":file.txt",
        "<file.txt",
        ">file.txt",
        "?file.txt",
        "\\file.txt",
        "|file.txt",
        [_]u8{0x10} ++ "file.txt",
        [_]u8{0x7F} ++ "file.txt",
        "\u{12345}file.txt",
    };

    var stream = &std.io.fixedBufferStream(&[_]u8{});
    for (name_cases) |case| {
        try expectError(error.InvalidName, Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, case[0..]));
    }
}

test "Fat32FS.nameToLongName - trailing spaces or dots" {
    const name_cases = [_][]const u8{
        "file.txt    ",
        "file.txt....",
        "file.txt . .",
        "file.txt" ++ [_]u8{' '} ** 256,
    };

    var stream = &std.io.fixedBufferStream(&[_]u8{});

    const expected = [_]u16{ 'f', 'i', 'l', 'e', '.', 't', 'x', 't' };

    for (name_cases) |case| {
        const actual = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, case[0..]);
        defer std.testing.allocator.free(actual);
        try expectEqualSlices(u16, expected[0..], actual);
    }
}

test "Fat32FS.nameToLongName - valid name" {
    const name_cases = [_][]const u8{
        "....leading_dots.txt",
        "[nope].txt",
        "A_verY_Long_File_namE_With_normal_Extension.tXt",
        "dot.in.file.txt",
        "file.long_ext",
        "file.t x t",
        "insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long_insanely_long.txt",
        "nope.[x]",
        "s  p  a  c  e  s.txt",
        "UTF16.€xt",
        "UTF16€.txt",
        "αlpha.txt",
        "file.txt",
    };

    var stream = &std.io.fixedBufferStream(&[_]u8{});
    for (name_cases) |case| {
        // Can just test no error
        const actual = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, case[0..]);
        defer std.testing.allocator.free(actual);
    }
}

test "Fat32FS.isValidSFNChar - invalid" {
    var stream = &std.io.fixedBufferStream(&[_]u8{});
    try expectEqual(Fat32FS(@TypeOf(stream)).isValidSFNChar(' '), null);
    try expectEqual(Fat32FS(@TypeOf(stream)).isValidSFNChar('€'), null);
    try expectEqual(Fat32FS(@TypeOf(stream)).isValidSFNChar('+'), null);
    try expectEqual(Fat32FS(@TypeOf(stream)).isValidSFNChar(','), null);
    try expectEqual(Fat32FS(@TypeOf(stream)).isValidSFNChar(';'), null);
    try expectEqual(Fat32FS(@TypeOf(stream)).isValidSFNChar('='), null);
    try expectEqual(Fat32FS(@TypeOf(stream)).isValidSFNChar('['), null);
    try expectEqual(Fat32FS(@TypeOf(stream)).isValidSFNChar(']'), null);

    try expectEqual(Fat32FS(@TypeOf(stream)).isValidSFNChar('α'), 0xE0);
    try expectEqual(Fat32FS(@TypeOf(stream)).isValidSFNChar('a'), 'a');
}

test "Fat32FS.longNameToShortName - leading dots and spaces" {
    // Using valid long names
    const name_cases = [_][]const u8{
        "....file.txt",
        ". . file.txt",
    };

    var stream = &std.io.fixedBufferStream(&[_]u8{});
    const expected = "FILE~1  TXT";

    for (name_cases) |case| {
        const long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, case[0..]);
        defer std.testing.allocator.free(long_name);
        const actual = try Fat32FS(@TypeOf(stream)).longNameToShortName(long_name, &[_][11]u8{});
        try expectEqualSlices(u8, actual[0..], expected[0..]);
    }
}

test "Fat32FS.longNameToShortName - embedded spaces" {
    // Using valid long names
    const name_cases = [_][]const u8{
        "f i l e.txt",
        "fi     le.txt",
        "file.t x t",
        "file.tx     t",
    };

    var stream = &std.io.fixedBufferStream(&[_]u8{});
    const expected = "FILE~1  TXT";

    for (name_cases) |case| {
        const long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, case[0..]);
        defer std.testing.allocator.free(long_name);
        const actual = try Fat32FS(@TypeOf(stream)).longNameToShortName(long_name, &[_][11]u8{});
        try expectEqualSlices(u8, actual[0..], expected[0..]);
    }
}

test "Fat32FS.longNameToShortName - dot before end" {
    // Using valid long names
    const name_cases = [_][]const u8{
        "fi.le.txt",
        "f.i.l.e.txt",
        "fi.....le.txt",
        "fi.   le.txt",
    };

    var stream = &std.io.fixedBufferStream(&[_]u8{});
    const expected = "FILE~1  TXT";

    for (name_cases) |case| {
        const long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, case[0..]);
        defer std.testing.allocator.free(long_name);
        const actual = try Fat32FS(@TypeOf(stream)).longNameToShortName(long_name, &[_][11]u8{});
        try expectEqualSlices(u8, actual[0..], expected[0..]);
    }
}

test "Fat32FS.longNameToShortName - long name" {
    // Using valid long names
    const name_cases = [_][]const u8{
        "loooooong.txt",
        "loooooo.ng.txt",
        "loooooo.ng€.txt",
        "looooo€.ng.txt",
        "loooooong.txttttt",
        "looooo.txttttt",
    };

    var stream = &std.io.fixedBufferStream(&[_]u8{});
    const expected = "LOOOOO~1TXT";

    for (name_cases) |case| {
        const long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, case[0..]);
        defer std.testing.allocator.free(long_name);
        const actual = try Fat32FS(@TypeOf(stream)).longNameToShortName(long_name, &[_][11]u8{});
        try expectEqualSlices(u8, actual[0..], expected[0..]);
    }
}

test "Fat32FS.longNameToShortName - short name" {
    // Using valid long names
    const name_cases = [_][]const u8{
        "file1234.txt",
        "FiLe1234.txt",
    };

    var stream = &std.io.fixedBufferStream(&[_]u8{});
    const expected = "FILE1234TXT";

    for (name_cases) |case| {
        const long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, case[0..]);
        defer std.testing.allocator.free(long_name);
        const actual = try Fat32FS(@TypeOf(stream)).longNameToShortName(long_name, &[_][11]u8{});
        try expectEqualSlices(u8, actual[0..], expected[0..]);
    }
}

test "Fat32FS.longNameToShortName - invalid short name characters" {
    // Using valid long names
    const name_cases = [_][]const u8{
        "+file.txt",
        ",file.txt",
        ";file.txt",
        "=file.txt",
        "[file.txt",
        "]file.txt",
        "€file.txt",
    };

    var stream = &std.io.fixedBufferStream(&[_]u8{});
    const expected = "_FILE~1 TXT";

    for (name_cases) |case| {
        const long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, case[0..]);
        defer std.testing.allocator.free(long_name);
        const actual = try Fat32FS(@TypeOf(stream)).longNameToShortName(long_name, &[_][11]u8{});
        try expectEqualSlices(u8, actual[0..], expected[0..]);
    }
}

test "Fat32FS.longNameToShortName - existing name short" {
    const excising_names = &[_][11]u8{
        "FILE    TXT".*,
        "FILE~1  TXT".*,
        "FILE~A  TXT".*,
        "FILE~2  TXT".*,
    };

    var stream = &std.io.fixedBufferStream(&[_]u8{});
    const expected = "FILE~3  TXT";

    const long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, "file.txt");
    defer std.testing.allocator.free(long_name);
    const actual = try Fat32FS(@TypeOf(stream)).longNameToShortName(long_name, excising_names);
    try expectEqualSlices(u8, actual[0..], expected[0..]);
}

test "Fat32FS.longNameToShortName - existing name short rev" {
    const excising_names = &[_][11]u8{
        "FILE~2  TXT".*,
        "FILE~A  TXT".*,
        "FILE~1  TXT".*,
        "FILE    TXT".*,
    };

    var stream = &std.io.fixedBufferStream(&[_]u8{});
    const expected = "FILE~3  TXT";

    const long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, "file.txt");
    defer std.testing.allocator.free(long_name);
    const actual = try Fat32FS(@TypeOf(stream)).longNameToShortName(long_name, excising_names);
    try expectEqualSlices(u8, actual[0..], expected[0..]);
}

test "Fat32FS.longNameToShortName - existing name long" {
    const excising_names = &[_][11]u8{
        "FILEFILETXT".*,
        "FILEFI~1TXT".*,
        "FILEFI~ATXT".*,
        "FILEFI~2TXT".*,
    };

    var stream = &std.io.fixedBufferStream(&[_]u8{});
    const expected = "FILEFI~3TXT";

    const long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, "filefilefile.txt");
    defer std.testing.allocator.free(long_name);
    const actual = try Fat32FS(@TypeOf(stream)).longNameToShortName(long_name, excising_names);
    try expectEqualSlices(u8, actual[0..], expected[0..]);
}

test "Fat32FS.longNameToShortName - existing name long no match" {
    const excising_names = &[_][11]u8{
        "FILEFI~1TXT".*,
        "FILEFI~ATXT".*,
        "FILEFI~2TXT".*,
    };

    var stream = &std.io.fixedBufferStream(&[_]u8{});
    const expected = "FILEFILETXT";

    const long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, "filefile.txt");
    defer std.testing.allocator.free(long_name);
    const actual = try Fat32FS(@TypeOf(stream)).longNameToShortName(long_name, excising_names);
    try expectEqualSlices(u8, actual[0..], expected[0..]);
}

test "Fat32FS.longNameToShortName - trail number to large" {
    const excising_names = &[_][11]u8{
        "F~999999TXT".*,
    };

    var stream = &std.io.fixedBufferStream(&[_]u8{});

    const long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, "filefilefile.txt");
    defer std.testing.allocator.free(long_name);
    try expectError(error.InvalidName, Fat32FS(@TypeOf(stream)).longNameToShortName(long_name, excising_names));
}

test "Fat32FS.longNameToShortName - large trail number" {
    const excising_names = &[_][11]u8{
        "FILE    TXT".*,
        "FILE~2  TXT".*,
        "FILE~3  TXT".*,
        "FILE~4  TXT".*,
        "FILE~5  TXT".*,
        "FILE~6  TXT".*,
        "FILE~7  TXT".*,
        "FILE~8  TXT".*,
        "FILE~9  TXT".*,
    };

    var stream = &std.io.fixedBufferStream(&[_]u8{});
    const expected = "FILE~10 TXT";

    const long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, "file.txt");
    defer std.testing.allocator.free(long_name);
    const actual = try Fat32FS(@TypeOf(stream)).longNameToShortName(long_name, excising_names);
    try expectEqualSlices(u8, actual[0..], expected[0..]);
}

test "Fat32FS.longNameToShortName - CP437" {
    var stream = &std.io.fixedBufferStream(&[_]u8{});
    const expected = [_]u8{0xE0} ++ "LPHA   TXT";

    const long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, "αlpha.txt");
    defer std.testing.allocator.free(long_name);
    const actual = try Fat32FS(@TypeOf(stream)).longNameToShortName(long_name, &[_][11]u8{});
    try expectEqualSlices(u8, actual[0..], expected[0..]);
}

test "Fat32FS.createLongNameEntry - less than 13 characters" {
    var stream = &std.io.fixedBufferStream(&[_]u8{});
    // Pre-calculated check fum for file.txt => FILE    TXT
    const check_sum: u8 = 25;
    // Using valid long name
    const long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, "file.txt");
    defer std.testing.allocator.free(long_name);
    const entries = try Fat32FS(@TypeOf(stream)).createLongNameEntry(std.testing.allocator, long_name, check_sum);
    defer std.testing.allocator.free(entries);

    try expectEqual(entries.len, 1);

    const expected = LongName{
        .order = 0x41,
        .first = [_]u16{'f'} ++ [_]u16{'i'} ++ [_]u16{'l'} ++ [_]u16{'e'} ++ [_]u16{'.'},
        .check_sum = check_sum,
        .second = [_]u16{'t'} ++ [_]u16{'x'} ++ [_]u16{'t'} ++ [_]u16{ 0x0000, 0xFFFF, 0xFFFF },
        .third = [_]u16{ 0xFFFF, 0xFFFF },
    };

    try expectEqual(entries[0], expected);
}

test "Fat32FS.createLongNameEntry - greater than 13 characters" {
    var stream = &std.io.fixedBufferStream(&[_]u8{});
    // Pre-calculated check fum for filefilefilefile.txt => FILEFI~1TXT
    const check_sum: u8 = 123;
    // Using valid long name
    const long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, "filefilefilefile.txt");
    defer std.testing.allocator.free(long_name);
    const entries = try Fat32FS(@TypeOf(stream)).createLongNameEntry(std.testing.allocator, long_name, check_sum);
    defer std.testing.allocator.free(entries);

    try expectEqual(entries.len, 2);

    var expected = [_]LongName{
        LongName{
            .order = 0x42,
            .first = [_]u16{'i'} ++ [_]u16{'l'} ++ [_]u16{'e'} ++ [_]u16{'.'} ++ [_]u16{'t'},
            .check_sum = check_sum,
            .second = [_]u16{'x'} ++ [_]u16{'t'} ++ [_]u16{ 0x0000, 0xFFFF, 0xFFFF, 0xFFFF },
            .third = [_]u16{ 0xFFFF, 0xFFFF },
        },
        LongName{
            .order = 0x01,
            .first = [_]u16{'f'} ++ [_]u16{'i'} ++ [_]u16{'l'} ++ [_]u16{'e'} ++ [_]u16{'f'},
            .check_sum = check_sum,
            .second = [_]u16{'i'} ++ [_]u16{'l'} ++ [_]u16{'e'} ++ [_]u16{'f'} ++ [_]u16{'i'} ++ [_]u16{'l'},
            .third = [_]u16{'e'} ++ [_]u16{'f'},
        },
    };

    try expectEqual(entries[0], expected[0]);
    try expectEqual(entries[1], expected[1]);
}

test "Fat32FS.createLongNameEntry - max 255 characters" {
    var stream = &std.io.fixedBufferStream(&[_]u8{});
    // Pre-calculated check fum for A**255 => AAAAAA~1TXT
    const check_sum: u8 = 17;
    // Using valid long name
    const name = [_]u8{'A'} ** 255;
    const long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, name[0..]);
    defer std.testing.allocator.free(long_name);
    const entries = try Fat32FS(@TypeOf(stream)).createLongNameEntry(std.testing.allocator, long_name, check_sum);
    defer std.testing.allocator.free(entries);

    try expectEqual(entries.len, 20);

    const UA = [_]u16{'A'};

    var expected = [_]LongName{LongName{
        .order = 0x00,
        .first = UA ** 5,
        .check_sum = check_sum,
        .second = UA ** 6,
        .third = UA ** 2,
    }} ** 20;

    for (expected) |*e, i| {
        e.order = 20 - @intCast(u8, i);
    }
    expected[0] = LongName{
        .order = 0x54, // 0x40 | 0x14
        .first = UA ** 5,
        .check_sum = check_sum,
        .second = UA ** 3 ++ [_]u16{ 0x0000, 0xFFFF, 0xFFFF },
        .third = [_]u16{ 0xFFFF, 0xFFFF },
    };

    for (expected) |ex, i| {
        try expectEqual(entries[i], ex);
    }
}

test "Fat32FS.createShortNameEntry" {
    var stream = &std.io.fixedBufferStream(&[_]u8{});
    const actual = Fat32FS(@TypeOf(stream)).createShortNameEntry("FILE    TXT".*, .None, 0x10);
    // Expects 12:12:13 12/12/2012 from mock arch
    const expected = ShortName{
        .name = "FILE    ".*,
        .extension = "TXT".*,
        .attributes = 0x00,
        .time_created_tenth = 0x64, // 100 (1 sec)
        .time_created = 0x6186,
        .date_created = 0x418C,
        .date_last_access = 0x418C,
        .cluster_high = 0x00,
        .time_last_modification = 0x6186,
        .date_last_modification = 0x418C,
        .cluster_low = 0x10,
        .size = 0x00000000,
    };
    try expectEqual(actual, expected);
}

test "Fat32FS.writeEntries - all free cluster" {
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
        // FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Backup FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var test_fs = try testFAT32FS(std.testing.allocator, stream, fat_config);
    defer test_fs.destroy() catch unreachable;

    const entries = FatDirEntry{
        .short_entry = Fat32FS(@TypeOf(stream)).createShortNameEntry("FILE    TXT".*, .None, 3),
        .long_entry = &[_]LongName{},
    };

    // Convert to bytes
    var expected_bytes: [32]u8 = undefined;
    initBytes(ShortName, entries.short_entry, expected_bytes[0..]);

    _ = try test_fs.writeEntries(entries, 2, 3, 0);
    try expectEqualSlices(u8, expected_bytes[0..], buff_stream[64..]);
}

test "Fat32FS.writeEntries - half free cluster" {
    const fat_config = FATConfig{
        .bytes_per_sector = 64,
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
        // FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Backup FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region
        0x49, 0x4E, 0x53, 0x41, 0x4E, 0x45, 0x7E, 0x31,
        0x54, 0x58, 0x54, 0x20, 0x00, 0x00, 0x9B, 0xB9,
        0x88, 0x51, 0x88, 0x51, 0x00, 0x00, 0x9B, 0xB9,
        0x88, 0x51, 0x0D, 0x00, 0xE3, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var test_fs = try testFAT32FS(std.testing.allocator, stream, fat_config);
    defer test_fs.destroy() catch unreachable;

    const entries = FatDirEntry{
        .short_entry = Fat32FS(@TypeOf(stream)).createShortNameEntry("FILE    TXT".*, .None, 3),
        .long_entry = &[_]LongName{},
    };

    // Convert to bytes
    var expected_bytes: [32]u8 = undefined;
    initBytes(ShortName, entries.short_entry, expected_bytes[0..]);

    _ = try test_fs.writeEntries(entries, 2, 3, 32);
    try expectEqualSlices(u8, expected_bytes[0..], buff_stream[160..]);
}

test "Fat32FS.writeEntries - full cluster" {
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
        // FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Backup FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region 1
        0x49, 0x4E, 0x53, 0x41, 0x4E, 0x45, 0x7E, 0x31,
        0x54, 0x58, 0x54, 0x20, 0x00, 0x00, 0x9B, 0xB9,
        0x88, 0x51, 0x88, 0x51, 0x00, 0x00, 0x9B, 0xB9,
        0x88, 0x51, 0x0D, 0x00, 0xE3, 0x00, 0x00, 0x00,
        // Data region 2
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var test_fs = try testFAT32FS(std.testing.allocator, stream, fat_config);
    defer test_fs.destroy() catch unreachable;

    const entries = FatDirEntry{
        .short_entry = Fat32FS(@TypeOf(stream)).createShortNameEntry("FILE    TXT".*, .None, 3),
        .long_entry = &[_]LongName{},
    };

    // Convert to bytes
    var expected_bytes: [32]u8 = undefined;
    initBytes(ShortName, entries.short_entry, expected_bytes[0..]);

    _ = try test_fs.writeEntries(entries, 2, 3, 32);
    try expectEqualSlices(u8, expected_bytes[0..], buff_stream[96..]);
    try expectEqualSlices(u8, buff_stream[8..16], &[_]u8{ 0x03, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F });
    try expectEqualSlices(u8, buff_stream[40..48], &[_]u8{ 0x03, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x0F });
}

test "Fat32FS.writeEntries - large entry over 3 clusters" {
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
        // FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Backup FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region 1
        0x49, 0x4E, 0x53, 0x41, 0x4E, 0x45, 0x7E, 0x31,
        0x54, 0x58, 0x54, 0x20, 0x00, 0x00, 0x9B, 0xB9,
        0x88, 0x51, 0x88, 0x51, 0x00, 0x00, 0x9B, 0xB9,
        0x88, 0x51, 0x0D, 0x00, 0xE3, 0x00, 0x00, 0x00,
        // Data region 2
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region 3
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region 4
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var test_fs = try testFAT32FS(std.testing.allocator, stream, fat_config);
    defer test_fs.destroy() catch unreachable;

    const short_entry = Fat32FS(@TypeOf(stream)).createShortNameEntry("FILE    TXT".*, .None, 3);

    const long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, "filefilefile.txt");
    defer std.testing.allocator.free(long_name);
    const long_entry = try Fat32FS(@TypeOf(stream)).createLongNameEntry(std.testing.allocator, long_name, short_entry.calcCheckSum());
    defer std.testing.allocator.free(long_entry);

    try expectEqual(long_entry.len, 2);

    const entries = FatDirEntry{
        .short_entry = short_entry,
        .long_entry = long_entry,
    };

    // Convert to bytes
    var expected_bytes: [96]u8 = undefined;
    initBytes(LongName, entries.long_entry[0], expected_bytes[0..32]);
    initBytes(LongName, entries.long_entry[1], expected_bytes[32..64]);
    initBytes(ShortName, entries.short_entry, expected_bytes[64..]);

    _ = try test_fs.writeEntries(entries, 2, 3, 32);
    try expectEqualSlices(u8, expected_bytes[0..], buff_stream[96..]);
}

test "Fat32FS.createFileOrDir - create file" {
    const fat_config = FATConfig{
        .bytes_per_sector = 32,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = 2,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = false,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    var buff_stream = [_]u8{
        // FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Backup FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region 1 (Root dir long name)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region 2 (File)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region 3 (Root dir short name)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var test_fs = try testFAT32FS(std.testing.allocator, stream, fat_config);
    defer test_fs.destroy() catch unreachable;

    const file = try Fat32FS(@TypeOf(stream)).createFileOrDir(test_fs.fs, &test_fs.root_node.node.Dir, "file.txt", false);
    defer file.File.close();

    const expected_short_entry = Fat32FS(@TypeOf(stream)).createShortNameEntry("FILE    TXT".*, .None, 3);
    const expected_long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, "file.txt");
    defer std.testing.allocator.free(expected_long_name);
    const expected_long_entry = try Fat32FS(@TypeOf(stream)).createLongNameEntry(std.testing.allocator, expected_long_name, expected_short_entry.calcCheckSum());
    defer std.testing.allocator.free(expected_long_entry);

    var temp_buf: [32]u8 = undefined;
    initBytes(LongName, expected_long_entry[0], temp_buf[0..]);
    try expectEqualSlices(u8, buff_stream[64..96], temp_buf[0..]);
    initBytes(ShortName, expected_short_entry, temp_buf[0..]);
    try expectEqualSlices(u8, buff_stream[128..], temp_buf[0..]);

    // FAT
    try expectEqualSlices(u8, buff_stream[8..12], &[_]u8{ 0x04, 0x00, 0x00, 0x00 });
    try expectEqualSlices(u8, buff_stream[12..16], &[_]u8{ 0xFF, 0xFF, 0xFF, 0x0F });
    try expectEqualSlices(u8, buff_stream[16..20], &[_]u8{ 0xFF, 0xFF, 0xFF, 0x0F });
}

test "Fat32FS.createFileOrDir - create directory" {
    const fat_config = FATConfig{
        .bytes_per_sector = 32,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = 2,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = false,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    var buff_stream = [_]u8{
        // FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Backup FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region 1 (Root dir long name)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region 2 (Directory)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region 3 (Root dir short name)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var test_fs = try testFAT32FS(std.testing.allocator, stream, fat_config);
    defer test_fs.destroy() catch unreachable;

    const file = try Fat32FS(@TypeOf(stream)).createFileOrDir(test_fs.fs, &test_fs.root_node.node.Dir, "folder", true);
    defer file.Dir.close();

    const expected_short_entry = Fat32FS(@TypeOf(stream)).createShortNameEntry("FOLDER     ".*, .Directory, 3);
    const expected_long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, "folder");
    defer std.testing.allocator.free(expected_long_name);
    const expected_long_entry = try Fat32FS(@TypeOf(stream)).createLongNameEntry(std.testing.allocator, expected_long_name, expected_short_entry.calcCheckSum());
    defer std.testing.allocator.free(expected_long_entry);

    var temp_buf: [32]u8 = undefined;
    initBytes(LongName, expected_long_entry[0], temp_buf[0..]);
    try expectEqualSlices(u8, buff_stream[64..96], temp_buf[0..]);
    initBytes(ShortName, expected_short_entry, temp_buf[0..]);
    try expectEqualSlices(u8, buff_stream[128..], temp_buf[0..]);

    // FAT
    try expectEqualSlices(u8, buff_stream[8..12], &[_]u8{ 0x04, 0x00, 0x00, 0x00 });
    try expectEqualSlices(u8, buff_stream[12..16], &[_]u8{ 0xFF, 0xFF, 0xFF, 0x0F });
    try expectEqualSlices(u8, buff_stream[16..20], &[_]u8{ 0xFF, 0xFF, 0xFF, 0x0F });
}

test "Fat32FS.createFileOrDir - create file parent cluster full" {
    const fat_config = FATConfig{
        .bytes_per_sector = 32,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = 2,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = false,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };
    var buff_stream = [_]u8{
        // FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Backup FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region 1 (Root dir full)
        0x49, 0x4E, 0x53, 0x41, 0x4E, 0x45, 0x7E, 0x31,
        0x54, 0x58, 0x54, 0x20, 0x00, 0x00, 0x9B, 0xB9,
        0x88, 0x51, 0x88, 0x51, 0x00, 0x00, 0x9B, 0xB9,
        0x88, 0x51, 0x0D, 0x00, 0xE3, 0x00, 0x00, 0x00,
        // Data region 2 (File)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region 3 (Root dir long name)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region 4 (Root dir short name)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var test_fs = try testFAT32FS(std.testing.allocator, stream, fat_config);
    defer test_fs.destroy() catch unreachable;

    const file = try Fat32FS(@TypeOf(stream)).createFileOrDir(test_fs.fs, &test_fs.root_node.node.Dir, "file.txt", false);
    defer file.File.close();

    const expected_short_entry = Fat32FS(@TypeOf(stream)).createShortNameEntry("FILE    TXT".*, .None, 3);
    const expected_long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, "file.txt");
    defer std.testing.allocator.free(expected_long_name);
    const expected_long_entry = try Fat32FS(@TypeOf(stream)).createLongNameEntry(std.testing.allocator, expected_long_name, expected_short_entry.calcCheckSum());
    defer std.testing.allocator.free(expected_long_entry);

    var temp_buf: [32]u8 = undefined;
    initBytes(LongName, expected_long_entry[0], temp_buf[0..]);
    try expectEqualSlices(u8, buff_stream[128..160], temp_buf[0..]);
    initBytes(ShortName, expected_short_entry, temp_buf[0..]);
    try expectEqualSlices(u8, buff_stream[160..], temp_buf[0..]);

    // FAT
    try expectEqualSlices(u8, buff_stream[8..12], &[_]u8{ 0x04, 0x00, 0x00, 0x00 });
    try expectEqualSlices(u8, buff_stream[12..16], &[_]u8{ 0xFF, 0xFF, 0xFF, 0x0F });
    try expectEqualSlices(u8, buff_stream[16..20], &[_]u8{ 0x05, 0x00, 0x00, 0x00 });
    try expectEqualSlices(u8, buff_stream[20..24], &[_]u8{ 0xFF, 0xFF, 0xFF, 0x0F });
}

test "Fat32FS.createFileOrDir - half root" {
    const fat_config = FATConfig{
        .bytes_per_sector = 64,
        .sectors_per_cluster = 1,
        .reserved_sectors = 0,
        .hidden_sectors = undefined,
        .total_sectors = undefined,
        .sectors_per_fat = 1,
        .root_directory_cluster = 2,
        .fsinfo_sector = undefined,
        .backup_boot_sector = undefined,
        .has_fs_info = false,
        .number_free_clusters = undefined,
        .next_free_cluster = undefined,
        .cluster_end_marker = 0x0FFFFFFF,
    };

    var buff_stream = [_]u8{
        // FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Backup FAT region 1
        0xFF, 0xFF, 0xFF, 0x0F, 0xF8, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region 1 (Root long)
        0x49, 0x4E, 0x53, 0x41, 0x4E, 0x45, 0x7E, 0x31,
        0x54, 0x58, 0x54, 0x20, 0x00, 0x00, 0x9B, 0xB9,
        0x88, 0x51, 0x88, 0x51, 0x00, 0x00, 0x9B, 0xB9,
        0x88, 0x51, 0x0D, 0x00, 0xE3, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region 2 (File)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Data region 2 (Root short half)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var stream = &std.io.fixedBufferStream(buff_stream[0..]);
    var test_fs = try testFAT32FS(std.testing.allocator, stream, fat_config);
    defer test_fs.destroy() catch unreachable;

    const file = try Fat32FS(@TypeOf(stream)).createFileOrDir(test_fs.fs, &test_fs.root_node.node.Dir, "file.txt", false);
    defer file.File.close();

    const expected_short_entry = Fat32FS(@TypeOf(stream)).createShortNameEntry("FILE    TXT".*, .None, 3);
    const expected_long_name = try Fat32FS(@TypeOf(stream)).nameToLongName(std.testing.allocator, "file.txt");
    defer std.testing.allocator.free(expected_long_name);
    const expected_long_entry = try Fat32FS(@TypeOf(stream)).createLongNameEntry(std.testing.allocator, expected_long_name, expected_short_entry.calcCheckSum());
    defer std.testing.allocator.free(expected_long_entry);

    var temp_buf: [32]u8 = undefined;
    initBytes(LongName, expected_long_entry[0], temp_buf[0..]);
    try expectEqualSlices(u8, buff_stream[160..192], temp_buf[0..]);
    initBytes(ShortName, expected_short_entry, temp_buf[0..]);
    try expectEqualSlices(u8, buff_stream[256..288], temp_buf[0..]);

    // FAT
    try expectEqualSlices(u8, buff_stream[8..12], &[_]u8{ 0x04, 0x00, 0x00, 0x00 });
    try expectEqualSlices(u8, buff_stream[12..16], &[_]u8{ 0xFF, 0xFF, 0xFF, 0x0F });
    try expectEqualSlices(u8, buff_stream[16..20], &[_]u8{ 0xFF, 0xFF, 0xFF, 0x0F });
}

test "Fat32FS.write - small file" {
    var test_file_buf = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(test_file_buf);

    var stream = &std.io.fixedBufferStream(test_file_buf[0..]);

    try mkfat32.Fat32.make(.{ .image_size = test_file_buf.len }, stream, false);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy() catch unreachable;

    try vfs.setRoot(test_fs.root_node.node);

    const file = try vfs.openFile("/file.txt", .CREATE_FILE);

    const text = "Hello, world!\n";

    const written = try file.write(text[0..]);
    try expectEqual(written, text.len);

    var read_buf1: [text.len * 2]u8 = undefined;
    const read1 = try file.read(read_buf1[0..]);
    try expectEqual(read1, text.len);
    try expectEqualSlices(u8, text[0..], read_buf1[0..read1]);
    file.close();

    const read_file = try vfs.openFile("/file.txt", .NO_CREATION);
    defer read_file.close();

    var read_buf2: [text.len * 2]u8 = undefined;
    const read2 = try read_file.read(read_buf2[0..]);

    try expectEqual(read2, text.len);
    try expectEqualSlices(u8, text[0..], read_buf2[0..read2]);
}

test "Fat32FS.write - large file" {
    var test_file_buf = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(test_file_buf);

    var stream = &std.io.fixedBufferStream(test_file_buf[0..]);

    try mkfat32.Fat32.make(.{ .image_size = test_file_buf.len }, stream, false);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy() catch unreachable;

    try vfs.setRoot(test_fs.root_node.node);

    const file = try vfs.openFile("/file.txt", .CREATE_FILE);

    // Check the opened file
    const open_info1 = test_fs.opened_files.get(@ptrCast(*const vfs.Node, file)).?;
    try expectEqual(open_info1.cluster, 3);
    try expectEqual(open_info1.size, 0);
    try expectEqual(open_info1.entry_cluster, 2);
    try expectEqual(open_info1.entry_offset, 60);

    const fat_offset = test_fs.fat_config.reserved_sectors * test_fs.fat_config.bytes_per_sector + 12;
    try expectEqualSlices(u8, test_file_buf[fat_offset .. fat_offset + 4], &[_]u8{ 0xFF, 0xFF, 0xFF, 0x0F });

    const text = [_]u8{'A'} ** (8 * 1024);

    const written = try file.write(text[0..]);
    try expectEqual(written, text.len);

    // Check the FAT
    const expected_fat = [_]u32{ 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x0FFFFFFF };
    try expectEqualSlices(u8, test_file_buf[fat_offset .. fat_offset + (16 * 4)], std.mem.sliceAsBytes(expected_fat[0..]));

    var read_buf1: [text.len * 2]u8 = undefined;
    const read1 = try file.read(read_buf1[0..]);
    try expectEqual(read1, text.len);
    try expectEqualSlices(u8, text[0..], read_buf1[0..read1]);
    file.close();

    const read_file = try vfs.openFile("/file.txt", .NO_CREATION);
    defer read_file.close();

    const open_info2 = test_fs.opened_files.get(@ptrCast(*const vfs.Node, read_file)).?;
    try expectEqual(open_info2.cluster, 3);
    try expectEqual(open_info2.size, text.len);
    try expectEqual(open_info2.entry_cluster, 2);
    try expectEqual(open_info2.entry_offset, 60);

    var read_buf2: [text.len * 2]u8 = undefined;
    const read2 = try read_file.read(read_buf2[0..]);

    try expectEqual(read2, text.len);
    try expectEqualSlices(u8, text[0..], read_buf2[0..read2]);
}

fn testWriteRec(dir_node: *const vfs.DirNode, path: []const u8) anyerror!void {
    var test_files = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer test_files.close();

    var it = test_files.iterate();
    while (try it.next()) |file| {
        if (file.kind == .Directory) {
            var dir_path = try std.testing.allocator.alloc(u8, path.len + file.name.len + 1);
            defer std.testing.allocator.free(dir_path);
            std.mem.copy(u8, dir_path[0..], path);
            dir_path[path.len] = '/';
            std.mem.copy(u8, dir_path[path.len + 1 ..], file.name);
            const new_dir = &(try dir_node.open(file.name, .CREATE_DIR, .{})).Dir;
            defer new_dir.close();
            try testWriteRec(new_dir, dir_path);
        } else {
            // Open the test file
            const test_file = try test_files.openFile(file.name, .{});
            defer test_file.close();

            // Read the content
            const test_file_content = try test_file.readToEndAlloc(std.testing.allocator, 0xFFFF);
            defer std.testing.allocator.free(test_file_content);

            const open_file = &(try dir_node.open(file.name, .CREATE_FILE, .{})).File;
            defer open_file.close();

            // Write the content
            const written = try open_file.write(test_file_content);
            if (written != test_file_content.len) {
                return error.BadWrite;
            }
        }
    }
}

test "Fat32FS.write - test files" {
    var test_file_buf = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(test_file_buf);

    var stream = &std.io.fixedBufferStream(test_file_buf[0..]);

    try mkfat32.Fat32.make(.{ .image_size = test_file_buf.len }, stream, false);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy() catch unreachable;

    try vfs.setRoot(test_fs.root_node.node);

    try testWriteRec(&test_fs.root_node.node.Dir, "test/fat32/test_files");

    const image = try std.fs.cwd().createFile("ig.img", .{});
    defer image.close();

    _ = try image.writer().writeAll(test_file_buf);

    try testReadRec(&test_fs.root_node.node.Dir, "test/fat32/test_files", true);
}

test "Fat32FS.write - not enough space" {
    var test_file_buf = try std.testing.allocator.alloc(u8, 37 * 512);
    defer std.testing.allocator.free(test_file_buf);

    var stream = &std.io.fixedBufferStream(test_file_buf[0..]);

    try mkfat32.Fat32.make(.{ .image_size = test_file_buf.len }, stream, false);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.destroy() catch unreachable;

    try vfs.setRoot(test_fs.root_node.node);

    const text = [_]u8{'A'} ** 1025;

    const file = try vfs.openFile("/file.txt", .CREATE_FILE);
    defer file.close();

    try expectError(error.Unexpected, file.write(text[0..]));

    const offset = test_fs.fat_config.clusterToSector(3) * test_fs.fat_config.bytes_per_sector;
    try expectEqualSlices(u8, test_file_buf[offset .. offset + 1024], &[_]u8{0x00} ** 1024);
}

test "Fat32FS.init no error" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;
}

test "Fat32FS.init errors" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_file_buf = try std.testing.allocator.alloc(u8, (32 * 512 + 4) + 1);
    defer std.testing.allocator.free(test_file_buf);

    _ = try test_fat32_image.reader().readAll(test_file_buf[0..]);
    const stream = &std.io.fixedBufferStream(test_file_buf[0..]);

    // BadMBRMagic
    test_file_buf[510] = 0x00;
    try expectError(error.BadMBRMagic, initialiseFAT32(std.testing.allocator, stream));
    test_file_buf[510] = 0x55;

    test_file_buf[511] = 0x00;
    try expectError(error.BadMBRMagic, initialiseFAT32(std.testing.allocator, stream));
    test_file_buf[511] = 0xAA;

    // BadRootCluster
    // Little endian, so just eed to set the upper bytes
    test_file_buf[44] = 0;
    try expectError(error.BadRootCluster, initialiseFAT32(std.testing.allocator, stream));

    test_file_buf[44] = 1;
    try expectError(error.BadRootCluster, initialiseFAT32(std.testing.allocator, stream));
    test_file_buf[44] = 2;

    // BadFATCount
    test_file_buf[16] = 0;
    try expectError(error.BadFATCount, initialiseFAT32(std.testing.allocator, stream));

    test_file_buf[16] = 1;
    try expectError(error.BadFATCount, initialiseFAT32(std.testing.allocator, stream));

    test_file_buf[16] = 10;
    try expectError(error.BadFATCount, initialiseFAT32(std.testing.allocator, stream));
    test_file_buf[16] = 2;

    // NotMirror
    test_file_buf[40] = 1;
    try expectError(error.NotMirror, initialiseFAT32(std.testing.allocator, stream));

    test_file_buf[40] = 10;
    try expectError(error.NotMirror, initialiseFAT32(std.testing.allocator, stream));
    test_file_buf[40] = 0;

    // BadMedia
    test_file_buf[21] = 0xF0;
    try expectError(error.BadMedia, initialiseFAT32(std.testing.allocator, stream));
    test_file_buf[21] = 0xF8;

    // BadFat32
    test_file_buf[17] = 10;
    try expectError(error.BadFat32, initialiseFAT32(std.testing.allocator, stream));
    test_file_buf[17] = 0;

    test_file_buf[19] = 10;
    try expectError(error.BadFat32, initialiseFAT32(std.testing.allocator, stream));
    test_file_buf[19] = 0;

    test_file_buf[22] = 10;
    try expectError(error.BadFat32, initialiseFAT32(std.testing.allocator, stream));
    test_file_buf[22] = 0;

    // BadSignature
    test_file_buf[66] = 0x28;
    try expectError(error.BadSignature, initialiseFAT32(std.testing.allocator, stream));
    test_file_buf[66] = 0x29;

    // BadFSType
    // Change from FAT32 to FAT16
    test_file_buf[85] = '1';
    test_file_buf[86] = '6';
    try expectError(error.BadFSType, initialiseFAT32(std.testing.allocator, stream));
    test_file_buf[85] = '3';
    test_file_buf[86] = '2';

    // Test the bad reads
    // Boot sector
    try expectError(error.BadRead, initialiseFAT32(std.testing.allocator, &std.io.fixedBufferStream(test_file_buf[0..510])));
    // FSInfo (we have one)
    try expectError(error.BadRead, initialiseFAT32(std.testing.allocator, &std.io.fixedBufferStream(test_file_buf[0 .. 512 + 100])));
    // FAT
    try expectError(error.BadRead, initialiseFAT32(std.testing.allocator, &std.io.fixedBufferStream(test_file_buf[0 .. (32 * 512 + 4) + 1])));
}

test "Fat32FS.init free memory" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    const allocations: usize = 5;
    var i: usize = 0;
    while (i < allocations) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, i);
        try expectError(error.OutOfMemory, initialiseFAT32(fa.allocator(), test_fat32_image));
    }
}

test "Fat32FS.init FATConfig expected" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_fs = try initialiseFAT32(std.testing.allocator, test_fat32_image);
    defer test_fs.destroy() catch unreachable;

    // This is the expected FAT config from the initialised FAT device
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
        .number_free_clusters = 65473,
        .next_free_cluster = 53,
        .cluster_end_marker = 0x0FFFFFFF,
    };

    try expectEqual(test_fs.fat_config, expected);
}

test "Fat32FS.init FATConfig mix FSInfo" {
    const test_fat32_image = try std.fs.cwd().openFile("test/fat32/test_fat32.img", .{});
    defer test_fat32_image.close();

    var test_file_buf = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(test_file_buf);

    _ = try test_fat32_image.reader().readAll(test_file_buf[0..]);
    const stream = &std.io.fixedBufferStream(test_file_buf[0..]);

    // No FSInfo
    {
        // Force no FSInfo
        test_file_buf[48] = 0x00;

        var test_fs = try initialiseFAT32(std.testing.allocator, stream);
        defer test_fs.destroy() catch unreachable;

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

        try expectEqual(test_fs.fat_config, expected);
        test_file_buf[48] = 0x01;
    }

    // Bad Signatures
    {
        // Corrupt a signature
        test_file_buf[512] = 0xAA;

        var test_fs = try initialiseFAT32(std.testing.allocator, stream);
        defer test_fs.destroy() catch unreachable;

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

        try expectEqual(test_fs.fat_config, expected);
        test_file_buf[512] = 0x52;
    }

    // Bad number_free_clusters
    {
        // Make is massive
        test_file_buf[512 + 4 + 480 + 4] = 0xAA;
        test_file_buf[512 + 4 + 480 + 5] = 0xBB;
        test_file_buf[512 + 4 + 480 + 6] = 0xCC;
        test_file_buf[512 + 4 + 480 + 7] = 0xDD;

        var test_fs = try initialiseFAT32(std.testing.allocator, stream);
        defer test_fs.destroy() catch unreachable;

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
            .next_free_cluster = 53,
            .cluster_end_marker = 0x0FFFFFFF,
        };

        try expectEqual(test_fs.fat_config, expected);
    }
}
