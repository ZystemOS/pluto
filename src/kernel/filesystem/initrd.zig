const std = @import("std");
const builtin = @import("builtin");
const is_test = builtin.is_test;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualSlices = std.testing.expectEqualSlices;
const build_options = @import("build_options");
const mock_path = build_options.mock_path;
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;
const vfs = @import("vfs.zig");
const mem = if (is_test) @import("../" ++ mock_path ++ "mem_mock.zig") else @import("../mem.zig");
const panic = if (is_test) @import("../" ++ mock_path ++ "panic_mock.zig").panic else @import("../panic.zig").panic;

/// The Initrd file system struct.
/// Format of raw ramdisk:
/// (NumOfFiles:usize)[(name_length:usize)(name:u8[name_length])(content_length:usize)(content:u8[content_length])]*
pub const InitrdFS = struct {
    /// The ramdisk header that stores pointers to the raw ramdisk for the name and file content.
    /// As the ramdisk is read only, these can be const pointers.
    const InitrdHeader = struct {
        /// The name of the file
        name: []const u8,

        /// The content of the file
        content: []const u8,
    };

    /// The error set for the ramdisk file system.
    const Error = error{
        /// The error for an invalid raw ramdisk when
        /// parsing.
        InvalidRamDisk,
    };

    const Self = @This();

    /// A mapping of opened files so can easily retrieved opened files for reading.
    opened_files: AutoHashMap(*const vfs.Node, *InitrdHeader),

    /// The underlying file system
    fs: *vfs.FileSystem,

    /// The allocator used for allocating memory for opening and reading.
    allocator: *Allocator,

    /// The list of files in the ram disk. These will be pointers into the raw ramdisk to save on
    /// allocations.
    files: []InitrdHeader,

    /// The root node for the ramdisk file system. This is just a root directory as there is not
    /// subdirectories.
    root_node: *vfs.Node,

    /// See vfs.FileSystem.instance
    instance: usize,

    /// See vfs.FileSystem.getRootNode
    fn getRootNode(fs: *const vfs.FileSystem) *const vfs.DirNode {
        var self = @fieldParentPtr(InitrdFS, "instance", fs.instance);
        return &self.root_node.Dir;
    }

    /// See vfs.FileSystem.close
    fn close(fs: *const vfs.FileSystem, node: *const vfs.FileNode) void {
        var self = @fieldParentPtr(InitrdFS, "instance", fs.instance);
        const cast_node = @ptrCast(*const vfs.Node, node);
        // As close can't error, if provided with a invalid Node that isn't opened or try to close
        // the same file twice, will just do nothing.
        if (self.opened_files.contains(cast_node)) {
            _ = self.opened_files.remove(cast_node);
            self.allocator.destroy(node);
        }
    }

    /// See vfs.FileSystem.read
    fn read(fs: *const vfs.FileSystem, node: *const vfs.FileNode, len: usize) (Allocator.Error || vfs.Error)![]u8 {
        var self = @fieldParentPtr(InitrdFS, "instance", fs.instance);
        const cast_node = @ptrCast(*const vfs.Node, node);
        const file_header = self.opened_files.get(cast_node) orelse return vfs.Error.NotOpened;
        const length = std.math.min(len, file_header.content.len);
        const buff = try self.allocator.alloc(u8, length);
        std.mem.copy(u8, buff, file_header.content[0..length]);
        return buff;
    }

    /// See vfs.FileSystem.write
    fn write(fs: *const vfs.FileSystem, node: *const vfs.FileNode, bytes: []const u8) (Allocator.Error || vfs.Error)!void {}

    /// See vfs.FileSystem.open
    fn open(fs: *const vfs.FileSystem, dir: *const vfs.DirNode, name: []const u8, flags: vfs.OpenFlags) (Allocator.Error || vfs.Error)!*vfs.Node {
        var self = @fieldParentPtr(InitrdFS, "instance", fs.instance);
        switch (flags) {
            .CREATE_DIR, .CREATE_FILE => return vfs.Error.InvalidFlags,
            .NO_CREATION => {
                for (self.files) |*file| {
                    if (std.mem.eql(u8, file.name, name)) {
                        // Opening 2 files of the same name, will create 2 different Nodes
                        // Create a node
                        var file_node = try self.allocator.create(vfs.Node);
                        file_node.* = .{ .File = .{ .fs = self.fs } };
                        try self.opened_files.put(file_node, file);
                        return file_node;
                    }
                }
                return vfs.Error.NoSuchFileOrDir;
            },
        }
    }

    ///
    /// Free all memory allocated.
    ///
    /// Arguments:
    ///     IN self: *Self - Self
    ///
    pub fn deinit(self: *Self) void {
        // If there are any files open, then we have a error.
        std.debug.assert(self.opened_files.items().len == 0);
        self.allocator.destroy(self.root_node);
        self.allocator.destroy(self.fs);
        self.opened_files.deinit();
        self.allocator.free(self.files);
        self.allocator.destroy(self);
    }

    ///
    /// Initialise a ramdisk file system from a raw ramdisk in memory provided by the bootloader.
    /// Any memory allocated will be freed.
    ///
    /// Arguments:
    ///     IN rd_module: mem.Module - The bootloader module that contains the raw ramdisk.
    ///     IN allocator: *Allocator - The allocator used for initialising any memory needed.
    ///
    /// Return: *InitrdFS
    ///     A pointer to the ram disk file system.
    ///
    /// Error: Allocator.Error || Error
    ///     error.OutOfMemory    - If there isn't enough memory for initialisation. Any memory
    ///                            allocated will be freed.
    ///     error.InvalidRamDisk - If the provided raw ramdisk is invalid. This can be due to a
    ///                            mis-match of the number of files to the length of the raw
    ///                            ramdisk or the wrong length provided to cause undefined parsed
    ///                            lengths for other parts of the ramdisk.
    ///
    pub fn init(rd_module: mem.Module, allocator: *Allocator) (Allocator.Error || Error)!*InitrdFS {
        std.log.info(.initrd, "Init\n", .{});
        defer std.log.info(.initrd, "Done\n", .{});

        const rd_len: usize = rd_module.region.end - rd_module.region.start;
        const ramdisk_bytes = @intToPtr([*]u8, rd_module.region.start)[0..rd_len];
        // First @sizeOf(usize) bytes is the number of files
        const num_of_files = std.mem.readIntSlice(usize, ramdisk_bytes[0..], builtin.endian);
        var headers = try allocator.alloc(InitrdHeader, num_of_files);
        errdefer allocator.free(headers);

        // Populate the headers
        var i: usize = 0;
        // Keep track of the offset into the ramdisk memory
        var current_offset: usize = @sizeOf(usize);
        while (i < num_of_files) : (i += 1) {
            // We don't need to store the name length any more as we have the name.len
            const name_len = std.mem.readIntSlice(usize, ramdisk_bytes[current_offset..], builtin.endian);
            current_offset += @sizeOf(usize);
            if (current_offset >= rd_len) {
                return Error.InvalidRamDisk;
            }
            headers[i].name = ramdisk_bytes[current_offset .. current_offset + name_len];
            current_offset += name_len;
            if (current_offset >= rd_len) {
                return Error.InvalidRamDisk;
            }
            const content_len = std.mem.readIntSlice(usize, ramdisk_bytes[current_offset..], builtin.endian);
            current_offset += @sizeOf(usize);
            if (current_offset >= rd_len) {
                return Error.InvalidRamDisk;
            }
            headers[i].content = ramdisk_bytes[current_offset .. current_offset + content_len];
            current_offset += content_len;
            // We could be at the end of the ramdisk, so only need to check for grater than.
            if (current_offset > rd_len) {
                return Error.InvalidRamDisk;
            }
        }

        // Make sure we are at the end
        if (current_offset != rd_len) {
            return Error.InvalidRamDisk;
        }

        var rd_fs = try allocator.create(InitrdFS);
        errdefer allocator.destroy(rd_fs);
        var fs = try allocator.create(vfs.FileSystem);
        errdefer allocator.destroy(fs);
        var root_node = try allocator.create(vfs.Node);

        root_node.* = .{ .Dir = .{ .fs = fs, .mount = null } };
        fs.* = .{ .open = open, .close = close, .read = read, .write = write, .instance = &rd_fs.instance, .getRootNode = getRootNode };

        rd_fs.* = .{
            .opened_files = AutoHashMap(*const vfs.Node, *InitrdHeader).init(allocator),
            .fs = fs,
            .allocator = allocator,
            .files = headers,
            .root_node = root_node,
            .instance = 1,
        };

        switch (build_options.test_mode) {
            .Initialisation => runtimeTests(rd_fs),
            else => {},
        }

        return rd_fs;
    }
};

