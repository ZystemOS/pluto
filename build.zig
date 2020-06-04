const std = @import("std");
const builtin = @import("builtin");
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const Step = std.build.Step;
const Target = std.Target;
const CrossTarget = std.zig.CrossTarget;
const fs = std.fs;
const Mode = builtin.Mode;

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

    const build_mode = b.standardReleaseOptions();
    const rt_test = b.option(bool, "rt-test", "enable/disable runtime testing") orelse false;

    const exec = b.addExecutable("pluto.elf", main_src);
    exec.addPackagePath("constants", constants_path);
    exec.setOutputDir(b.cache_root);
    exec.addBuildOption(bool, "rt_test", rt_test);
    exec.setBuildMode(build_mode);
    const linker_script_path = try fs.path.join(b.allocator, &[_][]const u8{ arch_root, arch, "link.ld" });
    exec.setLinkerScriptPath(linker_script_path);
    exec.setTarget(target);

    const output_iso = try fs.path.join(b.allocator, &[_][]const u8{ b.exe_dir, "pluto.iso" });
    const iso_dir_path = try fs.path.join(b.allocator, &[_][]const u8{ b.exe_dir, "iso" });
    const boot_path = try fs.path.join(b.allocator, &[_][]const u8{ b.exe_dir, "iso", "boot" });
    const modules_path = try fs.path.join(b.allocator, &[_][]const u8{ b.exe_dir, "iso", "modules" });

    const make_iso = switch (target.getCpuArch()) {
        .i386 => b.addSystemCommand(&[_][]const u8{ "./makeiso.sh", boot_path, modules_path, iso_dir_path, exec.getOutputPath(), output_iso }),
        else => unreachable,
    };

    make_iso.step.dependOn(&exec.step);
    b.default_step.dependOn(&make_iso.step);

    const test_step = b.step("test", "Run tests");
    if (rt_test) {
        const script = b.addSystemCommand(&[_][]const u8{ "python3", "test/rt-test.py", arch, b.zig_exe });
        test_step.dependOn(&script.step);
    } else {
        const mock_path = "\"../../test/mock/kernel/\"";
        const arch_mock_path = "\"../../../../test/mock/kernel/\"";
        const unit_tests = b.addTest(main_src);
        unit_tests.setBuildMode(build_mode);
        unit_tests.setMainPkgPath(".");
        unit_tests.addPackagePath("constants", constants_path);
        unit_tests.addBuildOption(bool, "rt_test", rt_test);
        unit_tests.addBuildOption([]const u8, "mock_path", mock_path);
        unit_tests.addBuildOption([]const u8, "arch_mock_path", arch_mock_path);

        if (builtin.os.tag != .windows) unit_tests.enable_qemu = true;

        unit_tests.setTarget(.{ .cpu_arch = target.cpu_arch });

        test_step.dependOn(&unit_tests.step);
    }

    const run_step = b.step("run", "Run with qemu");
    const run_debug_step = b.step("debug-run", "Run with qemu and wait for a gdb connection");

    const qemu_bin = switch (target.getCpuArch()) {
        .i386 => "qemu-system-i386",
        else => unreachable,
    };
    const qemu_args = &[_][]const u8{
        qemu_bin,
        "-serial",
        "stdio",
    };
    const qemu_machine_args = switch (target.getCpuArch()) {
        .i386 => &[_][]const u8{
            "-boot",
            "d",
            "-cdrom",
            output_iso,
        },
        else => null,
    };
    const qemu_cmd = b.addSystemCommand(qemu_args);
    const qemu_debug_cmd = b.addSystemCommand(qemu_args);
    qemu_debug_cmd.addArgs(&[_][]const u8{ "-s", "-S" });
    if (qemu_machine_args) |machine_args| {
        qemu_cmd.addArgs(machine_args);
        qemu_debug_cmd.addArgs(machine_args);
    }

    if (rt_test) {
        const qemu_rt_test_args = &[_][]const u8{ "-display", "none" };
        qemu_cmd.addArgs(qemu_rt_test_args);
        qemu_debug_cmd.addArgs(qemu_rt_test_args);
    }

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
