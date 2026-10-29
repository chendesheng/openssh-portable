#!/usr/bin/env python3
"""Check packaged PE images for PDB files and embedded CodeView references."""
from pathlib import Path
import struct
import sys


def check_image(path):
    data = path.read_bytes()
    if len(data) < 64 or data[:2] != b'MZ':
        raise ValueError('not a PE image')
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if pe + 24 > len(data) or data[pe:pe + 4] != b'PE\0\0':
        raise ValueError('invalid PE header')
    sections = struct.unpack_from('<H', data, pe + 6)[0]
    optional_size = struct.unpack_from('<H', data, pe + 20)[0]
    optional = pe + 24
    magic = struct.unpack_from('<H', data, optional)[0]
    if magic not in (0x10b, 0x20b):
        raise ValueError('unsupported PE optional header')
    directory = optional + (112 if magic == 0x20b else 96)
    if directory + 56 > optional + optional_size:
        raise ValueError('missing PE data directories')
    rva, size = struct.unpack_from('<II', data, directory + 48)
    if not rva and not size:
        return
    if not rva or not size or size % 28:
        raise ValueError('invalid PE debug directory')
    table = optional + optional_size
    raw = None
    for index in range(sections):
        offset = table + index * 40
        virtual_size, virtual_address, raw_size, raw_offset = struct.unpack_from('<IIII', data, offset + 8)
        if virtual_address <= rva < virtual_address + max(virtual_size, raw_size):
            delta = rva - virtual_address
            if delta + size > raw_size:
                raise ValueError('debug directory outside section data')
            raw = raw_offset + delta
            break
    if raw is None or raw + size > len(data):
        raise ValueError('debug directory not mapped in file')
    for offset in range(raw, raw + size, 28):
        kind = struct.unpack_from('<I', data, offset + 12)[0]
        if kind == 2:
            raise ValueError('CodeView/PDB debug reference remains')


def main(root):
    root = Path(root)
    failures = []
    for path in root.rglob('*'):
        if path.is_file() and path.suffix.lower() == '.pdb':
            failures.append(f'{path.name}: PDB file remains')
    images = sorted(p for p in root.rglob('*') if p.is_file() and p.suffix.lower() in ('.exe', '.dll'))
    if not images:
        failures.append('package contains no EXE/DLL images')
    for path in images:
        try:
            check_image(path)
        except (ValueError, struct.error) as error:
            failures.append(f'{path.name}: {error}')
    if failures:
        print('\n'.join(failures), file=sys.stderr)
        return 1
    print(f'PASS: no PDB files or CodeView/PDB references in {len(images)} packaged images.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1]))