///
/// Crate a raw ramdisk in memory to be used to initialise the ramdisk file system. This create
/// three files: test1.txt, test2.txt and test3.txt.
///
/// Arguments:
///     IN allocator: *Allocator - The allocator to alloc the raw ramdisk.
///
/// Return: []u8
///     The bytes of the raw ramdisk in memory.
///
/// Error: Allocator.Error
///     error.OutOfMemory - If there isn't enough memory for the in memory ramdisk.
///
fn createInitrd(allocator: *Allocator) Allocator.Error![]u8 {
    // Create 3 valid ramdisk files in memory
    const file_names = [_][]const u8{ "test1.txt", "test2.txt", "test3.txt" };
    const file_contents = [_][]const u8{ "This is a test", "This is a test: part 2", "This is a test: the prequel" };

    var sum: usize = 0;
    const files_length = for ([_]usize{ 0, 1, 2 }) |i| {
        sum += @sizeOf(usize) + file_names[i].len + @sizeOf(usize) + file_contents[i].len;
    } else sum;

    const total_ramdisk_len = @sizeOf(usize) + files_length;
    var ramdisk_mem = try allocator.alloc(u8, total_ramdisk_len);

    // Copy the data into the allocated memory
    std.mem.writeIntSlice(usize, ramdisk_mem[0..], 3, builtin.endian);
    var current_offset: usize = @sizeOf(usize);
    inline for ([_]usize{ 0, 1, 2 }) |i| {
        // Name len
        std.mem.writeIntSlice(usize, ramdisk_mem[current_offset..], file_names[i].len, builtin.endian);
        current_offset += @sizeOf(usize);
        // Name
        std.mem.copy(u8, ramdisk_mem[current_offset..], file_names[i]);
        current_offset += file_names[i].len;
        // File len
        std.mem.writeIntSlice(usize, ramdisk_mem[current_offset..], file_contents[i].len, builtin.endian);
        current_offset += @sizeOf(usize);
        // File content
        std.mem.copy(u8, ramdisk_mem[current_offset..], file_contents[i]);
        current_offset += file_contents[i].len;
    }
    // Make sure we are full
    expectEqual(current_offset, total_ramdisk_len);
    return ramdisk_mem;
}

