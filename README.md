# Pluto

## Build
Requires *xorriso* and the grub tools (such as *grub-mkrescue*).
```
mkdir -p bin/kernel
mkdir -p bin/iso/boot/grub
zig build
```

Note that the `mkdir` invocations are only needed once. See `zig build --help` for a list of options.

## Run
```
zig build run
```
To debug the kernel:
```
zig build run -Ddebug=true
zig build debug
```

# Test
```
zig build test
```
