const std = @import("std");
const builtin = @import("builtin");
const tty = @import("tty.zig");
const arch = @import("arch.zig").internals;
const log = @import("log.zig");
const multiboot = @import("multiboot.zig");
const mem = @import("mem.zig");
const build_options = @import("build_options");
const ArrayList = std.ArrayList;
const testing = std.testing;

/// The possible errors from panic code
const PanicError = error{
    /// The symbol file is of an invalid format.
    /// This could be because it lacks whitespace, a column or required newline characters.
    InvalidSymbolFile,
};

/// An entry within a symbol map. Corresponds to one entry in a symbole file
const MapEntry = struct {
    /// The address that the entry corresponds to
    addr: usize,

    /// The name of the function that starts at the address
    func_name: []const u8,
};

const SymbolMap = struct {
    symbols: ArrayList(MapEntry),

    ///
    /// Initialise an empty symbol map.
    ///
    /// Arguments:
    ///     IN allocator: *std.mem.Allocator - The allocator to use to initialise the array list.
    ///
    /// Return: SymbolMap
    ///     The symbol map.
    ///
    pub fn init(allocator: *std.mem.Allocator) SymbolMap {
        return SymbolMap{
            .symbols = ArrayList(MapEntry).init(allocator),
        };
    }

    ///
    /// Deinitialise the symbol map, freeing all memory used.
    ///
    pub fn deinit(self: *SymbolMap) void {
        self.symbols.deinit();
    }

    ///
    /// Add a symbol map entry with a name and address.
    ///
    /// Arguments:
    ///     IN name: []const u8 - The name of the entry.
    ///     IN addr: usize - The address for the entry.
    ///
    /// Error: std.mem.Allocator.Error
    ///      * - See ArrayList.append
    ///
    pub fn add(self: *SymbolMap, name: []const u8, addr: u32) !void {
        try self.addEntry(MapEntry{ .addr = addr, .func_name = name });
    }

    pub fn addEntry(self: *SymbolMap, entry: MapEntry) !void {
        try self.symbols.append(entry);
    }

    ///
    /// Search for the function name associated with the address.
    ///
    /// Arguments:
    ///     IN addr: usize - The address to search for.
    ///
    /// Return: ?[]const u8
    ///     The function name associated with that program address, or null if one wasn't found.
    ///
    pub fn search(self: *const SymbolMap, addr: usize) ?[]const u8 {
        if (self.symbols.items.len == 0)
            return null;
        // Find the first element whose address is greater than addr
        var previous_name: ?[]const u8 = null;
        for (self.symbols.items) |entry| {
            if (entry.addr > addr)
                return previous_name;
            previous_name = entry.func_name;
        }
        return previous_name;
    }
};

var symbol_map: ?SymbolMap = null;

///
/// Log a stacktrace address. Logs "(no symbols are available)" if no symbols are available,
/// "?????" if the address wasn't found in the symbol map, else logs the function name.
///
/// Arguments:
///     IN addr: usize - The address to log.
///
fn logTraceAddress(addr: usize) void {
    const str = if (symbol_map) |syms| syms.search(addr) orelse "?????" else "(no symbols available)";
    log.logError("{x}: {}\n", .{ addr, str });
}

pub fn panic(trace: ?*builtin.StackTrace, comptime format: []const u8, args: var) noreturn {
    @setCold(true);
    log.logError("Kernel panic: " ++ format ++ "\n", args);
    if (trace) |trc| {
        var last_addr: u64 = 0;
        for (trc.instruction_addresses) |ret_addr| {
            if (ret_addr != last_addr) logTraceAddress(ret_addr);
            last_addr = ret_addr;
        }
    } else {
        const first_ret_addr = @returnAddress();
        var last_addr: u64 = 0;
        var it = std.debug.StackIterator.init(first_ret_addr, null);
        while (it.next()) |ret_addr| {
            if (ret_addr != last_addr) logTraceAddress(ret_addr);
            last_addr = ret_addr;
        }
    }
    arch.haltNoInterrupts();
}

