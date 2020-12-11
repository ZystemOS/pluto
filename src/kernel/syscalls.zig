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
const testing = std.testing;

var allocator: *std.mem.Allocator = undefined;

/// The maximum amount of data to allocate when copying user memory into kernel memory
pub const USER_MAX_DATA_LEN = 16 * 1024;

/// A compilation of all errors that syscall handlers could return.
pub const Error = error{
    OutOfMemory,
    NoMoreFSHandles,
    InvalidFlags,
    TooBig,
    NoSuchFileOrDir,
    NotADirectory,
    IsADirectory,
    IsAFile,
    NotAFile,
    NotAbsolutePath,
    NotOpened,
    NoSymlinkTarget,
    OutOfBounds,
    NotAllocated,
    AlreadyAllocated,
    PhysicalAlreadyAllocated,
    PhysicalVirtualMismatch,
    InvalidVirtAddresses,
    InvalidPhysAddresses,
    Unexpected,
};

comptime {
    // Make sure toErrorCode and fromErrorCode are synchronised, and that no errors share the same error code
    @setEvalBranchQuota(1000000);
    inline for (@typeInfo(Error).ErrorSet.?) |err| {
        const error_instance = @field(Error, err.name);
        if (fromErrorCode(toErrorCode(error_instance)) != error_instance) {
            @compileError("toErrorCode and fromErrorCode are not synchronised for syscall error '" ++ err.name ++ "'\n");
        }
        inline for (@typeInfo(Error).ErrorSet.?) |err2| {
            const error2_instance = @field(Error, err2.name);
            if (error_instance != error2_instance and toErrorCode(error_instance) == toErrorCode(error2_instance)) {
                @compileError("Syscall errors '" ++ err.name ++ "' and '" ++ err2.name ++ "' share the same error code\n");
            }
        }
    }
}

/// All implemented syscalls
pub const Syscall = enum {
    Open,
    Read,
    Write,
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
};

