const std = @import("std");
const builtin = @import("builtin");
const Arch = std.Target.Cpu.Arch;
const Endian = builtin.Endian;
const log = std.log.scoped(.elf);
const testing = std.testing;

/// The data sizes that ELF files support. The int value corresponds to the value used in the file
pub const DataSize = enum(u8) {
    /// 32-bit
    ThirtyTwoBit = 1,
    /// 64-bit
    SixtyFourBit = 2,

    ///
    /// Get the number of bits taken by the data size
    ///
    /// Arguments:
    ///     IN self: DataSize - The data size to get the number of bits for
    ///
    /// Return: usize
    ///     The number of bits
    ///
    pub fn toNumBits(self: @This()) usize {
        return switch (self) {
            .ThirtyTwoBit => 32,
            .SixtyFourBit => 64,
        };
    }
};

/// The endiannesses supported by Elf files. The int value corresponds to the value used in the file
pub const Endianness = enum(u8) {
    /// Little-endian
    Little = 1,
    /// Big-endian
    Big = 2,

    ///
    /// Translate into the corresponding std lib Endian
    ///
    /// Arguments:
    ///     IN self: Endianness - The endianness to translate
    ///
    /// Return: Endian
    ///     The corresponding std lib Endian value
    ///
    pub fn toEndian(self: @This()) Endian {
        return switch (self) {
            .Big => .Big,
            .Little => .Little,
        };
    }
};

/// The type of the elf file. The int value corresponds to the value used in the file
pub const Type = enum(u16) {
    /// Unused
    None = 0,
    /// Relocatable
    Rel = 1,
    /// Executable
    Executable = 2,
    /// Dynamic linking
    Dynamic = 3,
    /// Core dump
    Core = 4,
    /// OS-specific
    LowOS = 0xFE00,
    /// OS-specific
    HighOS = 0xFEFF,
    /// CPU-specific
    LowCPU = 0xFF00,
    /// CPU-specific
    HighCPU = 0xFFFF,
};

/// The architectures supported by ELF
pub const Architecture = enum(u16) {
    /// No specific instruction set
    None = 0,
    WE32100 = 1,
    Sparc = 2,
    x86 = 3,
    Motoroloa_68k = 4,
    Motorola_88k = 5,
    Intel_MCU = 6,
    Intel_80860 = 7,
    MIPS = 8,
    IBM_370 = 9,
    MIPS_RS3000_LE = 10,
    Reserved1 = 11,
    Reserved2 = 12,
    Reserved3 = 13,
    HP_PA_RISC = 14,
    Reserbed4 = 15,
    Intel_80960 = 19,
    PowerPC = 20,
    PowerPC_64 = 21,
    S390 = 22,
    ARM = 0x28,
    SuperH = 0x2A,
    IA_64 = 0x32,
    AMD_64 = 0x3E,
    TMS = 0x8C,
    Aarch64 = 0xB7,
    RISC_V = 0xF3,
    WDC_65C816 = 0x101,

    ///
    /// Translate to a std lib Arch
    ///
    /// Arguments:
    ///     IN self: Architecture - The architecture to translate
    ///
    /// Return: Arch
    ///     The corresponding std lib Arch
    ///
    pub fn toArch(self: @This()) Error!Arch {
        return switch (self) {
            .None, .TMS, .WDC_65C816, .SuperH, .IA_64, .S390, .IBM_370, .Reserved1, .Reserved2, .WE32100, .Motorola_88k, .Motoroloa_68k, .Intel_MCU, .Intel_80860, .Intel_80960, .MIPS_RS3000_LE, .HP_PA_RISC, .Reserved3, .Reserbed4 => Error.UnknownArchitecture,
            .Sparc => .sparc,
            .x86 => .i386,
            .MIPS => .mips,
            .PowerPC => .powerpc,
            .PowerPC_64 => .powerpc64,
            .ARM => .arm,
            .AMD_64 => .x86_64,
            .Aarch64 => .aarch64,
            .RISC_V => .riscv32,
        };
    }
};