///
/// Parse a hexadecimal address from the pointer up until the end pointer. Must be terminated by a
/// whitespace character.
///
/// Arguments:
///     INOUT ptr: *[*]const u8 - The address at which to start looking, updated after all
///         characters have been consumed.
///     IN end: *const u8 - The end address at which to start looking. A whitespace character must
///         be found before this.
///
/// Return: usize
///     The address parsed.
///
/// Error: PanicError || std.fmt.ParseUnsignedError
///     PanicError.InvalidSymbolFile: A terminating whitespace wasn't found before the end address.
///     std.fmt.ParseUnsignedError: See std.fmt.parseInt
///
fn parseAddr(ptr: *[*]const u8, end: *const u8) !usize {
    const addr_start = ptr.*;
    ptr.* = try parseNonWhitespace(ptr.*, end);
    const len = @ptrToInt(ptr.*) - @ptrToInt(addr_start);
    const addr_str = addr_start[0..len];
    return try std.fmt.parseInt(usize, addr_str, 16);
}

///
/// Parse a single character. The address given cannot be greater than or equal to the end address
/// given.
///
/// Arguments:
///     IN ptr: [*]const u8 - The address at which to get the character from.
///     IN end: *const u8 - The end address at which to start looking. ptr cannot be greater than or
///         equal to this.
///
/// Return: u8
///     The character parsed.
///
/// Error: PanicError
///     PanicError.InvalidSymbolFile: The address given is greater than or equal to the end address.
///
fn parseChar(ptr: [*]const u8, end: *const u8) PanicError!u8 {
    if (@ptrToInt(ptr) >= @ptrToInt(end)) {
        return PanicError.InvalidSymbolFile;
    }
    return ptr[0];
}

///
/// Parse until a non-whitespace character. Must be terminated by a non-whitespace character before
/// the end address.
///
/// Arguments:
///     IN ptr: [*]const u8 - The address at which to start looking.
///     IN end: *const u8 - The end address at which to start looking. A non-whitespace character
///         must be found before this.
///
/// Return: [*]const u8
///     ptr plus the number of whitespace characters consumed.
///
/// Error: PanicError
///     PanicError.InvalidSymbolFile: A terminating non-whitespace character wasn't found before the
///         end address.
///
fn parseWhitespace(ptr: [*]const u8, end: *const u8) PanicError![*]const u8 {
    var i: u32 = 0;
    while (std.fmt.isWhiteSpace(try parseChar(ptr + i, end))) : (i += 1) {}
    return ptr + i;
}

///
/// Parse until a whitespace character. Must be terminated by a whitespace character before the end
/// address.
///
/// Arguments:
///     IN ptr: [*]const u8 - The address at which to start looking.
///     IN end: *const u8 - The end address at which to start looking. A whitespace character must
///         be found before this.
///
/// Return: [*]const u8
///     ptr plus the number of non-whitespace characters consumed.
///
/// Error: PanicError
///     PanicError.InvalidSymbolFile: A terminating whitespace character wasn't found before the end
///         address.
///
fn parseNonWhitespace(ptr: [*]const u8, end: *const u8) PanicError![*]const u8 {
    var i: u32 = 0;
    while (!std.fmt.isWhiteSpace(try parseChar(ptr + i, end))) : (i += 1) {}
    return ptr + i;
}

///
/// Parse a name from the pointer up until the end pointer. Must be terminated by a whitespace
/// character.
///
/// Arguments:
///     INOUT ptr: *[*]const u8 - The address at which to start looking, updated after all
///         characters have been consumed.
///     IN end: *const u8 - The end address at which to start looking. A whitespace character must
///         be found before this.
///
/// Return: []const u8
///     The name parsed.
///
/// Error: PanicError
///     PanicError.InvalidSymbolFile: A terminating whitespace wasn't found before the end address.
///
fn parseName(ptr: *[*]const u8, end: *const u8) PanicError![]const u8 {
    const name_start = ptr.*;
    ptr.* = try parseNonWhitespace(ptr.*, end);
    const len = @ptrToInt(ptr.*) - @ptrToInt(name_start);
    return name_start[0..len];
}

///
/// Parse a symbol map entry from the pointer up until the end pointer,
/// in the format of '\d+\w+[a-zA-Z0-9]+'. Must be terminated by a whitespace character.
///
/// Arguments:
///     INOUT ptr: *[*]const u8 - The address at which to start looking, updated once after the
///         address has been consumed and once again after the name has been consumed.
///     IN end: *const u8 - The end address at which to start looking. A whitespace character must
///         be found before this.
///
/// Return: MapEntry
///     The entry parsed.
///
/// Error: PanicError || std.fmt.ParseUnsignedError
///     PanicError.InvalidSymbolFile: A terminating whitespace wasn't found before the end address.
///     std.fmt.ParseUnsignedError: See parseAddr.
///
fn parseMapEntry(start: *[*]const u8, end: *const u8) !MapEntry {
    var ptr = try parseWhitespace(start.*, end);
    defer start.* = ptr;
    const addr = try parseAddr(&ptr, end);
    ptr = try parseWhitespace(ptr, end);
    const name = try parseName(&ptr, end);
    return MapEntry{ .addr = addr, .func_name = name };
}

