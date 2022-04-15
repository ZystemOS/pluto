ARG ZIG_TAG=llvm13-x86_64-1
FROM ziglang/static-base:$ZIG_TAG

RUN apk update && \
    apk add xorriso grub qemu qemu-system-i386

RUN echo "export PATH=\"/deps/local/bin/zig:$PATH\"" >> /root/.profile
