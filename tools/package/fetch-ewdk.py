#!/usr/bin/env python3
"""Cache the official 19041 EWDK with bounded parallel range requests.

The first acquisition records an observed digest, not a publisher signature.
Subsequent acquisitions require --sha256 from the reviewed build-input lock.
Never executes or installs downloaded software.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.request

URL = 'https://software-download.microsoft.com/download/pr/EWDK_vb_release_svc_prod1_19041_201201-2105.iso'
SIZE = 13180262400
CHUNK = 32 * 1024 * 1024


def validate_range(headers, start, end, etag):
    if headers.get('Content-Range') != f'bytes {start}-{end}/{SIZE}':
        raise RuntimeError('server did not honor the exact requested byte range')
    if headers.get('ETag') != etag:
        raise RuntimeError('remote artifact changed during acquisition')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    digest = parser.add_mutually_exclusive_group(required=True)
    digest.add_argument('--sha256')
    digest.add_argument('--record-first-acquisition', action='store_true')
    args = parser.parse_args()
    if args.sha256 and not re.fullmatch('[0-9a-f]{64}', args.sha256):
        parser.error('expected a lowercase SHA-256 digest')
    dest = args.output.resolve()
    partial = dest.with_suffix(dest.suffix + '.partial')
    manifest = dest.with_suffix(dest.suffix + '.json')
    if any(p.exists() for p in (dest, partial, manifest)):
        parser.error('output, partial and manifest paths must be fresh')
    with urllib.request.urlopen(urllib.request.Request(URL, method='HEAD'), timeout=30) as response:
        etag = response.headers.get('ETag')
        if not etag or int(response.headers.get('Content-Length', 0)) != SIZE:
            raise RuntimeError('unexpected official artifact identity or size')
    fd = os.open(partial, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.ftruncate(fd, SIZE)

        def fetch(start):
            end = min(start + CHUNK, SIZE) - 1
            request = urllib.request.Request(URL, headers={'Range': f'bytes={start}-{end}', 'If-Match': etag})
            with urllib.request.urlopen(request, timeout=120) as response:
                if response.status != 206:
                    raise RuntimeError('range request was not partial content')
                validate_range(response.headers, start, end, etag)
                offset = start
                while data := response.read(1024 * 1024):
                    if offset + len(data) > end + 1:
                        raise RuntimeError('range response exceeded its bound')
                    view = memoryview(data)
                    while view:
                        count = os.pwrite(fd, view, offset)
                        if count <= 0:
                            raise RuntimeError('short output write')
                        offset += count
                        view = view[count:]
                if offset != end + 1:
                    raise RuntimeError('truncated range response')
            return end - start + 1

        complete = 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            futures = [pool.submit(fetch, start) for start in range(0, SIZE, CHUNK)]
            for future in concurrent.futures.as_completed(futures):
                complete += future.result()
                if complete // CHUNK % 16 == 0 or complete == SIZE:
                    print(f'downloaded {complete}/{SIZE} bytes', flush=True)
        os.fsync(fd)
    finally:
        os.close(fd)
    with partial.open('rb') as source:
        actual = hashlib.file_digest(source, 'sha256').hexdigest()
    if args.sha256 and actual != args.sha256:
        raise RuntimeError('download hash mismatch; partial retained, not promoted')
    with manifest.open('x') as out:
        json.dump(dict(url=URL, size=SIZE, etag=etag, sha256=actual,
                       verification='pinned-sha256' if args.sha256 else 'first-acquisition-observed'), out, indent=2)
        out.write('\n')
    partial.rename(dest)
    print(f'{actual}  {dest}', flush=True)


if __name__ == '__main__':
    main()