///
/// Initialise the panic subsystem by looking for a boot module called "kernel.map" and loading the
/// symbols from it. Exits early if no such module was found.
///
/// Arguments:
///     IN mem_profile: *const mem.MemProfile - The memory profile from which to get the loaded boot
///         modules.
///     IN allocator: *std.mem.Allocator - The allocator to use to store the symbol map.
///
/// Error: PanicError || std.fmt.ParseUnsignedError
///     PanicError.InvalidSymbolFile: A terminating whitespace wasn't found before the end address.
///     std.fmt.ParseUnsignedError: See parseMapEntry.
///
pub fn init(mem_profile: *const mem.MemProfile, allocator: *std.mem.Allocator) !void {
    log.logInfo("Init panic\n", .{});
    defer log.logInfo("Done panic\n", .{});

    // Exit if we haven't loaded all debug modules
    if (mem_profile.boot_modules.len < 1) {
        return;
    }
    var kmap_start: u32 = 0;
    var kmap_end: u32 = 0;
    for (mem_profile.boot_modules) |module| {
        const mod_start = mem.physToVirt(@intCast(usize, module.mod_start));
        const mod_end = mem.physToVirt(@intCast(usize, module.mod_end) - 1);
        const mod_str_ptr = mem.physToVirt(@intToPtr([*:0]u8, module.cmdline));
        if (std.mem.eql(u8, std.mem.span(mod_str_ptr), "kernel.map")) {
            kmap_start = mod_start;
            kmap_end = mod_end;
            break;
        }
    }
    // Don't try to load the symbols if there was no symbol map file. This is a valid state so just
    // exit early
    if (kmap_start == 0 or kmap_end == 0) {
        return;
    }

    var syms = SymbolMap.init(allocator);
    errdefer syms.deinit();
    var file_index = kmap_start;
    var kmap_ptr = @intToPtr([*]u8, kmap_start);
    while (@ptrToInt(kmap_ptr) < kmap_end - 1) {
        const entry = try parseMapEntry(&kmap_ptr, @intToPtr(*const u8, kmap_end));
        try syms.addEntry(entry);
    }
    symbol_map = syms;

    switch (build_options.test_type) {
        .PANIC => runtimeTests(),
        else => {},
    }
}

test "parseChar" {
    const str: []const u8 = "plutoisthebest";
    const end = @ptrCast(*const u8, str.ptr + 14);
    var char = try parseChar(str.ptr, end);
    testing.expectEqual(char, 'p');
    char = try parseChar(str.ptr + 1, end);
    testing.expectEqual(char, 'l');
    testing.expectError(PanicError.InvalidSymbolFile, parseChar(str.ptr + 14, end));
}

test "parseWhitespace" {
    const str: []const u8 = "    a";
    const end = @ptrCast(*const u8, str.ptr + 5);
    var ptr = try parseWhitespace(str.ptr, end);
    testing.expectEqual(@ptrToInt(str.ptr) + 4, @ptrToInt(ptr));
}

test "parseWhitespace fails without a terminating whitespace" {
    const str: []const u8 = "   ";
    const end = @ptrCast(*const u8, str.ptr + 3);
    testing.expectError(PanicError.InvalidSymbolFile, parseWhitespace(str.ptr, end));
}

test "parseNonWhitespace" {
    const str: []const u8 = "ab ";
    const end = @ptrCast(*const u8, str.ptr + 3);
    var ptr = try parseNonWhitespace(str.ptr, end);
    testing.expectEqual(@ptrToInt(str.ptr) + 2, @ptrToInt(ptr));
}

test "parseNonWhitespace fails without a terminating whitespace" {
    const str: []const u8 = "abc";
    const end = @ptrCast(*const u8, str.ptr + 3);
    testing.expectError(PanicError.InvalidSymbolFile, parseNonWhitespace(str.ptr, end));
}

test "parseAddr" {
    const str: []const u8 = "1a2b3c4d ";
    const end = @ptrCast(*const u8, str.ptr + 9);
    var ptr = str.ptr;
    testing.expectEqual(try parseAddr(&ptr, end), 0x1a2b3c4d);
}

