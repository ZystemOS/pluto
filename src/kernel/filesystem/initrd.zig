const std = @import("std");
const builtin = @import("builtin");
const is_test = std.builtin.is_test;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualSlices = std.testing.expectEqualSlices;
const log = std.log.scoped(.initrd);
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;
const vfs = @import("vfs.zig");
const mem = @import("../mem.zig");
const panic = @import("../panic.zig").panic;

/// The Initrd file system struct.
/// Format of raw ramdisk:
/// (NumOfFiles:usize)[(name_length:usize)(name:u8[name_length])(content_length:usize)(content:u8[content_length])]*
pub const InitrdFS = struct {
    /// The ramdisk header that stores pointers for the name and file content.
    const InitrdHeader = struct {
        /// The name of the file
        name: []u8,

        /// The content of the file
        content: []u8,
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

    /// The allocator used for allocating memory for opening files.
    allocator: Allocator,

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
    fn close(fs: *const vfs.FileSystem, node: *const vfs.Node) void {
        var self = @fieldParentPtr(InitrdFS, "instance", fs.instance);
        // As close can't error, if provided with a invalid Node that isn't opened or try to close
        // the same file twice, will just do nothing.
        if (self.opened_files.remove(node)) {
            self.allocator.destroy(node);
        }
    }

    /// See vfs.FileSystem.read
    fn read(fs: *const vfs.FileSystem, file_node: *const vfs.FileNode, bytes: []u8) (Allocator.Error || vfs.Error)!usize {
        var self = @fieldParentPtr(InitrdFS, "instance", fs.instance);
        const node = @ptrCast(*const vfs.Node, file_node);
        const file_header = self.opened_files.get(node) orelse return vfs.Error.NotOpened;
        const length = std.math.min(bytes.len, file_header.content.len);
        std.mem.copy(u8, bytes, file_header.content[0..length]);
        return length;
    }

    /// See vfs.FileSystem.write
    fn write(fs: *const vfs.FileSystem, node: *const vfs.FileNode, bytes: []const u8) (Allocator.Error || vfs.Error)!usize {
        // Suppress unused var warning
        _ = fs;
        _ = node;
        _ = bytes;
        return 0;
    }

    /// See vfs.FileSystem.open
    fn open(fs: *const vfs.FileSystem, dir: *const vfs.DirNode, name: []const u8, flags: vfs.OpenFlags, args: vfs.OpenArgs) (Allocator.Error || vfs.Error)!*vfs.Node {
        var self = @fieldParentPtr(InitrdFS, "instance", fs.instance);
        // Suppress unused var warning
        _ = args;
        _ = dir;
        switch (flags) {
            .CREATE_DIR, .CREATE_FILE, .CREATE_SYMLINK => return vfs.Error.InvalidFlags,
            .NO_CREATION => {
                for (self.files) |*file| {
                    if (std.mem.eql(u8, file.name, name)) {
                        // Opening 2 files of the same name, will create 2 different Nodes
                        // Create a node
                        var node = try self.allocator.create(vfs.Node);
                        errdefer self.allocator.destroy(node);
                        node.* = .{ .File = .{ .fs = self.fs } };
                        try self.opened_files.put(node, file);
                        return node;
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
        std.debug.assert(self.opened_files.count() == 0);
        self.allocator.destroy(self.root_node);
        self.allocator.destroy(self.fs);
        self.opened_files.deinit();
        for (self.files) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.content);
        }
        self.allocator.free(self.files);
        self.allocator.destroy(self);
    }

    ///
    /// Initialise a ramdisk file system from a raw ramdisk in memory provided by the bootloader in a stream.
    /// Any memory allocated will be freed.
    ///
    /// Arguments:
    ///     IN stream: *std.io.FixedBufferStream([]u8) - The stream that contains the raw ramdisk data.
    ///     IN allocator: Allocator - The allocator used for initialising any memory needed.
    ///
    /// Return: *InitrdFS
    ///     A pointer to the ram disk file system.
    ///
    /// Error: Error || error{EndOfStream} || Allocator.Error || std.io.FixedBufferStream([]u8).ReadError
    ///     error.InvalidRamDisk - If the provided raw ramdisk is invalid. This can be due to a
    ///                            mis-match of the number of files to the length of the raw
    ///                            ramdisk or the wrong length provided to cause undefined parsed
    ///                            lengths for other parts of the ramdisk.
    ///     error.EndOfStream    - When reading from the stream, we reach the end of the stream
    ///                            before completing the read.
    ///     error.OutOfMemory    - If there isn't enough memory for initialisation. Any memory
    ///                            allocated will be freed.
    ///
    pub fn init(stream: *std.io.FixedBufferStream([]u8), allocator: Allocator) (Error || error{EndOfStream} || Allocator.Error)!*InitrdFS {
        log.info("Init\n", .{});
        defer log.info("Done\n", .{});

        // First @sizeOf(usize) bytes is the number of files
        const num_of_files = try stream.reader().readIntNative(usize);
        var headers = try allocator.alloc(InitrdHeader, num_of_files);
        errdefer allocator.free(headers);

        // Populate the headers
        var i: usize = 0;

        // If we error, then free any headers that we allocated.
        errdefer {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                allocator.free(headers[j].name);
                allocator.free(headers[j].content);
            }
        }

        while (i < num_of_files) : (i += 1) {
            // We don't need to store the lengths any more as we have the slice.len
            const name_len = try stream.reader().readIntNative(usize);
            if (name_len == 0) {
                return Error.InvalidRamDisk;
            }
            headers[i].name = try allocator.alloc(u8, name_len);
            errdefer allocator.free(headers[i].name);
            if ((try stream.reader().readAll(headers[i].name)) != name_len) {
                return Error.InvalidRamDisk;
            }
            const content_len = try stream.reader().readIntNative(usize);
            if (content_len == 0) {
                return Error.InvalidRamDisk;
            }
            headers[i].content = try allocator.alloc(u8, content_len);
            errdefer allocator.free(headers[i].content);
            if ((try stream.reader().readAll(headers[i].content)) != content_len) {
                return Error.InvalidRamDisk;
            }
        }

        // If we aren't at the end, error.
        if ((try stream.getPos()) != (try stream.getEndPos())) {
            return Error.InvalidRamDisk;
        }

        var rd_fs = try allocator.create(InitrdFS);
        errdefer allocator.destroy(rd_fs);
        var fs = try allocator.create(vfs.FileSystem);
        errdefer allocator.destroy(fs);
        var root_node = try allocator.create(vfs.Node);

        root_node.* = .{ .Dir = .{ .fs = fs, .mount = null } };
        fs.* = .{
            .open = open,
            .close = close,
            .read = read,
            .write = write,
            .instance = &rd_fs.instance,
            .getRootNode = getRootNode,
        };

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
///     IN allocator: Allocator - The allocator to alloc the raw ramdisk.
///
/// Return: []u8
///     The bytes of the raw ramdisk in memory.
///
/// Error: Allocator.Error
///     error.OutOfMemory - If there isn't enough memory for the in memory ramdisk.
///     FixedBufferStream.WriterError - Writing to the fixed buffer stream failed
///     error.TestExpectedEqual - An equality test failed
///
fn createInitrd(allocator: Allocator) ![]u8 {
    // Create 3 valid ramdisk files in memory
    const file_names = [_][]const u8{ "test1.txt", "test2.txt", "test3.txt" };
    const file_contents = [_][]const u8{ "This is a test", "This is a test: part 2", "This is a test: the prequel" };

    // Ensure these two arrays are the same length
    std.debug.assert(file_names.len == file_contents.len);

    var sum: usize = 0;
    const files_length = for ([_]usize{ 0, 1, 2 }) |i| {
        sum += @sizeOf(usize) + file_names[i].len + @sizeOf(usize) + file_contents[i].len;
    } else sum;

    const total_ramdisk_len = @sizeOf(usize) + files_length;
    var ramdisk_bytes = try allocator.alloc(u8, total_ramdisk_len);
    var ramdisk_stream = std.io.fixedBufferStream(ramdisk_bytes);

    // Copy the data into the allocated memory
    try ramdisk_stream.writer().writeIntNative(usize, file_names.len);
    inline for ([_]usize{ 0, 1, 2 }) |i| {
        // Name len
        try ramdisk_stream.writer().writeIntNative(usize, file_names[i].len);
        // Name
        try ramdisk_stream.writer().writeAll(file_names[i]);
        // File len
        try ramdisk_stream.writer().writeIntNative(usize, file_contents[i].len);
        // File content
        try ramdisk_stream.writer().writeAll(file_contents[i]);
    }
    // Make sure we are full
    try expectEqual(try ramdisk_stream.getPos(), total_ramdisk_len);
    try expectEqual(try ramdisk_stream.getPos(), try ramdisk_stream.getEndPos());
    return ramdisk_bytes;
}

test "init with files valid" {
    var ramdisk_bytes = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_bytes);

    var initrd_stream = std.io.fixedBufferStream(ramdisk_bytes);
    var fs = try InitrdFS.init(&initrd_stream, std.testing.allocator);
    defer fs.deinit();

    try expectEqual(fs.files.len, 3);
    try expectEqualSlices(u8, fs.files[0].name, "test1.txt");
    try expectEqualSlices(u8, fs.files[1].content, "This is a test: part 2");
    try expectEqual(fs.opened_files.count(), 0);
}

test "init with files invalid - invalid number of files" {
    var ramdisk_bytes = try createInitrd(std.testing.allocator);
    // Override the number of files
    std.mem.writeIntSlice(usize, ramdisk_bytes[0..], 10, builtin.cpu.arch.endian());
    defer std.testing.allocator.free(ramdisk_bytes);

    var initrd_stream = std.io.fixedBufferStream(ramdisk_bytes);
    try expectError(error.InvalidRamDisk, InitrdFS.init(&initrd_stream, std.testing.allocator));

    // Override the number of files
    std.mem.writeIntSlice(usize, ramdisk_bytes[0..], 0, builtin.cpu.arch.endian());
    try expectError(error.InvalidRamDisk, InitrdFS.init(&initrd_stream, std.testing.allocator));
}

test "init with files invalid - mix - bad" {
    // TODO: Craft a ramdisk that would parse but is invalid
    //       This is possible, but will think about this another time
    //       Challenge, make this a effective security vulnerability
    //       P.S. I don't know if adding magics will stop this
    {
        var ramdisk_bytes = try createInitrd(std.testing.allocator);
        // Override the first file name length, make is shorter
        std.mem.writeIntSlice(usize, ramdisk_bytes[4..], 2, builtin.cpu.arch.endian());
        defer std.testing.allocator.free(ramdisk_bytes);

        var initrd_stream = std.io.fixedBufferStream(ramdisk_bytes);
        try expectError(error.InvalidRamDisk, InitrdFS.init(&initrd_stream, std.testing.allocator));
    }

    {
        var ramdisk_bytes = try createInitrd(std.testing.allocator);
        // Override the first file name length, make is 4 shorter
        std.mem.writeIntSlice(usize, ramdisk_bytes[4..], 5, builtin.cpu.arch.endian());
        // Override the second file name length, make is 4 longer
        std.mem.writeIntSlice(usize, ramdisk_bytes[35..], 13, builtin.cpu.arch.endian());
        defer std.testing.allocator.free(ramdisk_bytes);

        var initrd_stream = std.io.fixedBufferStream(ramdisk_bytes);
        try expectError(error.InvalidRamDisk, InitrdFS.init(&initrd_stream, std.testing.allocator));
    }
}

/// The number of allocations that the init function make.
const init_allocations: usize = 10;

test "init with files cleans memory if OutOfMemory" {
    var i: usize = 0;
    while (i < init_allocations) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, i);

        var ramdisk_bytes = try createInitrd(std.testing.allocator);
        defer std.testing.allocator.free(ramdisk_bytes);

        var initrd_stream = std.io.fixedBufferStream(ramdisk_bytes);
        try expectError(error.OutOfMemory, InitrdFS.init(&initrd_stream, fa.allocator()));
    }
}

test "getRootNode" {
    var ramdisk_bytes = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_bytes);

    var initrd_stream = std.io.fixedBufferStream(ramdisk_bytes);
    var fs = try InitrdFS.init(&initrd_stream, std.testing.allocator);
    defer fs.deinit();

    try expectEqual(fs.fs.getRootNode(fs.fs), &fs.root_node.Dir);
}

