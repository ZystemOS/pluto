const std = @import("std");
const vmm = @import("vmm_mock.zig");
const arch = @import("arch_mock.zig");
const Allocator = std.mem.Allocator;

const mock_framework = @import("mock_framework.zig");
pub const initTest = mock_framework.initTest;
pub const freeTest = mock_framework.freeTest;
pub const addTestParams = mock_framework.addTestParams;
pub const addConsumeFunction = mock_framework.addConsumeFunction;
pub const addRepeatFunction = mock_framework.addRepeatFunction;

pub const EntryPoint = usize;

pub const Task = struct {
    const Self = @This();

    pid: u32,
    kernel_stack: []u32,
    user_stack: []u32,
    stack_pointer: usize,
    kernel: bool,
    vmm: vmm.VirtualMemoryManager(arch.VmmPayload),

    pub fn create(entry_point: EntryPoint, kernel: bool, task_vmm: *vmm.VirtualMemoryManager(arch.VmmPayload), allocator: *Allocator) Allocator.Error!*Task {
        return mock_framework.performAction("Task.create", Allocator.Error!*Task, .{ entry_point, allocator, kernel, task_vmm });
    }

    pub fn destroy(self: *Self, allocator: *Allocator) void {
        return mock_framework.performAction("Task.destroy", void, .{ self, allocator });
    }
};
