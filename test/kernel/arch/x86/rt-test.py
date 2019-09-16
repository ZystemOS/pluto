def getTestCases(TestCase):
    return [
            TestCase("GDT init", [r"Init gdt", r"Done"]),
            TestCase("GDT tests", [r"GDT: Tested loading GDT"]),
            TestCase("IDT init", [r"Init idt", r"Done"]),
            TestCase("PIT init", [r"Init pit", r".+", "Done"]),
            TestCase("Syscalls init", [r"Init syscalls", "Done"]),
            TestCase("Syscall tests", [r"Syscalls: Tested no args", r"Syscalls: Tested 1 arg", r"Syscalls: Tested 2 args", r"Syscalls: Tested 3 args", r"Syscalls: Tested 4 args", r"Syscalls: Tested 5 args"])
        ]
