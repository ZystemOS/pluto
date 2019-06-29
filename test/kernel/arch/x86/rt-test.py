def getTestCases(TestCase):
    return [
            TestCase("GDT init", [r"Init gdt", r"Done"]),
            TestCase("IDT init", [r"Init idt", r"Done"]),
            TestCase("PIT init", [r"Init pit", r".+", "Done"])
        ]
