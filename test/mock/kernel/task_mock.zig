const std = @import("std");
const Allocator = std.mem.Allocator;

const mock_framework = @import("mock_framework.zig");
pub const initTest = mock_framework.initTest;
pub const freeTest = mock_framework.freeTest;
pub const addTestParams = mock_framework.addTestParams;
pub const addConsumeFunction = mock_framework.addConsumeFunction;
pub const addRepeatFunction = mock_framework.addRepeatFunction;

const EntryPointFn = fn () void;

pub const Task = struct {
    const Self = @This();

    pid: u32,
    stack: []u32,
    stack_pointer: usize,

    pub fn create(entry_point: EntryPointFn, allocator: *Allocator) Allocator.Error!*Task {
        return mock_framework.performAction("Task.create", Allocator.Error!*Task, .{ entry_point, allocator });
    }

    pub fn destroy(self: *Self, allocator: *Allocator) void {
        return mock_framework.performAction("Task.destroy", void, .{ self, allocator });
    }
};