test "open valid file" {
    var ramdisk_bytes = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_bytes);

    var initrd_stream = std.io.fixedBufferStream(ramdisk_bytes);
    var fs = try InitrdFS.init(&initrd_stream, std.testing.allocator);
    defer fs.deinit();

    try vfs.setRoot(fs.root_node);

    var file1 = try vfs.openFile("/test1.txt", .NO_CREATION);
    defer file1.close();

    try expectEqual(fs.opened_files.count(), 1);
    try expectEqualSlices(u8, fs.opened_files.get(@ptrCast(*const vfs.Node, file1)).?.name, "test1.txt");

    var file3_node = try vfs.open("/test3.txt", true, .NO_CREATION, .{});
    defer file3_node.File.close();

    try expectEqual(fs.opened_files.count(), 2);
    try expectEqualSlices(u8, fs.opened_files.get(file3_node).?.content, "This is a test: the prequel");

    var dir1 = try vfs.openDir("/", .NO_CREATION);
    try expectEqual(&fs.root_node.Dir, dir1);
    var file2 = &(try dir1.open("test2.txt", .NO_CREATION, .{})).File;
    defer file2.close();

    try expectEqual(fs.opened_files.count(), 3);
}

test "open fail with invalid flags" {
    var ramdisk_bytes = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_bytes);

    var initrd_stream = std.io.fixedBufferStream(ramdisk_bytes);
    var fs = try InitrdFS.init(&initrd_stream, std.testing.allocator);
    defer fs.deinit();

    try vfs.setRoot(fs.root_node);

    try expectError(error.InvalidFlags, vfs.openFile("/text10.txt", .CREATE_DIR));
    try expectError(error.InvalidFlags, vfs.openFile("/text10.txt", .CREATE_FILE));
    try expectError(error.InvalidFlags, vfs.openFile("/text10.txt", .CREATE_SYMLINK));
    try expectError(error.InvalidFlags, vfs.openDir("/text10.txt", .CREATE_DIR));
    try expectError(error.InvalidFlags, vfs.openDir("/text10.txt", .CREATE_FILE));
    try expectError(error.InvalidFlags, vfs.openDir("/text10.txt", .CREATE_SYMLINK));
    try expectError(error.InvalidFlags, vfs.openFile("/test/", .CREATE_DIR));
    try expectError(error.InvalidFlags, vfs.openFile("/test/", .CREATE_FILE));
    try expectError(error.InvalidFlags, vfs.openFile("/test/", .CREATE_SYMLINK));
    try expectError(error.InvalidFlags, vfs.openDir("/test/", .CREATE_DIR));
    try expectError(error.InvalidFlags, vfs.openDir("/test/", .CREATE_FILE));
    try expectError(error.InvalidFlags, vfs.openDir("/test/", .CREATE_SYMLINK));
    try expectError(error.InvalidFlags, vfs.openSymlink("/test/", "", .CREATE_FILE));
    try expectError(error.InvalidFlags, vfs.openSymlink("/test/", "", .CREATE_DIR));
    try expectError(error.InvalidFlags, vfs.openSymlink("/test/", "", .CREATE_SYMLINK));
}

