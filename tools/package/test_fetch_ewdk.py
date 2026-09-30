import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('fetch_ewdk', Path(__file__).with_name('fetch-ewdk.py'))
fetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetch)


class RangeContract(unittest.TestCase):
    def test_exact_range_and_identity_required(self):
        good = {'Content-Range': f'bytes 32-63/{fetch.SIZE}', 'ETag': 'pinned'}
        fetch.validate_range(good, 32, 63, 'pinned')
        for bad in ({}, dict(good, ETag='changed'),
                    dict(good, **{'Content-Range': f'bytes 0-63/{fetch.SIZE}'}),
                    dict(good, **{'Content-Range': 'bytes 32-63/999'})):
            with self.subTest(headers=bad), self.assertRaises(RuntimeError):
                fetch.validate_range(bad, 32, 63, 'pinned')


if __name__ == '__main__':
    unittest.main()