test "init with files valid" {
    var ramdisk_mem = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_mem);

    const ramdisk_range = .{ .start = @ptrToInt(ramdisk_mem.ptr), .end = @ptrToInt(ramdisk_mem.ptr) + ramdisk_mem.len };
    const ramdisk_module = .{ .region = ramdisk_range, .name = "ramdisk.initrd" };
    var fs = try InitrdFS.init(ramdisk_module, std.testing.allocator);
    defer fs.deinit();

    expectEqual(fs.files.len, 3);
    expectEqualSlices(u8, fs.files[0].name, "test1.txt");
    expectEqualSlices(u8, fs.files[1].content, "This is a test: part 2");
    expectEqual(fs.opened_files.items().len, 0);
}

test "init with files invalid - invalid number of files" {
    var ramdisk_mem = try createInitrd(std.testing.allocator);
    // Override the number of files
    std.mem.writeIntSlice(usize, ramdisk_mem[0..], 10, builtin.endian);
    defer std.testing.allocator.free(ramdisk_mem);

    const ramdisk_range = .{ .start = @ptrToInt(ramdisk_mem.ptr), .end = @ptrToInt(ramdisk_mem.ptr) + ramdisk_mem.len };
    const ramdisk_module = .{ .region = ramdisk_range, .name = "ramdisk.initrd" };
    expectError(error.InvalidRamDisk, InitrdFS.init(ramdisk_module, std.testing.allocator));

    // Override the number of files
    std.mem.writeIntSlice(usize, ramdisk_mem[0..], 0, builtin.endian);
    expectError(error.InvalidRamDisk, InitrdFS.init(ramdisk_module, std.testing.allocator));
}

