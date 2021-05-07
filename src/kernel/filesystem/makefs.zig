const std = @import("std");
const expectError = std.testing.expectError;
const builtin = @import("builtin");
const fs_common = @import("filesystem_common.zig");
const mbr_driver = @import("mbr.zig");

/// A FAT32 static structure for creating a empty FAT32 image. This contains helper functions
/// for creating a empty FAT32 image.
/// For more information, see: https://en.wikipedia.org/wiki/Design_of_the_FAT_file_system
pub const Fat32 = struct {
    /// The FAT32 boot sector header (without the jmp and boot code) including the extended
    /// parameter block for FAT32 with the extended signature 0x29.
    const Header = struct {
        /// The OEM.
        oem: [8]u8 = "ZystemOS".*,

        /// The number of bytes per sector. This needs to be initialised by the user or use the
        /// default value at runtime. Use `getDefaultSectorSize` for the default.
        bytes_per_sector: u16,

        /// The number of sectors per cluster. This needs to be initialised by the user or use the
        /// default value at runtime. Use `getDefaultSectorsPerCluster` for the default.
        sectors_per_cluster: u8,

        /// The number of reserved sectors at the beginning of the image. This is where the fat
        /// header, FSInfo and FAT is stored. The default is 32 sectors.
        /// TODO: Investigate if this can be reduced if not all sectors are needed.
        reserved_sectors: u16 = getReservedSectors(),

        /// The number of FAT's. This is always 2.
        fat_count: u8 = 2,

        /// The size in bytes of the root directory. This is only used by FAT12 and FAT16, so is
        /// always 0 for FAT32.
        zero_root_directory_size: u16 = 0,

        /// The total number of sectors. This is only used for FAT12 and FAT16, so is always 0 for
        /// FAT32.
        zero_total_sectors_16: u16 = 0,

        /// The media type. This is used to identify the type of media this image is. As all FAT's
        /// that are created as a fixed disk, non of that old school floppy, this is always 0xF8.
        media_descriptor_type: u8 = 0xF8,

        /// The total number of sectors of the FAT. This is only used for FAT12 and FAT16, so
        /// always 0 for FAT32.
        zero_sectors_per_fat: u16 = 0,

        /// The number of sectors per track for Int 13h. This isn't really needed as we are
        /// creating a fixed disk. An example used 63.
        sectors_per_track: u16 = 63,

        /// The number of heads for Int 13h. This isn't really needed as we are creating a fixed
        /// disk. An example used 255.
        head_count: u16 = 255,

        /// The number of hidden sectors. As there is no support for partitions, this is set ot zero.
        hidden_sectors: u32 = 0,

        /// The total number of sectors of the image. This is determined at runtime by the size of
        /// image and the sector size.
        total_sectors: u32,

        /// The number of sectors the FAT takes up. This is set based on the size of the image.
        sectors_per_fat: u32,

        /// Mirror flags. If bit 7 is set, then bits 0-3 represent the number of active FAT entries
        /// (zero based) and if clear, all FAT's are mirrored. Always mirror, so zero.
        mirror_flags: u16 = 0x0000,

        /// The version. This is usually always zero (0.0). If version is 1.2, this will be stored
        /// as 0x0201.
        version_number: u16 = 0x0000,

        /// The start cluster of the root directory. This is usually always 2 unless there is a bad
        /// sector, 0 or 1 are invalid.
        root_directory_cluster: u32 = 2,

        /// The sector where is the FS information sector is located. A value of 0x0000 or 0xFFFF
        /// indicates that there isn't a FSInfo structure. A value of 0x0000 should not be treated
        /// as a valid FSInfo sector. Without a FS Information Sector, the minimum allowed logical
        /// sector size of FAT32 volumes can be reduced down to 128 bytes for special purposes.
        /// This is usually sector 1.
        fsinfo_sector: u16 = 1,

        /// The sector for the backup boot record where the first 3 sectors are copied. A value of
        /// 0x000 or 0xFFFF indicate there is no backup. This usually 6.
        backup_boot_sector: u16 = 6,

        /// Reserved,. All zero.
        reserved0: u96 = 0x000000000000,

        /// The physical drive number for Int 13h in the BIOS. 0x80 is for fixed disks, but as this
        /// is used for bootloaders, this isn't really needed.
        drive_number: u8 = 0x80,

        /// Reserved. All zero.
        reserved1: u8 = 0x00,

        /// The extended boot signature. 0x29, can be 0x28, but will only accept 0x29. If 0x28,
        /// then the below (serial_number, volume_label and filesystem_type) will be unavailable.
        signature: u8 = 0x29,

        /// The serial number of the FAT image at format. This is a function of the current
        /// timestamp of creation.
        serial_number: u32,

        /// The partitioned volume label. This can be set by the user else the default name will be
        /// give: "NO NAME    ".
        volume_label: [11]u8,

        /// The file system type, "FAT32   " for FAT32.
        filesystem_type: [8]u8 = "FAT32   ".*,
    };

    /// Options used for initialising a new FAT image.
    pub const Options = struct {
        /// The FAT32 image size in bytes. This is not the formatted size.
        /// The default (recommenced smallest) is 34090496 bytes (~32.5KB). This can be reduced to
        /// the lowest value of 17920 bytes (17.5KB). This image size is the smallest possible size
        /// where you can only create files, but not write to them. This image size can be mounted
        /// in Linux and ZystemOS.
        image_size: u32 = getDefaultImageSize(),

        /// The sector size in bytes. The minimum value for this is 512, and a maximum of 4096.
        /// This also must be a multiple of 512. Default 512.
        sector_size: u16 = getDefaultSectorSize(),

        /// The number of sectors per clusters. A default is chosen depending on the image size and
        /// sector size. Valid value are: 1, 2, 4, 8, 16, 32, 64 and 128. Default 1.
        cluster_size: u8 = getDefaultSectorsPerCluster(getDefaultImageSize(), getDefaultSectorSize()) catch unreachable,

        /// The formatted volume name. Volume names shorter than 11 characters must have trailing
        /// spaces. Default NO MANE.
        volume_name: [11]u8 = getDefaultVolumeName(),

        /// Whether to quick format the filesystem. Whether to completely zero the stream
        /// initially or zero just the important sectors.
        quick_format: bool = false,
    };

    /// The error set for the static functions for creating a FAT32 image.
    pub const Error = error{
        /// If the FAT image that the user wants to create is too small: < 17.5KB.
        TooSmall,

        /// If the FAT image that the user wants to create is too large: > 2TB.
        TooLarge,

        /// The value in a option provided from the user is invalid.
        InvalidOptionValue,
    };

    /// The log function for printing errors when creating a FAT32 image.
    const log = std.log.scoped(.mkfat32);

    ///
    /// Get the number of reserved sectors. The number of reserved sectors doesn't have to be 32,
    /// but this is a commonly used value.
    ///
    /// Return: u16
    ///     The number of reserved sectors.
    ///
    fn getReservedSectors() u16 {
        return 32;
    }

    ///
    /// Get the default sector size for a FAT32 image. (512)
    ///
    /// Return: u16
    ///     The default sector size (512).
    ///
    fn getDefaultSectorSize() u16 {
        // TODO: Look into if this could be different for different scenarios
        return 512;
    }

    ///
    /// Based on the image size, the sector size per cluster can vary. See
    /// https://support.microsoft.com/en-us/help/140365/default-cluster-size-for-ntfs-fat-and-exfat
    /// but with some modifications to allow for smaller size images (The smallest image size possible is 17.5KB):
    ///     17.5KB -> 64MB:  512 bytes
    ///     64MB   -> 128MB: 1024 bytes (1KB)
    ///     128MB  -> 256MB: 2048 bytes (2KB)
    ///     256MB  -> 8GB:   4096 bytes (4KB)
    ///     8GB    -> 16GB:  8192 bytes (8KB)
    ///     16GB   -> 32GB:  16384 bytes (16KB)
    ///     32GB   -> 2TB:   32768 bytes (32KB)
    ///     else:           Error
    ///
    /// The smallest size is calculated as follows:
    ///     (reserved_sectors + num_of_fats + root_directory) * smallest_sector_size = (32 + 2 + 1) * 512 = 35 * 512
    ///
    /// Arguments:
    ///     IN image_size: u64       - The image size the user wants to create.
    ///     IN bytes_per_sector: u16 - The bytes per sector the user defined, or the default value.
    ///
    /// Return: u16
    ///     The default sectors per cluster based on the image size and sector size.
    ///
    /// Error: Error
    ///     error.TooSmall - If the image size is too small (below 35 * 512 (17.5KB))
    ///     error.TooLarge - If the image size is too large (above 2TB)
    ///
    fn getDefaultSectorsPerCluster(image_size: u64, bytes_per_sector: u16) Error!u8 {
        // A couple of constants to help
        const KB = 1024;
        const MB = 1024 * KB;
        const GB = 1024 * MB;
        const TB = 1024 * GB;

        return switch (image_size) {
            0...35 * 512 - 1 => Error.TooSmall,
            35 * 512...64 * MB - 1 => @intCast(u8, std.math.max(512, bytes_per_sector) / bytes_per_sector),
            64 * MB...128 * MB - 1 => @intCast(u8, std.math.max(1024, bytes_per_sector) / bytes_per_sector),
            128 * MB...256 * MB - 1 => @intCast(u8, std.math.max(2048, bytes_per_sector) / bytes_per_sector),
            256 * MB...8 * GB - 1 => @intCast(u8, std.math.max(4096, bytes_per_sector) / bytes_per_sector),
            8 * GB...16 * GB - 1 => @intCast(u8, std.math.max(8192, bytes_per_sector) / bytes_per_sector),
            16 * GB...32 * GB - 1 => @intCast(u8, std.math.max(16384, bytes_per_sector) / bytes_per_sector),
            32 * GB...2 * TB - 1 => @intCast(u8, std.math.max(32768, bytes_per_sector) / bytes_per_sector),
            else => Error.TooLarge,
        };
    }

    ///
    /// Get the default volume name of a FAT image: "NO NAME    ".
    ///
    /// Return: [11]u8
    ///     The default volume name.
    ///
    fn getDefaultVolumeName() [11]u8 {
        return "NO NAME    ".*;
    }

    ///
    /// Get the default image size: 34090496 (~32.5MB). This is the recommended minimum image size
    /// for FAT32. (Valid cluster values + (sectors per FAT * 2) + reserved sectors) * bytes per sector.
    ///
    /// Return: u32
    ///     The smallest recommended FAT32 image size.
    ///
    fn getDefaultImageSize() u32 {
        // The 513*2 was pre calculated
        return (0xFFF5 + 1026 + @as(u32, getReservedSectors())) * @as(u32, getDefaultSectorSize());
    }

    ///
    /// Create the FAT32 serial number. This is generated from the date. Reference:
    /// https://www.digital-detective.net/documents/Volume%20Serial%20Numbers.pdf
    ///
    /// Return: u32
    ///     Serial number for a new FAT32 image.
    ///
    fn createSerialNumber() u32 {
        // TODO: Get the actual date. Currently there is no std lib for human readable date.
        const year = 2020;
        const month = 09;
        const day = 27;
        const hour = 13;
        const minute = 46;
        const second = 53;
        const millisecond_10 = 54;

        const p1 = (@as(u16, month) << 8) | day;
        const p2 = (@as(u16, second) << 8) | millisecond_10;
        const p3 = (@as(u16, hour) << 8) | minute;

        const p4 = p1 + p2;
        const p5 = p3 + year;

        return (@as(u32, p4) << 16) + p5;
    }

    ///
    /// Write the FSInfo and backup FSInfo sector to a stream. This uses a valid FAT32 boot sector
    /// header for creating the FSInfo sector.
    ///
    /// Argument:
    ///     IN/OUT stream: anytype    - The stream to write the FSInfo to.
    ///     IN fat32_header: Header   - A valid FAT32 boot header for creating the FSInfo sector.
    ///     IN free_cluster_num: u32  - The number of free data clusters on the image.
    ///     IN next_free_cluster: u32 - The next free data cluster to start looking for when writing
    ///                                 files.
    ///
    /// Error @TypeOf(stream).WriteError || @TypeOf(stream).SeekError
    ///     @TypeOf(stream).WriteError - If there is an error when writing. See the relevant error for the stream.
    ///     @TypeOf(stream).SeekError  - If there is an error when seeking. See the relevant error for the stream.
    ///
    fn writeFSInfo(stream: anytype, fat32_header: Header, free_cluster_num: u32, next_free_cluster: u32) (fs_common.GetSeekError(@TypeOf(stream)) || fs_common.GetWriteError(@TypeOf(stream)))!void {
        const seekable_stream = stream.seekableStream();
        const writer = stream.writer();

        // Seek to the correct location
        try seekable_stream.seekTo(fat32_header.fsinfo_sector * fat32_header.bytes_per_sector);

        // First signature
        try writer.writeIntLittle(u32, 0x41615252);

        // These next bytes are reserved and unused
        try seekable_stream.seekBy(480);

        // Second signature
        try writer.writeIntLittle(u32, 0x61417272);

        // Last know free cluster count
        try writer.writeIntLittle(u32, free_cluster_num);

        // Cluster number to start looking for available clusters
        try writer.writeIntLittle(u32, next_free_cluster);

        // These next bytes are reserved and unused
        try seekable_stream.seekBy(12);

        // Trail signature
        try writer.writeIntLittle(u32, 0xAA550000);

        // Repeat again for the backup
        try seekable_stream.seekTo((fat32_header.backup_boot_sector + fat32_header.fsinfo_sector) * fat32_header.bytes_per_sector);
        try writer.writeIntLittle(u32, 0x41615252);
        try seekable_stream.seekBy(480);
        try writer.writeIntLittle(u32, 0x61417272);
        try writer.writeIntLittle(u32, free_cluster_num);
        try writer.writeIntLittle(u32, next_free_cluster);
        try seekable_stream.seekBy(12);
        try writer.writeIntLittle(u32, 0xAA550000);
    }

    ///
    /// Write the FAT to the stream. This sets up a blank FAT with end marker of 0x0FFFFFFF and root
    /// directory cluster of 0x0FFFFFFF (one cluster chain).
    ///
    /// Argument:
    ///     IN/OUT stream: anytype  - The stream to write the FSInfo to.
    ///     IN fat32_header: Header - A valid FAT32 boot header for creating the FAT.
    ///
    /// Error @TypeOf(stream).WriteError || @TypeOf(stream).SeekError
    ///     @TypeOf(stream).WriteError - If there is an error when writing. See the relevant error for the stream.
    ///     @TypeOf(stream).SeekError  - If there is an error when seeking. See the relevant error for the stream.
    ///
    fn writeFAT(stream: anytype, fat32_header: Header) (fs_common.GetSeekError(@TypeOf(stream)) || fs_common.GetWriteError(@TypeOf(stream)))!void {
        const seekable_stream = stream.seekableStream();
        const writer = stream.writer();

        // This FAT is below the reserved sectors
        try seekable_stream.seekTo(fat32_header.reserved_sectors * fat32_header.bytes_per_sector);

        // Last byte is the same as the media descriptor, the rest are 1's.
        try writer.writeIntLittle(u32, 0xFFFFFF00 | @as(u32, fat32_header.media_descriptor_type));

        // End of chain indicator. This can be 0x0FFFFFF8 - 0x0FFFFFFF, but 0x0FFFFFFF is better supported.
        try writer.writeIntLittle(u32, 0x0FFFFFFF);

        // Root director cluster, 0x0FFFFFFF = initially only one cluster for root directory
        try writer.writeIntLittle(u32, 0x0FFFFFFF);

        // Write the second FAT, same as the first
        try seekable_stream.seekTo(fat32_header.reserved_sectors * fat32_header.bytes_per_sector + (fat32_header.sectors_per_fat * fat32_header.bytes_per_sector));
        try writer.writeIntLittle(u32, 0xFFFFFF00 | @as(u32, fat32_header.media_descriptor_type));
        try writer.writeIntLittle(u32, 0x0FFFFFFF);
        try writer.writeIntLittle(u32, 0x0FFFFFFF);
    }

    ///
    /// Write the FAT boot sector with the boot code and FAT32 header to the stream.
    ///
    /// Argument:
    ///     IN/OUT stream: anytype  - The stream to write the FSInfo to.
    ///     IN fat32_header: Header - A valid FAT32 boot header for creating the FAT.
    ///
    /// Error: @TypeOf(stream).WriteError || @TypeOf(stream).SeekError
    ///     @TypeOf(stream).WriteError - If there is an error when writing. See the relevant error for the stream.
    ///     @TypeOf(stream).SeekError  - If there is an error when seeking. See the relevant error for the stream.
    ///
    fn writeBootSector(stream: anytype, fat32_header: Header) (fs_common.GetSeekError(@TypeOf(stream)) || fs_common.GetWriteError(@TypeOf(stream)))!void {
        const seekable_stream = stream.seekableStream();
        const writer = stream.writer();

        var boot_sector: [512]u8 = undefined;
        std.mem.copy(u8, &boot_sector, &fs_common.filesystem_bootsector_boot_code);

        // Write the header into the boot sector variable
        var fat32_header_stream = std.io.fixedBufferStream(boot_sector[3..90]);
        inline for (std.meta.fields(Header)) |item| {
            switch (@typeInfo(item.field_type)) {
                .Array => |info| switch (info.child) {
                    u8 => try fat32_header_stream.writer().writeAll(&@field(fat32_header, item.name)),
                    else => @compileError("Unexpected field type: " ++ @typeName(info.child)),
                },
                .Int => try fat32_header_stream.writer().writeIntLittle(item.field_type, @field(fat32_header, item.name)),
                else => @compileError("Unexpected field type: " ++ @typeName(info.child)),
            }
        }

        // Write the bootstrap and header sector to the image
        try seekable_stream.seekTo(0);
        try writer.writeAll(&boot_sector);

        // Also write the backup sector to the image
        try seekable_stream.seekTo(fat32_header.backup_boot_sector * fat32_header.bytes_per_sector);
        try writer.writeAll(&boot_sector);
    }

    ///
    /// Create a valid FAT32 header with out the bootstrap code with either user defined parameters
    /// or default FAT32 parameters.
    ///
    /// Argument:
    ///     IN options: Options - The values provided by the user or default values.
    ///
    /// Return: Fat32.Header
    ///     A valid FAT32 header without the bootstrap code.
    ///
    /// Error: Error
    ///     Error.InvalidOptionValue - If the values provided by the user are invalid and/or out of
    ///                                bounds. A log message will be printed to display the valid
    ///                                ranges.
    ///
    fn createFATHeader(options: Options) Error!Header {
        // 512 is the smallest sector size for FAT32
        if (options.sector_size < 512 or options.sector_size > 4096 or options.sector_size % 512 != 0) {
            log.err("Bytes per sector is invalid. Must be greater then 512 and a multiple of 512. Found: {}", .{options.sector_size});
            return Error.InvalidOptionValue;
        }

        // Valid clusters are 1, 2, 4, 8, 16, 32, 64 and 128
        if (options.cluster_size < 1 or options.cluster_size > 128 or !std.math.isPowerOfTwo(options.cluster_size)) {
            log.err("Sectors per cluster is invalid. Must be less then or equal to 128 and a power of 2. Found: {}", .{options.cluster_size});
            return Error.InvalidOptionValue;
        }

        // Ensure the image is aligned to the bytes per sector
        // Backwards as if being imaged to a device, we can't can't go over
        const image_size = std.mem.alignBackward(options.image_size, options.sector_size);

        // This is the bare minimum. It wont hold any data in a file, but can create some files. But it still can be mounted in Linux
        // +1 for the root director sector,                                                      2 TB
        // FAT count for FAT32 is always 2
        if (image_size < ((getReservedSectors() + 2 + 1) * options.sector_size) or image_size >= 2 * 1024 * 1024 * 1024 * 1024) {
            log.err("Image size is invalid. Must be greater then 17919 (~18KB). Found: {}", .{image_size});
            return Error.InvalidOptionValue;
        }

        // See: https://board.flatassembler.net/topic.php?t=12680
        var sectors_per_fat = @intCast(u32, (image_size - getReservedSectors() + (2 * options.cluster_size)) / ((options.cluster_size * (options.sector_size / 4)) + 2));
        // round up sectors
        sectors_per_fat = (sectors_per_fat + options.sector_size - 1) / options.sector_size;

        return Header{
            .bytes_per_sector = options.sector_size,
            .sectors_per_cluster = options.cluster_size,
            .total_sectors = @intCast(u32, @divExact(image_size, options.sector_size)),
            .sectors_per_fat = sectors_per_fat,
            .serial_number = createSerialNumber(),
            .volume_label = options.volume_name,
        };
    }

    ///
    /// Make a FAT32 image. This will either use the default options or modified defaults from the
    /// user. The file will be saved to the path specified. If quick format is on, then the entire
    /// stream is zeroed else the reserved and FAT sectors are zeroed.
    ///
    /// Argument:
    ///     IN options: Options - The FAT32 options that the user can provide to change the
    ///                           parameters of a FAT32 image.
    ///     IN stream: anytype  - The stream to create a new FAT32 image. This stream must support
    ///                           reader(), writer() and seekableStream() interfaces.
    ///
    /// Error: @TypeOf(stream).WriteError || @TypeOf(stream).SeekError || Error
    ///     @TypeOf(stream).WriteError       - If there is an error when writing. See the relevant error for the stream.
    ///     @TypeOf(stream).SeekError        - If there is an error when seeking. See the relevant error for the stream.
    ///     Error.InvalidOptionValue         - In the user has provided invalid options.
    ///     Error.TooLarge                   - The stream size is too small. < 17.5KB.
    ///     Error.TooSmall                   - The stream size is to large. > 2TB.
    ///
    pub fn make(options: Options, stream: anytype) (fs_common.GetSeekError(@TypeOf(stream)) || fs_common.GetWriteError(@TypeOf(stream)) || Error)!void {
        // Don't print when testing as it floods the terminal
        if (options.image_size < getDefaultImageSize() and !builtin.is_test) {
            log.warn("Image size smaller than default. Got: 0x{X}, default: 0x{X}\n", .{ options.image_size, getDefaultImageSize() });
        }

        // First set up the header
        const fat32_header = try Fat32.createFATHeader(options);

        // Initialise the stream with all zeros
        try stream.seekableStream().seekTo(0);
        if (options.quick_format) {
            // Zero just the reserved and FAT sectors
            try fs_common.clearStream(stream, (fat32_header.reserved_sectors + (fat32_header.sectors_per_fat * 2)) * fat32_header.bytes_per_sector);
        } else {
            const image_size = std.mem.alignBackward(options.image_size, fat32_header.bytes_per_sector);
            try fs_common.clearStream(stream, image_size);
        }

        // Write the boot sector with the bootstrap code and header and the backup boot sector.
        try Fat32.writeBootSector(stream, fat32_header);

        // Write the FAT and second FAT
        try Fat32.writeFAT(stream, fat32_header);

        // Calculate the usable clusters.
        const usable_sectors = fat32_header.total_sectors - fat32_header.reserved_sectors - (fat32_header.fat_count * fat32_header.sectors_per_fat);
        const usable_clusters = @divFloor(usable_sectors, fat32_header.sectors_per_cluster) - 1;

        // Write the FSInfo and backup FSInfo sectors
        try Fat32.writeFSInfo(stream, fat32_header, usable_clusters, 2);
    }
};

