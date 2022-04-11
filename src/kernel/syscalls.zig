const std = @import("std");
const is_test = @import("builtin").is_test;
const scheduler = @import("scheduler.zig");
const panic = @import("panic.zig").panic;
const log = std.log.scoped(.syscalls);
const vfs = @import("filesystem/vfs.zig");
const vmm = @import("vmm.zig");
const bitmap = @import("bitmap.zig");
const task = @import("task.zig");
const arch = @import("arch.zig").internals;
const mem = @import("mem.zig");
const pmm = @import("pmm.zig");
const testing = std.testing;

var allocator: std.mem.Allocator = undefined;

/// The maximum amount of data to allocate when copying user memory into kernel memory
pub const USER_MAX_DATA_LEN = 16 * 1024;

/// A compilation of all errors that syscall handlers could return.
pub const Error = error{ NoMoreFSHandles, TooBig, NotAFile } || std.mem.Allocator.Error || vfs.Error || vmm.VmmError || bitmap.BitmapError;

/// All implemented syscalls
pub const Syscall = enum {
    /// Open a new vfs node
    ///
    /// Arguments:
    ///     path_ptr: usize - The user/kernel pointer to the file path to open
    ///     path_len: usize - The length of the file path
    ///     flags: usize    - The flag specifying what to do with the opened node. Use the integer value of vfs.OpenFlags
    ///     args: usize     - The user/kernel pointer to the structure holding the vfs.OpenArgs
    ///     ignored: usize  - Ignored
    ///
    /// Return: usize
    ///     The handle for the opened vfs node
    ///
    /// Error:
    ///     NoMoreFSHandles     - The task has reached the maximum number of allowed vfs handles
    ///     OutOfMemory         - There wasn't enough kernel (heap or VMM) memory left to fulfill the request.
    ///     TooBig              - The path length is greater than allowed
    ///     InvalidAddress      - A pointer that the user task passed is invalid (not mapped, out of bounds etc.)
    ///     InvalidFlags        - The flags provided don't correspond to a vfs.OpenFlags value
    ///     Refer to vfs.Error for details on what causes vfs errors
    ///
    Open,

    /// Read data from an open vfs file
    ///
    /// Arguments:
    ///     node_handle: usize  - The file handle returned from the open syscall
    ///     buff_ptr: usize `   - The user/kernel address of the buffer to put the read data in
    ///     buff_len: usize     - The size of the buffer
    ///     ignored1: usize     - Ignored
    ///     ignored2: usize     - Ignored
    ///
    /// Return: usize
    ///     The number of bytes read and put into the buffer
    ///
    /// Error:
    ///     OutOfBounds         - The node handle is outside of the maximum per process
    ///     TooBig              - The buffer is bigger than what a user process is allowed to give the kernel
    ///     NotAFile            - The handle does not correspond to a file
    ///     Refer to vfs.FileNode.read and vmm.VirtualMemoryManager.copyData for details on what causes other errors
    ///
    Read,
    /// Write data from to open vfs file
    ///
    /// Arguments:
    ///     node_handle: usize  - The file handle returned from the open syscall
    ///     buff_ptr: usize `   - The user/kernel address of the buffer containing the data to write
    ///     buff_len: usize     - The size of the buffer
    ///     ignored1: usize     - Ignored
    ///     ignored2: usize     - Ignored
    ///
    /// Return: usize
    ///     The number of bytes written
    ///
    /// Error:
    ///     OutOfBounds         - The node handle is outside of the maximum per process
    ///     TooBig              - The buffer is bigger than what a user process is allowed to give the kernel
    ///     NotAFile            - The handle does not correspond to a file
    ///     Refer to vfs.FileNode.read and vmm.VirtualMemoryManager.copyData for details on what causes other errors
    ///
    Write,
    ///
    /// Close an open vfs node. What it means to "close" depends on the underlying file system, but often it will cause the file to be committed to disk or for a network socket to be closed
    ///
    /// Arguments:
    ///     node_handle: usize  - The handle to close
    ///     ignored1..4: usize  - Ignored
    ///
    /// Return: void
    ///
    /// Error:
    ///     OutOfBounds         - The node handle is outside of the maximum per process
    ///     NotOpened           - The node handle hasn't been opened
    Close,
    Test1,
    Test2,
    Test3,

    ///
    /// Get the handler associated with the syscall
    ///
    /// Arguments:
    ///     IN self: Syscall - The syscall to get the handler for
    ///
    /// Return: Handler
    ///     The handler that takes care of this syscall
    ///
    fn getHandler(self: @This()) Handler {
        return switch (self) {
            .Open => handleOpen,
            .Read => handleRead,
            .Write => handleWrite,
            .Close => handleClose,
            .Test1 => handleTest1,
            .Test2 => handleTest2,
            .Test3 => handleTest3,
        };
    }

    ///
    /// Check if the syscall is just used for testing, and therefore shouldn't be exposed at runtime
    ///
    /// Arguments:
    ///     IN self: Syscall - The syscall to check
    ///
    /// Return: bool
    ///     true if the syscall is only to be used for testing, else false
    ///
    pub fn isTest(self: @This()) bool {
        return switch (self) {
            .Test1, .Test2, .Test3 => true,
            else => false,
        };
    }
};

