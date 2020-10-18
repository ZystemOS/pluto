const std = @import("std");
const cp437= @import("cp437.zig");

const CodePage = struct {

    pub const CodePages = enum{
        CP437,
    };

    pub const Error = error{
        InvalidChar,
    };

    pub fn toOEM(code_page: CodePages, char: u16) Error!u8 {
        const table = switch (code_page) {
            .CP437 => cp437.table,
        };

        // Optimisation for ascii
        if (char >= 0x20 and char < 0x7F) {
            return @intCast(u8, char);
        }

        // Find the code point and then return the index
        for (table) |code_point, i| {
            if (code_point == char) {
                return @intCast(u8, i);
            }
        }
        return Error.InvalidChar;
    }

    pub fn toUnicode(code_page: CodePages, char: u8) u16 {
        return switch (code_page) {
            .CP437 => cp437.table[char],
        };
    }
};

test "ASCII toOEM" {
    // The ASCII characters will be the same values
    var ascii: u8 = 0x20;
    while (ascii < 0x7F) : (ascii += 1) {
        const char = try CodePage.toOEM(.CP437, ascii);
        std.testing.expectEqual(char, ascii);
    }
}

test "ASCII toUnicode" {
    // The ASCII characters will be the same values
    var ascii: u8 = 0x20;
    while (ascii < 0x7F) : (ascii += 1) {
        const char = CodePage.toUnicode(.CP437, ascii);
        std.testing.expectEqual(char, ascii);
    }
}

test "Invalid characters" {
    const char = '€';
    std.testing.expectError(CodePage.Error.InvalidChar, CodePage.toOEM(.CP437, char));
}