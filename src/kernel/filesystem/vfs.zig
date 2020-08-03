const std = @import("std");
const testing = std.testing;
const TailQueue = std.TailQueue;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Device = @import("device.zig").Device;

/// Flags specifying what to do when opening a file or directory
pub const OpenFlags = enum {
    /// Create a directory if it doesn't exist
    CREATE_DIR,
    /// Create a file if it doesn't exist
    CREATE_FILE,
    /// Do not create a file or directory
    NO_CREATION,
};

/// A filesystem node that could either be a directory or a file
pub const Node = union(enum) {
    /// The file node if this represents a file
    File: FileNode,
    /// The dir node if this represents a directory
    Dir: DirNode,
    const Self = @This();

    ///
    /// Check if this node is a directory
    ///
    /// Arguments:
    ///     IN self: Self - The node being checked
    ///
    /// Return: bool
    ///     True if this is a directory else false
    ///
    pub fn isDir(self: Self) bool {
        return switch (self) {
            .Dir => true,
            .File => false,
        };
    }

    ///
    /// Check if this node is a file
    ///
    /// Arguments:
    ///     IN self: Self - The node being checked
    ///
    /// Return: bool
    ///     True if this is a file else false
    ///
    pub fn isFile(self: Self) bool {
        return switch (self) {
            .File => true,
            .Dir => false,
        };
    }
};

/// The functions of a filesystem
pub const FileSystem = struct {
    const Self = @This();

    ///
    /// Close an open file, performing any last operations required to save data etc.
    ///
    /// Arguments:
    ///     IN self: *const FileSystem - The filesystem in question being operated on.
    ///     IN node: *const FileNode - The file being closed
    ///
    const Close = fn (self: *const Self, node: *const FileNode) void;

    ///
    /// Read from an open file
    ///
    /// Arguments:
    ///     IN self: *const FileSystem - The filesystem in question being operated on
    ///     IN node: *const FileNode - The file being read from
    ///     IN len: usize - The number of bytes to read from the file
    ///
    /// Return: []u8
    ///     The data read as a slice of bytes. The length will be <= len, including 0 if there was no data to read
    ///
    /// Error: Allocator.Error || Error
    ///     Allocator.Error.OutOfMemory - There wasn't enough memory to fulfill the request
    ///     Error.NotOpened - If the node provided is not one that the file system recognised as being opened.
    ///
    const Read = fn (self: *const Self, node: *const FileNode, len: usize) (Allocator.Error || Error)![]u8;

    ///
    /// Write to an open file
    ///
    /// Arguments:
    ///     IN self: *const FileSystem - The filesystem in question being operated on
    ///     IN node: *const FileNode - The file being read from
    ///     IN bytes: []u8 - The bytes to write to the file
    ///
    /// Error: Allocator.Error
    ///     Allocator.Error.OutOfMemory - There wasn't enough memory to fulfill the request
    ///
    const Write = fn (self: *const Self, node: *const FileNode, bytes: []const u8) (Allocator.Error || Error)!void;

    ///
    /// Open a file/dir within the filesystem. The result can then be used for write, read or close operations
    ///
    /// Arguments:
    ///     IN self: *const FileSystem - The filesystem in question being operated on
    ///     IN node: *const DirNode - The directory under which to open the file/dir from
    ///     IN name: []const u8 - The name of the file to open
    ///     IN flags: OpenFlags - The flags to consult when opening the file
    ///
    /// Return: *const Node
    ///     The node representing the file/dir opened
    ///
    /// Error: Allocator.Error || Error
    ///     Allocator.Error.OutOfMemory - There wasn't enough memory to fulfill the request
    ///     Error.NoSuchFileOrDir - The file/dir by that name doesn't exist and the flags didn't specify to create it
    ///
    const Open = fn (self: *const Self, node: *const DirNode, name: []const u8, flags: OpenFlags) (Allocator.Error || Device.Error || Error)!*Node;

    ///
    /// Get the node representing the root of the filesystem. Used when mounting to bind the mount point to the root of the mounted fs
    ///
    /// Arguments:
    ///     IN self: *const Self - The filesystem to get the root node for
    ///
    /// Return: *const DirNode
    ///     The root directory node
    ///
    const GetRootNode = fn (self: *const Self) *const DirNode;

    /// The close function
    close: Close,

    /// The read function
    read: Read,

    /// The write function
    write: Write,

    /// The open function
    open: Open,

    /// The function for retrieving the root node
    getRootNode: GetRootNode,

    /// Points to a usize field within the underlying filesystem so that the close, read, write and open functions can access its low-level implementation using @fieldParentPtr. For example, this could point to a usize field within a FAT32 filesystem data structure, which stores all the data and state that is needed in order to interact with a physical disk
    /// The value of instance is reserved for future use and so should be left as 0
    instance: *usize,
};

