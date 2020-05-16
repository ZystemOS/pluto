import atexit
import queue
import threading
import subprocess
import signal
import sys
import os
import importlib.util
import colorama
from colorama import Fore, Style

msg_queue = queue.Queue(-1)
proc = None

class TestBase:

    def __init__(self, zig_path: str, **kwargs):
        self.msg_queue = queue.Queue(-1)
        self.program_str = zig_path + " build run -Dtest-type=" + kwargs["test_type"]
        
    def start(self):
        self.os_process = subprocess.Popen(self.program_str, stdout=subprocess.PIPE, shell=True, start_new_session=True)
        
        self.read_thread = threading.Thread(target=self.__read_messages)
        self.read_thread.daemon = True
        self.read_thread.start()

    def get_log_msg(self) -> str:
        try:
            line = self.msg_queue.get(block=True, timeout=5)
            line = line.strip()
            return line
        except queue.Empty:
            return None
    
    def run_test(self):
        raise NotImplementedError
    
    def cleanup(self):
        os.killpg(os.getpgid(self.os_process.pid), signal.SIGTERM)

    def __read_messages(self):
        while True:
            line = self.os_process.stdout.readline().decode("utf-8")
            self.msg_queue.put(line)


class NormalTest(TestBase):

    def __init__(self, zig_path):
        super().__init__(zig_path, test_type="NORMAL")
    
    def run_test(self) -> bool:
        self.start()
        # This test will check no kernel panic occurs as this is a failure
        test_passed = False
        while not test_passed:
            log_line = self.get_log_msg()
            if log_line is None:
                # This is a time out and didn't find the kernel panic so fail
                break
            else:
                print(Fore.LIGHTMAGENTA_EX + log_line)
                if "Kernel panic" in log_line or "FAILURE" in log_line:
                    # A kernel panic, or failed test so fail the test
                    break
                elif "SUCCESS" in log_line:
                    # Test passed
                    test_passed = True
        
        self.cleanup()
        return test_passed


class PanicTest(TestBase):

    def __init__(self, zig_path):
        super().__init__(zig_path, test_type="PANIC")
    
    def run_test(self) -> bool:
        self.start()
        # This test will only look for integer overflow test
        test_passed = False
        while not test_passed:
            log_line = self.get_log_msg()
            if log_line is None:
                # This is a time out and didn't find the kernel panic so fail
                break
            else:
                print(Fore.LIGHTMAGENTA_EX + log_line)
                if "Kernel panic: integer overflow" in log_line:
                    # Found the integer overflow, test passed
                    test_passed = True
        
        self.cleanup()
        return test_passed


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python <zig_path> <arch> <test_type>\n")
        sys.exit(1)
    
    colorama.init(autoreset=True)
    
    zig_path = sys.argv[1]
    arch = sys.argv[2]
    test_type = sys.argv[3]

    # All tests
    all_tests = {
        "NORMAL": NormalTest(zig_path),
        "PANIC": PanicTest(zig_path),
    }

    if test_type == "ALL_RUNTIME":
        # Make multithreaded + add option for this
        for test_type, test in all_tests.items():
            print(Fore.CYAN + "\nRunning test for: {}\n".format(test_type))
            if test.run_test():
                print(Fore.LIGHTGREEN_EX + "\nTest {} passed\n".format(test_type))
            else:
                print(Fore.RED + "\nTest {} failed\n".format(test_type))
                break
        print(Fore.LIGHTGREEN_EX + "\nAll tests passed\n")
    else:
        print(Fore.CYAN + "\nRunning test for: {}\n".format(test_type))
        if all_tests[test_type].run_test():
            print(Fore.LIGHTGREEN_EX + "\nTest {} passed\n".format(test_type))
        else:
            print(Fore.RED + "\nTest {} failed\n".format(test_type))