test "init with files invalid - mix - bad" {
    // TODO: Craft a ramdisk that would parse but is invalid
    //       This is possible, but will think about this another time
    //       Challenge, make this a effective security vulnerability
    //       P.S. I don't know if adding magics will stop this
    {
        var ramdisk_mem = try createInitrd(std.testing.allocator);
        // Override the first file name length, make is shorter
        std.mem.writeIntSlice(usize, ramdisk_mem[4..], 2, builtin.endian);
        defer std.testing.allocator.free(ramdisk_mem);

        const ramdisk_range = .{ .start = @ptrToInt(ramdisk_mem.ptr), .end = @ptrToInt(ramdisk_mem.ptr) + ramdisk_mem.len };
        const ramdisk_module = .{ .region = ramdisk_range, .name = "ramdisk.initrd" };
        expectError(error.InvalidRamDisk, InitrdFS.init(ramdisk_module, std.testing.allocator));
    }

    {
        var ramdisk_mem = try createInitrd(std.testing.allocator);
        // Override the first file name length, make is 4 shorter
        std.mem.writeIntSlice(usize, ramdisk_mem[4..], 5, builtin.endian);
        // Override the second file name length, make is 4 longer
        std.mem.writeIntSlice(usize, ramdisk_mem[35..], 13, builtin.endian);
        defer std.testing.allocator.free(ramdisk_mem);

        const ramdisk_range = .{ .start = @ptrToInt(ramdisk_mem.ptr), .end = @ptrToInt(ramdisk_mem.ptr) + ramdisk_mem.len };
        const ramdisk_module = .{ .region = ramdisk_range, .name = "ramdisk.initrd" };
        expectError(error.InvalidRamDisk, InitrdFS.init(ramdisk_module, std.testing.allocator));
    }
}

test "init with files cleans memory if OutOfMemory" {
    // There are 4 allocations
    for ([_]usize{ 0, 1, 2, 3 }) |i| {
        {
            var fa = std.testing.FailingAllocator.init(std.testing.allocator, i);

            var ramdisk_mem = try createInitrd(std.testing.allocator);
            defer std.testing.allocator.free(ramdisk_mem);

            const ramdisk_range = .{ .start = @ptrToInt(ramdisk_mem.ptr), .end = @ptrToInt(ramdisk_mem.ptr) + ramdisk_mem.len };
            const ramdisk_module = .{ .region = ramdisk_range, .name = "ramdisk.initrd" };
            expectError(error.OutOfMemory, InitrdFS.init(ramdisk_module, &fa.allocator));
        }

        // Ensure we have freed any memory allocated
        try std.testing.allocator_instance.validate();
    }
}

test "getRootNode" {
    var ramdisk_mem = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_mem);

    const ramdisk_range = .{ .start = @ptrToInt(ramdisk_mem.ptr), .end = @ptrToInt(ramdisk_mem.ptr) + ramdisk_mem.len };
    const ramdisk_module = .{ .region = ramdisk_range, .name = "ramdisk.initrd" };
    var fs = try InitrdFS.init(ramdisk_module, std.testing.allocator);
    defer fs.deinit();

    expectEqual(fs.fs.getRootNode(fs.fs), &fs.root_node.Dir);
}

test "open valid file" {
    var ramdisk_mem = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_mem);

    const ramdisk_range = .{ .start = @ptrToInt(ramdisk_mem.ptr), .end = @ptrToInt(ramdisk_mem.ptr) + ramdisk_mem.len };
    const ramdisk_module = .{ .region = ramdisk_range, .name = "ramdisk.initrd" };
    var fs = try InitrdFS.init(ramdisk_module, std.testing.allocator);
    defer fs.deinit();

    vfs.setRoot(fs.root_node);

    var file1 = try vfs.openFile("/test1.txt", .NO_CREATION);
    defer file1.close();

    var file1_node = @ptrCast(*const vfs.Node, file1);

    expectEqual(fs.opened_files.items().len, 1);
    expectEqualSlices(u8, fs.opened_files.get(file1_node).?.name, "test1.txt");

    var file3_node = try vfs.open("/test3.txt", .NO_CREATION);
    defer file3_node.File.close();

    expectEqual(fs.opened_files.items().len, 2);
    expectEqualSlices(u8, fs.opened_files.get(file3_node).?.content, "This is a test: the prequel");

    var dir1 = try vfs.openDir("/", .NO_CREATION);
    expectEqual(&fs.root_node.Dir, dir1);
    var file2 = &(try dir1.open("test2.txt", .NO_CREATION)).File;
    defer file2.close();

    expectEqual(fs.opened_files.items().len, 3);
}