/// A node representing a file within a filesystem
pub const FileNode = struct {
    /// The filesystem that handles operations on this file
    fs: *const FileSystem,

    /// See the documentation for FileSystem.Read
    pub fn read(self: *const FileNode, len: usize) (Allocator.Error || Error)![]u8 {
        return self.fs.read(self.fs, self, len);
    }

    /// See the documentation for FileSystem.Close
    pub fn close(self: *const FileNode) void {
        return self.fs.close(self.fs, self);
    }

    /// See the documentation for FileSystem.Write
    pub fn write(self: *const FileNode, bytes: []const u8) (Allocator.Error || Error)!void {
        return self.fs.write(self.fs, self, bytes);
    }
};

/// A node representing a directory within a filesystem
pub const DirNode = struct {
    /// The filesystem that handles operations on this directory
    fs: *const FileSystem,

    /// The directory that this directory is mounted to, else null
    mount: ?*const DirNode,

    /// See the documentation for FileSystem.Open
    pub fn open(self: *const DirNode, name: []const u8, flags: OpenFlags) (Allocator.Error || Device.Error || Error)!*Node {
        var fs = self.fs;
        var node = self;
        if (self.mount) |mnt| {
            fs = mnt.fs;
            node = mnt;
        }
        return fs.open(fs, node, name, flags);
    }
};

/// Errors that can be thrown by filesystem functions
pub const Error = error{
    /// The file or directory requested doesn't exist in the filesystem
    NoSuchFileOrDir,

    /// The parent of a requested file or directory isn't a directory itself
    NotADirectory,

    /// The requested file is actually a directory
    IsADirectory,

    /// The path provided is not absolute
    NotAbsolutePath,

    /// The flags provided are invalid for the requested operation
    InvalidFlags,

    /// The node is not recognised as being opened by the filesystem
    NotOpened,
};

/// Errors that can be thrown when attempting to mount
pub const MountError = error{
    /// The directory being mounted to a filesystem is already mounted to something
    DirAlreadyMounted,
};

/// The separator used between segments of a file path
pub const SEPARATOR: u8 = '/';

/// The root of the system's top-level filesystem
var root: *Node = undefined;

///
/// Traverse the specified path from the root and open the file/dir corresponding to that path. If the file/dir doesn't exist it can be created by specifying the open flags
///
/// Arguments:
///     IN path: []const u8 - The path to traverse. Must be absolute (see isAbsolute)
///     IN flags: OpenFlags - The flags that specify if the file/dir should be created if it doesn't exist
///
/// Return: *const Node
///     The node that exists at the path starting at the system root
///
/// Error: Allocator.Error || Error
///     Allocator.Error.OutOfMemory - There wasn't enough memory to fulfill the request
///     Error.NotADirectory - A segment within the path which is not at the end does not correspond to a directory
///     Error.NoSuchFileOrDir - The file/dir at the end of the path doesn't exist and the flags didn't specify to create it
///
fn traversePath(path: []const u8, flags: OpenFlags) (Allocator.Error || Device.Error || Error)!*Node {
    if (!isAbsolute(path)) {
        return Error.NotAbsolutePath;
    }

    const TraversalParent = struct {
        parent: *Node,
        child: []const u8,

        const Self = @This();
        fn func(split: *std.mem.SplitIterator, node: *Node, rec_flags: OpenFlags) (Allocator.Error || Device.Error || Error)!Self {
            // Get segment string. This will not be unreachable as we've made sure the spliterator has more segments left
            const seg = split.next() orelse unreachable;
            if (split.rest().len == 0) {
                return Self{
                    .parent = node,
                    .child = seg,
                };
            }
            return switch (node.*) {
                .File => Error.NotADirectory,
                .Dir => |*dir| try func(split, try dir.open(seg, rec_flags), rec_flags),
            };
        }
    };

    // Split path but skip the first separator character
    var split = std.mem.split(path[1..], &[_]u8{SEPARATOR});
    // Traverse directories while we're not at the last segment
    const result = try TraversalParent.func(&split, root, .NO_CREATION);

    // There won't always be a second segment in the path, e.g. in "/"
    if (std.mem.eql(u8, result.child, "")) {
        return result.parent;
    }

    // Open the final segment of the path from whatever the parent is
    return switch (result.parent.*) {
        .File => Error.NotADirectory,
        .Dir => |*dir| try dir.open(result.child, flags),
    };
}

