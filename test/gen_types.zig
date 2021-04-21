const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;

// Check duplicate types
comptime {
    @setEvalBranchQuota(types.len * types.len * 7);
    inline for (types) |t1, i| {
        inline for (types) |t2, j| {
            if (i != j) {
                if (std.mem.eql(u8, t1[0], t2[0])) {
                    @compileError("Duplicate types: " ++ t1[0]);
                } else if (std.mem.eql(u8, t1[1], t2[1])) {
                    @compileError("Duplicate enum literal: " ++ t1[1]);
                }
            }
        }
    }
}

/// The types needed for mocking
/// The format is as follows:
///     1. The type represented as a string. This is because @typeName doesn't play nicely with
///        all types so this way, what is put here is what you get when generated. There can only
///        be one of each type.
///     2. The enum to represent the type. See other below for example names. These have to be
///        unique.
///     3. The import name for a type (what would go in the @import()) without the .zig. This is
///        optional as some types won't need an import. If a type has already been imported, then
///        this can be omitted. Currently this is a single import, but this can be extended to have
///        a comma separated list of import with types that contain types from multiple places.
///     4. The sub import. This is what would come after the @import() but before the type to be
///        imported. An easy example is the Allocator where the sub import would be std.mem with no
///        import as @import("std") is already included. Another example is if including a type
///        from a struct.
///     5. The base type to include. This is different to the type in (1) as will exclude pointer.
///        This will be the name of the type to be included.
const types = .{
    .{ "bool", "BOOL", "", "", "" },
    .{ "u4", "U4", "", "", "" },
    .{ "u8", "U8", "", "", "" },
    .{ "u16", "U16", "", "", "" },
    .{ "u32", "U32", "", "", "" },
    .{ "usize", "USIZE", "", "", "" },
    .{ "StatusRegister", "STATUSREGISTER", "cmos_mock", "", "StatusRegister" },
    .{ "RtcRegister", "RTCREGISTER", "cmos_mock", "", "RtcRegister" },
    .{ "IdtPtr", "IDTPTR", "idt_mock", "", "IdtPtr" },
    .{ "*const GdtPtr", "PTR_CONST_GDTPTR", "gdt_mock", "", "GdtPtr" },
    .{ "*const IdtPtr", "PTR_CONST_IDTPTR", "idt_mock", "", "IdtPtr" },
    .{ "*Allocator", "PTR_ALLOCATOR", "", "std.mem", "Allocator" },

    .{ "IdtError!void", "ERROR_IDTERROR_RET_VOID", "idt_mock", "", "IdtError" },

    .{ "fn () callconv(.C) void", "FN_CCC_OVOID", "", "", "" },
    .{ "fn () callconv(.Naked) void", "FN_CCNAKED_OVOID", "", "", "" },
    .{ "fn () void", "FN_OVOID", "", "", "" },
    .{ "fn () u16", "FN_OU16", "", "", "" },
    .{ "fn () usize", "FN_OUSIZE", "", "", "" },
    .{ "fn () GdtPtr", "FN_OGDTPTR", "", "", "" },
    .{ "fn () IdtPtr", "FN_OIDTPTR", "", "", "" },

    .{ "fn (u8) void", "FN_IU8_OVOID", "", "", "" },
    .{ "fn (u8) bool", "FN_IU8_OBOOL", "", "", "" },
    .{ "fn (u16) void", "FN_IU16_OVOID", "", "", "" },
    .{ "fn (u16) u8", "FN_IU16_OU8", "", "", "" },
    .{ "fn (u16) u32", "FN_IU16_OU32", "", "", "" },
    .{ "fn (usize) bool", "FN_IUSIZE_OBOOL", "", "", "" },
    .{ "fn (RtcRegister) u8", "FN_IRTCREGISTER_OU8", "", "", "" },
    .{ "fn (IdtEntry) bool", "FN_IIDTENTRY_OBOOL", "idt_mock", "", "IdtEntry" },
    .{ "fn (*const GdtPtr) void", "FN_IPTRCONSTGDTPTR_OVOID", "", "", "" },
    .{ "fn (*const IdtPtr) void", "FN_IPTRCONSTIDTPTR_OVOID", "", "", "" },

    .{ "fn (u4, u4) u8", "FN_IU4_IU4_OU8", "", "", "" },
    .{ "fn (u8, u8) u16", "FN_IU8_IU8_OU16", "", "", "" },
    .{ "fn (u8, fn () callconv(.Naked) void) IdtError!void", "FN_IU8_IFNCCNAKEDOVOID_EIDTERROR_OVOID", "", "", "" },
    .{ "fn (u16, u8) void", "FN_IU16_IU8_OVOID", "", "", "" },
    .{ "fn (u16, u16) void", "FN_IU16_IU16_OVOID", "", "", "" },
    .{ "fn (u16, u32) void", "FN_IU16_IU32_OVOID", "", "", "" },
    .{ "fn (StatusRegister, bool) u8", "FN_ISTATUSREGISTER_IBOOL_OU8", "", "", "" },

    .{ "fn (StatusRegister, u8, bool) void", "FN_ISTATUSREGISTER_IU8_IBOOL_OVOID", "", "", "" },
};

