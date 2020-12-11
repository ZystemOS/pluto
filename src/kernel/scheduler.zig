const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const assert = std.debug.assert;
const log = std.log.scoped(.scheduler);
const builtin = @import("builtin");
const is_test = builtin.is_test;
const build_options = @import("build_options");
const mock_path = build_options.mock_path;
const arch = @import("arch.zig").internals;
const panic = @import("panic.zig").panic;
const task = @import("task.zig");
const vmm = @import("vmm.zig");
const mem = @import("mem.zig");
const fs = @import("filesystem/vfs.zig");
const bitmap = @import("bitmap.zig");
const Task = task.Task;
const EntryPoint = task.EntryPoint;
const Allocator = std.mem.Allocator;
const TailQueue = std.TailQueue;

/// The default stack size of a task. Currently this is set to a page size.
const STACK_SIZE: u32 = arch.MEMORY_BLOCK_SIZE / @sizeOf(usize);

/// Pointer to the start of the main kernel stack
extern var KERNEL_STACK_START: []u32;
extern var KERNEL_STACK_END: []u32;

/// The current task running
pub var current_task: *Task = undefined;

/// Array list of all runnable tasks
var tasks: TailQueue(*Task) = undefined;

/// Whether the scheduler is allowed to switch tasks.
var can_switch: bool = true;

///
/// The idle task that just halts the CPU but the CPU can still handle interrupts.
///
fn idle() noreturn {
    arch.spinWait();
}

pub fn taskSwitching(enabled: bool) void {
    can_switch = enabled;
}

///
/// Round robin. This will first save the the current tasks stack pointer, then will pick the next
/// task to be run from the queue. It will add the current task to the end of the queue and pop the
/// next task from the front as set this as the current task. Then will return the stack pointer
/// of the next task to be loaded into the stack register to load the next task stack to pop off
/// its state. Interrupts are assumed disabled.
///
/// Argument:
///     IN ctx: *arch.CpuState - Pointer to the exception context containing the contents
///                              of the registers at the time of a exception.
///
/// Return: usize
///     The new stack pointer to the next stack of the next task.
///
pub fn pickNextTask(ctx: *arch.CpuState) usize {
    switch (build_options.test_mode) {
        .Scheduler => if (!current_task.kernel) {
            if (!arch.runtimeTestCheckUserTaskState(ctx)) {
                panic(null, "User task state check failed\n", .{});
            }
        },
        else => {},
    }
    // Save the stack pointer from old task
    current_task.stack_pointer = @ptrToInt(ctx);

    // If we can't switch, then continue with the current task
    if (!can_switch) {
        return current_task.stack_pointer;
    }

    // Pick the next task
    // If there isn't one, then just return the same task
    if (tasks.pop()) |new_task_node| {
        // Get the next task
        const next_task = new_task_node.data;

        // Move some pointers to don't need to allocate memory, speeds things up
        new_task_node.data = current_task;
        new_task_node.prev = null;
        new_task_node.next = null;

        // Add the 'current_task' node to the end of the queue
        tasks.prepend(new_task_node);

        current_task = next_task;
    }

    // Context switch in the interrupt stub handler which will pop the next task state off the
    // stack
    return current_task.stack_pointer;
}

///
/// Create a new task and add it to the scheduling queue. No locking.
///
/// Arguments:
///     IN entry_point: EntryPoint - The entry point into the task. This must be a function.
///
/// Error: Allocator.Error
///     OutOfMemory - If there isn't enough memory for the a task/stack. Any memory allocated will
///                   be freed on return.
///
pub fn scheduleTask(new_task: *Task, allocator: *Allocator) Allocator.Error!void {
    var task_node = try allocator.create(TailQueue(*Task).Node);
    task_node.* = .{ .data = new_task };
    tasks.prepend(task_node);
}

