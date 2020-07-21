const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const builtin = @import("builtin");
const is_test = builtin.is_test;
const build_options = @import("build_options");
const mock_path = build_options.mock_path;
const arch = @import("arch.zig").internals;
const log = if (is_test) @import(mock_path ++ "log_mock.zig") else @import("log.zig");
const panic = if (is_test) @import(mock_path ++ "panic_mock.zig").panic else @import("panic.zig").panic;
const ComptimeBitmap = @import("bitmap.zig").ComptimeBitmap;
const Allocator = std.mem.Allocator;

/// The kernels main stack start as this is used to check for if the task being destroyed is this stack
/// as we cannot deallocate this.
extern var KERNEL_STACK_START: *u32;

/// The function type for the entry point.
const EntryPointFn = fn () void;

/// The bitmap type for the PIDs
const PidBitmap = if (is_test) ComptimeBitmap(u128) else ComptimeBitmap(u1024);

/// The list of PIDs that have been allocated.
var all_pids: PidBitmap = brk: {
    var pids = PidBitmap.init();
    // Set the first PID as this is for the current task running, init 0
    _ = pids.setFirstFree() orelse unreachable;
    break :brk pids;
};

/// The task control block for storing all the information needed to save and restore a task.
pub const Task = struct {
    const Self = @This();

    /// The unique task identifier
    pid: PidBitmap.IndexType,

    /// Pointer to the stack for the task. This will be allocated on initialisation.
    stack: []u32,

    /// The current stack pointer into the stack.
    stack_pointer: usize,

    ///
    /// Create a task. This will allocate a PID and the stack. The stack will be set up as a
    /// kernel task. As this is a new task, the stack will need to be initialised with the CPU
    /// state as described in arch.CpuState struct.
    ///
    /// Arguments:
    ///     IN entry_point: EntryPointFn - The entry point into the task. This must be a function.
    ///     IN allocator: *Allocator     - The allocator for allocating memory for a task.
    ///
    /// Return: *Task
    ///     Pointer to an allocated task. This will then need to be added to the task queue.
    ///
    /// Error: Allocator.Error
    ///     OutOfMemory - If there is no more memory to allocate. Any memory or PID allocated will
    ///                   be freed on return.
    ///
    pub fn create(entry_point: EntryPointFn, allocator: *Allocator) Allocator.Error!*Task {
        var task = try allocator.create(Task);
        errdefer allocator.destroy(task);

        task.pid = allocatePid();
        errdefer freePid(task.pid);

        const task_stack = try arch.initTaskStack(@ptrToInt(entry_point), allocator);
        task.stack = task_stack.stack;
        task.stack_pointer = task_stack.pointer;

        return task;
    }

    ///
    /// Destroy the task. This will release the allocated PID and free the stack and self.
    ///
    /// Arguments:
    ///     IN/OUT self: *Self - The pointer to self.
    ///
    pub fn destroy(self: *Self, allocator: *Allocator) void {
        freePid(self.pid);
        // We need to check that the the stack has been allocated as task 0 (init) won't have a
        // stack allocated as this in the linker script
        if (@ptrToInt(self.stack.ptr) != @ptrToInt(&KERNEL_STACK_START)) {
            allocator.free(self.stack);
        }
        allocator.destroy(self);
    }
};

///
/// Allocate a process identifier. If out of PIDs, then will panic. Is this occurs, will need to
/// increase the bitmap.
///
/// Return: u32
///     A new PID.
///
fn allocatePid() PidBitmap.IndexType {
    return all_pids.setFirstFree() orelse panic(@errorReturnTrace(), "Out of PIDs\n", .{});
}

///
/// Free an allocated PID. One must be allocated to be freed. If one wasn't allocated will panic.
///
/// Arguments:
///     IN pid: u32 - The PID to free.
///
fn freePid(pid: PidBitmap.IndexType) void {
    if (!all_pids.isSet(pid)) {
        panic(@errorReturnTrace(), "PID {} not allocated\n", .{pid});
    }
    all_pids.clearEntry(pid);
}

// For testing the errdefer
const FailingAllocator = std.testing.FailingAllocator;
const testing_allocator = &std.testing.base_allocator_instance.allocator;

fn test_fn1() void {}

test "create out of memory for task" {
    // Set the global allocator
    var fa = FailingAllocator.init(testing_allocator, 0);

    expectError(error.OutOfMemory, Task.create(test_fn1, &fa.allocator));

    // Make sure any memory allocated is freed
    expectEqual(fa.allocated_bytes, fa.freed_bytes);

    // Make sure no PIDs were allocated
    expectEqual(all_pids.bitmap, 1);
}

test "create out of memory for stack" {
    // Set the global allocator
    var fa = FailingAllocator.init(testing_allocator, 1);

    expectError(error.OutOfMemory, Task.create(test_fn1, &fa.allocator));

    // Make sure any memory allocated is freed
    expectEqual(fa.allocated_bytes, fa.freed_bytes);

    // Make sure no PIDs were allocated
    expectEqual(all_pids.bitmap, 1);
}

test "create expected setup" {
    var task = try Task.create(test_fn1, std.testing.allocator);
    defer task.destroy(std.testing.allocator);

    // Will allocate the first PID 1, 0 will always be allocated
    expectEqual(task.pid, 1);
}

test "destroy cleans up" {
    // This used the leak detector allocator in testing
    // So if any alloc were not freed, this will fail the test
    var fa = FailingAllocator.init(testing_allocator, 2);

    var task = try Task.create(test_fn1, &fa.allocator);

    task.destroy(&fa.allocator);

    // Make sure any memory allocated is freed
    expectEqual(fa.allocated_bytes, fa.freed_bytes);

    // All PIDs were freed
    expectEqual(all_pids.bitmap, 1);
}

test "Multiple create" {
    var task1 = try Task.create(test_fn1, std.testing.allocator);
    var task2 = try Task.create(test_fn1, std.testing.allocator);

    expectEqual(task1.pid, 1);
    expectEqual(task2.pid, 2);
    expectEqual(all_pids.bitmap, 7);

    task1.destroy(std.testing.allocator);

    expectEqual(all_pids.bitmap, 5);

    var task3 = try Task.create(test_fn1, std.testing.allocator);

    expectEqual(task3.pid, 1);
    expectEqual(all_pids.bitmap, 7);

    task2.destroy(std.testing.allocator);
    task3.destroy(std.testing.allocator);
}

test "allocatePid and freePid" {
    expectEqual(all_pids.bitmap, 1);

    var i: usize = 1;
    while (i < PidBitmap.NUM_ENTRIES) : (i += 1) {
        expectEqual(i, allocatePid());
    }

    expectEqual(all_pids.bitmap, PidBitmap.BITMAP_FULL);

    i = 0;
    while (i < PidBitmap.NUM_ENTRIES) : (i += 1) {
        freePid(@truncate(PidBitmap.IndexType, i));
    }

    expectEqual(all_pids.bitmap, 0);
}