/// A function that can handle a syscall and return a result or an error
pub const Handler = fn (arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize;

pub fn init(alloc: *std.mem.Allocator) void {
    allocator = alloc;
}

///
/// Convert an error code to an instance of Error. The conversion must be synchronised with toErrorCode
///
/// Arguments:
///     IN code: usize - The erorr code to convert
///
/// Return: Error
///     The error corresponding to the error code
///
pub fn fromErrorCode(code: usize) Error {
    return switch (code) {
        1 => Error.OutOfMemory,
        2 => Error.NoMoreFSHandles,
        3 => Error.InvalidFlags,
        4 => Error.TooBig,
        5 => Error.NoSuchFileOrDir,
        6 => Error.NotADirectory,
        7 => Error.IsADirectory,
        8 => Error.IsAFile,
        9 => Error.NotAbsolutePath,
        10 => Error.NotOpened,
        11 => Error.NoSymlinkTarget,
        12 => Error.OutOfBounds,
        13 => Error.NotAllocated,
        14 => Error.NotAFile,
        15 => Error.AlreadyAllocated,
        16 => Error.PhysicalAlreadyAllocated,
        17 => Error.PhysicalVirtualMismatch,
        18 => Error.InvalidVirtAddresses,
        19 => Error.InvalidPhysAddresses,
        20 => Error.Unexpected,
        else => unreachable,
    };
}

///
/// Convert an instance of Error to an error code. The conversion must be synchronised with fromErrorCode
///
/// Arguments:
///     IN err: Error - The erorr to convert
///
/// Return: usize
///     The error code corresponding to the error
///
pub fn toErrorCode(err: Error) usize {
    return switch (err) {
        Error.OutOfMemory => 1,
        Error.NoMoreFSHandles => 2,
        Error.InvalidFlags => 3,
        Error.TooBig => 4,
        Error.NoSuchFileOrDir => 5,
        Error.NotADirectory => 6,
        Error.IsADirectory => 7,
        Error.IsAFile => 8,
        Error.NotAbsolutePath => 9,
        Error.NotOpened => 10,
        Error.NoSymlinkTarget => 11,
        Error.OutOfBounds => 12,
        Error.NotAllocated => 13,
        Error.NotAFile => 14,
        Error.AlreadyAllocated => 15,
        Error.PhysicalAlreadyAllocated => 16,
        Error.PhysicalVirtualMismatch => 17,
        Error.InvalidVirtAddresses => 18,
        Error.InvalidPhysAddresses => 19,
        Error.Unexpected => 20,
    };
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
///     Error.InvalidAddress - The address that the user task passed is invalid (not mapped, out of bounds etc.)
///
/// Return: []u8
///     The slice of data. Will be stack-allocated if the current task is kernel-level, otherwise will be heap-allocated
///
fn getData(ptr: usize, len: usize) Error![]u8 {
    if (scheduler.current_task.kernel) {
        return @intToPtr([*]u8, ptr)[0..len];
    } else {
        if (len > USER_MAX_DATA_LEN) {
            return Error.TooBig;
        }
        var buff = try allocator.alloc(u8, len);
        errdefer allocator.free(buff);
        try vmm.kernel_vmm.copyData(scheduler.current_task.vmm, buff, ptr, false);
        return buff;
    }
}

fn handleOpen(path_ptr: usize, path_len: usize, flags: usize, args: usize, ignored: usize) Error!usize {
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

    var node = try vfs.open(path, true, open_flags, open_args);
    return current_task.addVFSHandle(node) orelse panic(null, "Failed to add a VFS handle to current_task\n", .{});
}

fn handleRead(node_handle: usize, buff_ptr: usize, buff_len: usize, ignored1: usize, ignored2: usize) Error!usize {
    if (buff_len > USER_MAX_DATA_LEN) {
        return Error.TooBig;
    }

    const current_task = scheduler.current_task;
    const node_opt = current_task.getVFSHandle(node_handle) catch panic(@errorReturnTrace(), "Failed to get VFS node for handle {}\n", .{node_handle});
    if (node_opt) |node| {
        const file = switch (node.*) {
            .File => |*f| f,
            else => return Error.NotAFile,
        };
        var buff = if (current_task.kernel) @intToPtr([*]u8, buff_ptr)[0..buff_len] else try allocator.alloc(u8, buff_len);
        defer if (!current_task.kernel) allocator.free(buff);

        const bytes_read = try file.read(buff);
        // TODO: A more performant method would be mapping in the user memory and using that directly. Then we wouldn't need to allocate or copy the buffer
        if (!current_task.kernel) try vmm.kernel_vmm.copyData(current_task.vmm, buff, buff_ptr, true);
        return bytes_read;
    }

    return Error.NotOpened;
}

fn handleWrite(node_handle: usize, buff_ptr: usize, buff_len: usize, ignored1: usize, ignored2: usize) Error!usize {
    if (buff_len > USER_MAX_DATA_LEN) {
        return Error.TooBig;
    }

    const current_task = scheduler.current_task;
    const node_opt = current_task.getVFSHandle(node_handle) catch panic(@errorReturnTrace(), "Failed to get VFS node for handle {}\n", .{node_handle});
    if (node_opt) |node| {
        const file = switch (node.*) {
            .File => |f| f,
            else => return Error.NotAFile,
        };
        var buff = if (current_task.kernel) @intToPtr([*]u8, buff_ptr)[0..buff_len] else try allocator.alloc(u8, buff_len);
        defer if (!current_task.kernel) allocator.free(buff);

        // TODO: A more performant method would be mapping in the user memory and using that directly. Then we wouldn't need to allocate or copy the buffer
        if (!current_task.kernel) try vmm.kernel_vmm.copyData(current_task.vmm, buff, buff_ptr, false);
        const bytes_read = try file.read(buff);
        return bytes_read;
    }

    return Error.NotOpened;
}

fn handleClose(node_handle: usize, ignored1: usize, ignored2: usize, ignored3: usize, ignored4: usize) Error!usize {
    const current_task = scheduler.current_task;
    const node_opt = current_task.getVFSHandle(node_handle) catch panic(@errorReturnTrace(), "Failed to get VFS node for handle {}\n", .{node_handle});
    if (node_opt) |node| {
        //try node.close();
        current_task.clearVFSHandle(node_handle) catch |e| return switch (e) {
            error.VFSHandleNotSet, error.OutOfBounds => Error.NotOpened,
        };
    }
    return Error.NotOpened;
}

pub fn handleTest1(arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize {
    return 0;
}

pub fn handleTest2(arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize {
    return arg1 + arg2 + arg3 + arg4 + arg5;
}

pub fn handleTest3(arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) Error!usize {
    return std.mem.Allocator.Error.OutOfMemory;
}

test "getHandler" {
    std.testing.expectEqual(Syscall.Test1.getHandler(), handleTest1);
    std.testing.expectEqual(Syscall.Test2.getHandler(), handleTest2);
    std.testing.expectEqual(Syscall.Test3.getHandler(), handleTest3);
    std.testing.expectEqual(Syscall.Open.getHandler(), handleOpen);
    std.testing.expectEqual(Syscall.Close.getHandler(), handleClose);
    std.testing.expectEqual(Syscall.Read.getHandler(), handleRead);
    std.testing.expectEqual(Syscall.Write.getHandler(), handleWrite);
}

test "handle" {
    std.testing.expectEqual(@as(usize, 0), try handle(.Test1, 0, 0, 0, 0, 0));
    std.testing.expectEqual(@as(usize, 1 + 2 + 3 + 4 + 5), try handle(.Test2, 1, 2, 3, 4, 5));
    std.testing.expectError(Error.OutOfMemory, handle(.Test3, 0, 0, 0, 0, 0));
}

test "handleOpen" {
    allocator = std.testing.allocator;
    var testfs = try vfs.testInitFs(allocator);
    defer allocator.destroy(testfs);
    defer testfs.deinit();

    testfs.instance = 1;
    vfs.root = testfs.tree.val;

    scheduler.current_task = try task.Task.create(0, true, undefined, allocator);
    defer scheduler.current_task.destroy(allocator);
    var current_task = scheduler.current_task;

    // Creating a file
    const name1 = "/abc.txt";
    var test_handle = try handleOpen(@ptrToInt(name1), name1.len, @enumToInt(vfs.OpenFlags.CREATE_FILE), undefined, undefined);
    var test_node = (try current_task.getVFSHandle(test_handle)).?;
    testing.expectEqual(testfs.tree.children.items.len, 1);
    var tree = testfs.tree.children.items[0];
    testing.expect(tree.val.isFile() and test_node.isFile());
    testing.expectEqual(&test_node.File, &tree.val.File);
    testing.expect(std.mem.eql(u8, tree.name, "abc.txt"));
    testing.expectEqual(tree.data, null);
    testing.expectEqual(tree.children.items.len, 0);

    // Creating a dir
    const name2 = "/def";
    test_handle = try handleOpen(@ptrToInt(name2), name2.len, @enumToInt(vfs.OpenFlags.CREATE_DIR), undefined, undefined);
    test_node = (try current_task.getVFSHandle(test_handle)).?;
    testing.expectEqual(testfs.tree.children.items.len, 2);
    tree = testfs.tree.children.items[1];
    testing.expect(tree.val.isDir() and test_node.isDir());
    testing.expectEqual(&test_node.Dir, &tree.val.Dir);
    testing.expect(std.mem.eql(u8, tree.name, "def"));
    testing.expectEqual(tree.data, null);
    testing.expectEqual(tree.children.items.len, 0);

    // Creating a file under a new dir
    const name3 = "/def/ghi.zig";
    test_handle = try handleOpen(@ptrToInt(name3), name3.len, @enumToInt(vfs.OpenFlags.CREATE_FILE), undefined, undefined);
    test_node = (try current_task.getVFSHandle(test_handle)).?;
    testing.expectEqual(testfs.tree.children.items[1].children.items.len, 1);
    tree = testfs.tree.children.items[1].children.items[0];
    testing.expect(tree.val.isFile() and test_node.isFile());
    testing.expectEqual(&test_node.File, &tree.val.File);
    testing.expect(std.mem.eql(u8, tree.name, "ghi.zig"));
    testing.expectEqual(tree.data, null);
    testing.expectEqual(tree.children.items.len, 0);

    // Opening an existing file
    test_handle = try handleOpen(@ptrToInt(name3), name3.len, @enumToInt(vfs.OpenFlags.NO_CREATION), undefined, undefined);
    test_node = (try current_task.getVFSHandle(test_handle)).?;
    testing.expectEqual(testfs.tree.children.items[1].children.items.len, 1);
    testing.expect(test_node.isFile());
    testing.expectEqual(&test_node.File, &tree.val.File);
}

test "handleRead" {
    allocator = std.testing.allocator;
    var testfs = try vfs.testInitFs(allocator);
    defer allocator.destroy(testfs);
    defer testfs.deinit();

    testfs.instance = 1;
    vfs.root = testfs.tree.val;

    vmm.kernel_vmm = try vmm.VirtualMemoryManager(arch.VmmPayload).init(0, 1024, allocator, arch.VMM_MAPPER, arch.KERNEL_VMM_PAYLOAD);
    defer vmm.kernel_vmm.deinit();
    scheduler.current_task = try task.Task.create(0, true, &vmm.kernel_vmm, allocator);
    defer scheduler.current_task.destroy(allocator);
    var current_task = scheduler.current_task;

    var test_file = try handleOpen(@ptrToInt("/foo.txt"), "/foo.txt".len, @enumToInt(vfs.OpenFlags.CREATE_FILE), undefined, undefined);
    var f_data = &testfs.tree.children.items[0].data;
    var str = "test123";
    f_data.* = try std.mem.dupe(testing.allocator, u8, str);

    var buffer: [str.len]u8 = undefined;
    {
        const length = try handleRead(test_file, @ptrToInt(&buffer[0]), buffer.len, undefined, undefined);
        testing.expect(std.mem.eql(u8, str, buffer[0..length]));
    }

    {
        const length = try handleRead(test_file, @ptrToInt(&buffer[0]), buffer.len + 1, undefined, undefined);
        testing.expect(std.mem.eql(u8, str, buffer[0..length]));
    }

    {
        const length = try handleRead(test_file, @ptrToInt(&buffer[0]), buffer.len + 3, undefined, undefined);
        testing.expect(std.mem.eql(u8, str, buffer[0..length]));
    }

    {
        const length = try handleRead(test_file, @ptrToInt(&buffer[0]), buffer.len - 1, undefined, undefined);
        testing.expect(std.mem.eql(u8, str[0 .. str.len - 1], buffer[0..length]));
    }

    {
        const length = try handleRead(test_file, @ptrToInt(&buffer[0]), 0, undefined, undefined);
        testing.expect(std.mem.eql(u8, str[0..0], buffer[0..length]));
    }
    // Try reading from a symlink
    const args = vfs.OpenArgs{ .symlink_target = "/foo.txt" };
    var test_link = try handleOpen(@ptrToInt("/link"), "/link".len, @enumToInt(vfs.OpenFlags.CREATE_SYMLINK), @ptrToInt(&args), undefined);
    {
        const length = try handleRead(test_link, @ptrToInt(&buffer[0]), buffer.len, undefined, undefined);
        testing.expect(std.mem.eql(u8, str[0..str.len], buffer[0..length]));
    }
}