///
/// Initialise the scheduler. This will set up the current task to the code that is currently
/// running. So if there is a task switch before kmain can finish, can continue when switched back.
/// This will set the stack to KERNEL_STACK_START from the linker stript. This will also create the
/// idle task for when there is no more tasks to run.
///
/// Arguments:
///     IN allocator: *Allocator - The allocator to use when needing to allocate memory.
///     IN mem_profile: *const mem.MemProfile - The system's memory profile used for runtime testing.
///
/// Error: Allocator.Error
///     OutOfMemory - There is no more memory. Any memory allocated will be freed on return.
///
pub fn init(allocator: *Allocator, mem_profile: *const mem.MemProfile) Allocator.Error!void {
    // TODO: Maybe move the task init here?
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});

    // Init the task list for round robin
    tasks = TailQueue(*Task){};

    // Set up the init task to continue execution
    current_task = try allocator.create(Task);
    errdefer allocator.destroy(current_task);
    // PID 0
    current_task.pid = 0;
    const kernel_stack_size = @ptrToInt(&KERNEL_STACK_END) - @ptrToInt(&KERNEL_STACK_START);
    current_task.kernel_stack = @intToPtr([*]u32, @ptrToInt(&KERNEL_STACK_START))[0..kernel_stack_size];
    current_task.user_stack = &[_]usize{};
    current_task.kernel = true;
    // TODO: Use Task.create instead of setting it up manually
    current_task.file_handles = try bitmap.Bitmap(usize).init(task.VFS_HANDLES_PER_PROCESS, allocator);
    current_task.file_handle_mapping = std.hash_map.AutoHashMap(task.Handle, *fs.Node).init(allocator);
    // ESP will be saved on next schedule

    // Run the runtime tests here
    switch (build_options.test_mode) {
        .Scheduler => runtimeTests(allocator, mem_profile),
        else => {},
    }

    // Create the idle task when there are no more tasks left
    var idle_task = try Task.create(@ptrToInt(idle), true, &vmm.kernel_vmm, allocator);
    errdefer idle_task.destroy(allocator);

    try scheduleTask(idle_task, allocator);
}

// For testing the errdefer
const FailingAllocator = std.testing.FailingAllocator;
const testing_allocator = &std.testing.base_allocator_instance.allocator;

fn test_fn1() void {}
fn test_fn2() void {}

var test_pid_counter: u7 = 1;

fn createTestTask(entry_point: EntryPoint, allocator: *Allocator, kernel: bool, task_vmm: *vmm.VirtualMemoryManager(u8)) Allocator.Error!*Task {
    var t = try allocator.create(Task);
    errdefer allocator.destroy(t);
    t.pid = test_pid_counter;
    // Just alloc something
    t.kernel_stack = try allocator.alloc(u32, 1);
    t.stack_pointer = 0;
    test_pid_counter += 1;
    return t;
}

fn destroyTestTask(self: *Task, allocator: *Allocator) void {
    if (@ptrToInt(self.kernel_stack.ptr) != @ptrToInt(&KERNEL_STACK_START)) {
        allocator.free(self.kernel_stack);
    }
    allocator.destroy(self);
}