///
/// Mount the root of a filesystem to a directory. Opening files within that directory will then redirect to the target filesystem
///
/// Arguments:
///     IN dir: *DirNode - The directory to mount to. dir.mount is modified.
///     IN fs: *const FileSystem - The filesystem to mount
///
/// Error: MountError
///     MountError.DirAlreadyMounted - The directory is already mounted to a filesystem
///
pub fn mount(dir: *DirNode, fs: *const FileSystem) MountError!void {
    if (dir.mount) |_| {
        return MountError.DirAlreadyMounted;
    }
    dir.mount = fs.getRootNode(fs);
}

///
/// Open a node at a path.
///
/// Arguments:
///     IN path: []const u8 - The path to open. Must be absolute (see isAbsolute)
///     IN flags: OpenFlags - The flags specifying if this node should be created if it doesn't exist
///
/// Return: *const Node
///     The node that exists at the path starting at the system root
///
/// Error: Allocator.Error || Error
///     Allocator.Error.OutOfMemory - There wasn't enough memory to fulfill the request
///     Error.NotADirectory - A segment within the path which is not at the end does not correspond to a directory
///     Error.NoSuchFileOrDir - The file/dir at the end of the path doesn't exist and the flags didn't specify to create it
///
pub fn open(path: []const u8, flags: OpenFlags) (Allocator.Error || Device.Error || Error)!*Node {
    return try traversePath(path, flags);
}

///
/// Open a file at a path.
///
/// Arguments:
///     IN path: []const u8 - The path to open. Must be absolute (see isAbsolute)
///     IN flags: OpenFlags - The flags specifying if this node should be created if it doesn't exist. Cannot be CREATE_DIR
///
/// Return: *const FileNode
///     The node that exists at the path starting at the system root
///
/// Error: Allocator.Error || Error
///     Allocator.Error.OutOfMemory - There wasn't enough memory to fulfill the request
///     Error.InvalidFlags - The flags were a value invalid when opening files
///     Error.NotADirectory - A segment within the path which is not at the end does not correspond to a directory
///     Error.NoSuchFileOrDir - The file/dir at the end of the path doesn't exist and the flags didn't specify to create it
///     Error.IsADirectory - The path corresponds to a directory rather than a file
///
pub fn openFile(path: []const u8, flags: OpenFlags) (Allocator.Error || Device.Error || Error)!*const FileNode {
    switch (flags) {
        .CREATE_DIR => return Error.InvalidFlags,
        .NO_CREATION, .CREATE_FILE => {},
    }
    var node = try open(path, flags);
    return switch (node.*) {
        .File => &node.File,
        .Dir => Error.IsADirectory,
    };
}