test "open fail with invalid flags" {
    var ramdisk_mem = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_mem);

    const ramdisk_range = .{ .start = @ptrToInt(ramdisk_mem.ptr), .end = @ptrToInt(ramdisk_mem.ptr) + ramdisk_mem.len };
    const ramdisk_module = .{ .region = ramdisk_range, .name = "ramdisk.initrd" };
    var fs = try InitrdFS.init(ramdisk_module, std.testing.allocator);
    defer fs.deinit();

    vfs.setRoot(fs.root_node);

    expectError(error.InvalidFlags, vfs.openFile("/text10.txt", .CREATE_DIR));
    expectError(error.InvalidFlags, vfs.openFile("/text10.txt", .CREATE_FILE));
    expectError(error.InvalidFlags, vfs.openDir("/text10.txt", .CREATE_DIR));
    expectError(error.InvalidFlags, vfs.openDir("/text10.txt", .CREATE_FILE));
    expectError(error.InvalidFlags, vfs.openFile("/test/", .CREATE_DIR));
    expectError(error.InvalidFlags, vfs.openFile("/test/", .CREATE_FILE));
    expectError(error.InvalidFlags, vfs.openDir("/test/", .CREATE_DIR));
    expectError(error.InvalidFlags, vfs.openDir("/test/", .CREATE_FILE));
}

test "open fail with NoSuchFileOrDir" {
    expectError(error.NoSuchFileOrDir, vfs.openFile("/text10.txt", .NO_CREATION));
    expectError(error.NoSuchFileOrDir, vfs.openDir("/temp/", .NO_CREATION));
}

test "open a file, out of memory" {
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, 4);

    var ramdisk_mem = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_mem);

    const ramdisk_range = .{ .start = @ptrToInt(ramdisk_mem.ptr), .end = @ptrToInt(ramdisk_mem.ptr) + ramdisk_mem.len };
    const ramdisk_module = .{ .region = ramdisk_range, .name = "ramdisk.initrd" };
    var fs = try InitrdFS.init(ramdisk_module, &fa.allocator);
    defer fs.deinit();

    vfs.setRoot(fs.root_node);

    expectError(error.OutOfMemory, vfs.openFile("/test1.txt", .NO_CREATION));
}

test "open two of the same file" {
    var ramdisk_mem = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_mem);

    const ramdisk_range = .{ .start = @ptrToInt(ramdisk_mem.ptr), .end = @ptrToInt(ramdisk_mem.ptr) + ramdisk_mem.len };
    const ramdisk_module = .{ .region = ramdisk_range, .name = "ramdisk.initrd" };
    var fs = try InitrdFS.init(ramdisk_module, std.testing.allocator);
    defer fs.deinit();

    vfs.setRoot(fs.root_node);

    const file1 = try vfs.openFile("/test1.txt", .NO_CREATION);
    defer file1.close();

    const file2 = try vfs.openFile("/test1.txt", .NO_CREATION);
    defer file2.close();

    expectEqual(fs.opened_files.items().len, 2);
    expect(file1 != file2);

    const b1 = try file1.read(128);
    defer std.testing.allocator.free(b1);
    const b2 = try file2.read(128);
    defer std.testing.allocator.free(b2);
    expectEqualSlices(u8, b1, b2);
}

