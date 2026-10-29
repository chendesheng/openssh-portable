#!/usr/bin/env python3
"""Reject debug symbol files in the downloadable runtime package."""
from pathlib import Path
import sys


def main(root):
    root = Path(root)
    files = [path for path in root.rglob('*') if path.is_file()]
    symbols = [path for path in files if path.suffix.lower() == '.pdb']
    if symbols:
        print('PDB files remain: ' + ', '.join(str(path.relative_to(root)) for path in symbols), file=sys.stderr)
        return 1
    images = [path for path in files if path.suffix.lower() in ('.exe', '.dll')]
    if not images:
        print('Package contains no EXE/DLL images', file=sys.stderr)
        return 1
    print(f'PASS: no PDB files in the runtime package ({len(images)} EXE/DLL images).')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1]))
