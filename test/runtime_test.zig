const std = @import("std");
const ChildProcess = std.ChildProcess;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const Builder = std.build.Builder;
const Step = std.build.Step;
const Queue = std.atomic.Queue([]const u8);
const Node = std.TailQueue([]const u8).Node;

// Creating a new runtime test:
// 1. Add a enum to `TestMode`. The name should try to describe the test in one word :P
// 2. Add a description for the new runtime test to explain to the use what this will test.
// 3. Create a function with in the RuntimeStep struct that will perform the test. At least this
//    should use `self.get_msg()` which will get the serial log lines from the OS. Look at
//    test_init or test_panic for examples.
// 4. In the create function, add your test mode and test function to the switch.
// 5. Celebrate if it works lel

/// The enumeration of tests with all the runtime tests.
pub const TestMode = enum {
    /// This is for the default test mode. This will just run the OS normally.
    None,

    /// Run the OS's initialisation runtime tests to ensure the OS is properly set up.
    Initialisation,

    /// Run the panic runtime test.
    Panic,

    /// Run the scheduler runtime test.
    Scheduler,

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
            .None => "Runs the OS normally (Default)",
            .Initialisation => "Initialisation runtime tests",
            .Panic => "Panic runtime tests",
            .Scheduler => "Scheduler runtime tests",
        };
    }
};