test "parseAddr fails without a terminating whitespace" {
    const str: []const u8 = "1a2b3c4d";
    const end = @ptrCast(*const u8, str.ptr + 9);
    var ptr = str.ptr;
    testing.expectError(PanicError.InvalidSymbolFile, parseAddr(&ptr, end));
}

test "parseAddr fails with an invalid integer" {
    const str: []const u8 = "1g2t ";
    const end = @ptrCast(*const u8, str.ptr + 5);
    var ptr = str.ptr;
    testing.expectError(error.InvalidCharacter, parseAddr(&ptr, end));
}

test "parseName" {
    const str: []const u8 = "func_name ";
    const end = @ptrCast(*const u8, str.ptr + 10);
    var ptr = str.ptr;
    testing.expectEqualSlices(u8, try parseName(&ptr, end), "func_name");
}

test "parseName fails without a terminating whitespace" {
    const str: []const u8 = "func_name";
    const end = @ptrCast(*const u8, str.ptr + 9);
    var ptr = str.ptr;
    testing.expectError(PanicError.InvalidSymbolFile, parseName(&ptr, end));
}

test "parseMapEntry" {
    const str: []const u8 = "1a2b3c4d func_name\n5e6f7a8b func_name2\n";
    const end = @ptrCast(*const u8, str.ptr + 39);
    var ptr = str.ptr;

    var actual = try parseMapEntry(&ptr, end);
    var expected = MapEntry{ .addr = 0x1a2b3c4d, .func_name = "func_name" };
    testing.expectEqual(actual.addr, expected.addr);
    testing.expectEqualSlices(u8, actual.func_name, expected.func_name);

    actual = try parseMapEntry(&ptr, end);
    expected = MapEntry{ .addr = 0x5e6f7a8b, .func_name = "func_name2" };
    testing.expectEqual(actual.addr, expected.addr);
    testing.expectEqualSlices(u8, actual.func_name, expected.func_name);
}

test "parseMapEntry fails without a terminating whitespace" {
    const str: []const u8 = "1a2b3c4d func_name";
    var ptr = str.ptr;
    testing.expectError(PanicError.InvalidSymbolFile, parseMapEntry(&ptr, @ptrCast(*const u8, str.ptr + 18)));
}

test "parseMapEntry fails without any characters" {
    const str: []const u8 = " ";
    var ptr = str.ptr;
    testing.expectError(PanicError.InvalidSymbolFile, parseMapEntry(&ptr, @ptrCast(*const u8, str.ptr)));
}

test "parseMapEntry fails with an invalid address" {
    const str: []const u8 = "xyz func_name";
    var ptr = str.ptr;
    testing.expectError(error.InvalidCharacter, parseMapEntry(&ptr, @ptrCast(*const u8, str.ptr + 13)));
}

test "parseMapEntry fails without a name" {
    const str: []const u8 = "123 ";
    var ptr = str.ptr;
    testing.expectError(PanicError.InvalidSymbolFile, parseMapEntry(&ptr, @ptrCast(*const u8, str.ptr + 4)));
}

test "SymbolMap" {
    var allocator = std.heap.page_allocator;
    var map = SymbolMap.init(allocator);
    try map.add("abc"[0..], 123);
    try map.addEntry(MapEntry{ .func_name = "def"[0..], .addr = 456 });
    try map.add("ghi"[0..], 789);
    try map.addEntry(MapEntry{ .func_name = "jkl"[0..], .addr = 1010 });
    testing.expectEqual(map.search(54), null);
    testing.expectEqual(map.search(122), null);
    testing.expectEqual(map.search(123), "abc");
    testing.expectEqual(map.search(234), "abc");
    testing.expectEqual(map.search(455), "abc");
    testing.expectEqual(map.search(456), "def");
    testing.expectEqual(map.search(678), "def");
    testing.expectEqual(map.search(788), "def");
    testing.expectEqual(map.search(789), "ghi");
    testing.expectEqual(map.search(1009), "ghi");
    testing.expectEqual(map.search(1010), "jkl");
    testing.expectEqual(map.search(2345), "jkl");
}

///
/// Runtime test for panic. This will trigger a integer overflow.
///
pub fn runtimeTests() void {
    var x: u8 = 255;
    x += 1;
    // If we get here, then a panic was not triggered so fail
    panic(@errorReturnTrace(), "FAILURE: No integer overflow\n", .{});
}
