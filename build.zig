// Zig version: 0.4.0

const Builder = @import("std").build.Builder;
const builtin = @import("builtin");
const Array = @import("std").ArrayList;

pub fn build(b: *Builder) void {
    const kernel_out_dir = "bin/kernel";
    const kernel_src = "src/kernel/";

    var kernel = b.addExecutable("pluto.elf", kernel_src ++ "kmain.zig");
    //kernel.addAssemblyFile(kernel_src ++ "start.s");

    kernel.setOutputDir(kernel_out_dir);
    kernel.setBuildMode(b.standardReleaseOptions());
    kernel.setTarget(builtin.Arch.i386, builtin.Os.freestanding, builtin.Abi.gnu);
    kernel.setLinkerScriptPath("link.ld");

    const run_objcopy = b.addSystemCommand([][]const u8 {
        "objcopy", "-O", "binary", "-S", kernel.getOutputPath(), kernel_out_dir ++ "/pluto.bin",
    });
    run_objcopy.step.dependOn(&kernel.step);

    b.default_step.dependOn(&run_objcopy.step);

    const run_qemu = b.addSystemCommand([][]const u8 {
        "qemu-system-i386",
        "-display", "curses",
        "-kernel", kernel.getOutputPath(),
    });

    const run_qemu_debug = b.addSystemCommand([][]const u8 {
        "qemu-system-i386",
        "-display", "curses",
        "-kernel", kernel.getOutputPath(),
        "-s", "-S",
    });

    run_qemu.step.dependOn(&kernel.step);
    //run_qemu_debug.step.dependOn(&kernel.step);

    b.default_step.dependOn(&run_qemu.step);
}