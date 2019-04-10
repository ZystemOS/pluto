//
// build
// Zig version: 
// Author: DrDeano
// Date: 2019-03-30
//
//const Array = @import("std").ArrayList;
//const Builder = @import("std").build.Builder;
//const builtin = @import("builtin");
//const join = @import("std").mem.join;
//
//pub fn build(b: *Builder) void {
//    ////
//    // Default step.
//    //
//    const kernel = b.addExecutable("zen", "kernel/kmain.zig");
//    //kernel.addPackagePath("lib", "lib/index.zig");
//    kernel.setOutputPath("bin");
//
//    // Assembles
//    kernel.addAssemblyFile("kernel/start.s");
//
//    kernel.setBuildMode(b.standardReleaseOptions());
//    kernel.setTarget(builtin.Arch.i386, builtin.Os.freestanding, builtin.Environ.gnu);
//    kernel.setLinkerScriptPath("kernel/linker.ld");
//
//    b.default_step.dependOn(&kernel.step);
//    return kernel.getOutputPath();
//
//
//    ////
//    // Test and debug on Qemu.
//    //
//    const qemu = b.step("qemu", "Run the OS with Qemu");
//    const qemu_debug = b.step("qemu-debug", "Run the OS with Qemu and wait for debugger to attach");
//
//    const common_params = [][]const u8 {
//        "qemu-system-i386",
//        "-display", "curses",
//        "-kernel", kernel
//    };
//    const debug_params = [][]const u8 {"-s", "-S"};
//
//    var qemu_params = Array([]const u8).init(b.allocator);
//    var qemu_debug_params = Array([]const u8).init(b.allocator);
//    for (common_params) |p| { qemu_params.append(p) catch unreachable; qemu_debug_params.append(p) catch unreachable; }
//    for (debug_params) |p| { qemu_debug_params.append(p) catch unreachable; }
//
//    const run_qemu = b.addCommand(".", b.env_map, qemu_params.toSlice());
//    const run_qemu_debug = b.addCommand(".", b.env_map, qemu_debug_params.toSlice());
//
//    run_qemu.step.dependOn(b.default_step);
//    run_qemu_debug.step.dependOn(b.default_step);
//    qemu.dependOn(&run_qemu.step);
//    qemu_debug.dependOn(&run_qemu_debug.step);
//}
const Builder = @import("std").build.Builder;
const builtin = @import("builtin");

pub fn build(b: *Builder) void {
    var kernel = b.addExecutable("pluto", "kmain.zig");

    kernel.setTarget(builtin.Arch.i386, builtin.Os.freestanding, builtin.Abi.gnu);
    kernel.setLinkerScriptPath("kernel/linker.ld");
}