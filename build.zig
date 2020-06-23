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

pub fn build(b: *Builder) !void {
    const arch = b.option([]const u8, "arch", "Architecture to build for: x86") orelse "x86";
    const target: CrossTarget = if (std.mem.eql(u8, "x86", arch))
        x86_i686
    else {
        std.debug.warn("Unsupported or unknown architecture '{}'\n", .{arch});
        unreachable;
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
