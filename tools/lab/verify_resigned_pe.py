"""Strict byte comparison for this lab's signed PE32+ driver copies.

Not a signature validator: Windows must separately report a valid signature.
Only the checksum, security directory entry and final certificate table may
change. Reject unusual layouts rather than normalizing arbitrary PE content.
"""
import pathlib
import struct
import sys


def unsigned_content(data):
    if data[:2] != b'MZ' or len(data) < 64:
        raise ValueError('missing DOS header')
    pe = struct.unpack_from('<I', data, 60)[0]
    opt = pe + 24
    if data[pe:pe + 4] != b'PE\0\0' or opt + 152 > len(data):
        raise ValueError('invalid PE header')
    if struct.unpack_from('<H', data, opt)[0] != 0x20b:
        raise ValueError('expected PE32+')
    size = struct.unpack_from('<H', data, pe + 20)[0]
    count = struct.unpack_from('<I', data, opt + 108)[0]
    if size < 152 or count < 5:
        raise ValueError('security directory missing')
    security = opt + 144
    offset, length = struct.unpack_from('<II', data, security)
    if offset < opt + size or offset % 8 or length < 8 or offset + length != len(data):
        raise ValueError('expected a final aligned certificate table')
    result = bytearray(data[:offset])
    result[opt + 64:opt + 68] = bytes(4)
    result[security:security + 8] = bytes(8)
    return bytes(result)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('usage: verify_resigned_pe.py ORIGINAL RESIGNED')
    original, resigned = (pathlib.Path(p).read_bytes() for p in sys.argv[1:])
    if unsigned_content(original) != unsigned_content(resigned):
        sys.exit('FAIL: bytes outside the permitted signing fields changed')
    print('PASS: every byte outside checksum/security-directory/certificate table is identical')