///
/// Open a directory at a path.
///
/// Arguments:
///     IN path: []const u8 - The path to open. Must be absolute (see isAbsolute)
///     IN flags: OpenFlags - The flags specifying if this node should be created if it doesn't exist. Cannot be CREATE_FILE
///
/// Return: *const DirNode
///     The node that exists at the path starting at the system root
///
/// Error: Allocator.Error || Error
///     Allocator.Error.OutOfMemory - There wasn't enough memory to fulfill the request
///     Error.InvalidFlags - The flags were a value invalid when opening files
///     Error.NotADirectory - A segment within the path which is not at the end does not correspond to a directory
///     Error.NoSuchFileOrDir - The file/dir at the end of the path doesn't exist and the flags didn't specify to create it
///     Error.NotADirectory - The path corresponds to a file rather than a directory
///
pub fn openDir(path: []const u8, flags: OpenFlags) (Allocator.Error || Device.Error || Error)!*DirNode {
    switch (flags) {
        .CREATE_FILE => return Error.InvalidFlags,
        .NO_CREATION, .CREATE_DIR => {},
    }
    var node = try open(path, flags);
    return switch (node.*) {
        .File => Error.NotADirectory,
        .Dir => &node.Dir,
    };
}

// TODO: Replace this with the std lib implementation once the OS abstraction layer is up and running
///
/// Check if a path is absolute, i.e. its length is greater than 0 and starts with the path separator character
///
/// Arguments:
///     IN path: []const u8 - The path to check
///
/// Return: bool
///     True if the path is absolute else false
///
pub fn isAbsolute(path: []const u8) bool {
    return path.len > 0 and path[0] == SEPARATOR;
}

///
/// Initialise the virtual file system with a root Node. This will be a Directory node.
///
/// Arguments:
///     IN node: *Node - The node to initialise the root node.
///
pub fn setRoot(node: *Node) void {
    root = node;
}

const TestFS = struct {
    const TreeNode = struct {
        val: *Node,
        name: []u8,
        data: ?[]u8,
        children: *ArrayList(*@This()),

        fn deinit(self: *@This(), allocator: *Allocator) void {
            allocator.destroy(self.val);
            allocator.free(self.name);
            if (self.data) |d| {
                allocator.free(d);
            }
            for (self.children.items) |child| {
                child.deinit(allocator);
                allocator.destroy(child);
            }
            self.children.deinit();
            allocator.destroy(self.children);
        }
    };

    tree: TreeNode,
    fs: *FileSystem,
    allocator: *Allocator,
    instance: usize,

    const Self = @This();

    fn deinit(self: *@This()) void {
        self.tree.deinit(self.allocator);
        self.allocator.destroy(self.fs);
    }

    fn getTreeNode(test_fs: *Self, node: anytype) Allocator.Error!?*TreeNode {
        switch (@TypeOf(node)) {
            *const Node, *const FileNode, *const DirNode => {},
            else => @compileError("Node is of type " ++ @typeName(@TypeOf(node)) ++ ". Only *const Node, *const FileNode and *const DirNode are supported"),
        }
        // Form a list containing all directory nodes to check via a breadth-first search
        // This is inefficient but good for testing as it's clear and easy to modify
        var to_check = TailQueue(*TreeNode).init();
        var root_node = try to_check.createNode(&test_fs.tree, test_fs.allocator);
        to_check.append(root_node);

        while (to_check.popFirst()) |queue_node| {
            var tree_node = queue_node.data;
            to_check.destroyNode(queue_node, test_fs.allocator);
            if ((@TypeOf(node) == *const FileNode and tree_node.val.isFile() and &tree_node.val.File == node) or (@TypeOf(node) == *const DirNode and tree_node.val.isDir() and &tree_node.val.Dir == node) or (@TypeOf(node) == *const Node and &tree_node.val == node)) {
                // Clean up any unused queue nodes
                while (to_check.popFirst()) |t_node| {
                    to_check.destroyNode(t_node, test_fs.allocator);
                }
                return tree_node;
            }
            for (tree_node.children.items) |child| {
                // It's not the parent so add its children to the list for checking
                to_check.append(try to_check.createNode(child, test_fs.allocator));
            }
        }
        return null;
    }

    fn getRootNode(fs: *const FileSystem) *const DirNode {
        var test_fs = @fieldParentPtr(TestFS, "instance", fs.instance);
        return &test_fs.tree.val.Dir;
    }

    fn close(fs: *const FileSystem, node: *const FileNode) void {}

    fn read(fs: *const FileSystem, node: *const FileNode, len: usize) (Allocator.Error || Error)![]u8 {
        var test_fs = @fieldParentPtr(TestFS, "instance", fs.instance);
        // Get the tree that corresponds to the node. Cannot error as the file is already open so it does exist
        var tree = (getTreeNode(test_fs, node) catch unreachable) orelse unreachable;
        const count = if (tree.data) |d| std.math.min(len, d.len) else 0;
        const data = if (tree.data) |d| d[0..count] else "";
        var bytes = try test_fs.allocator.alloc(u8, count);
        std.mem.copy(u8, bytes, data);
        return bytes;
    }

    fn write(fs: *const FileSystem, node: *const FileNode, bytes: []const u8) (Allocator.Error || Error)!void {
        var test_fs = @fieldParentPtr(TestFS, "instance", fs.instance);
        var tree = (try getTreeNode(test_fs, node)) orelse unreachable;
        if (tree.data) |_| {
            test_fs.allocator.free(tree.data.?);
        }
        tree.data = try test_fs.allocator.alloc(u8, bytes.len);
        std.mem.copy(u8, tree.data.?, bytes);
    }

    fn open(fs: *const FileSystem, dir: *const DirNode, name: []const u8, flags: OpenFlags) (Allocator.Error || Error)!*Node {
        var test_fs = @fieldParentPtr(TestFS, "instance", fs.instance);
        const parent = (try getTreeNode(test_fs, dir)) orelse unreachable;
        // Check if the children match the file wanted
        for (parent.children.items) |child| {
            if (std.mem.eql(u8, child.name, name)) {
                return child.val;
            }
        }
        // The file/dir doesn't exist so create it if necessary
        if (flags != .NO_CREATION) {
            var child: *Node = undefined;
            switch (flags) {
                .CREATE_DIR => {
                    // Create the fs node
                    child = try test_fs.allocator.create(Node);
                    child.* = .{ .Dir = .{ .fs = test_fs.fs, .mount = null } };
                },
                .CREATE_FILE => {
                    // Create the fs node
                    child = try test_fs.allocator.create(Node);
                    child.* = .{ .File = .{ .fs = test_fs.fs } };
                },
                .NO_CREATION => unreachable,
            }
            // Create the test fs tree node
            var child_tree = try test_fs.allocator.create(TreeNode);
            var child_name = try test_fs.allocator.alloc(u8, name.len);
            std.mem.copy(u8, child_name, name);
            child_tree.* = .{
                .val = child,
                .name = child_name,
                .children = try test_fs.allocator.create(ArrayList(*TreeNode)),
                .data = null,
            };
            child_tree.children.* = ArrayList(*TreeNode).init(test_fs.allocator);
            // Add it to the tree
            try parent.children.append(child_tree);
            return child;
        }
        return Error.NoSuchFileOrDir;
    }
};