/// The header describing the entire ELF file
pub const Header = packed struct {
    /// Should be 0x7f | 0x45 | 0x4C | 0x46
    magic_number: u32,
    /// The size of the fields in the header after file_type. Should be the size/s compatibile with the machine
    data_size: DataSize,
    /// The endianness of the fields in the header after file_type. Should be the endianness compatible with the machine
    endianness: Endianness,
    /// ELF version. Set to 1
    version: u8,
    /// The target OS' ABI. Normally set to 0 no matter the platform, so we ignore it
    abi: u8,
    /// The version of the above ABI. Mostly ignored but some toolchains put expected linker features here
    abi_version: u8,
    /// All zeroes
    padding: u32,
    padding2: u16,
    padding3: u8,
    /// The type of elf file
    file_type: Type,
    /// The target architecture. Should be compatible with the machine
    architecture: Architecture,
    /// Same as above version field
    version2: u32,
    /// Execution entry point
    entry_address: usize,
    /// Offset of the program header form the start of the elf file
    program_header_offset: usize,
    /// offset of the section header from the start of the elf file
    section_header_offset: usize,
    /// Architecture-dependent flags
    flags: u32,
    /// The size of this elf header in bytes. 64 for the 64-bit format and 52 for the 32-bit format
    elf_header_size: u16,
    /// The size of a program header table entry
    program_header_entry_size: u16,
    /// The number of entries in the program header table
    program_header_entries: u16,
    /// The size of a section header table entry
    section_header_entry_size: u16,
    /// The number of entries in the section header table
    section_header_entries: u16,
    /// The index into the section header table that contains the section names
    section_name_index: u16,
};

/// The type of a program header entry
pub const ProgramEntryType = enum(u32) {
    Unused = 0,
    /// Should be loaded into memory
    Loadable = 1,
    /// Dynamic linking info
    Dynamic = 2,
    /// Interpreter info
    InterpreterInfo = 3,
    /// Extra information used depending on the elf type
    Auxiliary = 4,
    Reserved = 5,
    /// Entry containing the program header table
    ProgramHeader = 6,
    /// Info for thread-local storage
    ThreadLocalStorage = 7,
    /// Gnu toolchain-specific information
    GnuStack = 0x6474E551,
    /// OS-specific info
    LowOS = 0x60000000,
    /// OS-specific info
    HighOS = 0x6FFFFFFF,
    /// CPU-specific info
    LowCPU = 0x70000000,
    /// CPU-specific info
    HighCPU = 0x7FFFFFFF,
};

/// The header desribing the program entries
pub const ProgramHeader = packed struct {
    /// The type of the entry
    entry_type: ProgramEntryType,
    /// Entry type-specific flags for 64-bit ELF files
    flags_64bit: if (@bitSizeOf(usize) == 32) u0 else u32,
    /// Offset of the entry within the ELF file
    offset: usize,
    /// The virtual address associated with the entry
    virtual_address: usize,
    /// The virtual address associated with the entry, if applicable
    physical_address: usize,
    /// Size of the entry in the file
    file_size: usize,
    /// Size of the entry in memory
    mem_size: usize,
    /// Entry type-specific flags for 32-bit ELF files
    flags_32bit: if (@bitSizeOf(usize) == 64) u0 else u32,
    /// Alignment of the entry
    alignment: usize,
};

