const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const assert = std.debug.assert;
const log = std.log.scoped(.scheduler);
const builtin = @import("builtin");
const is_test = builtin.is_test;
const build_options = @import("build_options");
const arch = if (is_test) @import("arch_mock") else @import("arch");
const panic = @import("panic.zig").panic;
const task = @import("task.zig");
const vmm = @import("vmm.zig");
const mem = @import("mem.zig");
const fs = @import("filesystem/vfs.zig");
const elf = @import("elf.zig");
const pmm = @import("pmm.zig");
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
///     IN allocator: Allocator - The allocator to use
///
/// Error: Allocator.Error
///     OutOfMemory - If there isn't enough memory for the a task/stack. Any memory allocated will
///                   be freed on return.
///
pub fn scheduleTask(new_task: *Task, allocator: Allocator) Allocator.Error!void {
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
///     IN allocator: Allocator - The allocator to use when needing to allocate memory.
///     IN mem_profile: *const mem.MemProfile - The system's memory profile used for runtime testing.
///
/// Error: Allocator.Error
///     OutOfMemory - There is no more memory. Any memory allocated will be freed on return.
///
pub fn init(allocator: Allocator, mem_profile: *const mem.MemProfile) Allocator.Error!void {
    // TODO: Maybe move the task init here?
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});

    // Init the task list for round robin
    tasks = TailQueue(*Task){};

    // Set up the init task to continue execution.
    // The kernel stack will point to the stack section rather than the heap
    current_task = try Task.create(0, true, &vmm.kernel_vmm, allocator, false);
    errdefer allocator.destroy(current_task);

    const kernel_stack_size = @ptrToInt(&KERNEL_STACK_END) - @ptrToInt(&KERNEL_STACK_START);
    current_task.kernel_stack = @intToPtr([*]u32, @ptrToInt(&KERNEL_STACK_START))[0..kernel_stack_size];
    // ESP will be saved on next schedule

    // Run the runtime tests here
    switch (build_options.test_mode) {
        .Scheduler => runtimeTests(allocator, mem_profile),
        else => {},
    }

    // Create the idle task when there are no more tasks left
    var idle_task = try Task.create(@ptrToInt(idle), true, &vmm.kernel_vmm, allocator, true);
    errdefer idle_task.destroy(allocator);

    try scheduleTask(idle_task, allocator);
}

// For testing the errdefer
const FailingAllocator = std.testing.FailingAllocator;
const testing_allocator = &std.testing.base_allocator_instance.allocator;

fn test_fn1() void {}
fn test_fn2() void {}

var test_pid_counter: u7 = 1;

fn createTestTask(allocator: Allocator) Allocator.Error!*Task {
    var t = try allocator.create(Task);
    errdefer allocator.destroy(t);
    t.pid = test_pid_counter;
    // Just alloc something
    t.kernel_stack = try allocator.alloc(u32, 1);
    t.stack_pointer = 0;
    test_pid_counter += 1;
    return t;
}

fn destroyTestTask(self: *Task, allocator: Allocator) void {
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
    var first = try Task.create(0, true, &vmm.kernel_vmm, allocator, false);
    // We use an intermediary variable to avoid a double-free.
    // Deferring freeing current_task will free whatever current_task points to at the end
    defer first.destroy(allocator);
    current_task = first;
    current_task.pid = 0;
    current_task.kernel_stack = @intToPtr([*]u32, @ptrToInt(&KERNEL_STACK_START))[0..4096];
    current_task.stack_pointer = @ptrToInt(&KERNEL_STACK_START);

    // Create two tasks and schedule them
    var test_fn1_task = try Task.create(@ptrToInt(test_fn1), true, undefined, allocator, true);
    defer test_fn1_task.destroy(allocator);
    try scheduleTask(test_fn1_task, allocator);

    var test_fn2_task = try Task.create(@ptrToInt(test_fn2), true, undefined, allocator, true);
    defer test_fn2_task.destroy(allocator);
    try scheduleTask(test_fn2_task, allocator);

    // Get the stack pointers of the created tasks
    const fn1_stack_pointer = test_fn1_task.stack_pointer;
    const fn2_stack_pointer = test_fn2_task.stack_pointer;

    try expectEqual(pickNextTask(&ctx), fn1_stack_pointer);
    // The stack pointer of the re-added task should point to the context
    try expectEqual(tasks.first.?.data.stack_pointer, @ptrToInt(&ctx));

    // Should be the PID of the next task
    try expectEqual(current_task.pid, 1);

    try expectEqual(pickNextTask(&ctx), fn2_stack_pointer);
    // The stack pointer of the re-added task should point to the context
    try expectEqual(tasks.first.?.data.stack_pointer, @ptrToInt(&ctx));

    // Should be the PID of the next task
    try expectEqual(current_task.pid, 2);

    try expectEqual(pickNextTask(&ctx), @ptrToInt(&ctx));
    // The stack pointer of the re-added task should point to the context
    try expectEqual(tasks.first.?.data.stack_pointer, @ptrToInt(&ctx));

    // Should be back to the beginning
    try expectEqual(current_task.pid, 0);

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

    var test_fn1_task = try Task.create(@ptrToInt(test_fn1), true, undefined, allocator, true);
    defer test_fn1_task.destroy(allocator);
    try scheduleTask(test_fn1_task, allocator);

    try expectEqual(tasks.len, 1);

    // Free the memory
    allocator.destroy(tasks.first.?);
}