test "open fail with NoSuchFileOrDir" {
    var ramdisk_bytes = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_bytes);

    var initrd_stream = std.io.fixedBufferStream(ramdisk_bytes);
    var fs = try InitrdFS.init(&initrd_stream, std.testing.allocator);
    defer fs.deinit();

    try vfs.setRoot(fs.root_node);
    try expectError(error.NoSuchFileOrDir, vfs.openFile("/text10.txt", .NO_CREATION));
    try expectError(error.NoSuchFileOrDir, vfs.openDir("/temp/", .NO_CREATION));
}

test "open a file, out of memory" {
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, init_allocations);

    var ramdisk_bytes = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_bytes);

    var initrd_stream = std.io.fixedBufferStream(ramdisk_bytes);
    var fs = try InitrdFS.init(&initrd_stream, fa.allocator());
    defer fs.deinit();

    try vfs.setRoot(fs.root_node);

    try expectError(error.OutOfMemory, vfs.openFile("/test1.txt", .NO_CREATION));
}

test "open two of the same file" {
    var ramdisk_bytes = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_bytes);

    var initrd_stream = std.io.fixedBufferStream(ramdisk_bytes);
    var fs = try InitrdFS.init(&initrd_stream, std.testing.allocator);
    defer fs.deinit();

    try vfs.setRoot(fs.root_node);

    const file1 = try vfs.openFile("/test1.txt", .NO_CREATION);
    defer file1.close();

    const file2 = try vfs.openFile("/test1.txt", .NO_CREATION);
    defer file2.close();

    try expectEqual(fs.opened_files.count(), 2);
    try expect(file1 != file2);

    var b1: [128]u8 = undefined;
    const length1 = try file1.read(b1[0..b1.len]);
    var b2: [128]u8 = undefined;
    const length2 = try file2.read(b2[0..b2.len]);
    try expectEqualSlices(u8, b1[0..length1], b2[0..length2]);
}