// Create the imports
fn genImports() []const u8 {
    @setEvalBranchQuota(types.len * types.len * 7);
    comptime var str: []const u8 = "";
    comptime var seen_imports: []const u8 = &[_]u8{};
    comptime var seen_types: []const u8 = &[_]u8{};

    inline for (types) |t| {
        const has_import = !std.mem.eql(u8, t[2], "");
        const seen = if (std.mem.indexOf(u8, seen_imports, t[2])) |_| true else false;
        if (has_import and !seen) {
            str = str ++ "const " ++ t[2] ++ " = @import(\"" ++ t[2] ++ ".zig\");\n";
            seen_imports = seen_imports ++ t[2];
        }
    }

    inline for (types) |t| {
        const has_import = !std.mem.eql(u8, t[2], "");
        const has_base = !std.mem.eql(u8, t[3], "");
        const has_type = !std.mem.eql(u8, t[4], "");
        const seen = if (std.mem.indexOf(u8, seen_types, t[4])) |_| true else false;
        if (!seen and has_type and (has_import or has_base)) {
            str = str ++ "const " ++ t[4] ++ " = ";
            if (has_import) {
                str = str ++ t[2] ++ ".";
            }
            if (has_base) {
                str = str ++ t[3] ++ ".";
            }
            str = str ++ t[4] ++ ";\n";
            seen_types = seen_types ++ t[4];
        }
    }
    // Remove trailing new line
    return str;
}

// Create the DataElementType
fn genDataElementType() []const u8 {
    comptime var str: []const u8 = "const DataElementType = enum {\n";
    inline for (types) |t| {
        const spaces = " " ** 4;
        str = str ++ spaces ++ t[1] ++ ",\n";
    }
    return str ++ "};\n";
}

// Create the DataElement
fn genDataElement() []const u8 {
    comptime var str: []const u8 = "const DataElement = union(DataElementType) {\n";
    inline for (types) |t| {
        const spaces = " " ** 4;
        str = str ++ spaces ++ t[1] ++ ": " ++ t[0] ++ ",\n";
    }
    return str ++ "};\n";
}

// All the function generation parts are the same apart from 3 things
fn genGenericFunc(comptime intermediate: []const u8, comptime trail: []const u8, comptime end: []const u8) []const u8 {
    comptime var str: []const u8 = "";
    inline for (types) |t, i| {
        const spaces = if (i == 0) " " ** 4 else " " ** 16;
        str = str ++ spaces ++ t[0] ++ intermediate ++ t[1] ++ trail;
    }
    return str ++ " " ** 16 ++ end;
}

// Create the createDataElement
fn genCreateDataElement() []const u8 {
    return genGenericFunc(" => DataElement{ .", " = arg },\n", "else => @compileError(\"Type not supported: \" ++ @typeName(@TypeOf(arg))),");
}

// Create the getDataElementType
fn genGetDataElementType() []const u8 {
    return genGenericFunc(" => DataElement.", ",\n", "else => @compileError(\"Type not supported: \" ++ @typeName(T)),");
}

// Create the getDataValue
fn genGetDataValue() []const u8 {
    return genGenericFunc(" => element.", ",\n", "else => @compileError(\"Type not supported: \" ++ @typeName(T)),");
}

