const std = @import("std");
const ChildProcess = std.ChildProcess;
const Allocator = std.mem.Allocator;
const Builder = std.build.Builder;
const Step = std.build.Step;
const CrossTarget = std.zig.CrossTarget;
const ArrayList = std.ArrayList;
const Queue = std.atomic.Queue;
const File = std.fs.File;

/// The enumeration of tests with the unit test and all the runtime tests.
pub const TestMode = enum {
    /// This will run all the runtime tests below. The ALL_RUNTIME literal shouldn't be passed to
    /// the OS code.
    ALL_RUNTIME,

    /// Run the OS's initialisation runtime tests to ensure the OS is properly set up.
    INITIALISATION,

    /// Run the panic runtime test.
    PANIC,

    ///
    /// Return a string description for the test mode provided.
    ///
    /// Argument:
    ///     IN mode: TestMode - The test mode.
    ///
    /// Return: []const u8
    ///     The string description for the test mode.
    ///
    pub fn getDescription(mode: TestMode) []const u8 {
        return switch (mode) {
            .ALL_RUNTIME => "All runtime tests (Default)",
            .INITIALISATION => "Initialisation runtime tests",
            .PANIC => "Panic runtime tests",
        };
    }
};

const test_fn = fn () bool;

pub const RuntimeStep = struct {
    step: Step,
    builder: *Builder,
    msg_queue: Queue([][]const u8),
    os_proc: *ChildProcess,

    pub fn init(builder: *Builder, test_mode: TestMode, qemu_args: [][]const u8) !RuntimeStep {
        // const test_mode_option = try std.mem.join(builder.allocator, "", &[_][]const u8{ "-Dtest-mode=", @tagName(test_mode) });
        // const build_mode = builder.standardReleaseOptions();
        // var zig_args = ArrayList([]const u8).init(builder.allocator);
        // try zig_args.append(builder.zig_exe);
        // try zig_args.append("build");
        // try zig_args.append("run");
        // try zig_args.append("-Ddisable-display");
        // switch (build_mode) {
        //     .Debug => {},
        //     .ReleaseSafe => try zig_args.append("-Drelease-safe"),
        //     .ReleaseFast => try zig_args.append("-Drelease-fast"),
        //     .ReleaseSmall => try zig_args.append("-Drelease-small"),
        // }
        // try zig_args.append(test_mode_option);

        // const result = try ChildProcess.exec(.{
        //     .allocator = builder.allocator,
        //     .argv = qemu_args,
        //     .max_output_bytes = 1*1024*1024,
        // });

        // std.debug.warn("Res: {}\n", .{result});
        var rt_step = RuntimeStep{
            .builder = builder,
            .step = Step.init(builder.fmt("Runtime {}", .{@tagName(test_mode)}), builder.allocator, make),
            .msg_queue = Queue([][]const u8).init(),
            .os_proc = try ChildProcess.init(qemu_args, builder.allocator),
        };

        rt_step.os_proc.env_map = builder.env_map;
        rt_step.os_proc.stdout_behavior = .Pipe;
        rt_step.os_proc.stdin_behavior = .Inherit;
        rt_step.os_proc.stderr_behavior = .Inherit;

        // std.debug.warn("Running test for: {}, {}, {}\n", .{ target, build_mode, test_mode });
        std.debug.warn("Running: {}\n", .{try std.mem.join(builder.allocator, " ", qemu_args)});

        return rt_step;
    }

    fn make(step: *Step) anyerror!void {
        const self = @fieldParentPtr(RuntimeStep, "step", step);
        //std.debug.warn("{}\n", .{self.test_mode});
        if (!try self.run()) {
            return error.Nope;
        }
    }

    // In a thread
    fn readLogs(self: *RuntimeStep) void {
        const stream = self.os_proc.stdout.?.inStream();
        //const stream2 = self.os_proc.stderr.?.inStream();
        // Line shouldn't be longer than this
        const max_line_length: usize = 128;
        while (true) {
            //const line2 = stream2.readUntilDelimiterAlloc(self.builder.allocator, '\n', max_line_length) catch unreachable;
            //std.debug.warn("Line: {}\n", .{line2});
            const line = stream.readUntilDelimiterAlloc(self.builder.allocator, '\n', max_line_length) catch unreachable;
            std.debug.warn("Line: {}\n", .{line});
            std.time.sleep(std.time.millisecond);
        }
    }

    fn getMsg() ![]u8 {
        return "ads";
    }

    fn run(self: *RuntimeStep) !bool {
        try self.os_proc.spawn();
        //const stdout_stream = self.os_proc.stdout.?.inStream();

        // var i: u32 = 0;
        // while (i < 100) : (i += 1) {
        //     const line = try stdout_stream.readUntilDelimiterAlloc(self.builder.allocator, '\n', 128);
        //     std.debug.warn("Line: {}\n", .{line});
        // }

        //const stderr_stream = self.os_proc.stderr.?.inStream();
        const term = try self.os_proc.wait();
        std.debug.warn("Term: {}\n", .{term});

        std.time.sleep(5 * std.time.second);
        //const stdout_stream = os_proc.?.stdout.?.inStream();

        // Start up the reading thread
        //var thread = try std.Thread.spawn(self, readLogs);

        std.time.sleep(3 * std.time.second);

        std.debug.warn("End: {}\n", .{try self.os_proc.kill()});

        // Line should be longer than this
        //const max_line_length: usize = 128;

        // while (true) {
        //     //const line = try stdout_stream.readUntilDelimiterAlloc(self.builder.allocator, '\n', max_line_length);
        //     //std.debug.warn("Line: {}\n", .{line});
        // }

        // Run the test function here

        return false;
    }
};

pub fn addRuntime(builder: *Builder, test_mode: TestMode, qemu_args: [][]const u8) *RuntimeStep {
    const runtime_step = builder.allocator.create(RuntimeStep) catch unreachable;
    runtime_step.* = RuntimeStep.init(builder, test_mode, qemu_args) catch unreachable;
    return runtime_step;
}