test "close a file" {
    var ramdisk_bytes = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_bytes);

    var initrd_stream = std.io.fixedBufferStream(ramdisk_bytes);
    var fs = try InitrdFS.init(&initrd_stream, std.testing.allocator);
    defer fs.deinit();

    try vfs.setRoot(fs.root_node);

    var file1 = try vfs.openFile("/test1.txt", .NO_CREATION);

    try expectEqual(fs.opened_files.count(), 1);

    var file3_node = try vfs.open("/test3.txt", true, .NO_CREATION, .{});

    try expectEqual(fs.opened_files.count(), 2);
    file1.close();
    try expectEqual(fs.opened_files.count(), 1);

    var dir1 = try vfs.openDir("/", .NO_CREATION);
    try expectEqual(&fs.root_node.Dir, dir1);
    var file2 = &(try dir1.open("test2.txt", .NO_CREATION, .{})).File;
    defer file2.close();

    try expectEqual(fs.opened_files.count(), 2);
    file3_node.File.close();
    try expectEqual(fs.opened_files.count(), 1);
}

test "close a non-opened file" {
    var ramdisk_bytes = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_bytes);

    var initrd_stream = std.io.fixedBufferStream(ramdisk_bytes);
    var fs = try InitrdFS.init(&initrd_stream, std.testing.allocator);
    defer fs.deinit();

    try vfs.setRoot(fs.root_node);

    // Open a valid file
    var file1 = try vfs.openFile("/test1.txt", .NO_CREATION);
    defer file1.close();

    // Only one file open
    try expectEqual(fs.opened_files.count(), 1);

    // Craft a Node
    var fake_node = try std.testing.allocator.create(vfs.Node);
    defer std.testing.allocator.destroy(fake_node);
    fake_node.* = .{ .File = .{ .fs = fs.fs } };
    fake_node.File.close();

    // Still only one file open
    try expectEqual(fs.opened_files.count(), 1);
}

