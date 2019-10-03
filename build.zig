const std = @import("std");
const builtin = @import("builtin");
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const Step = std.build.Step;
const Target = std.build.Target;
const fs = std.fs;
const Mode = builtin.Mode;

pub fn build(b: *Builder) !void {
    const target = Target{
        .Cross = std.build.CrossTarget{
            .arch = .i386,
            .os = .freestanding,
            .abi = .gnu,
        },
    };

    const target_str = switch (target.getArch()) {
        .i386 => "x86",
        else => unreachable,
    };

    const build_mode = b.standardReleaseOptions();
    const rt_test = b.option(bool, "rt-test", "enable/disable runtime testing") orelse false;

    const main_src = "src/kernel/kmain.zig";

    const exec = b.addExecutable("pluto", main_src);
    const constants_path = try fs.path.join(b.allocator, [_][]const u8{ "src/kernel/arch", target_str, "constants.zig" });
    exec.addPackagePath("constants", constants_path);
    exec.setBuildMode(build_mode);
    exec.addBuildOption(bool, "rt_test", rt_test);
    exec.setLinkerScriptPath("link.ld");
    exec.setTheTarget(target);
    switch (target.getArch()) {
        .i386 => {
            exec.addAssemblyFile("src/kernel/arch/x86/irq_asm.s");
            exec.addAssemblyFile("src/kernel/arch/x86/isr_asm.s");
        },
        else => unreachable,
    }

    const iso_path = try fs.path.join(b.allocator, [_][]const u8{ b.exe_dir, "pluto.iso" });
    const grub_build_path = try fs.path.join(b.allocator, [_][]const u8{ b.exe_dir, "iso", "boot" });
    const iso_dir_path = try fs.path.join(b.allocator, [_][]const u8{ b.exe_dir, "iso" });

    const mkdir_cmd = b.addSystemCommand([_][]const u8{ "mkdir", "-p", fs.path.dirname(grub_build_path).? });

    const grub_cmd = b.addSystemCommand([_][]const u8{ "cp", "-r", "grub", grub_build_path });
    grub_cmd.step.dependOn(&mkdir_cmd.step);

    const cp_elf_cmd = b.addSystemCommand([_][]const u8{"cp"});
    const elf_path = try fs.path.join(b.allocator, [_][]const u8{ grub_build_path, "pluto.elf" });
    cp_elf_cmd.addArtifactArg(exec);
    cp_elf_cmd.addArg(elf_path);
    cp_elf_cmd.step.dependOn(&grub_cmd.step);
    cp_elf_cmd.step.dependOn(&exec.step);

    const iso_cmd = b.addSystemCommand([_][]const u8{ "grub-mkrescue", "-o", iso_path, iso_dir_path });
    iso_cmd.step.dependOn(&cp_elf_cmd.step);
    b.default_step.dependOn(&iso_cmd.step);

    const run_step = b.step("run", "Run with qemu");
    const run_debug_step = b.step("debug-run", "Run with qemu and wait for a gdb connection");

    const qemu_bin = switch (target.getArch()) {
        .i386 => "qemu-system-i386",
        else => unreachable,
    };
    const qemu_args = [_][]const u8{
        qemu_bin,
        "-cdrom",
        iso_path,
        "-boot",
        "d",
        "-serial",
        "stdio",
    };
    const qemu_cmd = b.addSystemCommand(qemu_args);
    const qemu_debug_cmd = b.addSystemCommand(qemu_args);
    qemu_debug_cmd.addArgs([_][]const u8{ "-s", "-S" });

    if (rt_test) {
        const qemu_rt_test_args = [_][]const u8{ "-display", "none" };
        qemu_cmd.addArgs(qemu_rt_test_args);
        qemu_debug_cmd.addArgs(qemu_rt_test_args);
    }

    qemu_cmd.step.dependOn(&iso_cmd.step);
    qemu_debug_cmd.step.dependOn(&iso_cmd.step);

    run_step.dependOn(&qemu_cmd.step);
    run_debug_step.dependOn(&qemu_debug_cmd.step);

    const test_step = b.step("test", "Run tests");
    if (rt_test) {
        const script = b.addSystemCommand([_][]const u8{ "python3", "test/rt-test.py", "x86", b.zig_exe });
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
        test_step.dependOn(&unit_tests.step);
    }

    const debug_step = b.step("debug", "Debug with gdb and connect to a running qemu instance");
    const symbol_file_arg = try std.mem.join(b.allocator, " ", [_][]const u8{ "symbol-file", elf_path });
    const debug_cmd = b.addSystemCommand([_][]const u8{
        "gdb",
        "-ex",
        symbol_file_arg,
    });
    debug_cmd.addArgs([_][]const u8{
        "-ex",
        "target remote localhost:1234",
    });
    debug_step.dependOn(&debug_cmd.step);
}
