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
        .aarch64 => b.addSystemCommand(&[_][]const u8{ "aarch64-linux-gnu-objcopy", exec.getOutputPath(), "-O", "binary", try fs.path.join(b.allocator, &[_][]const u8{ exec.output_dir.?, "kernel8.img" }) }),
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

    const zip_folder = "rpi-sdcard";
    const zip_mkdir_cmd = b.addSystemCommand(&[_][]const u8{
        "mkdir",
        "-p",
        zip_folder,
    });
    const zip_cp_files_cmd = b.addSystemCommand(&[_][]const u8{
        "cp",
        "-a",
        "src/kernel/arch/aarch64/rpi-sdcard/config.txt",
        "zig-cache/kernel8.img",
        zip_folder,
    });
    const firmware_url = "https://github.com/raspberrypi/firmware/raw/1.20200601+arm64/boot/";
    const zip_get_firmware_cmd = b.addSystemCommand(&[_][]const u8{
        "wget",
        "-Nq",
        "-P",
        zip_folder,
        firmware_url ++ "bootcode.bin",
        firmware_url ++ "fixup.dat",
        firmware_url ++ "start.elf",
    });
    const zip_do_zip_cmd = b.addSystemCommand(&[_][]const u8{
        "zip",
        "-jqr",
        zip_folder ++ ".zip",
        zip_folder,
    });

    const zip_step = b.step("zip", "Create product zip file");
    zip_step.dependOn(&make_iso.step);
    zip_step.dependOn(&zip_mkdir_cmd.step);
    zip_step.dependOn(&zip_cp_files_cmd.step);
    zip_step.dependOn(&zip_get_firmware_cmd.step);
    zip_step.dependOn(&zip_do_zip_cmd.step);
}
