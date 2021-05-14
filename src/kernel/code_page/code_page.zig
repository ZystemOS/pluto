const std = @import("std");
const cp437 = @import("cp437.zig");

/// The code page namespace
pub const CodePage = struct {
    /// The different code pages
    pub const CodePages = enum {
        /// Code page 437, the original IBM PC character set. Also known as OEM-US.
        CP437,
    };

    /// The Error set for converting characters.
    pub const Error = error{
        /// The character to be converted is not part of the code page table.
        InvalidChar,
    };

    ///
    /// Get the code page table for the given code page enum.
    ///
    /// Arguments:
    ///     IN code_page: CodePages - The code page enum to get the table for.
    ///
    /// Return: [0x100]u16
    ///     The table of u16 that represent the code page provided.
    ///
    fn getTable(code_page: CodePages) [0x100]u16 {
        return switch (code_page) {
            .CP437 => cp437.table,
        };
    }

    ///
    /// Convert a wide character (16-bits) to a code page.
    ///
    /// Arguments:
    ///     IN code_page: CodePages - The code page to convert to.
    ///     IN char: u16            - The character to convert.
    ///
    /// Return: u8
    ///     The converted character.
    ///
    /// Error: Error
    ///     error.InvalidChar - The character to be converted is not in the code page table.
    ///
    pub fn toCodePage(code_page: CodePages, char: u16) Error!u8 {
        // Optimisation for ascii
        if (char >= 0x20 and char < 0x7F) {
            return @intCast(u8, char);
        }

        // Find the code point and then return the index
        for (getTable(code_page)) |code_point, i| {
            if (code_point == char) {
                return @intCast(u8, i);
            }
        }
        return Error.InvalidChar;
    }

    ///
    /// Convert a code page character to a wide character (16-bits)
    ///
    /// Arguments:
    ///     IN code_page: CodePages - The code page the character is coming from.
    ///     IN char: u8             - The character to convert to wide char.
    ///
    /// Return: u16
    ///     The wide character.
    ///
    pub fn toWideChar(code_page: CodePages, char: u8) u16 {
        return getTable(code_page)[char];
    }
};

test "ASCII toCodePage" {
    // The ASCII characters will be the same values
    var ascii: u8 = 0x20;
    while (ascii < 0x7F) : (ascii += 1) {
        const char = try CodePage.toCodePage(.CP437, ascii);
        try std.testing.expectEqual(char, ascii);
    }
}

test "ASCII toWideChar" {
    // The ASCII characters will be the same values
    var ascii: u8 = 0x20;
    while (ascii < 0x7F) : (ascii += 1) {
        const char = CodePage.toWideChar(.CP437, ascii);
        try std.testing.expectEqual(char, ascii);
    }
}

test "Invalid characters" {
    const char = '€';
    try std.testing.expectError(CodePage.Error.InvalidChar, CodePage.toCodePage(.CP437, char));
}