test "read a file" {
    var ramdisk_bytes = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_bytes);

    var initrd_stream = std.io.fixedBufferStream(ramdisk_bytes);
    var fs = try InitrdFS.init(&initrd_stream, std.testing.allocator);
    defer fs.deinit();

    try vfs.setRoot(fs.root_node);

    var file1 = try vfs.openFile("/test1.txt", .NO_CREATION);
    defer file1.close();

    var bytes1: [128]u8 = undefined;
    const length1 = try file1.read(bytes1[0..bytes1.len]);

    try expectEqualSlices(u8, bytes1[0..length1], "This is a test");

    var bytes2: [5]u8 = undefined;
    const length2 = try file1.read(bytes2[0..bytes2.len]);

    try expectEqualSlices(u8, bytes2[0..length2], "This ");
}

test "read a file, invalid/not opened/crafted *const Node" {
    var ramdisk_bytes = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_bytes);

    var initrd_stream = std.io.fixedBufferStream(ramdisk_bytes);
    var fs = try InitrdFS.init(&initrd_stream, std.testing.allocator);
    defer fs.deinit();

    try vfs.setRoot(fs.root_node);

    // Open a valid file
    var file1 = try vfs.openFile("/test1.txt", .NO_CREATION);
    defer file1.close();

    // Only one file open
    try expectEqual(fs.opened_files.count(), 1);

    // Craft a Node
    var fake_node = try std.testing.allocator.create(vfs.Node);
    defer std.testing.allocator.destroy(fake_node);
    fake_node.* = .{ .File = .{ .fs = fs.fs } };

    var unused: [1]u8 = undefined;
    try expectError(error.NotOpened, fake_node.File.read(unused[0..unused.len]));

    // Still only one file open
    try expectEqual(fs.opened_files.count(), 1);
}

