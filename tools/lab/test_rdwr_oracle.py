"""Portable corruption control for the actual native suite buffer assignments.

This checks the C comparison oracle, not Windows filesystem behavior.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


class ReadbackOracle(unittest.TestCase):
    def test_aligned_readback_detects_corruption(self):
        source = (Path(__file__).resolve().parents[2] /
                  'tst/winfsp-tests/rdwr-test.c').read_text()
        assignments = re.findall(
            r'Buffer\[0\] = AllocBuffer\[0\];\s*Buffer\[1\] = AllocBuffer\[[01]\];',
            source)
        self.assertEqual(len(assignments), 2, 'review both sync and overlapped oracles')
        for index, assignment in enumerate(assignments):
            with self.subTest(oracle=index), tempfile.TemporaryDirectory() as directory:
                binary = Path(directory) / 'oracle'
                program = '''
#include <string.h>
int main(void) {
    unsigned char expected[16], readback[16];
    void *AllocBuffer[2] = { expected, readback }, *Buffer[2];
    memset(expected, 0x41, sizeof expected);
    memset(readback, 0, sizeof readback);
''' + assignment + '''
    /* Simulate incorrect bytes returned by ReadFile into its supplied buffer. */
    memset(Buffer[1], 0x42, sizeof readback);
    return memcmp(Buffer[0], Buffer[1], sizeof readback) == 0 ? 1 : 0;
}
'''
                compiled = subprocess.run(['cc', '-x', 'c', '-', '-o', str(binary)],
                                          input=program, capture_output=True, text=True)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                result = subprocess.run([str(binary)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0,
                                 'native readback oracle accepts corrupt bytes')


if __name__ == '__main__':
    unittest.main()
