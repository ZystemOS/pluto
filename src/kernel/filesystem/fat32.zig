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
    pub fn getName(self: *const LongName, buff: []u8) !u32 {
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
    /// Convert a cluster to the corresponding sector from the filesystems configuration.
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

        /// See vfs.FileSystem.getRootNode
        fn getRootNode(fs: *const vfs.FileSystem) *const vfs.DirNode {
            const self = @fieldParentPtr(Fat32Self, "instance", fs.instance);
            return &self.root_node.node.Dir;
        }

        /// See vfs.FileSystem.close
        fn close(fs: *const vfs.FileSystem, node: *const vfs.FileNode) void {
            const self = @fieldParentPtr(Fat32Self, "instance", fs.instance);
            const cast_node = @ptrCast(*const vfs.Node, node);
            // As close can't error, if provided with a invalid Node that isn't opened or try to close
            // the same file twice, will just do nothing.
            if (self.opened_files.contains(cast_node)) {
                const opened_node = self.opened_files.remove(cast_node).?.value;
                self.allocator.destroy(opened_node);
                self.allocator.destroy(node);
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
                .CREATE_SYMLINK => if (open_args.symlink_target) |target| .{ .Symlink = target } else return vfs.Error.NoSymlinkTarget,
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
        /// Error: Allocator.Error || ReadError || SeekError || vfs.Error
        ///     Allocator.Error           - Not enough memory for allocating memory
        ///     ReadError                 - Errors when reading the stream.
        ///     SeekError                 - Errors when seeking the stream.
        ///     vfs.Error.NoSuchFileOrDir - Error if the file/folder doesn't exist.
        ///
        fn openImpl(fs: *const vfs.FileSystem, dir: *const vfs.DirNode, name: []const u8) (Allocator.Error || ReadError || SeekError || vfs.Error)!*vfs.Node {
            const self = @fieldParentPtr(Fat32Self, "instance", fs.instance);

            // TODO: Future PR
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
        /// Deinitialise this file system.
        ///
        /// Arguments:
        ///     IN self: *Fat32Self - Self to free.
        ///
        pub fn deinit(self: *Fat32Self) void {
            // Make sure we have closed all files
            // TODO: Should this deinit close any open files instead?
            std.debug.assert(self.opened_files.count() == 0);
            self.opened_files.deinit();
            self.allocator.destroy(self.root_node.node);
            self.allocator.destroy(self.fs);
        }

        ///
        /// Initialise a FAT32 filesystem.
        ///
        /// Arguments:
        ///     IN allocator: *Allocator - Allocate memory.
        ///     IN stream: StreamType - Allocate memory.
        ///
        /// Return: *Fat32
        ///     The pointer to a Fat32 filesystem.
        ///
        /// Error: Allocator.Error || ReadError || SeekError || Error
        ///     Allocator.Error - If there is no more memory. Any memory allocated will be freed.
        ///     ReadError       - If there is an error reading from the stream.
        ///     SeekError       - If there si an error seeking the stream.
        ///     Error           - If there is an error when parsing the stream to set up a fAT32
        ///                       filesystem. See Error for the list of possible errors.
        ///
        pub fn init(allocator: *Allocator, stream: StreamType) (Allocator.Error || ReadError || SeekError || Error)!Fat32Self {
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

            var fat32_fs = Fat32Self{
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
//// allowed. This will allow the use of different devices such as Hard drives or RAM disks to have
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
pub fn initialiseFAT32(allocator: *Allocator, stream: anytype) (Allocator.Error || ErrorSet(@TypeOf(stream)) || Fat32FS(@TypeOf(stream)).Error)!Fat32FS(@TypeOf(stream)) {
    return Fat32FS(@TypeOf(stream)).init(allocator, stream);
}

/// The number of allocations that the init function make.
const test_init_allocations: usize = 4;

/// The test buffer for the test filesystem stream.
var test_stream_buff: [if (builtin.is_test) 34090496 else 0]u8 = undefined;

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
fn testWriteTestFiles(comptime StreamType: type, fat32fs: Fat32FS(StreamType)) (Allocator.Error || ErrorSet(StreamType) || vfs.Error || std.fs.File.OpenError || std.fs.File.ReadError)!void {
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

    try mkfat32.Fat32.make(.{}, stream);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.deinit();

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

    try mkfat32.Fat32.make(.{}, stream);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.deinit();

    expectEqual(test_fs.fs.getRootNode(test_fs.fs), &test_fs.root_node.node.Dir);
    expectEqual(test_fs.root_node.cluster, 2);
    expectEqual(test_fs.fat_config.root_directory_cluster, 2);
}

test "Fat32FS.read" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.deinit();

    // TODO: Once the read PR is done
}

test "Fat32FS.write" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.deinit();

    // TODO: Once the write PR is done
}

test "Fat32FS.open - no create" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.deinit();

    // TODO: Once the open PR is done
}

test "Fat32FS.open - create file" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.deinit();

    // TODO: Once the open and write PR is done
}

test "Fat32FS.open - create directory" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.deinit();

    // TODO: Once the open and write PR is done
}

test "Fat32FS.open - create symlink" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.deinit();

    // TODO: Once the open and write PR is done
}

test "Fat32FS.init no error" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.deinit();
}

test "Fat32FS.init errors" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream);

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

    try mkfat32.Fat32.make(.{}, stream);

    var i: usize = 0;
    while (i < test_init_allocations) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, i);

        expectError(error.OutOfMemory, initialiseFAT32(&fa.allocator, stream));
    }
}

test "Fat32FS.init FATConfig expected" {
    var stream = &std.io.fixedBufferStream(test_stream_buff[0..]);

    try mkfat32.Fat32.make(.{}, stream);

    var test_fs = try initialiseFAT32(std.testing.allocator, stream);
    defer test_fs.deinit();

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

    try mkfat32.Fat32.make(.{}, stream);

    // No FSInfo
    {
        // Force no FSInfo
        test_stream_buff[48] = 0x00;

        var test_fs = try initialiseFAT32(std.testing.allocator, stream);
        defer test_fs.deinit();

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
        defer test_fs.deinit();

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
        defer test_fs.deinit();

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