fn testInitFs(allocator: *Allocator) !*TestFS {
    const fs = try allocator.create(FileSystem);
    var testfs = try allocator.create(TestFS);
    var root_node = try allocator.create(Node);
    root_node.* = .{ .Dir = .{ .fs = fs, .mount = null } };
    var name = try allocator.alloc(u8, 4);
    std.mem.copy(u8, name, "root");
    testfs.* = TestFS{
        .tree = .{
            .val = root_node,
            .name = name,
            .children = try allocator.create(ArrayList(*TestFS.TreeNode)),
            .data = null,
        },
        .fs = fs,
        .instance = 123,
        .allocator = allocator,
    };
    testfs.tree.children.* = ArrayList(*TestFS.TreeNode).init(allocator);
    fs.* = .{ .open = TestFS.open, .close = TestFS.close, .read = TestFS.read, .write = TestFS.write, .instance = &testfs.instance, .getRootNode = TestFS.getRootNode };
    return testfs;
}

test "mount" {
    var allocator = testing.allocator;

    // The root fs
    var testfs = try testInitFs(allocator);
    defer testfs.deinit();
    defer allocator.destroy(testfs);

    testfs.instance = 1;
    root = testfs.tree.val;

    // The fs that is to be mounted
    var testfs2 = try testInitFs(allocator);
    defer testfs2.deinit();
    defer allocator.destroy(testfs2);

    testfs2.instance = 2;
    // Create the dir to mount to
    var dir = try openDir("/mnt", .CREATE_DIR);
    try mount(dir, testfs2.fs);
    testing.expectError(MountError.DirAlreadyMounted, mount(dir, testfs2.fs));

    // Ensure the mount worked
    testing.expectEqual((dir.mount orelse unreachable), testfs2.fs.getRootNode(testfs2.fs));
    testing.expectEqual((dir.mount orelse unreachable).fs, testfs2.fs);
    // Create a file within the mounted directory
    var test_file = try openFile("/mnt/123.txt", .CREATE_FILE);
    testing.expectEqual(@ptrCast(*const FileSystem, testfs2.fs), test_file.fs);
    // This shouldn't be in the root fs
    testing.expectEqual(@as(usize, 1), testfs.tree.children.items.len);
    testing.expectEqual(@as(usize, 0), testfs.tree.children.items[0].children.items.len);
    // It should be in the mounted fs
    testing.expectEqual(@as(usize, 1), testfs2.tree.children.items.len);
    testing.expectEqual(test_file, &testfs2.tree.children.items[0].val.File);
}