test "close a file" {
    var ramdisk_mem = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_mem);

    const ramdisk_range = .{ .start = @ptrToInt(ramdisk_mem.ptr), .end = @ptrToInt(ramdisk_mem.ptr) + ramdisk_mem.len };
    const ramdisk_module = .{ .region = ramdisk_range, .name = "ramdisk.initrd" };
    var fs = try InitrdFS.init(ramdisk_module, std.testing.allocator);
    defer fs.deinit();

    vfs.setRoot(fs.root_node);

    var file1 = try vfs.openFile("/test1.txt", .NO_CREATION);

    var file1_node = @ptrCast(*const vfs.Node, file1);

    expectEqual(fs.opened_files.items().len, 1);

    var file3_node = try vfs.open("/test3.txt", .NO_CREATION);

    expectEqual(fs.opened_files.items().len, 2);
    file1.close();
    expectEqual(fs.opened_files.items().len, 1);

    var dir1 = try vfs.openDir("/", .NO_CREATION);
    expectEqual(&fs.root_node.Dir, dir1);
    var file2 = &(try dir1.open("test2.txt", .NO_CREATION)).File;
    defer file2.close();

    expectEqual(fs.opened_files.items().len, 2);
    file3_node.File.close();
    expectEqual(fs.opened_files.items().len, 1);
}

test "close a non-opened file" {
    var ramdisk_mem = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_mem);

    const ramdisk_range = .{ .start = @ptrToInt(ramdisk_mem.ptr), .end = @ptrToInt(ramdisk_mem.ptr) + ramdisk_mem.len };
    const ramdisk_module = .{ .region = ramdisk_range, .name = "ramdisk.initrd" };
    var fs = try InitrdFS.init(ramdisk_module, std.testing.allocator);
    defer fs.deinit();

    vfs.setRoot(fs.root_node);

    // Open a valid file
    var file1 = try vfs.openFile("/test1.txt", .NO_CREATION);
    defer file1.close();

    // Only one file open
    expectEqual(fs.opened_files.items().len, 1);

    // Craft a Node
    var fake_node = try std.testing.allocator.create(vfs.Node);
    defer std.testing.allocator.destroy(fake_node);
    fake_node.* = .{ .File = .{ .fs = fs.fs } };
    fake_node.File.close();

    // Still only one file open
    expectEqual(fs.opened_files.items().len, 1);
}

test "read a file" {
    var ramdisk_mem = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_mem);

    const ramdisk_range = .{ .start = @ptrToInt(ramdisk_mem.ptr), .end = @ptrToInt(ramdisk_mem.ptr) + ramdisk_mem.len };
    const ramdisk_module = .{ .region = ramdisk_range, .name = "ramdisk.initrd" };
    var fs = try InitrdFS.init(ramdisk_module, std.testing.allocator);
    defer fs.deinit();

    vfs.setRoot(fs.root_node);

    var file1 = try vfs.openFile("/test1.txt", .NO_CREATION);
    defer file1.close();

    const bytes1 = try file1.read(128);
    defer std.testing.allocator.free(bytes1);

    expectEqualSlices(u8, bytes1, "This is a test");

    const bytes2 = try file1.read(5);
    defer std.testing.allocator.free(bytes2);

    expectEqualSlices(u8, bytes2, "This ");
}

test "read a file, out of memory" {
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, 6);

    var ramdisk_mem = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_mem);

    const ramdisk_range = .{ .start = @ptrToInt(ramdisk_mem.ptr), .end = @ptrToInt(ramdisk_mem.ptr) + ramdisk_mem.len };
    const ramdisk_module = .{ .region = ramdisk_range, .name = "ramdisk.initrd" };
    var fs = try InitrdFS.init(ramdisk_module, &fa.allocator);
    defer fs.deinit();

    vfs.setRoot(fs.root_node);

    var file1 = try vfs.openFile("/test1.txt", .NO_CREATION);
    defer file1.close();

    expectError(error.OutOfMemory, file1.read(1));
}

