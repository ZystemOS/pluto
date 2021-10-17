const isr = @import("isr.zig");

/// The isr number associated with syscalls
pub const INTERRUPT: u16 = @enumToInt(isr.ExceptionCodes.Syscall);