test "traversePath" {
    var allocator = testing.allocator;
    var testfs = try testInitFs(allocator);
    defer testfs.deinit();
    defer allocator.destroy(testfs);
    root = testfs.tree.val;

    // Get the root
    var test_root = try traversePath("/", .NO_CREATION);
    testing.expectEqual(test_root, root);
    // Create a file in the root and try to traverse to it
    var child1 = try test_root.Dir.open("child1.txt", .CREATE_FILE);
    testing.expectEqual(child1, try traversePath("/child1.txt", .NO_CREATION));
    // Same but with a directory
    var child2 = try test_root.Dir.open("child2", .CREATE_DIR);
    testing.expectEqual(child2, try traversePath("/child2", .NO_CREATION));
    // Again but with a file within that directory
    var child3 = try child2.Dir.open("child3.txt", .CREATE_FILE);
    testing.expectEqual(child3, try traversePath("/child2/child3.txt", .NO_CREATION));

    testing.expectError(Error.NotAbsolutePath, traversePath("abc", .NO_CREATION));
    testing.expectError(Error.NotAbsolutePath, traversePath("", .NO_CREATION));
    testing.expectError(Error.NotAbsolutePath, traversePath("a/", .NO_CREATION));
    testing.expectError(Error.NoSuchFileOrDir, traversePath("/notadir/abc.txt", .NO_CREATION));
    testing.expectError(Error.NoSuchFileOrDir, traversePath("/ ", .NO_CREATION));
    testing.expectError(Error.NotADirectory, traversePath("/child1.txt/abc.txt", .NO_CREATION));
}

test "isAbsolute" {
    testing.expect(isAbsolute("/"));
    testing.expect(isAbsolute("/abc"));
    testing.expect(isAbsolute("/abc/def"));
    testing.expect(isAbsolute("/ a bc/de f"));
    testing.expect(isAbsolute("//"));
    testing.expect(!isAbsolute(" /"));
    testing.expect(!isAbsolute(""));
    testing.expect(!isAbsolute("abc"));
    testing.expect(!isAbsolute("abc/def"));
}

test "isDir" {
    const fs: FileSystem = undefined;
    const dir = Node{ .Dir = .{ .fs = &fs, .mount = null } };
    const file = Node{ .File = .{ .fs = &fs } };
    testing.expect(dir.isDir());
    testing.expect(!file.isDir());
}

test "isFile" {
    const fs: FileSystem = undefined;
    const dir = Node{ .Dir = .{ .fs = &fs, .mount = null } };
    const file = Node{ .File = .{ .fs = &fs } };
    testing.expect(!dir.isFile());
    testing.expect(file.isFile());
}