test "read a file, invalid/not opened/crafted *const Node" {
    var ramdisk_mem = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_mem);

    const ramdisk_range = .{ .start = @ptrToInt(ramdisk_mem.ptr), .end = @ptrToInt(ramdisk_mem.ptr) + ramdisk_mem.len };
    const ramdisk_module = .{ .region = ramdisk_range, .name = "ramdisk.initrd" };
    var fs = try InitrdFS.init(ramdisk_module, std.testing.allocator);
    defer fs.deinit();

    vfs.setRoot(fs.root_node);

    // Open a valid file
    var file1 = try vfs.openFile("/test1.txt", .NO_CREATION);
    defer file1.close();

    // Only one file open
    expectEqual(fs.opened_files.items().len, 1);

    // Craft a Node
    var fake_node = try std.testing.allocator.create(vfs.Node);
    defer std.testing.allocator.destroy(fake_node);
    fake_node.* = .{ .File = .{ .fs = fs.fs } };

    expectError(error.NotOpened, fake_node.File.read(128));

    // Still only one file open
    expectEqual(fs.opened_files.items().len, 1);
}

test "write does nothing" {
    var ramdisk_mem = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_mem);

    const ramdisk_range = .{ .start = @ptrToInt(ramdisk_mem.ptr), .end = @ptrToInt(ramdisk_mem.ptr) + ramdisk_mem.len };
    const ramdisk_module = .{ .region = ramdisk_range, .name = "ramdisk.initrd" };
    var fs = try InitrdFS.init(ramdisk_module, std.testing.allocator);
    defer fs.deinit();

    vfs.setRoot(fs.root_node);

    // Open a valid file
    var file1 = try vfs.openFile("/test1.txt", .NO_CREATION);
    defer file1.close();

    try file1.write("Blah");

    // Unchanged file content
    expectEqualSlices(u8, fs.opened_files.get(@ptrCast(*const vfs.Node, file1)).?.content, "This is a test");
}

/// See std.testing.expectEqualSlices. As need our panic.
fn expectEqualSlicesClone(comptime T: type, expected: []const T, actual: []const T) void {
    if (expected.len != actual.len) {
        panic(@errorReturnTrace(), "slice lengths differ. expected {}, found {}", .{ expected.len, actual.len });
    }
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        if (!std.meta.eql(expected[i], actual[i])) {
            panic(@errorReturnTrace(), "index {} incorrect. expected {}, found {}", .{ i, expected[i], actual[i] });
        }
    }
}

///
/// Test that we can open, read and close a file
///
/// Arguments:
///     IN allocator: *Allocator - The allocator used for reading.
///
fn rt_openReadClose(allocator: *Allocator) void {
    const f1 = vfs.openFile("/ramdisk_test1.txt", .NO_CREATION) catch |e| {
        panic(@errorReturnTrace(), "FAILURE: Failed to open file: {}\n", .{e});
    };
    const bytes1 = f1.read(128) catch |e| {
        panic(@errorReturnTrace(), "FAILURE: Failed to read file: {}\n", .{e});
    };
    defer f1.close();
    expectEqualSlicesClone(u8, bytes1, "Testing ram disk");

    const f2 = vfs.openFile("/ramdisk_test2.txt", .NO_CREATION) catch |e| {
        panic(@errorReturnTrace(), "Failed to open file: {}\n", .{e});
    };
    const bytes2 = f2.read(128) catch |e| {
        panic(@errorReturnTrace(), "FAILURE: Failed to read file: {}\n", .{e});
    };
    defer f2.close();
    expectEqualSlicesClone(u8, bytes2, "Testing ram disk for the second time");

    // Try open a non-existent file
    _ = vfs.openFile("/nope.txt", .NO_CREATION) catch |e| switch (e) {
        error.NoSuchFileOrDir => {},
        else => panic(@errorReturnTrace(), "FAILURE: Expected error\n", .{}),
    };
    std.log.info(.initrd, "Opened, read and closed\n", .{});
}

///
/// The ramdisk runtime tests that will test the ramdisks functionality.
///
/// Arguments:
///     IN rd_fs: *InitrdFS - The initialised ramdisk to play with.
///
fn runtimeTests(rd_fs: *InitrdFS) void {
    // There will be test files provided for the runtime tests
    // Need to init the VFS. This will be overridden after the tests.
    vfs.setRoot(rd_fs.root_node);
    rt_openReadClose(rd_fs.allocator);
    if (rd_fs.opened_files.items().len != 0) {
        panic(@errorReturnTrace(), "FAILURE: Didn't close all files\n", .{});
    }
}
