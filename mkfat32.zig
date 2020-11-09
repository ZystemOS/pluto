const std = @import("std");

// This is the assembly for the FAT bootleader.
//     [bits   16]
//     [org    0x7C00]
//
//     jmp     short _start
//     nop
//
// times 87 db 0xAA
//
// _start:
//     jmp     long 0x0000:start_16bit
//
// start_16bit:
//     cli
//     mov     ax, cs
//     mov     ds, ax
//     mov     es, ax
//     mov     ss, ax
//     mov     sp, 0x7C00
//     lea     si, [message]
// .print_string_with_new_line:
//     mov     ah, 0x0E
//     xor     bx, bx
// .print_string_loop:
//     lodsb
//     cmp     al, 0
//     je      .print_string_done
//     int     0x10
//     jmp     short .print_string_loop
// .print_string_done:
//     mov     al, 0x0A
//     int     0x10
//     mov     al, 0x0D
//     int     0x10
//
// .reboot:
//     xor     ah, ah
//     int     0x16
//     int     0x19
//
// .loop_forever:
//     hlt
//     jmp .loop_forever

// message db "This is not a bootable disk. Please insert a bootable floppy and press any key to try again", 0
// times 510 - ($ - $$) db 0
// dw 0xAA55

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
    };

    /// The error set for the static functions for creating a FAT32 image.
    pub const Error = error{
        /// If the FAT image that the user want's to create is too small: < 17.5KB.
        TooSmall,

        /// If the FAT image that the user want's to create is too large: > 2TB.
        TooLarge,

        /// The value in a option provided from the user is invalid.
        InvalidOptionValue,
    };

    /// The logger function for printing errors when creating a FAT32 image.
    const logger = std.log.scoped(.mkfat32);

    /// The bootloader code for the FAT32 boot sector.
    const bootsector_boot_code = [512]u8{
        0xEB, 0x58, 0x90, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA,
        0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA,
        0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA,
        0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA,
        0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA,
        0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0x66, 0xEA, 0x62, 0x7C, 0x00, 0x00,
        0x00, 0x00, 0xFA, 0x8C, 0xC8, 0x8E, 0xD8, 0x8E, 0xC0, 0x8E, 0xD0, 0xBC, 0x00, 0x7C, 0x8D, 0x36,
        0x8F, 0x7C, 0xB4, 0x0E, 0x31, 0xDB, 0xAC, 0x3C, 0x00, 0x74, 0x04, 0xCD, 0x10, 0xEB, 0xF7, 0xB0,
        0x0A, 0xCD, 0x10, 0xB0, 0x0D, 0xCD, 0x10, 0x30, 0xE4, 0xCD, 0x16, 0xCD, 0x19, 0xEB, 0xFE, 0x54,
        0x68, 0x69, 0x73, 0x20, 0x69, 0x73, 0x20, 0x6E, 0x6F, 0x74, 0x20, 0x61, 0x20, 0x62, 0x6F, 0x6F,
        0x74, 0x61, 0x62, 0x6C, 0x65, 0x20, 0x64, 0x69, 0x73, 0x6B, 0x2E, 0x20, 0x50, 0x6C, 0x65, 0x61,
        0x73, 0x65, 0x20, 0x69, 0x6E, 0x73, 0x65, 0x72, 0x74, 0x20, 0x61, 0x20, 0x62, 0x6F, 0x6F, 0x74,
        0x61, 0x62, 0x6C, 0x65, 0x20, 0x66, 0x6C, 0x6F, 0x70, 0x70, 0x79, 0x20, 0x61, 0x6E, 0x64, 0x20,
        0x70, 0x72, 0x65, 0x73, 0x73, 0x20, 0x61, 0x6E, 0x79, 0x20, 0x6B, 0x65, 0x79, 0x20, 0x74, 0x6F,
        0x20, 0x74, 0x72, 0x79, 0x20, 0x61, 0x67, 0x61, 0x69, 0x6E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x55, 0xAA,
    };

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
    /// Get the default image size: 34090496 (~32.5KB). This is the recommended minimum image size
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
    fn writeFSInfo(stream: anytype, fat32_header: Header, free_cluster_num: u32, next_free_cluster: u32) (@TypeOf(stream).WriteError || @TypeOf(stream).SeekError)!void {
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
    fn writeFAT(stream: anytype, fat32_header: Header) (@TypeOf(stream).WriteError || @TypeOf(stream).SeekError)!void {
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
    fn writeBootSector(stream: anytype, fat32_header: Header) (@TypeOf(stream).WriteError || @TypeOf(stream).SeekError)!void {
        const seekable_stream = stream.seekableStream();
        const writer = stream.writer();

        var boot_sector: [512]u8 = undefined;
        std.mem.copy(u8, &boot_sector, &bootsector_boot_code);

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
            logger.err("Bytes per sector is invalid. Must be greater then 512 and a multiple of 512. Found: {}", .{options.sector_size});
            return Error.InvalidOptionValue;
        }

        // Valid clusters are 1, 2, 4, 8, 16, 32, 64 and 128
        if (options.cluster_size < 0 or options.cluster_size > 128 or !std.math.isPowerOfTwo(options.cluster_size)) {
            logger.err("Sectors per cluster is invalid. Must be less then 32 and a power of 2. Found: {}", .{options.cluster_size});
            return Error.InvalidOptionValue;
        }

        // Ensure the image is aligned to the bytes per sector
        // Backwards as if being imaged to a device, we can't can't go over
        const image_size = std.mem.alignBackward(options.image_size, options.sector_size);

        // This is the bare minimum. It wont hold any data in a file, but can create some files. But it still can be mounted in Linux
        // +1 for the root director sector,                                                      2 TB
        // FAT count for FAT32 is always 2
        if (image_size < ((getReservedSectors() + 2 + 1) * options.sector_size) or image_size >= 2 * 1024 * 1024 * 1024 * 1024) {
            logger.err("Image size is invalid. Must be greater then 17919 (~18KB). Found: {}", .{image_size});
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
    /// user. The file will be saved to the path specified.
    ///
    /// Argument:
    ///     IN options: Options - The FAT32 options that the user can provide to change the
    ///                           parameters of a FAT32 image.
    ///     IN stream: anytype  - The stream to create a new FAT32 image. This stream must support
    ///                           reader(), writer() and seekableStream() interfaces.
    ///
    /// Error:  @TypeOf(stream).WriteError ||  @TypeOf(stream).SeekError || Error
    ///     @TypeOf(stream).WriteError       - If there is an error when writing. See the relevant error for the stream.
    ///     @TypeOf(stream).SeekError        - If there is an error when seeking. See the relevant error for the stream.
    ///     Error.InvalidOptionValue         - In the user has provided invalid options.
    ///     Error.TooLarge                   - The stream size is too small. < 17.5KB.
    ///     Error.TooSmall                   - The stream size is to large. > 2TB.
    ///
    pub fn make(options: Options, stream: anytype) (@TypeOf(stream).WriteError || @TypeOf(stream).SeekError || Error)!void {
        // First set up the header
        const fat32_header = try Fat32.createFATHeader(options);
        // Get the total image size again. As the above has a check for the size, we don't need one here again
        const image_size = std.mem.alignBackward(options.image_size, fat32_header.bytes_per_sector);

        // Initialise the stream with all zeros
        try stream.writer().writeByteNTimes(0x00, image_size);

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
