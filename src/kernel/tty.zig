const std = @import("std");
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.tty);
const build_options = @import("build_options");
const arch = @import("arch.zig").internals;
const panic = @import("panic.zig").panic;

/// The OutStream for the format function
const Writer = std.io.Writer(void, anyerror, printCallback);

pub const TTY = struct {
    /// Print a already-formatted string
    print: fn ([]const u8) anyerror!void,
    /// Set the TTY cursor position to a row and column
    setCursor: fn (u8, u8) void,
    /// Clear the screen and set the cursor to top left. The default implementation will be used if null
    clear: ?fn () void,
    /// The number of character rows supported
    rows: u8,
    /// The number of character columns supported
    cols: u8,
};

/// The current tty stream
var tty: TTY = undefined;
var allocator: Allocator = undefined;

///
/// A call back function for use in the formation of a string. This calls the architecture's print function.
///
/// Arguments:
///     IN ctx: void       - The context of the printing. This will be empty.
///     IN str: []const u8 - The string to print.
///
/// Return: usize
///     The number of characters printed
///
fn printCallback(ctx: void, str: []const u8) !usize {
    // Suppress unused var warning
    _ = ctx;
    tty.print(str) catch |e| panic(@errorReturnTrace(), "Failed to print to tty: {}\n", .{e});
    return str.len;
}

///
/// Print a formatted string to the terminal in the current colour. This used the standard zig
/// formatting.
///
/// Arguments:
///     IN comptime format: []const u8 - The format string to print
///     IN args: anytype                   - The arguments to be used in the formatted string
///
pub fn print(comptime format: []const u8, args: anytype) void {
    // Printing can't error because of the scrolling, if it does, we have a big problem
    fmt.format(Writer{ .context = {} }, format, args) catch |e| {
        log.err("Error printing. Error: {}\n", .{e});
    };
}

///
/// Clear the screen by printing a space at each cursor position. Sets the cursor to the top left (0, 0)
///
pub fn clear() void {
    if (tty.clear) |clr| {
        clr();
    } else {
        // Try to allocate the number of spaces for a whole row to avoid calling print too many times
        var spaces = allocator.alloc(u8, tty.cols + 1) catch |e| switch (e) {
            Allocator.Error.OutOfMemory => {
                var row: u8 = 0;
                // If we can't allocate the spaces then try the unoptimised way instead
                while (row < tty.rows) : (row += 1) {
                    var col: u8 = 0;
                    while (col < tty.cols) : (col += 1) {
                        print(" ", .{});
                    }
                    print("\n", .{});
                }
                tty.setCursor(0, 0);
                return;
            },
        };
        defer allocator.free(spaces);

        var col: u8 = 0;
        while (col < tty.cols) : (col += 1) {
            spaces[col] = " "[0];
        }
        spaces[col] = "\n"[0];
        var row: u8 = 0;
        while (row < tty.rows) : (row += 1) {
            print("{s}", .{spaces});
        }
        tty.setCursor(0, 0);
    }
}

///
/// Initialise the TTY. The details of which are up to the architecture
///
/// Arguments:
///     IN alloc: Allocator - The allocator to use when requiring memory
///     IN boot_payload: arch.BootPayload - The payload passed to the kernel on boot
///
pub fn init(alloc: Allocator, boot_payload: arch.BootPayload) void {
    log.info("Init\n", .{});
    defer log.info("Done\n", .{});
    tty = arch.initTTY(boot_payload);
    allocator = alloc;
}
