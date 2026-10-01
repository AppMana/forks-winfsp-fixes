"""Portable controls for the native test's deletion assertion, not Win32 itself."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


class DeletionAssertion(unittest.TestCase):
    def test_deletion_requires_inaccessibility_and_eventual_absence(self):
        source = (Path(__file__).resolve().parents[2] /
                  'tst/winfsp-tests/rdwr-test.c').read_text()
        helper = re.search(
            r'static void rdwr_assert_deleted\(PWSTR FilePath\)\n\{\n(.*?)\n\}',
            source, re.S)
        if helper:
            body = helper[1]
            self.assertEqual(source.count('rdwr_assert_deleted(FilePath);'), 3)
        else:
            # Exercise the original assertion unchanged to retain the RED control.
            blocks = re.findall(
                r'Handle = CreateFileW\(FilePath,\s*'
                r'GENERIC_READ \| GENERIC_WRITE, FILE_SHARE_READ \| FILE_SHARE_WRITE, 0,\s*'
                r'OPEN_EXISTING, 0, 0\);\s*'
                r'ASSERT\(INVALID_HANDLE_VALUE == Handle\);\s*'
                r'ASSERT\(ERROR_FILE_NOT_FOUND == GetLastError\(\)\);', source)
            self.assertEqual(len(blocks), 3)
            self.assertEqual(len(set(blocks)), 1)
            body = 'HANDLE Handle;\n' + blocks[0]
        for case, expected in [(0, 0), (1, 0), (2, 91), (3, 91), (4, 91)]:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                binary = Path(directory) / 'control'
                program = r'''
#include <stdlib.h>
#include <stdint.h>
typedef uint32_t DWORD;
typedef intptr_t HANDLE;
typedef const char *PWSTR;
#define ASSERT(c) do { if (!(c)) exit(91); } while (0)
#define INVALID_HANDLE_VALUE ((HANDLE)-1)
#define GENERIC_READ 1
#define GENERIC_WRITE 2
#define FILE_SHARE_READ 1
#define FILE_SHARE_WRITE 2
#define OPEN_EXISTING 3
#define ERROR_FILE_NOT_FOUND 2
#define ERROR_ACCESS_DENIED 5
static DWORD elapsed, error;
static int calls;
static DWORD GetTickCount(void) { return elapsed; }
static void Sleep(DWORD n) { elapsed += n; if(elapsed > 10000) exit(92); }
static DWORD GetLastError(void) { return error; }
static HANDLE CreateFileW(PWSTR p, int a, int s, int sec, int d, int f, int t) {
    ++calls;
    /* absent, delayed delete, persistent denial, other error, readable file */
    error = CASE == 0 ? 2 : CASE == 1 ? (calls <= 2 ? 5 : 2) : CASE == 2 ? 5 : 32;
    return CASE == 4 ? 1 : INVALID_HANDLE_VALUE;
}
static void check(PWSTR FilePath) {
''' + body + '\n}\nint main(void) { check("owned-file"); return 0; }\n'
                compiled = subprocess.run(
                    ['cc', '-x', 'c', '-', '-DCASE=' + str(case), '-o', str(binary)],
                    input=program, capture_output=True, text=True)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                result = subprocess.run([str(binary)], timeout=2)
                self.assertEqual(result.returncode, expected)


if __name__ == '__main__':
    unittest.main()