test "write does nothing" {
    var ramdisk_bytes = try createInitrd(std.testing.allocator);
    defer std.testing.allocator.free(ramdisk_bytes);

    var initrd_stream = std.io.fixedBufferStream(ramdisk_bytes);
    var fs = try InitrdFS.init(&initrd_stream, std.testing.allocator);
    defer fs.deinit();

    try vfs.setRoot(fs.root_node);

    // Open a valid file
    var file1 = try vfs.openFile("/test1.txt", .NO_CREATION);
    defer file1.close();

    try expectEqual(@as(usize, 0), try file1.write("Blah"));

    // Unchanged file content
    try expectEqualSlices(u8, fs.opened_files.get(@ptrCast(*const vfs.Node, file1)).?.content, "This is a test");
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
fn rt_openReadClose() void {
    const f1 = vfs.openFile("/ramdisk_test1.txt", .NO_CREATION) catch |e| {
        panic(@errorReturnTrace(), "FAILURE: Failed to open file: {}\n", .{e});
    };
    var bytes1: [128]u8 = undefined;
    const length1 = f1.read(bytes1[0..bytes1.len]) catch |e| {
        panic(@errorReturnTrace(), "FAILURE: Failed to read file: {}\n", .{e});
    };
    defer f1.close();
    expectEqualSlicesClone(u8, bytes1[0..length1], "Testing ram disk");

    const f2 = vfs.openFile("/ramdisk_test2.txt", .NO_CREATION) catch |e| {
        panic(@errorReturnTrace(), "Failed to open file: {}\n", .{e});
    };
    var bytes2: [128]u8 = undefined;
    const length2 = f2.read(bytes2[0..bytes2.len]) catch |e| {
        panic(@errorReturnTrace(), "FAILURE: Failed to read file: {}\n", .{e});
    };
    defer f2.close();
    expectEqualSlicesClone(u8, bytes2[0..length2], "Testing ram disk for the second time");

    // Try open a non-existent file
    _ = vfs.openFile("/nope.txt", .NO_CREATION) catch |e| switch (e) {
        error.NoSuchFileOrDir => {},
        else => panic(@errorReturnTrace(), "FAILURE: Expected error\n", .{}),
    };
    log.info("Opened, read and closed\n", .{});
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
    vfs.setRoot(rd_fs.root_node) catch |e| {
        panic(@errorReturnTrace(), "Ramdisk root node isn't a directory node: {}\n", .{e});
    };
    rt_openReadClose();
    if (rd_fs.opened_files.count() != 0) {
        panic(@errorReturnTrace(), "FAILURE: Didn't close all files\n", .{});
    }
}