test "init" {
    var allocator = std.testing.allocator;

    try init(allocator, undefined);

    try expectEqual(current_task.pid, 0);
    try expectEqual(@ptrToInt(current_task.kernel_stack.ptr), @ptrToInt(&KERNEL_STACK_START));
    try expectEqual(current_task.kernel_stack.len, @ptrToInt(&KERNEL_STACK_END) - @ptrToInt(&KERNEL_STACK_START));

    try expectEqual(tasks.len, 1);

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
///     IN allocator: Allocator - The allocator to use when needing to allocate memory.
///
fn rt_variable_preserved(allocator: Allocator) void {
    // Create the memory for the boolean
    is_set = allocator.create(bool) catch unreachable;
    defer allocator.destroy(is_set);
    is_set.* = true;

    var test_task = Task.create(@ptrToInt(task_function), true, &vmm.kernel_vmm, allocator, true) catch |e| panic(@errorReturnTrace(), "Failed to create task in rt_variable_preserved: {}\n", .{e});
    scheduleTask(test_task, allocator) catch |e| panic(@errorReturnTrace(), "Failed to schedule a task in rt_variable_preserved: {}\n", .{e});
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
fn rt_user_task(allocator: Allocator, mem_profile: *const mem.MemProfile) void {
    for (&[_][]const u8{ "/user_program_data.elf", "/user_program.elf" }) |user_program| {
        // 1. Create user VMM
        var task_vmm = allocator.create(vmm.VirtualMemoryManager(arch.VmmPayload)) catch |e| {
            panic(@errorReturnTrace(), "Failed to allocate VMM for {s}: {}\n", .{ user_program, e });
        };
        task_vmm.* = vmm.VirtualMemoryManager(arch.VmmPayload).init(0, @ptrToInt(mem_profile.vaddr_start), allocator, arch.VMM_MAPPER, undefined) catch |e| panic(@errorReturnTrace(), "Failed to create the vmm for {s}: {}\n", .{ user_program, e });

        const user_program_file = fs.openFile(user_program, .NO_CREATION) catch |e| {
            panic(@errorReturnTrace(), "Failed to open {s}: {}\n", .{ user_program, e });
        };
        defer user_program_file.close();
        var code: [1024 * 9]u8 = undefined;
        const code_len = user_program_file.read(code[0..code.len]) catch |e| {
            panic(@errorReturnTrace(), "Failed to read {s}: {}\n", .{ user_program, e });
        };
        const program_elf = elf.Elf.init(code[0..code_len], builtin.cpu.arch, allocator) catch |e| panic(@errorReturnTrace(), "Failed to load {s}: {}\n", .{ user_program, e });
        defer program_elf.deinit();

        var user_task = task.Task.createFromElf(program_elf, false, task_vmm, allocator) catch |e| {
            panic(@errorReturnTrace(), "Failed to create task for {s}: {}\n", .{ user_program, e });
        };

        scheduleTask(user_task, allocator) catch |e| {
            panic(@errorReturnTrace(), "Failed to schedule the task for {s}: {}\n", .{ user_program, e });
        };

        var num_allocatable_sections: usize = 0;
        var size_allocatable_sections: usize = 0;
        for (program_elf.section_headers) |section| {
            if (section.flags & elf.SECTION_ALLOCATABLE != 0) {
                num_allocatable_sections += 1;
                size_allocatable_sections += std.mem.alignForward(section.size, vmm.BLOCK_SIZE);
            }
        }

        // Only a certain number of elf section are expected to have been allocated in the vmm
        if (task_vmm.allocations.count() != num_allocatable_sections) {
            panic(@errorReturnTrace(), "VMM allocated wrong number of virtual regions for {s}. Expected {} but found {}\n", .{ user_program, num_allocatable_sections, task_vmm.allocations.count() });
        }

        const allocated_size = (task_vmm.bmp.num_entries - task_vmm.bmp.num_free_entries) * vmm.BLOCK_SIZE;
        if (size_allocatable_sections != allocated_size) {
            panic(@errorReturnTrace(), "VMM allocated wrong amount of memory for {s}. Expected {} but found {}\n", .{ user_program, size_allocatable_sections, allocated_size });
        }
    }
}

///
/// The scheduler runtime tests that will test the scheduling functionality.
///
/// Arguments:
///     IN allocator: Allocator - The allocator to use when needing to allocate memory.
///     IN mem_profile: *const mem.MemProfile - The system's memory profile. Used to set up user task VMMs.
///
fn runtimeTests(allocator: Allocator, mem_profile: *const mem.MemProfile) void {
    arch.enableInterrupts();
    rt_user_task(allocator, mem_profile);
    rt_variable_preserved(allocator);
    while (true) {}
}