test "pickNextTask" {
    var ctx: arch.CpuState = std.mem.zeroes(arch.CpuState);

    var allocator = std.testing.allocator;
    tasks = TailQueue(*Task){};

    // Set up a current task
    current_task = try allocator.create(Task);
    defer allocator.destroy(current_task);
    current_task.pid = 0;
    current_task.kernel_stack = @intToPtr([*]u32, @ptrToInt(&KERNEL_STACK_START))[0..4096];
    current_task.stack_pointer = @ptrToInt(&KERNEL_STACK_START);

    // Create two tasks and schedule them
    var test_fn1_task = try Task.create(@ptrToInt(test_fn1), true, undefined, allocator);
    defer test_fn1_task.destroy(allocator);
    try scheduleTask(test_fn1_task, allocator);

    var test_fn2_task = try Task.create(@ptrToInt(test_fn2), true, undefined, allocator);
    defer test_fn2_task.destroy(allocator);
    try scheduleTask(test_fn2_task, allocator);

    // Get the stack pointers of the created tasks
    const fn1_stack_pointer = test_fn1_task.stack_pointer;
    const fn2_stack_pointer = test_fn2_task.stack_pointer;

    expectEqual(pickNextTask(&ctx), fn1_stack_pointer);
    // The stack pointer of the re-added task should point to the context
    expectEqual(tasks.first.?.data.stack_pointer, @ptrToInt(&ctx));

    // Should be the PID of the next task
    expectEqual(current_task.pid, 1);

    expectEqual(pickNextTask(&ctx), fn2_stack_pointer);
    // The stack pointer of the re-added task should point to the context
    expectEqual(tasks.first.?.data.stack_pointer, @ptrToInt(&ctx));

    // Should be the PID of the next task
    expectEqual(current_task.pid, 2);

    expectEqual(pickNextTask(&ctx), @ptrToInt(&ctx));
    // The stack pointer of the re-added task should point to the context
    expectEqual(tasks.first.?.data.stack_pointer, @ptrToInt(&ctx));

    // Should be back tot he beginning
    expectEqual(current_task.pid, 0);

    // Reset the test pid
    test_pid_counter = 1;

    // Free the queue
    while (tasks.pop()) |elem| {
        allocator.destroy(elem);
    }
}

test "createNewTask add new task" {
    // Set the global allocator
    var allocator = std.testing.allocator;

    // Init the task list
    tasks = TailQueue(*Task){};

    var test_fn1_task = try Task.create(@ptrToInt(test_fn1), true, undefined, allocator);
    defer test_fn1_task.destroy(allocator);
    try scheduleTask(test_fn1_task, allocator);

    expectEqual(tasks.len, 1);

    // Free the memory
    allocator.destroy(tasks.first.?);
}

test "init" {
    var allocator = std.testing.allocator;

    try init(allocator, undefined);

    expectEqual(current_task.pid, 0);
    expectEqual(@ptrToInt(current_task.kernel_stack.ptr), @ptrToInt(&KERNEL_STACK_START));
    expectEqual(current_task.kernel_stack.len, @ptrToInt(&KERNEL_STACK_END) - @ptrToInt(&KERNEL_STACK_START));

    expectEqual(tasks.len, 1);

    // Free the tasks created
    current_task.destroy(allocator);
    while (tasks.pop()) |elem| {
        elem.data.destroy(allocator);
        allocator.destroy(elem);
    }
}

/// A volatile pointer used to control a loop outside the task. This is so to ensure a task switch
/// ocurred.
var is_set: *volatile bool = undefined;

///
/// The test task function.
///
fn task_function() noreturn {
    log.info("Switched\n", .{});
    is_set.* = false;
    while (true) {}
}

///
/// This tests that variables in registers and on the stack are preserved when a task switch
/// occurs. Also tests that a global volatile can be test in one task and be reacted to in another.
///
/// Arguments:
///     IN allocator: *Allocator - The allocator to use when needing to allocate memory.
///
fn rt_variable_preserved(allocator: *Allocator) void {
    // Create the memory for the boolean
    is_set = allocator.create(bool) catch unreachable;
    defer allocator.destroy(is_set);
    is_set.* = true;

    var test_task = Task.create(@ptrToInt(task_function), true, undefined, allocator) catch unreachable;
    scheduleTask(test_task, allocator) catch unreachable;
    // TODO: Need to add the ability to remove tasks

    var w: u32 = 0;
    var x: u32 = 1;
    var y: u32 = 2;
    var z: u32 = 3;

    while (is_set.*) {
        if (w != 0) {
            panic(@errorReturnTrace(), "FAILED: w not 0, but: {}\n", .{w});
        }
        if (x != 1) {
            panic(@errorReturnTrace(), "FAILED: x not 1, but: {}\n", .{x});
        }
        if (y != 2) {
            panic(@errorReturnTrace(), "FAILED: y not 2, but: {}\n", .{y});
        }
        if (z != 3) {
            panic(@errorReturnTrace(), "FAILED: z not 3, but: {}\n", .{z});
        }
    }
    // Make sure these are the same values
    if (w != 0) {
        panic(@errorReturnTrace(), "FAILED: w not 0, but: {}\n", .{w});
    }
    if (x != 1) {
        panic(@errorReturnTrace(), "FAILED: x not 1, but: {}\n", .{x});
    }
    if (y != 2) {
        panic(@errorReturnTrace(), "FAILED: y not 2, but: {}\n", .{y});
    }
    if (z != 3) {
        panic(@errorReturnTrace(), "FAILED: z not 3, but: {}\n", .{z});
    }

    log.info("SUCCESS: Scheduler variables preserved\n", .{});
}

