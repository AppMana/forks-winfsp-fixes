import struct
import unittest

from verify_resigned_pe import unsigned_content


class ResignedPE(unittest.TestCase):
    def setUp(self):
        self.data = bytearray(600)
        self.data[:2] = b'MZ'
        struct.pack_into('<I', self.data, 60, 64)
        self.data[64:68] = b'PE\0\0'
        struct.pack_into('<H', self.data, 84, 240)
        struct.pack_into('<H', self.data, 88, 0x20b)
        struct.pack_into('<I', self.data, 196, 16)
        struct.pack_into('<II', self.data, 232, 512, 88)

    def test_signature_and_checksum_only(self):
        changed = self.data.copy()
        changed[152:156] = b'hash'
        changed[512:] = b'new signature'
        struct.pack_into('<I', changed, 236, len(changed) - 512)
        self.assertEqual(unsigned_content(self.data), unsigned_content(changed))

    def test_code_change_is_not_hidden(self):
        changed = self.data.copy()
        changed[400] = 1
        self.assertNotEqual(unsigned_content(self.data), unsigned_content(changed))

    def test_certificate_offset_change_is_not_hidden(self):
        changed = self.data.copy()
        struct.pack_into('<II', changed, 232, 520, 80)
        self.assertNotEqual(unsigned_content(self.data), unsigned_content(changed))

    def test_malformed_or_unsupported_layouts(self):
        for offset, fmt, value in [(60, '<I', 10000), (88, '<H', 0x10b),
                                   (84, '<H', 100), (196, '<I', 4),
                                   (232, '<I', 320), (232, '<I', 513),
                                   (236, '<I', 87)]:
            with self.subTest(offset=offset, value=value):
                changed = self.data.copy()
                struct.pack_into(fmt, changed, offset, value)
                with self.assertRaises(ValueError):
                    unsigned_content(changed)


if __name__ == '__main__':
    unittest.main()