/// The runtime step for running the runtime tests for the OS.
pub const RuntimeStep = struct {
    /// The Step, that is all you need to know
    step: Step,

    /// The builder pointer, also all you need to know
    builder: *Builder,

    /// The message queue that stores the log lines
    msg_queue: Queue,

    /// The qemu process, this is needed for the `read_logs` thread.
    os_proc: *ChildProcess,

    /// The argv of the qemu process so can create the qemu process
    argv: [][]const u8,

    /// The test function that will be run for the current runtime test.
    test_func: TestFn,

    /// The error set for the RuntimeStep
    const Error = error{
        /// The error for if a test fails. If the test function returns false, this will be thrown
        /// at the wnd of the make function as we need to clean up first. This will ensure the
        /// build fails.
        TestFailed,

        /// This is used for `self.get_msg()` when the queue is empty after a timeout.
        QueueEmpty,
    };

    /// The type of the test function.
    const TestFn = fn (self: *RuntimeStep) bool;

    /// The time used for getting message from the message queue. This is in milliseconds.
    const queue_timeout: usize = 5000;

    ///
    /// This will just print all the serial logs.
    ///
    /// Arguments:
    ///     IN/OUT self: *RuntimeStep - Self.
    ///
    /// Return: bool
    ///     This will always return true
    ///
    fn print_logs(self: *RuntimeStep) bool {
        while (true) {
            const msg = self.get_msg() catch return true;
            defer self.builder.allocator.free(msg);
            std.debug.warn("{}\n", .{msg});
        }
    }

    ///
    /// This tests the OS is initialised correctly by checking that we get a `SUCCESS` at the end.
    ///
    /// Arguments:
    ///     IN/OUT self: *RuntimeStep - Self.
    ///
    /// Return: bool
    ///     Whether the test has passed or failed.
    ///
    fn test_init(self: *RuntimeStep) bool {
        while (true) {
            const msg = self.get_msg() catch return false;
            defer self.builder.allocator.free(msg);
            // Print the line to see what is going on
            std.debug.warn("{}\n", .{msg});
            if (std.mem.indexOf(u8, msg, "FAILURE")) |_| {
                return false;
            } else if (std.mem.eql(u8, msg, "[info] (kmain): SUCCESS")) {
                return true;
            }
        }
    }

    ///
    /// This tests the OS's panic by checking that we get a kernel panic for integer overflow.
    ///
    /// Arguments:
    ///     IN/OUT self: *RuntimeStep - Self.
    ///
    /// Return: bool
    ///     Whether the test has passed or failed.
    ///
    fn test_panic(self: *RuntimeStep) bool {
        while (true) {
            const msg = self.get_msg() catch return false;
            defer self.builder.allocator.free(msg);
            // Print the line to see what is going on
            std.debug.warn("{}\n", .{msg});
            if (std.mem.eql(u8, msg, "[emerg] (panic): Kernel panic: integer overflow")) {
                return true;
            }
        }
    }

    ///
    /// This tests the OS's scheduling by checking that we schedule a task that prints the success.
    ///
    /// Arguments:
    ///     IN/OUT self: *RuntimeStep - Self.
    ///
    /// Return: bool
    ///     Whether the test has passed or failed.
    ///
    fn test_scheduler(self: *RuntimeStep) bool {
        var state: usize = 0;
        while (true) {
            const msg = self.get_msg() catch return false;
            defer self.builder.allocator.free(msg);

            std.debug.warn("{}\n", .{msg});

            // Make sure `[INFO] Switched` then `[INFO] SUCCESS: Scheduler variables preserved` are logged in this order
            if (std.mem.eql(u8, msg, "[info] (scheduler): Switched") and state == 0) {
                state = 1;
            } else if (std.mem.eql(u8, msg, "[info] (scheduler): SUCCESS: Scheduler variables preserved") and state == 1) {
                state = 2;
            }
            if (state == 2) {
                return true;
            }
        }
    }

    ///
    /// The make function that is called by the builder. This will create the qemu process with the
    /// stdout as a Pipe. Then create the read thread to read the logs from the qemu stdout. Then
    /// will call the test function to test a specifics part of the OS defined by the test mode.
    ///
    /// Arguments:
    ///     IN/OUT step: *Step - The step of this step.
    ///
    /// Error: Thread.SpawnError || ChildProcess.SpawnError || Allocator.Error || Error
    ///     Thread.SpawnError           - If there is an error spawning the real logs thread.
    ///     ChildProcess.SpawnError     - If there is an error spawning the qemu process.
    ///     Allocator.Error.OutOfMemory - If there is no more memory to allocate.
    ///     Error.TestFailed            - The error if the test failed.
    ///
    fn make(step: *Step) (Thread.SpawnError || ChildProcess.SpawnError || Allocator.Error || Error)!void {
        const self = @fieldParentPtr(RuntimeStep, "step", step);

        // Create the qemu process
        self.os_proc = try ChildProcess.init(self.argv, self.builder.allocator);
        defer self.os_proc.deinit();

        self.os_proc.stdout_behavior = .Pipe;
        self.os_proc.stdin_behavior = .Inherit;
        self.os_proc.stderr_behavior = .Inherit;

        try self.os_proc.spawn();

        // Start up the read thread
        var thread = try Thread.spawn(self, read_logs);

        // Call the testing function
        const res = self.test_func(self);

        // Now kill our baby
        _ = try self.os_proc.kill();

        // Join the thread
        thread.wait();

        // Free the rest of the queue
        while (self.msg_queue.get()) |node| {
            self.builder.allocator.free(node.data);
            self.builder.allocator.destroy(node);
        }

        // If the test function returns false, then fail the build
        if (!res) {
            return Error.TestFailed;
        }
    }

    ///
    /// This is to only be used in the read logs thread. This reads the stdout of the qemu process
    /// and stores each line in the queue.
    ///
    /// Arguments:
    ///     IN/OUT self: *RuntimeStep - Self.
    ///
    fn read_logs(self: *RuntimeStep) void {
        const stream = self.os_proc.stdout.?.reader();
        // Line shouldn't be longer than this
        const max_line_length: usize = 1024;
        while (true) {
            const line = stream.readUntilDelimiterAlloc(self.builder.allocator, '\n', max_line_length) catch |e| switch (e) {
                error.EndOfStream => {
                    // When the qemu process closes, this will return a EndOfStream, so can catch and return so then can
                    // join the thread to exit nicely :)
                    return;
                },
                else => {
                    std.debug.warn("Unexpected error: {}\n", .{e});
                    unreachable;
                },
            };

            // put line in the queue
            var node = self.builder.allocator.create(Node) catch unreachable;
            node.* = Node.init(line);
            self.msg_queue.put(node);
        }
    }

    ///
    /// This return a log message from the queue in the order it would appear in the qemu process.
    /// The line will need to be free with allocator.free(line) then finished with the line.
    ///
    /// Arguments:
    ///     IN/OUT self: *RuntimeStep - Self.
    ///
    /// Return: []const u8
    ///     A log line from the queue.
    ///
    /// Error: Error
    ///     error.QueueEmpty - If the queue is empty for more than the timeout, this will be thrown.
    ///
    fn get_msg(self: *RuntimeStep) Error![]const u8 {
        var i: usize = 0;
        while (i < queue_timeout) : (i += 1) {
            if (self.msg_queue.get()) |node| {
                defer self.builder.allocator.destroy(node);
                return node.data;
            }
            std.time.sleep(std.time.ns_per_ms);
        }
        return Error.QueueEmpty;
    }

    ///
    /// Create a runtime step with a specific test mode.
    ///
    /// Argument:
    ///     IN builder: *Builder       - The builder. This is used for the allocator.
    ///     IN test_mode: TestMode     - The test mode.
    ///     IN qemu_args: [][]const u8 - The qemu arguments used to create the OS process.
    ///
    /// Return: *RuntimeStep
    ///     The Runtime step pointer to add to the build process.
    ///
    pub fn create(builder: *Builder, test_mode: TestMode, qemu_args: [][]const u8) *RuntimeStep {
        const runtime_step = builder.allocator.create(RuntimeStep) catch unreachable;
        runtime_step.* = RuntimeStep{
            .step = Step.init(.Custom, builder.fmt("Runtime {}", .{@tagName(test_mode)}), builder.allocator, make),
            .builder = builder,
            .msg_queue = Queue.init(),
            .os_proc = undefined,
            .argv = qemu_args,
            .test_func = switch (test_mode) {
                .None => print_logs,
                .Initialisation => test_init,
                .Panic => test_panic,
                .Scheduler => test_scheduler,
            },
        };
        return runtime_step;
    }
};
