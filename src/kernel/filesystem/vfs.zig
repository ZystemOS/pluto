const std = @import("std");
const testing = std.testing;
const TailQueue = std.TailQueue;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

/// Flags specifying what to do when opening a file or directory
pub const OpenFlags = enum {
    /// Create a directory if it doesn't exist
    CREATE_DIR,
    /// Create a file if it doesn't exist
    CREATE_FILE,
    /// Create a symlink if it doesn't exist
    CREATE_SYMLINK,
    /// Do not create a file or directory
    NO_CREATION,
};

/// The args used when opening new or existing fs nodes
pub const OpenArgs = struct {
    /// What to set the target to when creating a symlink
    symlink_target: ?[]const u8 = null,
};

/// A filesystem node that could either be a directory or a file
pub const Node = union(enum) {
    /// The file node if this represents a file
    File: FileNode,
    /// The dir node if this represents a directory
    Dir: DirNode,
    /// The absolute path that this symlink is linked to
    Symlink: SymlinkNode,

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
            else => false,
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
            else => false,
        };
    }

    ///
    /// Check if this node is a symlink
    ///
    /// Arguments:
    ///     IN self: Self - The node being checked
    ///
    /// Return: bool
    ///     True if this is a symlink else false
    ///
    pub fn isSymlink(self: Self) bool {
        return switch (self) {
            .Symlink => true,
            else => false,
        };
    }
};

