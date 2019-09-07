# Pluto

[![Build Status](https://dev.azure.com/samueltebbs/pluto/_apis/build/status/SamTebbs33.pluto?branchName=develop)](https://dev.azure.com/samueltebbs/samueltebbs/_build/latest?definitionId=1&branchName=develop)

Pluto is a kernel written almost entirely in [Zig](https://github.com/ziglang/zig) and supports x86, with aarch64 and x64 backends being planned.

![Hello image](hello.jpg)

## Goals
* **Should be written in Zig as much as possible**. Assembly should only be used where required for functionality or performance reasons.
* **Light and performant**. The kernel should be usable both on embedded and desktop class CPUs, made possible by it being lightweight and modular.
* **Basic utilities will be written in Zig**. This includes a basic text editor and shell, and will be part of the filsystem external to the kernel itself.
* **Easy to port**. The kernel is oblivous to the underlying architecture, meaning that ports only need to implement the defined interface and they should work without a hitch.

All of these goals will benefit from the features of Zig.

## Build
Requires a master build of Zig ([downloaded](https://ziglang.org/download) or [built from source](https://github.com/ziglang/zig#building-from-source)) *xorriso* and the grub tools (such as *grub-mkrescue*). A gdb binary compatible with your chosen target is required to run the kernel (e.g. *qemu-system-i386*).
```
zig build
```

## Run
```
zig build run
```

## Debug
Launch a gdb instance and connect to qemu.
```
zig build debug
```

## Test
Run the unitests or runtime tests.
```
zig build test
```

## Options
* `-Ddebug=`: Boolean (default `false`).
	* **build**: Build with debug info included or stripped (see #70 for planned changes).
	* **run**: Wait for a gdb connection before executing.
* `-Drt-test=`: Boolean (default `false`).
	* **build**: Build with runtime testing enabled. Makes the kernel bigger and slower but tests important functionality.
	* **test**: Run the runtime testing script instead of the unittests. Checks for the expected log statements and fails if any are missing.

## Contribution
We welcome all contributions, be it bug reports, feature suggestions or pull requests. We follow the style mandated by zig fmt so make sure you've run `zig fmt` on your code before submitting it.

We also like to order a file's members (public after non-public):
1. imports
2. type definitions
3. constants
4. variables
5. inline functions
6. functions
7. entry point/init function
