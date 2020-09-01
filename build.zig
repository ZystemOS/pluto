const std = @import("std");
const builtin = @import("builtin");
const rt = @import("test/runtime_test.zig");
const RuntimeStep = rt.RuntimeStep;
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const Step = std.build.Step;
const Target = std.Target;
const CrossTarget = std.zig.CrossTarget;
const fs = std.fs;
const Mode = builtin.Mode;
const TestMode = rt.TestMode;
const ArrayList = std.ArrayList;

const x86_i686 = CrossTarget{
    .cpu_arch = .i386,
    .os_tag = .freestanding,
    .cpu_model = .{ .explicit = &Target.x86.cpu._i686 },
};

const aarch64_cortexa53 = CrossTarget{
    .cpu_arch = .aarch64,
    .os_tag = .freestanding,
    .cpu_model = .{ .explicit = &Target.aarch64.cpu.cortex_a53 },
};

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{ .whitelist = &[_]CrossTarget{ x86_i686, aarch64_cortexa53 }, .default_target = x86_i686 });
    const arch = switch (target.getCpuArch()) {
        .i386 => "x86",
        .aarch64 => "aarch64",
        else => unreachable,
    };

    const fmt_step = b.addFmt(&[_][]const u8{
        "build.zig",
        "src",
        "test",
    });
    b.default_step.dependOn(&fmt_step.step);

    const main_src = "src/kernel/kmain.zig";
    const arch_root = "src/kernel/arch";
    const constants_path = try fs.path.join(b.allocator, &[_][]const u8{ arch_root, arch, "constants.zig" });
    const linker_script_path = try fs.path.join(b.allocator, &[_][]const u8{ arch_root, arch, "link.ld" });
    const output_iso = try fs.path.join(b.allocator, &[_][]const u8{ b.exe_dir, "pluto.iso" });
    const iso_dir_path = try fs.path.join(b.allocator, &[_][]const u8{ b.exe_dir, "iso" });
    const boot_path = try fs.path.join(b.allocator, &[_][]const u8{ b.exe_dir, "iso", "boot" });
    const modules_path = try fs.path.join(b.allocator, &[_][]const u8{ b.exe_dir, "iso", "modules" });

    const build_mode = b.standardReleaseOptions();
    comptime var test_mode_desc: []const u8 = "\n                         ";
    inline for (@typeInfo(TestMode).Enum.fields) |field| {
        const tm = @field(TestMode, field.name);
        test_mode_desc = test_mode_desc ++ field.name ++ " (" ++ TestMode.getDescription(tm) ++ ")";
        test_mode_desc = test_mode_desc ++ "\n                         ";
    }

    const test_mode = b.option(TestMode, "test-mode", "Run a specific runtime test. This option is for the rt-test step. Available options: " ++ test_mode_desc) orelse .None;
    const disable_display = b.option(bool, "disable-display", "Disable the qemu window") orelse false;

    const exec = b.addExecutable("pluto.elf", main_src);
    exec.addPackagePath("constants", constants_path);
    exec.setOutputDir(b.cache_root);
    exec.addBuildOption(TestMode, "test_mode", test_mode);
    exec.setBuildMode(build_mode);
    exec.setLinkerScriptPath(linker_script_path);
    exec.setTarget(target);

    const make_iso = switch (target.getCpuArch()) {
        .i386 => b.addSystemCommand(&[_][]const u8{ "./makeiso.sh", boot_path, modules_path, iso_dir_path, exec.getOutputPath(), output_iso }),
        .aarch64 => zipSequence: {
            const sdcard_folder = try fs.path.join(b.allocator, &[_][]const u8{ b.cache_root, "rpi-sdcard" });
            const elf = try fs.path.join(b.allocator, &[_][]const u8{ exec.output_dir.?, "pluto.elf" });
            const kernel = try fs.path.join(b.allocator, &[_][]const u8{ sdcard_folder, "kernel8.img" });

            const mkdir = b.addSystemCommand(&[_][]const u8{
                "mkdir",
                "--parents",
                sdcard_folder,
            });
            mkdir.step.dependOn(&exec.step);

            const objcopy = b.addSystemCommand(&[_][]const u8{
                "aarch64-linux-gnu-objcopy",
                elf,
                "-O",
                "binary",
                try fs.path.join(b.allocator, &[_][]const u8{ b.cache_root, "kernel8.img" }),
            });
            objcopy.step.dependOn(&mkdir.step);

            const cp_sdcard_files = b.addSystemCommand(&[_][]const u8{
                "cp",
                "--archive",
                "src/kernel/arch/aarch64/rpi-sdcard/bootcode.bin",
                "src/kernel/arch/aarch64/rpi-sdcard/config.txt",
                "src/kernel/arch/aarch64/rpi-sdcard/fixup.dat",
                "src/kernel/arch/aarch64/rpi-sdcard/start.elf",
                sdcard_folder,
            });
            cp_sdcard_files.step.dependOn(&objcopy.step);

            const make_armstub = addCustomStep(b, MakeArmstubStep{
                .input_name = try fs.path.join(b.allocator, &[_][]const u8{ b.cache_root, "kernel8.img" }),
                .output_name = kernel,
            });
            make_armstub.step.dependOn(&cp_sdcard_files.step);

            const zip = b.addSystemCommand(&[_][]const u8{
                "zip",
                "--junk-paths",
                "--quiet",
                "--recurse-paths",
                try std.fmt.allocPrint(b.allocator, "{}.zip", .{sdcard_folder}),
                sdcard_folder,
            });
            zip.step.dependOn(&make_armstub.step);

            break :zipSequence zip;
        },
        else => unreachable,
    };
    make_iso.step.dependOn(&exec.step);

    b.default_step.dependOn(&make_iso.step);

    const test_step = b.step("test", "Run tests");
    const mock_path = "\"../../test/mock/kernel/\"";
    const arch_mock_path = "\"../../../../test/mock/kernel/\"";
    const unit_tests = b.addTest(main_src);
    unit_tests.setBuildMode(build_mode);
    unit_tests.setMainPkgPath(".");
    unit_tests.addPackagePath("constants", constants_path);
    unit_tests.addBuildOption(TestMode, "test_mode", test_mode);
    unit_tests.addBuildOption([]const u8, "mock_path", mock_path);
    unit_tests.addBuildOption([]const u8, "arch_mock_path", arch_mock_path);

    if (builtin.os.tag != .windows) {
        unit_tests.enable_qemu = true;
    }

    unit_tests.setTarget(.{ .cpu_arch = target.cpu_arch });
    test_step.dependOn(&unit_tests.step);

    const rt_test_step = b.step("rt-test", "Run runtime tests");
    const build_mode_str = switch (build_mode) {
        .Debug => "",
        .ReleaseSafe => "-Drelease-safe",
        .ReleaseFast => "-Drelease-fast",
        .ReleaseSmall => "-Drelease-small",
    };

    var qemu_args_al = ArrayList([]const u8).init(b.allocator);
    defer qemu_args_al.deinit();

    switch (target.getCpuArch()) {
        .i386 => try qemu_args_al.append("qemu-system-i386"),
        .aarch64 => try qemu_args_al.append("qemu-system-aarch64"),
        else => unreachable,
    }
    try qemu_args_al.append("-serial");
    try qemu_args_al.append("stdio");
    switch (target.getCpuArch()) {
        .i386 => {
            try qemu_args_al.append("-boot");
            try qemu_args_al.append("d");
            try qemu_args_al.append("-cdrom");
            try qemu_args_al.append(output_iso);
        },
        .aarch64 => try qemu_args_al.appendSlice(&[_][]const u8{ "-kernel", exec.getOutputPath(), "-machine", "raspi3" }),
        else => unreachable,
    }
    if (disable_display) {
        try qemu_args_al.append("-display");
        try qemu_args_al.append("none");
    }

    var qemu_args = qemu_args_al.toOwnedSlice();

    const rt_step = RuntimeStep.create(b, test_mode, qemu_args);
    rt_step.step.dependOn(&make_iso.step);
    rt_test_step.dependOn(&rt_step.step);

    const run_step = b.step("run", "Run with qemu");
    const run_debug_step = b.step("debug-run", "Run with qemu and wait for a gdb connection");

    const qemu_cmd = b.addSystemCommand(qemu_args);
    const qemu_debug_cmd = b.addSystemCommand(qemu_args);
    qemu_debug_cmd.addArgs(&[_][]const u8{ "-s", "-S" });

    qemu_cmd.step.dependOn(&make_iso.step);
    qemu_debug_cmd.step.dependOn(&make_iso.step);

    run_step.dependOn(&qemu_cmd.step);
    run_debug_step.dependOn(&qemu_debug_cmd.step);

    const debug_step = b.step("debug", "Debug with gdb and connect to a running qemu instance");
    const symbol_file_arg = try std.mem.join(b.allocator, " ", &[_][]const u8{ "symbol-file", exec.getOutputPath() });
    const debug_cmd = b.addSystemCommand(&[_][]const u8{
        "gdb-multiarch",
        "-ex",
        symbol_file_arg,
        "-ex",
        "set architecture auto",
    });
    debug_cmd.addArgs(&[_][]const u8{
        "-ex",
        "target remote localhost:1234",
    });
    debug_step.dependOn(&debug_cmd.step);
}