/// The functions of a filesystem
pub const FileSystem = struct {
    const Self = @This();

    ///
    /// Close an open node, performing any last operations required to save data etc.
    ///
    /// Arguments:
    ///     IN self: *const FileSystem - The filesystem in question being operated on.
    ///     IN node: *const Node - The node being closed.
    ///
    const Close = fn (self: *const Self, node: *const Node) void;

    ///
    /// Read from an open file
    ///
    /// Arguments:
    ///     IN self: *const FileSystem - The filesystem in question being operated on
    ///     IN node: *const FileNode - The file being read from
    ///     IN bytes: []u8 - The buffer to fill data from the file with
    ///
    /// Return: usize
    ///     The length of the actual data read. This being < bytes.len is not considered an error. It is never > bytes.len
    ///
    /// Error: Allocator.Error || Error
    ///     Allocator.Error.OutOfMemory - There wasn't enough memory to fulfill the request
    ///     Error.NotOpened - If the node provided is not one that the file system recognised as being opened.
    ///
    const Read = fn (self: *const Self, node: *const FileNode, buffer: []u8) (Allocator.Error || Error)!usize;

    ///
    /// Write to an open file
    ///
    /// Arguments:
    ///     IN self: *const FileSystem - The filesystem in question being operated on
    ///     IN node: *const FileNode - The file being read from
    ///     IN bytes: []u8 - The bytes to write to the file
    ///
    /// Return: usize
    ///     The length of the actual data written to the file. This being < bytes.len is not considered an error. It is never > bytes.len
    ///
    /// Error: Allocator.Error
    ///     Allocator.Error.OutOfMemory - There wasn't enough memory to fulfill the request
    ///
    const Write = fn (self: *const Self, node: *const FileNode, bytes: []const u8) (Allocator.Error || Error)!usize;

    ///
    /// Open a file/dir within the filesystem. The result can then be used for write, read or close operations
    ///
    /// Arguments:
    ///     IN self: *const FileSystem - The filesystem in question being operated on
    ///     IN node: *const DirNode - The directory under which to open the file/dir from
    ///     IN name: []const u8 - The name of the file to open
    ///     IN flags: OpenFlags - The flags to consult when opening the file
    ///     IN args: OpenArgs - The arguments to use when creating a node
    ///
    /// Return: *const Node
    ///     The node representing the file/dir opened
    ///
    /// Error: Allocator.Error || Error
    ///     Allocator.Error.OutOfMemory - There wasn't enough memory to fulfill the request
    ///     Error.NoSuchFileOrDir - The file/dir by that name doesn't exist and the flags didn't specify to create it
    ///     Error.NoSymlinkTarget - A symlink was created but no symlink target was provided in the args
    ///
    const Open = fn (self: *const Self, node: *const DirNode, name: []const u8, flags: OpenFlags, args: OpenArgs) (Allocator.Error || Error)!*Node;

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
    pub fn read(self: *const FileNode, bytes: []u8) (Allocator.Error || Error)!usize {
        return self.fs.read(self.fs, self, bytes);
    }

    /// See the documentation for FileSystem.Close
    pub fn close(self: *const FileNode) void {
        // TODO: Use @fieldParentPtr() once implemented for unions
        return self.fs.close(self.fs, @ptrCast(*const Node, self));
    }

    /// See the documentation for FileSystem.Write
    pub fn write(self: *const FileNode, bytes: []const u8) (Allocator.Error || Error)!usize {
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
    pub fn open(self: *const DirNode, name: []const u8, flags: OpenFlags, args: OpenArgs) (Allocator.Error || Error)!*Node {
        var node = self.mount orelse self;
        return node.fs.open(node.fs, node, name, flags, args);
    }

    /// See the documentation for FileSystem.Close
    pub fn close(self: *const DirNode) void {
        var fs = self.fs;
        var node = self;

        // TODO: Use @fieldParentPtr() once implemented for unions
        const cast_node = @ptrCast(*const Node, node);
        // Can't close the root node
        if (cast_node == root) {
            return;
        }
        return fs.close(fs, cast_node);
    }
};

pub const SymlinkNode = struct {
    /// The filesystem that handles operations on this directory
    fs: *const FileSystem,

    /// The absolute path that this symlink is linked to
    path: []const u8,

    /// See the documentation for FileSystem.Close
    pub fn close(self: *const SymlinkNode) void {
        // TODO: Use @fieldParentPtr() once implemented for unions
        return self.fs.close(self.fs, @ptrCast(*const Node, self));
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

    /// The requested symlink is actually a file
    IsAFile,

    /// The path provided is not absolute
    NotAbsolutePath,

    /// The flags provided are invalid for the requested operation
    InvalidFlags,

    /// The node is not recognised as being opened by the filesystem
    NotOpened,

    /// No symlink target was provided when one was expected
    NoSymlinkTarget,

    /// An unexpected error ocurred when performing a VFS operation.
    Unexpected,
};

/// Errors that can be thrown when attempting to mount
pub const MountError = error{
    /// The directory being mounted to a filesystem is already mounted to something
    DirAlreadyMounted,
};

/// The separator used between segments of a file path
pub const SEPARATOR: u8 = '/';

/// The root of the system's top-level filesystem
pub var root: *Node = undefined;

///
/// Traverse the specified path from the root and open the file/dir corresponding to that path. If the file/dir doesn't exist it can be created by specifying the open flags
///
/// Arguments:
///     IN path: []const u8 - The path to traverse. Must be absolute (see isAbsolute)
///     IN flags: OpenFlags - The flags that specify if the file/dir should be created if it doesn't exist
///     IN args: OpenArgs - The extra args needed when creating new nodes.
///
/// Return: *const Node
///     The node that exists at the path starting at the system root
///
/// Error: Allocator.Error || Error
///     Allocator.Error.OutOfMemory - There wasn't enough memory to fulfill the request
///     Error.NotADirectory - A segment within the path which is not at the end does not correspond to a directory
///     Error.NoSuchFileOrDir - The file/dir at the end of the path doesn't exist and the flags didn't specify to create it
///     Error.NoSymlinkTarget - A non-null symlink target was not provided when creating a symlink
///
fn traversePath(path: []const u8, follow_symlinks: bool, flags: OpenFlags, args: OpenArgs) (Allocator.Error || Error)!*Node {
    if (!isAbsolute(path)) {
        return Error.NotAbsolutePath;
    }

    const TraversalParent = struct {
        parent: *Node,
        child: []const u8,

        const Self = @This();

        fn func(split: *std.mem.SplitIterator(u8), node: *Node, follow_links: bool, rec_flags: OpenFlags) (Allocator.Error || Error)!Self {
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
                .Dir => |*dir| blk: {
                    var child = try dir.open(seg, rec_flags, .{});
                    defer dir.close();
                    // If the segment refers to a symlink, redirect to the node it represents instead
                    if (child.isSymlink() and follow_links) {
                        const new_child = try traversePath(child.Symlink.path, follow_links, rec_flags, .{});
                        child.Symlink.close();
                        child = new_child;
                    }
                    break :blk try func(split, child, follow_links, rec_flags);
                },
                .Symlink => |target| if (follow_links) try func(split, try traversePath(target.path, follow_links, .NO_CREATION, .{}), follow_links, rec_flags) else Error.NotADirectory,
            };
        }
    };

    // Split path but skip the first separator character
    var split = std.mem.split(u8, path[1..], &[_]u8{SEPARATOR});
    // Traverse directories while we're not at the last segment
    const result = try TraversalParent.func(&split, root, follow_symlinks, .NO_CREATION);

    // There won't always be a second segment in the path, e.g. in "/"
    if (std.mem.eql(u8, result.child, "")) {
        return result.parent;
    }

    // Open the final segment of the path from whatever the parent is
    return switch (result.parent.*) {
        .File => |*file| blk: {
            file.close();
            break :blk Error.NotADirectory;
        },
        .Symlink => |target| if (follow_symlinks) try traversePath(target.path, follow_symlinks, .NO_CREATION, .{}) else result.parent,
        .Dir => |*dir| blk: {
            var n = try dir.open(result.child, flags, args);
            defer dir.close();
            if (n.isSymlink() and follow_symlinks) {
                // If the child is a symlink and we're following them, find the node it refers to
                const new_n = try traversePath(n.Symlink.path, follow_symlinks, flags, args);
                n.Symlink.close();
                n = new_n;
            }
            break :blk n;
        },
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
/// Unmount the filesystem attached to a directory.
///
/// Arguments:
///     IN dir: *DirNode - The directory to unmount from.
///
pub fn umount(dir: *DirNode) void {
    dir.mount = null;
}

///
/// Open a node at a path.
///
/// Arguments:
///     IN path: []const u8 - The path to open. Must be absolute (see isAbsolute)
///     IN follow_symlinks: bool - Whether symbolic links should be followed. When this is false and the path traversal encounters a symlink before the end segment of the path, NotADirectory is returned.
///     IN flags: OpenFlags - The flags specifying if this node should be created if it doesn't exist
///     IN args: OpenArgs - The extra args needed when creating new nodes.
///
/// Return: *const Node
///     The node that exists at the path starting at the system root
///
/// Error: Allocator.Error || Error
///     Allocator.Error.OutOfMemory - There wasn't enough memory to fulfill the request
///     Error.NotADirectory - A segment within the path which is not at the end does not correspond to a directory
///     Error.NoSuchFileOrDir - The file/dir at the end of the path doesn't exist and the flags didn't specify to create it
///     Error.NoSymlinkTarget - A non-null symlink target was not provided when creating a symlink
///
pub fn open(path: []const u8, follow_symlinks: bool, flags: OpenFlags, args: OpenArgs) (Allocator.Error || Error)!*Node {
    return try traversePath(path, follow_symlinks, flags, args);
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
pub fn openFile(path: []const u8, flags: OpenFlags) (Allocator.Error || Error)!*const FileNode {
    switch (flags) {
        .CREATE_DIR, .CREATE_SYMLINK => return Error.InvalidFlags,
        .NO_CREATION, .CREATE_FILE => {},
    }
    var node = try open(path, true, flags, .{});
    return switch (node.*) {
        .File => &node.File,
        .Dir => |*dir| blk: {
            dir.close();
            break :blk Error.IsADirectory;
        },
        // We instructed open to follow symlinks above, so this is impossible
        .Symlink => unreachable,
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
///     Error.IsAFile - The path corresponds to a file rather than a directory
///
pub fn openDir(path: []const u8, flags: OpenFlags) (Allocator.Error || Error)!*DirNode {
    switch (flags) {
        .CREATE_FILE, .CREATE_SYMLINK => return Error.InvalidFlags,
        .NO_CREATION, .CREATE_DIR => {},
    }
    var node = try open(path, true, flags, .{});
    return switch (node.*) {
        .File => |*file| blk: {
            file.close();
            break :blk Error.IsAFile;
        },
        // We instructed open to follow symlinks above, so this is impossible
        .Symlink => unreachable,
        .Dir => &node.Dir,
    };
}

///
/// Open a symlink at a path with a target.
///
/// Arguments:
///     IN path: []const u8 - The path to open. Must be absolute (see isAbsolute)
///     IN target: ?[]const u8 - The target to use when creating the symlink. Can be null if .NO_CREATION is used as the open flag
///     IN flags: OpenFlags - The flags specifying if this node should be created if it doesn't exist. Cannot be CREATE_FILE
///
/// Return: []const u8
///     The opened symlink's target
///
/// Error: Allocator.Error || Error
///     Allocator.Error.OutOfMemory - There wasn't enough memory to fulfill the request
///     Error.InvalidFlags - The flags were a value invalid when opening a symlink
///     Error.NotADirectory - A segment within the path which is not at the end does not correspond to a directory
///     Error.NoSuchFileOrDir - The symlink at the end of the path doesn't exist and the flags didn't specify to create it
///     Error.IsAFile - The path corresponds to a file rather than a symlink
///     Error.IsADirectory - The path corresponds to a directory rather than a symlink
///
pub fn openSymlink(path: []const u8, target: ?[]const u8, flags: OpenFlags) (Allocator.Error || Error)![]const u8 {
    switch (flags) {
        .CREATE_DIR, .CREATE_FILE => return Error.InvalidFlags,
        .NO_CREATION, .CREATE_SYMLINK => {},
    }
    var node = try open(path, false, flags, .{ .symlink_target = target });
    return switch (node.*) {
        .Symlink => |t| t.path,
        .File => |*file| blk: {
            file.close();
            break :blk Error.IsAFile;
        },
        .Dir => |*dir| blk: {
            dir.close();
            break :blk Error.IsADirectory;
        },
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
/// Error: Error
///     Error.NotADirectory - The node isn't a directory node.
///
pub fn setRoot(node: *Node) Error!void {
    if (!node.isDir()) {
        return Error.NotADirectory;
    }
    root = node;
}

const TestFS = struct {
    const TreeNode = struct {
        val: *Node,
        name: []u8,
        data: ?[]u8,
        children: *ArrayList(*@This()),

        fn deinit(self: *@This(), allocator: Allocator) void {
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
    allocator: Allocator,
    open_count: usize,
    instance: usize,

    const Self = @This();

    pub fn deinit(self: *@This()) void {
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
        var to_check = TailQueue(*TreeNode){};
        var root_node = try test_fs.allocator.create(TailQueue(*TreeNode).Node);
        root_node.* = .{ .data = &test_fs.tree };
        to_check.append(root_node);

        while (to_check.popFirst()) |queue_node| {
            var tree_node = queue_node.data;
            test_fs.allocator.destroy(queue_node);
            if ((@TypeOf(node) == *const FileNode and tree_node.val.isFile() and &tree_node.val.File == node) or (@TypeOf(node) == *const DirNode and tree_node.val.isDir() and &tree_node.val.Dir == node) or (@TypeOf(node) == *const Node and &tree_node.val == node)) {
                // Clean up any unused queue nodes
                while (to_check.popFirst()) |t_node| {
                    test_fs.allocator.destroy(t_node);
                }
                return tree_node;
            }
            for (tree_node.children.items) |child| {
                // It's not the parent so add its children to the list for checking
                var n = try test_fs.allocator.create(TailQueue(*TreeNode).Node);
                n.* = .{ .data = child };
                to_check.append(n);
            }
        }
        return null;
    }

    fn getRootNode(fs: *const FileSystem) *const DirNode {
        var test_fs = @fieldParentPtr(TestFS, "instance", fs.instance);
        return &test_fs.tree.val.Dir;
    }

    fn close(fs: *const FileSystem, node: *const Node) void {
        // Suppress unused var warning
        _ = node;
        var test_fs = @fieldParentPtr(TestFS, "instance", fs.instance);
        test_fs.open_count -= 1;
    }

    fn read(fs: *const FileSystem, node: *const FileNode, bytes: []u8) (Allocator.Error || Error)!usize {
        var test_fs = @fieldParentPtr(TestFS, "instance", fs.instance);
        // Get the tree that corresponds to the node. Cannot error as the file is already open so it does exist
        var tree = (getTreeNode(test_fs, node) catch unreachable) orelse unreachable;
        const count = if (tree.data) |d| std.math.min(bytes.len, d.len) else 0;
        const data = if (tree.data) |d| d[0..count] else "";
        std.mem.copy(u8, bytes, data);
        return count;
    }

    fn write(fs: *const FileSystem, node: *const FileNode, bytes: []const u8) (Allocator.Error || Error)!usize {
        var test_fs = @fieldParentPtr(TestFS, "instance", fs.instance);
        var tree = (try getTreeNode(test_fs, node)) orelse unreachable;
        if (tree.data) |_| {
            test_fs.allocator.free(tree.data.?);
        }
        tree.data = try test_fs.allocator.alloc(u8, bytes.len);
        std.mem.copy(u8, tree.data.?, bytes);
        return bytes.len;
    }

    fn open(fs: *const FileSystem, dir: *const DirNode, name: []const u8, flags: OpenFlags, args: OpenArgs) (Allocator.Error || Error)!*Node {
        var test_fs = @fieldParentPtr(TestFS, "instance", fs.instance);
        const parent = (try getTreeNode(test_fs, dir)) orelse unreachable;
        // Check if the children match the file wanted
        for (parent.children.items) |child| {
            if (std.mem.eql(u8, child.name, name)) {
                // Increment the open count
                test_fs.open_count += 1;
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
                .CREATE_SYMLINK => {
                    if (args.symlink_target) |target| {
                        child = try test_fs.allocator.create(Node);
                        child.* = .{ .Symlink = .{ .fs = test_fs.fs, .path = target } };
                    } else {
                        return Error.NoSymlinkTarget;
                    }
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
            // Increment the open count
            test_fs.open_count += 1;
            return child;
        }
        return Error.NoSuchFileOrDir;
    }
};

pub fn testInitFs(allocator: Allocator) !*TestFS {
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
        .open_count = 0,
        .allocator = allocator,
    };
    testfs.tree.children.* = ArrayList(*TestFS.TreeNode).init(allocator);
    fs.* = .{
        .open = TestFS.open,
        .close = TestFS.close,
        .read = TestFS.read,
        .write = TestFS.write,
        .instance = &testfs.instance,
        .getRootNode = TestFS.getRootNode,
    };
    return testfs;
}

test "mount" {
    var allocator = testing.allocator;

    // The root fs
    var testfs = try testInitFs(allocator);
    defer allocator.destroy(testfs);
    defer testfs.deinit();
    defer testing.expectEqual(testfs.open_count, 0) catch @panic("Test fs open count is not zero\n");

    testfs.instance = 1;
    root = testfs.tree.val;

    // The fs that is to be mounted
    var testfs2 = try testInitFs(allocator);
    defer allocator.destroy(testfs2);
    defer testfs2.deinit();
    defer testing.expectEqual(testfs2.open_count, 0) catch @panic("Second test fs open count is not zero\n");

    testfs2.instance = 2;
    // Create the dir to mount to
    var dir = try openDir("/mnt", .CREATE_DIR);
    defer dir.close();
    try mount(dir, testfs2.fs);
    defer umount(dir);
    try testing.expectError(MountError.DirAlreadyMounted, mount(dir, testfs2.fs));

    // Ensure the mount worked
    try testing.expectEqual((dir.mount orelse unreachable), testfs2.fs.getRootNode(testfs2.fs));
    try testing.expectEqual((dir.mount orelse unreachable).fs, testfs2.fs);
    // Create a file within the mounted directory
    var test_file = try openFile("/mnt/123.txt", .CREATE_FILE);
    defer test_file.close();
    try testing.expectEqual(@ptrCast(*const FileSystem, testfs2.fs), test_file.fs);
    // This shouldn't be in the root fs
    try testing.expectEqual(@as(usize, 1), testfs.tree.children.items.len);
    try testing.expectEqual(@as(usize, 0), testfs.tree.children.items[0].children.items.len);
    // It should be in the mounted fs
    try testing.expectEqual(@as(usize, 1), testfs2.tree.children.items.len);
    try testing.expectEqual(test_file, &testfs2.tree.children.items[0].val.File);
}

test "traversePath" {
    var allocator = testing.allocator;
    var testfs = try testInitFs(allocator);
    defer allocator.destroy(testfs);
    defer testfs.deinit();
    root = testfs.tree.val;

    // Get the root
    var test_root = try traversePath("/", false, .NO_CREATION, .{});
    try testing.expectEqual(test_root, root);
    // Create a file in the root and try to traverse to it
    var child1 = try test_root.Dir.open("child1.txt", .CREATE_FILE, .{});
    var child1_traversed = try traversePath("/child1.txt", false, .NO_CREATION, .{});
    try testing.expectEqual(child1, child1_traversed);
    // Close the open files
    child1.File.close();
    child1_traversed.File.close();

    // Same but with a directory
    var child2 = try test_root.Dir.open("child2", .CREATE_DIR, .{});
    const child2_traversed = try traversePath("/child2", false, .NO_CREATION, .{});
    try testing.expectEqual(child2, child2_traversed);

    // Again but with a file within that directory
    var child3 = try child2.Dir.open("child3.txt", .CREATE_FILE, .{});
    var child3_traversed = try traversePath("/child2/child3.txt", false, .NO_CREATION, .{});
    try testing.expectEqual(child3, child3_traversed);
    // Close the open files
    child2.Dir.close();
    child2_traversed.Dir.close();
    child3_traversed.File.close();

    // Create and open a symlink
    var child4 = try traversePath("/child2/link", false, .CREATE_SYMLINK, .{ .symlink_target = "/child2/child3.txt" });
    var child4_linked = try traversePath("/child2/link", true, .NO_CREATION, .{});
    try testing.expectEqual(child4_linked, child3);
    var child5 = try traversePath("/child4", false, .CREATE_SYMLINK, .{ .symlink_target = "/child2" });
    var child5_linked = try traversePath("/child4/child3.txt", true, .NO_CREATION, .{});
    try testing.expectEqual(child5_linked, child4_linked);
    child3.File.close();
    child4.Symlink.close();
    child5.Symlink.close();
    child4_linked.File.close();
    child5_linked.File.close();

    try testing.expectError(Error.NotAbsolutePath, traversePath("abc", false, .NO_CREATION, .{}));
    try testing.expectError(Error.NotAbsolutePath, traversePath("", false, .NO_CREATION, .{}));
    try testing.expectError(Error.NotAbsolutePath, traversePath("a/", false, .NO_CREATION, .{}));
    try testing.expectError(Error.NoSuchFileOrDir, traversePath("/notadir/abc.txt", false, .NO_CREATION, .{}));
    try testing.expectError(Error.NoSuchFileOrDir, traversePath("/ ", false, .NO_CREATION, .{}));
    try testing.expectError(Error.NotADirectory, traversePath("/child1.txt/abc.txt", false, .NO_CREATION, .{}));
    try testing.expectError(Error.NoSymlinkTarget, traversePath("/childX.txt", false, .CREATE_SYMLINK, .{}));

    // Since we've closed all the files, the open files count should be zero
    try testing.expectEqual(testfs.open_count, 0);
}

test "isAbsolute" {
    try testing.expect(isAbsolute("/"));
    try testing.expect(isAbsolute("/abc"));
    try testing.expect(isAbsolute("/abc/def"));
    try testing.expect(isAbsolute("/ a bc/de f"));
    try testing.expect(isAbsolute("//"));
    try testing.expect(!isAbsolute(" /"));
    try testing.expect(!isAbsolute(""));
    try testing.expect(!isAbsolute("abc"));
    try testing.expect(!isAbsolute("abc/def"));
}

test "isDir" {
    const fs: FileSystem = undefined;
    const dir = Node{ .Dir = .{ .fs = &fs, .mount = null } };
    const file = Node{ .File = .{ .fs = &fs } };
    const symlink = Node{ .Symlink = .{ .fs = &fs, .path = "" } };
    try testing.expect(!symlink.isDir());
    try testing.expect(!file.isDir());
    try testing.expect(dir.isDir());
}

test "isFile" {
    const fs: FileSystem = undefined;
    const dir = Node{ .Dir = .{ .fs = &fs, .mount = null } };
    const file = Node{ .File = .{ .fs = &fs } };
    const symlink = Node{ .Symlink = .{ .fs = &fs, .path = "" } };
    try testing.expect(!dir.isFile());
    try testing.expect(!symlink.isFile());
    try testing.expect(file.isFile());
}

test "isSymlink" {
    const fs: FileSystem = undefined;
    const dir = Node{ .Dir = .{ .fs = &fs, .mount = null } };
    const file = Node{ .File = .{ .fs = &fs } };
    const symlink = Node{ .Symlink = .{ .fs = &fs, .path = "" } };
    try testing.expect(!dir.isSymlink());
    try testing.expect(!file.isSymlink());
    try testing.expect(symlink.isSymlink());
}

test "open" {
    var testfs = try testInitFs(testing.allocator);
    defer testing.allocator.destroy(testfs);
    defer testfs.deinit();
    root = testfs.tree.val;

    // Creating a file
    var test_node = try openFile("/abc.txt", .CREATE_FILE);
    try testing.expectEqual(testfs.tree.children.items.len, 1);
    var tree = testfs.tree.children.items[0];
    try testing.expect(tree.val.isFile());
    try testing.expectEqual(test_node, &tree.val.File);
    try testing.expect(std.mem.eql(u8, tree.name, "abc.txt"));
    try testing.expectEqual(tree.data, null);
    try testing.expectEqual(tree.children.items.len, 0);

    // Creating a dir
    var test_dir = try openDir("/def", .CREATE_DIR);
    try testing.expectEqual(testfs.tree.children.items.len, 2);
    tree = testfs.tree.children.items[1];
    try testing.expect(tree.val.isDir());
    try testing.expectEqual(test_dir, &tree.val.Dir);
    try testing.expect(std.mem.eql(u8, tree.name, "def"));
    try testing.expectEqual(tree.data, null);
    try testing.expectEqual(tree.children.items.len, 0);

    // Creating a file under a new dir
    test_node = try openFile("/def/ghi.zig", .CREATE_FILE);
    try testing.expectEqual(testfs.tree.children.items[1].children.items.len, 1);
    tree = testfs.tree.children.items[1].children.items[0];
    try testing.expect(tree.val.isFile());
    try testing.expectEqual(test_node, &tree.val.File);
    try testing.expect(std.mem.eql(u8, tree.name, "ghi.zig"));
    try testing.expectEqual(tree.data, null);
    try testing.expectEqual(tree.children.items.len, 0);

    try testing.expectError(Error.NoSuchFileOrDir, openDir("/jkl", .NO_CREATION));
    try testing.expectError(Error.NoSuchFileOrDir, openFile("/mno.txt", .NO_CREATION));
    try testing.expectError(Error.NoSuchFileOrDir, openFile("/def/pqr.txt", .NO_CREATION));
    try testing.expectError(Error.NoSuchFileOrDir, openDir("/mno/stu", .NO_CREATION));
    try testing.expectError(Error.NoSuchFileOrDir, openFile("/mno/stu.txt", .NO_CREATION));
    try testing.expectError(Error.NotADirectory, openFile("/abc.txt/vxy.md", .NO_CREATION));
    try testing.expectError(Error.IsADirectory, openFile("/def", .NO_CREATION));
    try testing.expectError(Error.InvalidFlags, openFile("/abc.txt", .CREATE_DIR));
    try testing.expectError(Error.InvalidFlags, openDir("/abc.txt", .CREATE_FILE));
    try testing.expectError(Error.NotAbsolutePath, open("", false, .NO_CREATION, .{}));
    try testing.expectError(Error.NotAbsolutePath, open("abc", false, .NO_CREATION, .{}));
    try testing.expectError(Error.NoSymlinkTarget, open("/abc", false, .CREATE_SYMLINK, .{}));
}

test "read" {
    var testfs = try testInitFs(testing.allocator);
    defer testing.allocator.destroy(testfs);
    defer testfs.deinit();
    root = testfs.tree.val;

    var test_file = try openFile("/foo.txt", .CREATE_FILE);
    var f_data = &testfs.tree.children.items[0].data;
    var str = "test123";
    f_data.* = try Allocator.dupe(testing.allocator, u8, str);

    var buffer: [64]u8 = undefined;
    {
        const length = try test_file.read(buffer[0..str.len]);
        try testing.expect(std.mem.eql(u8, str, buffer[0..length]));
    }

    {
        const length = try test_file.read(buffer[0 .. str.len + 1]);
        try testing.expect(std.mem.eql(u8, str, buffer[0..length]));
    }

    {
        const length = try test_file.read(buffer[0 .. str.len + 3]);
        try testing.expect(std.mem.eql(u8, str, buffer[0..length]));
    }

    {
        const length = try test_file.read(buffer[0 .. str.len - 1]);
        try testing.expect(std.mem.eql(u8, str[0 .. str.len - 1], buffer[0..length]));
    }

    {
        const length = try test_file.read(buffer[0..0]);
        try testing.expect(std.mem.eql(u8, str[0..0], buffer[0..length]));
    }
    // Try reading from a symlink
    var test_link = try openSymlink("/link", "/foo.txt", .CREATE_SYMLINK);
    try testing.expectEqual(test_link, "/foo.txt");
    var link_file = try openFile("/link", .NO_CREATION);
    {
        const length = try link_file.read(buffer[0..]);
        try testing.expect(std.mem.eql(u8, str[0..], buffer[0..length]));
    }
}

test "write" {
    var testfs = try testInitFs(testing.allocator);
    defer testing.allocator.destroy(testfs);
    defer testfs.deinit();
    root = testfs.tree.val;

    var test_file = try openFile("/foo.txt", .CREATE_FILE);
    var f_data = &testfs.tree.children.items[0].data;
    try testing.expectEqual(f_data.*, null);

    var str = "test123";
    const length = try test_file.write(str);
    try testing.expect(std.mem.eql(u8, str, f_data.* orelse unreachable));
    try testing.expect(length == str.len);

    // Try writing to a symlink
    var test_link = try openSymlink("/link", "/foo.txt", .CREATE_SYMLINK);
    try testing.expectEqual(test_link, "/foo.txt");
    _ = try openFile("/link", .NO_CREATION);

    var str2 = "test456";
    _ = try test_file.write(str2);
    try testing.expect(std.mem.eql(u8, str2, f_data.* orelse unreachable));
}