/// The type of section
pub const SectionType = enum(u32) {
    Unused = 0,
    /// Executable code
    ProgramData = 1,
    /// The symbol table
    SymbolTable = 2,
    /// The table containing all strings used by other sections
    StringTable = 3,
    /// Relocation data with addends
    RelocationWithAddends = 4,
    /// The symbol has table
    SymbolHashTable = 5,
    /// Dynamic linking info
    Dynamic = 6,
    /// Extra information
    Auxiliary = 7,
    /// Space within the program, normally used to store data
    ProgramSpace = 8,
    /// Relocation data without addends
    RelocationWithoutAddends = 9,
    Reserved = 10,
    /// The dynamic linker symbol table
    DynamicSymbolTable = 11,
    /// List of constructors
    Constructors = 14,
    /// List of destructors
    Destructors = 15,
    /// List of pre-contructors
    PreConstructors = 16,
    /// A group of sections
    SectionGroup = 17,
    /// Extended section indices
    ExtendedSectionIndices = 18,
    /// The number of defined types
    NumberDefinedType = 19,
    /// OS-specific
    LowOS = 0x60000000,

    ///
    /// Check if the section has an associated chunk of data in the ELF file
    ///
    /// Arguments:
    ///     IN self: SectionType - The section type
    ///
    /// Return: bool
    ///     Whether the section type has associated data
    ///
    pub fn hasData(self: @This()) bool {
        return switch (self) {
            .Unused, .ProgramData, .ProgramSpace, .Reserved => false,
            else => true,
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(SectionHeader) == if (@bitSizeOf(usize) == 32) 0x28 else 0x40);
    std.debug.assert(@sizeOf(Header) == if (@bitSizeOf(usize) == 32) 0x32 else 0x40);
    std.debug.assert(@sizeOf(ProgramHeader) == if (@bitSizeOf(usize) == 32) 0x20 else 0x38);
}

/// The section is writable
pub const SECTION_WRITABLE = 1;
/// The section occupies memory during execution
pub const SECTION_ALLOCATABLE = 2;
/// The section is executable
pub const SECTION_EXECUTABLE = 4;
/// The section may be merged
pub const SECTION_MERGED = 16;
/// The section contains strings
pub const SECTION_HAS_STRINGS = 32;
/// Contains a SHT index
pub const SECTION_INFO_LINK = 64;
/// Preserve the section order after combining
pub const SECTION_PRESERVE_ORDER = 128;
/// Non-standard OS-specific handling is required
pub const SECTION_OS_NON_STANDARD = 256;
/// Member of a group
pub const SECTION_GROUP = 512;
/// The section contains thread-local data
pub const SECTION_THREAD_LOCAL_DATA = 1024;
/// OS-specific
pub const SECTION_OS_MASK = 0x0FF00000;
/// CPU-specific
pub const SECTION_CPU_MASK = 0xF0000000;

/// The header for an ELF section
pub const SectionHeader = packed struct {
    /// Offset into the string table of the section's name
    name_offset: u32,
    /// The section's type
    section_type: SectionType,
    /// Flags for this section
    flags: usize,
    /// The virtual address at which this section should be loaded (if it is loadable)
    virtual_address: usize,
    /// Offset of the section's data into the file
    offset: usize,
    /// The size of the section's data
    size: usize,
    /// An associated section. Usage depends on the section type
    linked_section_idx: u32,
    /// Extra info. Usage depends on the section type
    info: u32,
    /// The section's alignment
    alignment: usize,
    /// The size of each entry within this section, for sections that contain sub-entries
    entry_size: usize,

    const Self = @This();

    ///
    /// Find the name of this section from the ELF's string table.
    ///
    /// Arguments:
    ///     IN self: SectionHeader - The header to get the name for
    ///     IN elf: Elf - The elf file
    ///
    /// Return: []const u8
    ///     The name of the section
    ///
    pub fn getName(self: Self, elf: Elf) []const u8 {
        // section_name_index has already been checked so will exist
        const string_table = elf.section_data[elf.header.section_name_index] orelse unreachable;
        const str = @ptrCast([*]const u8, string_table.ptr + self.name_offset);
        var len: usize = 0;
        while (str[len] != 0) : (len += 1) {}
        const name = str[0..len];
        return name;
    }
};

/// A loaded ELF file
pub const Elf = struct {
    /// The ELF header that describes the entire file
    header: Header,
    /// The program entry headers
    program_headers: []ProgramHeader,
    /// The section headers
    section_headers: []SectionHeader,
    /// The data associated with each section, or null if a section doesn't have a data area
    section_data: []?[]const u8,
    /// The allocator used
    allocator: *std.mem.Allocator,

    const Self = @This();

    ///
    /// Load and initialise from a data stream for a specific architecture
    ///
    /// Arguments:
    ///     IN elf_data: []const u8 - The data stream to load the elf information from
    ///     IN arch: Arch - The intended architecture to load for
    ///     IN allocator: Allocator - The allocator to use when needing memory
    ///
    /// Return: Elf
    ///     The loaded ELF file
    ///
    /// Error: Allocator.Error || Error
    ///     Allocator.Error - There wasn't enough memory free to allocate the required state
    ///     Error.InvalidMagicNumber - The ELF file magic number wasn't as expected
    ///     Error.InvalidArchitecture - The ELF file wasn't built for the expected architecture
    ///     Error.InvalidDataSize - The ELF file wasn't built for the data size supported by the given architecture
    ///     Error.InvalidEndianness - The ELF file wasn't built with the endianness supported by the given architecture
    ///     Error.WrongStringTableIndex - The string table index in the header does not point to a StringTable section
    ///
    pub fn init(elf_data: []const u8, arch: Arch, allocator: *std.mem.Allocator) (std.mem.Allocator.Error || Error)!Self {
        const header = std.mem.bytesToValue(Header, elf_data[0..@sizeOf(Header)]);
        if (header.magic_number != 0x464C457F) {
            return Error.InvalidMagicNumber;
        }
        if ((try header.architecture.toArch()) != arch) {
            return Error.InvalidArchitecture;
        }
        if (header.data_size.toNumBits() != @bitSizeOf(usize)) {
            return Error.InvalidDataSize;
        }
        if (header.endianness.toEndian() != arch.endian()) {
            return Error.InvalidEndianness;
        }
        if (header.section_name_index >= header.section_header_entries)
            return Error.WrongStringTableIndex;

        var program_segments = try allocator.alloc(ProgramHeader, header.program_header_entries);
        errdefer allocator.free(program_segments);
        var seg_offset = header.program_header_offset;
        for (program_segments) |*segment| {
            segment.* = @ptrCast(*const ProgramHeader, elf_data.ptr + seg_offset).*;
            seg_offset += header.program_header_entry_size;
        }

        var section_headers = try allocator.alloc(SectionHeader, header.section_header_entries);
        errdefer allocator.free(section_headers);
        var section_data = try allocator.alloc(?[]const u8, header.section_header_entries);
        errdefer allocator.free(section_data);
        var sec_offset = header.section_header_offset;
        for (section_headers) |*section, i| {
            section.* = std.mem.bytesToValue(SectionHeader, (elf_data.ptr + sec_offset)[0..@sizeOf(SectionHeader)]);
            section_data[i] = if (section.section_type.hasData()) elf_data[section.offset .. section.offset + section.size] else null;
            sec_offset += header.section_header_entry_size;
        }

        if (section_headers[header.section_name_index].section_type != .StringTable) {
            return Error.WrongStringTableIndex;
        }

        return Elf{
            .header = header,
            .program_headers = program_segments,
            .section_headers = section_headers,
            .section_data = section_data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const Self) void {
        self.allocator.free(self.section_data);
        self.allocator.free(self.section_headers);
        self.allocator.free(self.program_headers);
    }
};

pub const Error = error{
    UnknownArchitecture,
    InvalidArchitecture,
    InvalidDataSize,
    InvalidMagicNumber,
    InvalidEndianness,
    WrongStringTableIndex,
};

fn testSetHeader(data: []u8, header: Header) void {
    std.mem.copy(u8, data[0..@sizeOf(Header)], @ptrCast([*]const u8, &header)[0..@sizeOf(Header)]);
}

fn testSetSection(data: []u8, header: SectionHeader, idx: usize) void {
    const offset = @sizeOf(Header) + @sizeOf(SectionHeader) * idx;
    std.mem.copy(u8, data[offset .. offset + @sizeOf(SectionHeader)], @ptrCast([*]const u8, &header)[0..@sizeOf(SectionHeader)]);
}

fn testInitData(section_name: []const u8, string_section_name: []const u8, file_type: Type, entry_address: usize, flags: u32, section_flags: u32, strings_flags: u32, section_address: usize, strings_address: usize) []u8 {
    const is_32_bit = @bitSizeOf(usize) == 32;
    const header_size = if (is_32_bit) 0x34 else 0x40;
    const p_header_size = if (is_32_bit) 0x20 else 0x38;
    const s_header_size = if (is_32_bit) 0x28 else 0x40;
    const data_size = header_size + s_header_size + s_header_size + section_name.len + 1 + string_section_name.len + 1;
    var data = testing.allocator.alloc(u8, data_size) catch unreachable;

    var header = Header{
        .magic_number = 0x464C457F,
        .data_size = switch (@bitSizeOf(usize)) {
            32 => .ThirtyTwoBit,
            64 => .SixtyFourBit,
            else => unreachable,
        },
        .endianness = switch (builtin.arch.endian()) {
            .Big => .Big,
            .Little => .Little,
        },
        .version = 1,
        .abi = 0,
        .abi_version = 0,
        .padding = 0,
        .padding2 = 0,
        .padding3 = 0,
        .file_type = file_type,
        .architecture = .AMD_64,
        .version2 = 1,
        .entry_address = entry_address,
        .program_header_offset = undefined,
        .section_header_offset = header_size,
        .flags = flags,
        .elf_header_size = header_size,
        .program_header_entry_size = p_header_size,
        .program_header_entries = 0,
        .section_header_entry_size = s_header_size,
        .section_header_entries = 2,
        .section_name_index = 1,
    };
    var data_offset: usize = 0;
    testSetHeader(data, header);
    data_offset += header_size;

    var section_header = SectionHeader{
        .name_offset = 0,
        .section_type = .ProgramData,
        .flags = section_flags,
        .virtual_address = section_address,
        .offset = 0,
        .size = 0,
        .linked_section_idx = undefined,
        .info = undefined,
        .alignment = 1,
        .entry_size = undefined,
    };
    testSetSection(data, section_header, 0);
    data_offset += s_header_size;

    var string_section_header = SectionHeader{
        .name_offset = @intCast(u32, section_name.len) + 1,
        .section_type = .StringTable,
        .flags = strings_flags,
        .virtual_address = strings_address,
        .offset = data_offset + s_header_size,
        .size = section_name.len + 1 + string_section_name.len + 1,
        .linked_section_idx = undefined,
        .info = undefined,
        .alignment = 1,
        .entry_size = undefined,
    };
    testSetSection(data, string_section_header, 1);
    data_offset += s_header_size;

    std.mem.copy(u8, data[data_offset .. data_offset + section_name.len], section_name);
    data_offset += section_name.len;
    data[data_offset] = 0;
    data_offset += 1;

    std.mem.copy(u8, data[data_offset .. data_offset + string_section_name.len], string_section_name);
    data_offset += string_section_name.len;
    data[data_offset] = 0;
    data_offset += 1;
    return data[0..data_size];
}

test "init" {
    const section_name = "some_section";
    const string_section_name = "strings";
    const is_32_bit = @bitSizeOf(usize) == 32;
    var data = testInitData(section_name, string_section_name, .Executable, 0, undefined, 123, 789, 456, 012);
    defer testing.allocator.free(data);
    const elf = try Elf.init(data, builtin.arch, testing.allocator);
    defer elf.deinit();

    testing.expectEqual(elf.header.data_size, if (is_32_bit) .ThirtyTwoBit else .SixtyFourBit);
    testing.expectEqual(elf.header.file_type, .Executable);
    testing.expectEqual(elf.header.architecture, .AMD_64);
    testing.expectEqual(elf.header.entry_address, 0);
    testing.expectEqual(elf.header.flags, undefined);
    testing.expectEqual(elf.header.section_name_index, 1);

    testing.expectEqual(elf.program_headers.len, 0);

    testing.expectEqual(elf.section_headers.len, 2);
    const section_one = elf.section_headers[0];
    testing.expectEqual(@as(u32, 0), section_one.name_offset);
    testing.expectEqual(SectionType.ProgramData, section_one.section_type);
    testing.expectEqual(@as(usize, 123), section_one.flags);
    testing.expectEqual(@as(usize, 456), section_one.virtual_address);

    const section_two = elf.section_headers[1];
    testing.expectEqual(section_name.len + 1, section_two.name_offset);
    testing.expectEqual(SectionType.StringTable, section_two.section_type);
    testing.expectEqual(@as(usize, 789), section_two.flags);
    testing.expectEqual(@as(usize, 012), section_two.virtual_address);

    testing.expectEqual(@as(usize, 2), elf.section_data.len);
    testing.expectEqual(@as(?[]const u8, null), elf.section_data[0]);
    for ("some_section" ++ [_]u8{0} ++ "strings" ++ [_]u8{0}) |char, i| {
        testing.expectEqual(char, elf.section_data[1].?[i]);
    }

    // Test the string section having the wrong type
    var section_header = elf.section_headers[1];
    section_header.section_type = .ProgramData;
    testSetSection(data, section_header, 1);
    testing.expectError(Error.WrongStringTableIndex, Elf.init(data, builtin.arch, testing.allocator));
    testSetSection(data, elf.section_headers[1], 1);

    // Test the section_name_index being out of bounds
    var header = elf.header;
    header.section_name_index = 3;
    testSetHeader(data, header);
    testing.expectError(Error.WrongStringTableIndex, Elf.init(data, builtin.arch, testing.allocator));

    // Test incorrect endianness
    header = elf.header;
    header.endianness = switch (builtin.arch.endian()) {
        .Big => .Little,
        .Little => .Big,
    };
    testSetHeader(data, header);
    testing.expectError(Error.InvalidEndianness, Elf.init(data, builtin.arch, testing.allocator));

    // Test invalid data size
    header.data_size = switch (@bitSizeOf(usize)) {
        32 => .SixtyFourBit,
        else => .ThirtyTwoBit,
    };
    testSetHeader(data, header);
    testing.expectError(Error.InvalidDataSize, Elf.init(data, builtin.arch, testing.allocator));

    // Test invalid architecture
    header.architecture = switch (builtin.arch) {
        .x86_64 => .Aarch64,
        else => .AMD_64,
    };
    testSetHeader(data, header);
    testing.expectError(Error.InvalidArchitecture, Elf.init(data, builtin.arch, testing.allocator));

    // Test incorrect magic number
    header.magic_number = 123;
    testSetHeader(data, header);
    testing.expectError(Error.InvalidMagicNumber, Elf.init(data, builtin.arch, testing.allocator));
}

test "getName" {
    // The entire ELF test data. The header, program header, two section headers and the section name (with the null terminator)
    var section_name = "some_section";
    var string_section_name = "strings";
    const data = testInitData(section_name, string_section_name, .Executable, 0, undefined, undefined, undefined, undefined, undefined);
    defer testing.allocator.free(data);
    const elf = try Elf.init(data, builtin.arch, testing.allocator);
    defer elf.deinit();
    testing.expectEqualSlices(u8, elf.section_headers[0].getName(elf), section_name);
    testing.expectEqualSlices(u8, elf.section_headers[1].getName(elf), string_section_name);
}

test "toNumBits" {
    testing.expectEqual(DataSize.ThirtyTwoBit.toNumBits(), 32);
    testing.expectEqual(DataSize.SixtyFourBit.toNumBits(), 64);
}

test "toEndian" {
    testing.expectEqual(Endianness.Little.toEndian(), Endian.Little);
    testing.expectEqual(Endianness.Big.toEndian(), Endian.Big);
}

test "toArch" {
    const known_architectures = [_]Architecture{ .Sparc, .x86, .MIPS, .PowerPC, .PowerPC_64, .ARM, .AMD_64, .Aarch64, .RISC_V };
    const known_archs = [known_architectures.len]Arch{ .sparc, .i386, .mips, .powerpc, .powerpc64, .arm, .x86_64, .aarch64, .riscv32 };

    inline for (@typeInfo(Architecture).Enum.fields) |field| {
        const architecture = @field(Architecture, field.name);

        const is_known = inline for (known_architectures) |known_architecture, i| {
            if (known_architecture == architecture) {
                testing.expectEqual(architecture.toArch(), known_archs[i]);
                break true;
            }
        } else false;

        if (!is_known) {
            testing.expectError(Error.UnknownArchitecture, architecture.toArch());
        }
    }
}

test "hasData" {
    const no_data = [_]SectionType{ .Unused, .ProgramSpace, .Reserved, .ProgramData };

    inline for (@typeInfo(SectionType).Enum.fields) |field| {
        const sec_type = @field(SectionType, field.name);
        const has_data = inline for (no_data) |no_data_type| {
            if (sec_type == no_data_type) {
                break false;
            }
        } else true;

        testing.expectEqual(has_data, sec_type.hasData());
    }
}