/// A function that can handle a syscall and return a result or an error
pub const Handler = fn (arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize;

pub fn init(alloc: std.mem.Allocator) void {
    allocator = alloc;
}

///
/// Convert an error code to an instance of Error. The conversion must be synchronised with toErrorCode
/// Passing an error code that does not correspond to an error results in safety-protected undefined behaviour
///
/// Arguments:
///     IN code: u16 - The erorr code to convert
///
/// Return: Error
///     The error corresponding to the error code
///
pub fn fromErrorCode(code: u16) anyerror {
    return @intToError(code);
}

///
/// Convert an instance of Error to an error code. The conversion must be synchronised with fromErrorCode
///
/// Arguments:
///     IN err: Error - The erorr to convert
///
/// Return: u16
///     The error code corresponding to the error
///
pub fn toErrorCode(err: anyerror) u16 {
    return @errorToInt(err);
}

///
/// Handle a syscall and return a result or error
///
/// Arguments:
///     IN syscall: Syscall - The syscall to handle
///     IN argX: usize - The xth argument that was passed to the syscall
///
/// Return: usize
///     The syscall result
///
/// Error: Error
///     The error raised by the handler
///
pub fn handle(syscall: Syscall, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize {
    return try syscall.getHandler()(arg1, arg2, arg3, arg4, arg5);
}

///
/// Get a slice containing the data at an address and length. If the current task is a kernel task then a simple pointer to slice conversion is performed,
/// otherwise the slice is allocated on the heap and the data is copied in from user space.
///
/// Arguments:
///     IN ptr: usize - The slice's address
///     IN len: usize - The number of bytes
///
/// Error: Error
///     Error.OutOfMemory - There wasn't enough kernel (heap or VMM) memory left to fulfill the request.
///     Error.TooBig - The user task requested to have too much data copied
///     Error.NotAllocated - The pointer hasn't been mapped by the task
///     Error.OutOfBounds - The pointer and length is out of bounds of the task's VMM
///
/// Return: []u8
///     The slice of data. Will be stack-allocated if the current task is kernel-level, otherwise will be heap-allocated
///
fn getData(ptr: usize, len: usize) Error![]u8 {
    if (scheduler.current_task.kernel) {
        if (try vmm.kernel_vmm.isSet(ptr)) {
            return @intToPtr([*]u8, ptr)[0..len];
        } else {
            return Error.NotAllocated;
        }
    } else {
        if (len > USER_MAX_DATA_LEN) {
            return Error.TooBig;
        }
        var buff = try allocator.alloc(u8, len);
        errdefer allocator.free(buff);
        try vmm.kernel_vmm.copyData(scheduler.current_task.vmm, false, buff, ptr);
        return buff;
    }
}

/// Open a new vfs node
///
/// Arguments:
///     path_ptr: usize - The user/kernel pointer to the file path to open
///     path_len: usize - The length of the file path
///     flags: usize    - The flag specifying what to do with the opened node. Use the integer value of vfs.OpenFlags
///     args: usize     - The user/kernel pointer to the structure holding the vfs.OpenArgs
///     ignored: usize  - Ignored
///
/// Return: usize
///     The handle for the opened vfs node
///
/// Error:
///     NoMoreFSHandles     - The task has reached the maximum number of allowed vfs handles
///     OutOfMemory         - There wasn't enough kernel (heap or VMM) memory left to fulfill the request.
///     TooBig              - The path length is greater than allowed
///     InvalidAddress      - A pointer that the user task passed is invalid (not mapped, out of bounds etc.)
///     InvalidFlags        - The flags provided don't correspond to a vfs.OpenFlags value
///     Refer to vfs.Error for details on what causes vfs errors
///
fn handleOpen(path_ptr: usize, path_len: usize, flags: usize, args: usize, ignored: usize) Error!usize {
    _ = ignored;
    const current_task = scheduler.current_task;
    if (!current_task.hasFreeVFSHandle()) {
        return Error.NoMoreFSHandles;
    }

    // Fetch the open arguments from user/kernel memory
    var open_args: vfs.OpenArgs = if (args == 0) .{} else blk: {
        const data = try getData(args, @sizeOf(vfs.OpenArgs));
        defer if (!current_task.kernel) allocator.free(data);
        break :blk std.mem.bytesAsValue(vfs.OpenArgs, data[0..@sizeOf(vfs.OpenArgs)]).*;
    };
    // The symlink target could refer to a location in user memory so convert that too
    if (open_args.symlink_target) |target| {
        open_args.symlink_target = try getData(@ptrToInt(target.ptr), target.len);
    }
    defer if (!current_task.kernel) if (open_args.symlink_target) |target| allocator.free(target);

    const open_flags = std.meta.intToEnum(vfs.OpenFlags, flags) catch return Error.InvalidFlags;
    const path = try getData(path_ptr, path_len);
    defer if (!current_task.kernel) allocator.free(path);

    const node = try vfs.open(path, true, open_flags, open_args);
    errdefer vfs.close(node.*);
    return (try current_task.addVFSHandle(node)) orelse panic(null, "Failed to add a VFS handle to current_task\n", .{});
}

/// Read data from an open vfs file
///
/// Arguments:
///     node_handle: usize  - The file handle returned from the open syscall
///     buff_ptr: usize `   - The user/kernel address of the buffer to put the read data in
///     buff_len: usize     - The size of the buffer
///     ignored1: usize     - Ignored
///     ignored2: usize     - Ignored
///
/// Return: usize
///     The number of bytes read and put into the buffer
///
/// Error:
///     OutOfBounds         - The node handle is outside of the maximum per process
///     TooBig              - The buffer is bigger than what a user process is allowed to give the kernel
///     NotAFile            - The handle does not correspond to a file
///     Refer to vfs.FileNode.read and vmm.VirtualMemoryManager.copyData for details on what causes other errors
///
fn handleRead(node_handle: usize, buff_ptr: usize, buff_len: usize, ignored1: usize, ignored2: usize) Error!usize {
    _ = ignored1;
    _ = ignored2;
    if (node_handle >= task.VFS_HANDLES_PER_PROCESS)
        return error.OutOfBounds;
    const real_handle = @intCast(task.Handle, node_handle);
    if (buff_len > USER_MAX_DATA_LEN) {
        return Error.TooBig;
    }

    const current_task = scheduler.current_task;
    const node_opt = current_task.getVFSHandle(real_handle) catch panic(@errorReturnTrace(), "Failed to get VFS node for handle {}\n", .{real_handle});
    if (node_opt) |node| {
        const file = switch (node.*) {
            .File => |*f| f,
            else => return Error.NotAFile,
        };
        var buff = if (current_task.kernel) @intToPtr([*]u8, buff_ptr)[0..buff_len] else try allocator.alloc(u8, buff_len);
        defer if (!current_task.kernel) allocator.free(buff);

        const bytes_read = try file.read(buff);
        // TODO: A more performant method would be mapping in the user memory and using that directly. Then we wouldn't need to allocate or copy the buffer
        if (!current_task.kernel) try vmm.kernel_vmm.copyData(current_task.vmm, true, buff, buff_ptr);
        return bytes_read;
    }

    return Error.NotOpened;
}

/// Write data from to open vfs file
///
/// Arguments:
///     node_handle: usize  - The file handle returned from the open syscall
///     buff_ptr: usize `   - The user/kernel address of the buffer containing the data to write
///     buff_len: usize     - The size of the buffer
///     ignored1: usize     - Ignored
///     ignored2: usize     - Ignored
///
/// Return: usize
///     The number of bytes written
///
/// Error:
///     OutOfBounds         - The node handle is outside of the maximum per process
///     TooBig              - The buffer is bigger than what a user process is allowed to give the kernel
///     NotAFile            - The handle does not correspond to a file
///     Refer to vfs.FileNode.read and vmm.VirtualMemoryManager.copyData for details on what causes other errors
///
fn handleWrite(node_handle: usize, buff_ptr: usize, buff_len: usize, ignored1: usize, ignored2: usize) Error!usize {
    _ = ignored1;
    _ = ignored2;
    if (node_handle >= task.VFS_HANDLES_PER_PROCESS)
        return error.OutOfBounds;
    const real_handle = @intCast(task.Handle, node_handle);

    const current_task = scheduler.current_task;
    const node_opt = current_task.getVFSHandle(real_handle) catch panic(@errorReturnTrace(), "Failed to get VFS node for handle {}\n", .{real_handle});
    if (node_opt) |node| {
        const file = switch (node.*) {
            .File => |f| f,
            else => return Error.NotAFile,
        };

        // TODO: A more performant method would be mapping in the user memory and using that directly. Then we wouldn't need to allocate or copy the buffer
        var buff = try getData(buff_ptr, buff_len);
        defer if (!current_task.kernel) allocator.free(buff);
        return try file.write(buff);
    }

    return Error.NotOpened;
}

///
/// Close an open vfs node. What it means to "close" depends on the underlying file system, but often it will cause the file to be committed to disk or for a network socket to be closed
///
/// Arguments:
///     node_handle: usize  - The handle to close
///     ignored1..4: usize  - Ignored
///
/// Return: void
///
/// Error:
///     OutOfBounds         - The node handle is outside of the maximum per process
///     NotOpened           - The node handle hasn't been opened
fn handleClose(node_handle: usize, ignored1: usize, ignored2: usize, ignored3: usize, ignored4: usize) Error!usize {
    _ = ignored1;
    _ = ignored2;
    _ = ignored3;
    _ = ignored4;
    if (node_handle >= task.VFS_HANDLES_PER_PROCESS)
        return error.OutOfBounds;
    const real_handle = @intCast(task.Handle, node_handle);
    const current_task = scheduler.current_task;
    const node_opt = current_task.getVFSHandle(real_handle) catch panic(@errorReturnTrace(), "Failed to get VFS node for handle {}\n", .{real_handle});
    if (node_opt) |node| {
        current_task.clearVFSHandle(real_handle) catch |e| return switch (e) {
            error.VFSHandleNotSet, error.OutOfBounds => Error.NotOpened,
        };
        switch (node.*) {
            .File => |f| f.close(),
            .Dir => |d| d.close(),
            .Symlink => |s| s.close(),
        }
    }
    return Error.NotOpened;
}

pub fn handleTest1(arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize {
    // Suppress unused variable warnings
    _ = arg1;
    _ = arg2;
    _ = arg3;
    _ = arg4;
    _ = arg5;
    return 0;
}

pub fn handleTest2(arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize {
    return arg1 + arg2 + arg3 + arg4 + arg5;
}

pub fn handleTest3(arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize {
    // Suppress unused variable warnings
    _ = arg1;
    _ = arg2;
    _ = arg3;
    _ = arg4;
    _ = arg5;
    return std.mem.Allocator.Error.OutOfMemory;
}

fn testInitMem(comptime num_vmm_entries: usize, alloc: std.mem.Allocator, map_all: bool) !std.heap.FixedBufferAllocator {
    // handleOpen requires that the name passed is mapped in the VMM
    // Allocate them within a buffer so we know the start and end address to give to the VMM
    var buffer = try alloc.alloc(u8, num_vmm_entries * vmm.BLOCK_SIZE);
    var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(buffer[0..]);

    vmm.kernel_vmm = try vmm.VirtualMemoryManager(arch.VmmPayload).init(@ptrToInt(fixed_buffer_allocator.buffer.ptr), @ptrToInt(fixed_buffer_allocator.buffer.ptr) + buffer.len, alloc, arch.VMM_MAPPER, arch.KERNEL_VMM_PAYLOAD);
    // The PMM is required as well
    const mem_profile = mem.MemProfile{
        .vaddr_end = undefined,
        .vaddr_start = undefined,
        .physaddr_start = undefined,
        .physaddr_end = undefined,
        .mem_kb = num_vmm_entries * vmm.BLOCK_SIZE / 1024,
        .fixed_allocator = undefined,
        .virtual_reserved = &[_]mem.Map{},
        .physical_reserved = &[_]mem.Range{},
        .modules = &[_]mem.Module{},
    };
    pmm.init(&mem_profile, alloc);
    // Set the whole VMM space as mapped so all address within the buffer allocator will be considered valid
    if (map_all) _ = try vmm.kernel_vmm.alloc(num_vmm_entries, null, .{ .kernel = true, .writable = true, .cachable = true });
    return fixed_buffer_allocator;
}

fn testDeinitMem(alloc: std.mem.Allocator, buffer_allocator: std.heap.FixedBufferAllocator) void {
    alloc.free(buffer_allocator.buffer);
    vmm.kernel_vmm.deinit();
    pmm.deinit();
}

test "getHandler" {
    try std.testing.expectEqual(Syscall.Test1.getHandler(), handleTest1);
    try std.testing.expectEqual(Syscall.Test2.getHandler(), handleTest2);
    try std.testing.expectEqual(Syscall.Test3.getHandler(), handleTest3);
    try std.testing.expectEqual(Syscall.Open.getHandler(), handleOpen);
    try std.testing.expectEqual(Syscall.Close.getHandler(), handleClose);
    try std.testing.expectEqual(Syscall.Read.getHandler(), handleRead);
    try std.testing.expectEqual(Syscall.Write.getHandler(), handleWrite);
}

test "handle basic functionality" {
    try std.testing.expectEqual(@as(usize, 0), try handle(.Test1, 0, 0, 0, 0, 0));
    try std.testing.expectEqual(@as(usize, 1 + 2 + 3 + 4 + 5), try handle(.Test2, 1, 2, 3, 4, 5));
    try std.testing.expectError(Error.OutOfMemory, handle(.Test3, 0, 0, 0, 0, 0));
}

test "handleOpen" {
    allocator = std.testing.allocator;
    var testfs = try vfs.testInitFs(allocator);
    defer allocator.destroy(testfs);
    defer testfs.deinit();

    testfs.instance = 1;
    try vfs.setRoot(testfs.tree.val);

    scheduler.current_task = try task.Task.create(0, true, undefined, allocator);
    defer scheduler.current_task.destroy(allocator);
    var current_task = scheduler.current_task;

    // Creating a file
    const name1 = "/abc.txt";
    var test_handle = @intCast(task.Handle, try handleOpen(@ptrToInt(name1), name1.len, @enumToInt(vfs.OpenFlags.CREATE_FILE), 0, undefined));
    var test_node = (try current_task.getVFSHandle(test_handle)).?;
    try testing.expectEqual(testfs.tree.children.items.len, 1);
    var tree = testfs.tree.children.items[0];
    try testing.expect(tree.val.isFile() and test_node.isFile());
    try testing.expectEqual(&test_node.File, &tree.val.File);
    try testing.expect(std.mem.eql(u8, tree.name, "abc.txt"));
    try testing.expectEqual(tree.data, null);
    try testing.expectEqual(tree.children.items.len, 0);

    // Creating a dir
    const name2 = "/def";
    test_handle = @intCast(task.Handle, try handleOpen(@ptrToInt(name2), name2.len, @enumToInt(vfs.OpenFlags.CREATE_DIR), 0, undefined));
    test_node = (try current_task.getVFSHandle(test_handle)).?;
    try testing.expectEqual(testfs.tree.children.items.len, 2);
    tree = testfs.tree.children.items[1];
    try testing.expect(tree.val.isDir() and test_node.isDir());
    try testing.expectEqual(&test_node.Dir, &tree.val.Dir);
    try testing.expect(std.mem.eql(u8, tree.name, "def"));
    try testing.expectEqual(tree.data, null);
    try testing.expectEqual(tree.children.items.len, 0);

    // Creating a file under a new dir
    const name3 = "/def/ghi.zig";
    test_handle = @intCast(task.Handle, try handleOpen(@ptrToInt(name3), name3.len, @enumToInt(vfs.OpenFlags.CREATE_FILE), 0, undefined));
    test_node = (try current_task.getVFSHandle(test_handle)).?;
    try testing.expectEqual(testfs.tree.children.items[1].children.items.len, 1);
    tree = testfs.tree.children.items[1].children.items[0];
    try testing.expect(tree.val.isFile() and test_node.isFile());
    try testing.expectEqual(&test_node.File, &tree.val.File);
    try testing.expect(std.mem.eql(u8, tree.name, "ghi.zig"));
    try testing.expectEqual(tree.data, null);
    try testing.expectEqual(tree.children.items.len, 0);

    // Opening an existing file
    test_handle = @intCast(task.Handle, try handleOpen(@ptrToInt(name3), name3.len, @enumToInt(vfs.OpenFlags.NO_CREATION), 0, undefined));
    test_node = (try current_task.getVFSHandle(test_handle)).?;
    try testing.expectEqual(testfs.tree.children.items[1].children.items.len, 1);
    try testing.expect(test_node.isFile());
    try testing.expectEqual(&test_node.File, &tree.val.File);
}

test "handleRead" {
    allocator = std.testing.allocator;
    var testfs = try vfs.testInitFs(allocator);
    defer allocator.destroy(testfs);
    defer testfs.deinit();

    testfs.instance = 1;
    try vfs.setRoot(testfs.tree.val);

    vmm.kernel_vmm = try vmm.VirtualMemoryManager(arch.VmmPayload).init(0, 1024, allocator, arch.VMM_MAPPER, arch.KERNEL_VMM_PAYLOAD);
    defer vmm.kernel_vmm.deinit();
    scheduler.current_task = try task.Task.create(0, true, &vmm.kernel_vmm, allocator);
    defer scheduler.current_task.destroy(allocator);
    _ = scheduler.current_task;

    const test_file_path = "/foo.txt";
    var test_file = @intCast(task.Handle, try handleOpen(@ptrToInt(test_file_path), test_file_path.len, @enumToInt(vfs.OpenFlags.CREATE_FILE), 0, undefined));
    var f_data = &testfs.tree.children.items[0].data;
    var str = "test123";
    f_data.* = try testing.allocator.dupe(u8, str);

    var buffer: [str.len]u8 = undefined;
    {
        const length = try handleRead(test_file, @ptrToInt(&buffer[0]), buffer.len, 0, undefined);
        try testing.expect(std.mem.eql(u8, str, buffer[0..length]));
    }

    {
        const length = try handleRead(test_file, @ptrToInt(&buffer[0]), buffer.len + 1, 0, undefined);
        try testing.expect(std.mem.eql(u8, str, buffer[0..length]));
    }

    {
        const length = try handleRead(test_file, @ptrToInt(&buffer[0]), buffer.len + 3, 0, undefined);
        try testing.expect(std.mem.eql(u8, str, buffer[0..length]));
    }

    {
        const length = try handleRead(test_file, @ptrToInt(&buffer[0]), buffer.len - 1, 0, undefined);
        try testing.expect(std.mem.eql(u8, str[0 .. str.len - 1], buffer[0..length]));
    }

    {
        const length = try handleRead(test_file, @ptrToInt(&buffer[0]), 0, 0, undefined);
        try testing.expect(std.mem.eql(u8, str[0..0], buffer[0..length]));
    }
    // Try reading from a symlink
    const args = vfs.OpenArgs{ .symlink_target = test_file_path };
    var test_link = @intCast(task.Handle, try handleOpen(@ptrToInt("/link"), "/link".len, @enumToInt(vfs.OpenFlags.CREATE_SYMLINK), @ptrToInt(&args), undefined));
    {
        const length = try handleRead(test_link, @ptrToInt(&buffer[0]), buffer.len, 0, undefined);
        try testing.expect(std.mem.eql(u8, str[0..str.len], buffer[0..length]));
    }
}

test "handleOpen errors" {
    allocator = std.testing.allocator;
    var testfs = try vfs.testInitFs(allocator);
    {
        defer allocator.destroy(testfs);
        defer testfs.deinit();

        testfs.instance = 1;
        try vfs.setRoot(testfs.tree.val);

        // The data we pass to handleOpen needs to be mapped within the VMM, so we need to know their address
        // Allocating the data within a fixed buffer allocator is the best way to know the address of the data
        var fixed_buffer_allocator = try testInitMem(3, allocator, false);
        var buffer_allocator = fixed_buffer_allocator.allocator();
        defer testDeinitMem(allocator, fixed_buffer_allocator);

        scheduler.current_task = try task.Task.create(0, true, &vmm.kernel_vmm, allocator);
        defer scheduler.current_task.destroy(allocator);

        // Check opening with no free file handles left
        const free_handles = scheduler.current_task.file_handles.num_free_entries;
        scheduler.current_task.file_handles.num_free_entries = 0;
        try testing.expectError(Error.NoMoreFSHandles, handleOpen(0, 0, 0, 0, 0));
        scheduler.current_task.file_handles.num_free_entries = free_handles;

        // Using a path that is too long
        scheduler.current_task.kernel = false;
        try testing.expectError(Error.TooBig, handleOpen(0, USER_MAX_DATA_LEN + 1, 0, 0, 0));

        // Unallocated user address
        const test_alloc = try buffer_allocator.alloc(u8, 1);
        // The kernel VMM and task VMM need to have their buffers mapped, so we'll temporarily use the buffer allocator since it operates within a known address space
        allocator = buffer_allocator;
        std.debug.print("test_alloc: {}, vmm start: {}, vmm end: {}\n", .{ @ptrToInt(test_alloc.ptr), vmm.kernel_vmm.start, vmm.kernel_vmm.end });
        try testing.expectError(Error.NotAllocated, handleOpen(@ptrToInt(test_alloc.ptr), 1, 0, 0, 0));
        allocator = std.testing.allocator;

        // Unallocated kernel address
        scheduler.current_task.kernel = true;
        try testing.expectError(Error.NotAllocated, handleOpen(@ptrToInt(test_alloc.ptr), 1, 0, 0, 0));

        // Invalid flag enum value
        try testing.expectError(Error.InvalidFlags, handleOpen(@ptrToInt(test_alloc.ptr), 1, 999, 0, 0));
    }
    try testing.expect(!testing.allocator_instance.detectLeaks());
}