pub const MBRPartition = struct {
    /// The MBR make options
    pub const Options = struct {
        /// The options for the partition table as percentages. The total should not exceed 100%.
        partition_options: [4]?u16 = .{ null, null, null, null },

        /// The total image size to create.
        image_size: u64,
    };

    /// The error set for making a new MBR partition scheme.
    const Error = error{
        /// The start position of the partition stream is past the end of the main stream.
        InvalidStart,

        /// The percentage of given is either to high (above 100) or the accumulative partition
        /// percentages of all partitions exceeds 100.
        InvalidPercentage,

        /// The size of the stream is invalid, i.e. too small.
        InvalidSize,
    };

    /// The sector size of the drive. Unfortunately MBR assumes 512 bytes.
    const SECTOR_SIZE: u32 = 512;

    /// The log function for printing errors when creating a FAT32 image.
    const log = std.log.scoped(.mkmbr);

    ///
    /// Write the partition table to the stream from the provided options.
    ///
    /// Arguments:
    ///     IN partition_num: u2  - The partition to write.
    ///     IN stream: StreamType - The stream to write the partition to.
    ///     IN size_percent: u16  - The size of stream to partition for this partition in a percentage.
    ///     IN start_pos: u32     - The start position to start the partition in sectors.
    ///     IN end_of_stream: u32 - The end of the stream in bytes.
    ///
    /// Return: u32
    ///     The next sector after the end of the partition created.
    ///
    /// Error: Error || StreamType.WriteError || StreamType.SeekError
    ///     Error                 - The percentage of the stream is too large (> 100) or the
    //                              start of the partition is past the end of the stream.
    ///     StreamType.WriteError - Error writing ot the stream.
    ///     StreamType.SeekError  - Error seeking the stream.
    ///
    fn writePartition(partition_num: u2, stream: anytype, size_percent: u16, start_pos: u32, end_of_stream: u64) (Error || fs_common.GetSeekError(@TypeOf(stream)) || fs_common.GetWriteError(@TypeOf(stream)))!u32 {
        // The offset of where the boot code finishes and partition table starts
        const boot_code_end_offset = 446;

        if (size_percent > 100) {
            return Error.InvalidPercentage;
        }

        const seek_stream = stream.seekableStream();
        const writer_stream = stream.writer();

        if (start_pos * SECTOR_SIZE > end_of_stream) {
            return Error.InvalidStart;
        }

        // Round up the partition size in number of sectors
        const partition_size: u32 = @intCast(u32, ((end_of_stream - (start_pos * SECTOR_SIZE)) * (size_percent / 100) + (SECTOR_SIZE - 1)) / SECTOR_SIZE);

        // Seek to the offset to write the partition table
        const partition_offset = @as(u32, partition_num) * @sizeOf(mbr_driver.Partition) + boot_code_end_offset;
        try seek_stream.seekTo(partition_offset);

        // TODO: Add the CHS values, These seem to not be needed as can still mount in Linux
        //       But should be set at some point
        const partition = mbr_driver.Partition{
            .drive_attributes = 0x80,
            .chs_address_start1 = undefined,
            .chs_address_start2 = undefined,
            .chs_address_start3 = undefined,
            .partition_type = 0x83,
            .chs_address_end1 = undefined,
            .chs_address_end2 = undefined,
            .chs_address_end3 = undefined,
            .lba_start = start_pos,
            .number_of_sectors = partition_size,
        };

        const partition_bytes = @ptrCast([*]const u8, &partition)[0..16];
        try writer_stream.writeAll(partition_bytes);
        return partition_size + 1;
    }

    ///
    /// Get the size of the reserved bytes at the beginning of the stream. This is set to 1MB
    /// as this is reserved for the bootloader code.
    ///
    /// Return: u32
    ///     The number of bytes reserved at the beginning of the stream.
    ///
    pub fn getReservedStartSize() u32 {
        return 1024 * 1024;
    }

    ///
    /// Create a new MBR partition scheme on the provided stream. Any error returned will
    /// result in the stream being left in a undefined state. This will clear the stream
    /// and fill with all zeros based on the image size in the options.
    ///
    /// Arguments:
    ///     IN options: Options - The options for creating the MBR partition scheme.
    ///     IN stream: anytype  - The stream to write the partition table to.
    ///
    /// Error: Error || StreamType.WriteError || StreamType.SeekError
    ///     Error                 - The image size is too small or there was an error writing
    ///                             to the stream. Or the total percentage exceeds 100%.
    ///     StreamType.WriteError - Error writing ot the stream.
    ///     StreamType.SeekError  - Error seeking the stream.
    ///
    pub fn make(options: Options, stream: anytype) (Error || fs_common.GetSeekError(@TypeOf(stream)) || fs_common.GetWriteError(@TypeOf(stream)))!void {
        if (options.image_size < getReservedStartSize()) {
            return Error.InvalidSize;
        }

        // Clear/make the image the size given in the options
        try fs_common.clearStream(stream, options.image_size);

        const seek_stream = stream.seekableStream();
        const writer_stream = stream.writer();

        try seek_stream.seekTo(0);
        try writer_stream.writeAll(fs_common.filesystem_bootsector_boot_code[0..]);

        // First MB is for the boot code
        var next_start_sector_pos: u32 = getReservedStartSize() / SECTOR_SIZE;

        var acc_size: u16 = 0;
        for (options.partition_options) |null_part_option, i| {
            if (null_part_option) |size_percent| {
                if (size_percent > 100 or acc_size > 100 - size_percent) {
                    return Error.InvalidPercentage;
                }
                acc_size += size_percent;
                next_start_sector_pos = try writePartition(@intCast(u2, i), stream, size_percent, next_start_sector_pos, options.image_size);
            }
        }
    }
};

test "MBRPartition.make - more than 100% for one partition" {
    const allocator = std.testing.allocator;

    const size = 1024 * 1024 * 10;
    var buffer = try allocator.alloc(u8, size);
    defer allocator.free(buffer);

    const stream = &std.io.fixedBufferStream(buffer);
    expectError(error.InvalidPercentage, MBRPartition.make(.{ .partition_options = .{ 101, null, null, null }, .image_size = size }, stream));
}

test "MBRPartition.make - more than 100% accumulative" {
    const allocator = std.testing.allocator;

    const size = 1024 * 1024 * 10;
    var buffer = try allocator.alloc(u8, size);
    defer allocator.free(buffer);

    const stream = &std.io.fixedBufferStream(buffer);
    expectError(error.InvalidPercentage, MBRPartition.make(.{ .partition_options = .{ 50, 25, 25, 1 }, .image_size = size }, stream));
}