const MakeArmstubStep = struct {
    step: std.build.Step = undefined,
    input_name: []const u8,
    output_name: []const u8,
    pub fn make(step: *std.build.Step) anyerror!void {
        const self = @fieldParentPtr(MakeArmstubStep, "step", step);
        const cwd = fs.cwd();
        const image = try cwd.openFile(self.input_name, fs.File.OpenFlags{});
        defer image.close();
        const armstub_image = try cwd.createFile(self.output_name, fs.File.CreateFlags{});
        defer armstub_image.close();
        // armstub not yet working, therefore: b 0x80000 (which is 0x14020000)
        _ = try armstub_image.write(&[4]u8{ 0x00, 0x00, 0x02, 0x14 });
        // followed by 0 filler until 0x80000
        var i: usize = 4;
        while (i < 0x80000) : (i += 1) {
            _ = try armstub_image.write(&[1]u8{0x00});
        }
        // followed finally by kernel that starts at 0x80000
        var read_buf: [1]u8 = undefined;
        while (true) {
            var n = try image.read(&read_buf);
            if (n == 0) {
                break;
            }
            _ = try armstub_image.write(&read_buf);
        }
    }
};

pub fn addCustomStep(self: *std.build.Builder, customStep: anytype) *@TypeOf(customStep) {
    var allocated = self.allocator.create(@TypeOf(customStep)) catch unreachable;
    allocated.* = customStep;
    allocated.*.step = std.build.Step.init(.Custom, @typeName(@TypeOf(customStep)), self.allocator, @TypeOf(customStep).make);
    return allocated;
}