///
/// Test the initialisation and running of a task running in user mode
///
/// Arguments:
///     IN allocator: *std.mem.Allocator - The allocator to use when intialising the task
///     IN mem_profile: mem.MemProfile - The system's memory profile. Determines the end address of the user task's VMM.
///
fn rt_user_task(allocator: *Allocator, mem_profile: *const mem.MemProfile) void {
    // 1. Create user VMM
    var task_vmm = allocator.create(vmm.VirtualMemoryManager(arch.VmmPayload)) catch |e| {
        panic(@errorReturnTrace(), "Failed to allocate user task VMM: {}\n", .{e});
    };
    task_vmm.* = vmm.VirtualMemoryManager(arch.VmmPayload).init(0, @ptrToInt(mem_profile.vaddr_start), allocator, arch.VMM_MAPPER, undefined) catch unreachable;
    // 2. Create user task. The code will be loaded at address 0
    var user_task = task.Task.create(0, false, task_vmm, allocator) catch |e| {
        panic(@errorReturnTrace(), "Failed to create user task: {}\n", .{e});
    };
    // 3. Read the user program file from the filesystem
    const user_program_file = fs.openFile("/user_program", .NO_CREATION) catch |e| {
        panic(@errorReturnTrace(), "Failed to open /user_program: {}\n", .{e});
    };
    defer user_program_file.close();
    var code: [1024]u8 = undefined;
    const code_len = user_program_file.read(code[0..1024]) catch |e| {
        panic(@errorReturnTrace(), "Failed to read user program file: {}\n", .{e});
    };
    // 4. Allocate space in the vmm for the user_program
    const code_start = task_vmm.alloc(std.mem.alignForward(code_len, vmm.BLOCK_SIZE) / vmm.BLOCK_SIZE, .{ .kernel = false, .writable = true, .cachable = true }) catch |e| {
        panic(@errorReturnTrace(), "Failed to allocate VMM memory for user program code: {}\n", .{e});
    } orelse panic(null, "User task VMM didn't allocate space for the user program\n", .{});
    if (code_start != 0) panic(null, "User program start address was {} instead of 0\n", .{code_start});
    // 5. Copy user_program code over
    vmm.kernel_vmm.copyData(task_vmm, code[0..code_len], code_start, true) catch |e| {
        panic(@errorReturnTrace(), "Failed to copy user code: {}\n", .{e});
    };
    // 6. Schedule it
    scheduleTask(user_task, allocator) catch |e| {
        panic(@errorReturnTrace(), "Failed to schedule the user task: {}\n", .{e});
    };
}

///
/// The scheduler runtime tests that will test the scheduling functionality.
///
/// Arguments:
///     IN allocator: *Allocator - The allocator to use when needing to allocate memory.
///     IN mem_profile: *const mem.MemProfile - The system's memory profile. Used to set up user task VMMs.
///
fn runtimeTests(allocator: *Allocator, mem_profile: *const mem.MemProfile) void {
    arch.enableInterrupts();
    rt_user_task(allocator, mem_profile);
    rt_variable_preserved(allocator);
    while (true) {}
}
