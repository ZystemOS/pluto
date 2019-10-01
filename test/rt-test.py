import subprocess
import signal
import re
import sys
import datetime
import os
import importlib.util

class TestCase:
    def __init__(self, name, expected):
        self.name = name
        self.expected = expected

def test_failure(case, exp, expected_idx, found):
    print("FAILURE: %s #%d, expected '%s', found '%s'" %(case.name, expected_idx + 1, exp, found))
    sys.exit(1)

def test_pass(case, exp, expected_idx, found):
    print("PASS: %s #%d, expected '%s', found '%s'" %(case.name, expected_idx + 1, exp, found))

def get_pre_archinit_cases():
    return [
            TestCase("Arch init starts", [r"Init arch \w+"])
        ]

def get_post_archinit_cases():
    return [
            TestCase("Arch init finishes", [r"Arch init done"]),
            TestCase("VGA init", [r"Init vga", r"Done"]),
            TestCase("VGA tests", [r"VGA: Tested max scan line", r"VGA: Tested cursor shape", r"VGA: Tested updating cursor"]),
            TestCase("TTY init", [r"Init tty", r"Done"]),
            TestCase("TTY tests", [r"TTY: Tested globals", r"TTY: Tested printing"]),
            TestCase("Init finishes", [r"Init done"])
        ]

if __name__ == "__main__":
    arch = sys.argv[1]
    zig_path = sys.argv[2]
    spec = importlib.util.spec_from_file_location("arch", "test/kernel/arch/" + arch + "/rt-test.py")
    arch_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(arch_module)

    # The list of log statements to look for before arch init is called +
    # All log statements to look for, including the arch-specific ones +
    # The list of log statements to look for after arch init is called
    cases = get_pre_archinit_cases() + arch_module.get_test_cases(TestCase) + get_post_archinit_cases()

    if len(cases) > 0:
        proc = subprocess.Popen(zig_path + " build run -Drt-test=true", stdout=subprocess.PIPE, shell=True)
        case_idx = 0
        # Go through the cases
        while case_idx < len(cases):
            case = cases[case_idx]
            expected_idx = 0
            # Go through the expected log messages
            while expected_idx < len(case.expected):
                e = r"\[INFO\] " + case.expected[expected_idx]
                line = proc.stdout.readline().decode("utf-8")
                if not line:
                    break
                line = line.strip()
                pattern = re.compile(e)
                # Pass if the line matches the expected pattern, else fail
                if pattern.fullmatch(line):
                    test_pass(case, e, expected_idx, line)
                else:
                    test_failure(case, e, expected_idx, line)
                expected_idx += 1
            case_idx += 1
        proc.kill()
    sys.exit(0)