///
/// Generate the mocking framework file from the template file and the type.
///
/// Error: Allocator.Error || File.OpenError || File.WriteError || File.ReadError
///     Allocator.Error - If there wasn't enough memory for reading in the mocking template file.
///     File.OpenError  - Error opening the mocking template and output file.
///     File.WriteError - Error writing to the output mocking file.
///     File.ReadError  - Error reading the mocking template file.
///
pub fn main() (Allocator.Error || File.OpenError || File.WriteError || File.ReadError)!void {
    std.log.debug("Running MOCK gen\n", .{});
    // Create the file output mocking framework file
    const mock_file = try std.fs.cwd().createFile("test/mock/kernel/mock_framework.zig", .{});
    defer mock_file.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    // All the string
    const imports_str = comptime genImports();
    const data_element_type_str = comptime genDataElementType();
    const data_element_str = comptime genDataElement();
    const create_data_element_str = comptime genCreateDataElement();
    const get_data_element_type_str = comptime genGetDataElementType();
    const get_data_value_str = comptime genGetDataValue();

    // Read the mock template file
    const mock_template = try std.fs.cwd().openFile("test/mock/kernel/mock_framework_template.zig", .{});
    defer mock_template.close();
    const mock_framework_str = try mock_template.readToEndAlloc(allocator, 1024 * 1024 * 1024);
    defer allocator.free(mock_framework_str);

    // The index where to write the templates
    const imports_delimiter = "////Imports////";
    const imports_index = (std.mem.indexOf(u8, mock_framework_str, imports_delimiter) orelse unreachable);

    const data_element_type_delimiter = "////DataElementType////";
    const data_element_type_index = (std.mem.indexOf(u8, mock_framework_str, data_element_type_delimiter) orelse unreachable);

    const data_element_delimiter = "////DataElement////";
    const data_element_index = (std.mem.indexOf(u8, mock_framework_str, data_element_delimiter) orelse unreachable);

    const create_data_elem_delimiter = "////createDataElement////";
    const create_data_elem_index = (std.mem.indexOf(u8, mock_framework_str, create_data_elem_delimiter) orelse unreachable);

    const get_data_elem_type_delimiter = "////getDataElementType////";
    const get_data_elem_type_index = (std.mem.indexOf(u8, mock_framework_str, get_data_elem_type_delimiter) orelse unreachable);

    const get_data_value_delimiter = "////getDataValue////";
    const get_data_value_index = (std.mem.indexOf(u8, mock_framework_str, get_data_value_delimiter) orelse unreachable);

    // Write the beginning of the file
    try mock_file.writer().writeAll(mock_framework_str[0..imports_index]);

    // Write the Imports
    try mock_file.writer().writeAll(imports_str);

    // Write the up to DataElementType
    try mock_file.writer().writeAll(mock_framework_str[imports_index + imports_delimiter.len .. data_element_type_index]);

    // Write the DataElementType
    try mock_file.writer().writeAll(data_element_type_str);

    // Write the up to DataElement
    try mock_file.writer().writeAll(mock_framework_str[data_element_type_index + data_element_type_delimiter.len .. data_element_index]);

    // Write the DataElement
    try mock_file.writer().writeAll(data_element_str);

    // Write the up to createDataElement
    try mock_file.writer().writeAll(mock_framework_str[data_element_index + data_element_delimiter.len .. create_data_elem_index]);

    // Write the createDataElement
    try mock_file.writer().writeAll(create_data_element_str);

    // Write the up to getDataElementType
    try mock_file.writer().writeAll(mock_framework_str[create_data_elem_index + create_data_elem_delimiter.len .. get_data_elem_type_index]);

    // Write the getDataElementType
    try mock_file.writer().writeAll(get_data_element_type_str);

    // Write the up to getDataValue
    try mock_file.writer().writeAll(mock_framework_str[get_data_elem_type_index + get_data_elem_type_delimiter.len .. get_data_value_index]);

    // Write the getDataValue
    try mock_file.writer().writeAll(get_data_value_str);

    // Write the rest of the file
    try mock_file.writer().writeAll(mock_framework_str[get_data_value_index + get_data_value_delimiter.len ..]);
}