test "open" {
    var testfs = try testInitFs(testing.allocator);
    defer testfs.deinit();
    defer testing.allocator.destroy(testfs);
    root = testfs.tree.val;

    // Creating a file
    var test_node = try openFile("/abc.txt", .CREATE_FILE);
    testing.expectEqual(testfs.tree.children.items.len, 1);
    var tree = testfs.tree.children.items[0];
    testing.expect(tree.val.isFile());
    testing.expectEqual(test_node, &tree.val.File);
    testing.expect(std.mem.eql(u8, tree.name, "abc.txt"));
    testing.expectEqual(tree.data, null);
    testing.expectEqual(tree.children.items.len, 0);

    // Creating a dir
    var test_dir = try openDir("/def", .CREATE_DIR);
    testing.expectEqual(testfs.tree.children.items.len, 2);
    tree = testfs.tree.children.items[1];
    testing.expect(tree.val.isDir());
    testing.expectEqual(test_dir, &tree.val.Dir);
    testing.expect(std.mem.eql(u8, tree.name, "def"));
    testing.expectEqual(tree.data, null);
    testing.expectEqual(tree.children.items.len, 0);

    // Creating a file under a new dir
    test_node = try openFile("/def/ghi.zig", .CREATE_FILE);
    testing.expectEqual(testfs.tree.children.items[1].children.items.len, 1);
    tree = testfs.tree.children.items[1].children.items[0];
    testing.expect(tree.val.isFile());
    testing.expectEqual(test_node, &tree.val.File);
    testing.expect(std.mem.eql(u8, tree.name, "ghi.zig"));
    testing.expectEqual(tree.data, null);
    testing.expectEqual(tree.children.items.len, 0);

    testing.expectError(Error.NoSuchFileOrDir, openDir("/jkl", .NO_CREATION));
    testing.expectError(Error.NoSuchFileOrDir, openFile("/mno.txt", .NO_CREATION));
    testing.expectError(Error.NoSuchFileOrDir, openFile("/def/pqr.txt", .NO_CREATION));
    testing.expectError(Error.NoSuchFileOrDir, openDir("/mno/stu", .NO_CREATION));
    testing.expectError(Error.NoSuchFileOrDir, openFile("/mno/stu.txt", .NO_CREATION));
    testing.expectError(Error.NotADirectory, openFile("/abc.txt/vxy.md", .NO_CREATION));
    testing.expectError(Error.IsADirectory, openFile("/def", .NO_CREATION));
    testing.expectError(Error.InvalidFlags, openFile("/abc.txt", .CREATE_DIR));
    testing.expectError(Error.InvalidFlags, openDir("/abc.txt", .CREATE_FILE));
    testing.expectError(Error.NotAbsolutePath, open("", .NO_CREATION));
    testing.expectError(Error.NotAbsolutePath, open("abc", .NO_CREATION));
}

test "read" {
    var testfs = try testInitFs(testing.allocator);
    defer testfs.deinit();
    defer testing.allocator.destroy(testfs);
    root = testfs.tree.val;

    var test_file = try openFile("/foo.txt", .CREATE_FILE);
    var f_data = &testfs.tree.children.items[0].data;
    var str = "test123";
    f_data.* = try std.mem.dupe(testing.allocator, u8, str);

    {
        var data = try test_file.read(str.len);
        defer testing.allocator.free(data);
        testing.expect(std.mem.eql(u8, str, data));
    }

    {
        var data = try test_file.read(str.len + 1);
        defer testing.allocator.free(data);
        testing.expect(std.mem.eql(u8, str, data));
    }

    {
        var data = try test_file.read(str.len + 3);
        defer testing.allocator.free(data);
        testing.expect(std.mem.eql(u8, str, data));
    }

    {
        var data = try test_file.read(str.len - 1);
        defer testing.allocator.free(data);
        testing.expect(std.mem.eql(u8, str[0 .. str.len - 1], data));
    }

    testing.expect(std.mem.eql(u8, str[0..0], try test_file.read(0)));
}

test "write" {
    var testfs = try testInitFs(testing.allocator);
    defer testfs.deinit();
    defer testing.allocator.destroy(testfs);
    root = testfs.tree.val;

    var test_file = try openFile("/foo.txt", .CREATE_FILE);
    var f_data = &testfs.tree.children.items[0].data;
    testing.expectEqual(f_data.*, null);

    var str = "test123";
    try test_file.write(str);
    testing.expect(std.mem.eql(u8, str, f_data.* orelse unreachable));
}
