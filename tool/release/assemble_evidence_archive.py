#!/usr/bin/env python3
"""Assemble generator/inspector JSON into deterministic public release evidence.

Input is an exact tree of REQUIRED_FILES (no pre-existing SHA256SUMS). Output
must not exist; it receives release-evidence/ and its gzip tar, never APKs.
This is encoding/packaging only, not license, provenance or release approval.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import stat
import sys
import tarfile
import tempfile

from validate_evidence_archive import REQUIRED_FILES, ROOT, MANIFEST


class AssemblyError(ValueError):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise AssemblyError(f'duplicate JSON key: {key}')
        result[key] = value
    return result


def invalid_constant(value):
    raise AssemblyError(f'non-JSON constant: {value}')


def assemble(source: Path, output: Path) -> None:
    if source.is_symlink() or not source.is_dir():
        raise AssemblyError(f'{source}: input must be a real directory')
    if output.exists() or output.is_symlink():
        raise AssemblyError(f'{output}: output already exists')
    directories = {parent.as_posix() for name in REQUIRED_FILES
                   for parent in PurePosixPath(name).parents if parent.as_posix() != '.'}
    files = set()
    actual_directories = set()
    for path in source.rglob('*'):
        name = path.relative_to(source).as_posix()
        mode = path.lstat().st_mode
        if stat.S_ISREG(mode):
            files.add(name)
        elif stat.S_ISDIR(mode):
            actual_directories.add(name)
        else:
            raise AssemblyError(f'{name}: links and special files are forbidden')
    if files != REQUIRED_FILES or actual_directories != directories:
        raise AssemblyError(f'{source}: wrong input set; missing={sorted(REQUIRED_FILES - files)}, extra={sorted(files - REQUIRED_FILES)}, missing directories={sorted(directories - actual_directories)}, extra directories={sorted(actual_directories - directories)}')
    contents = {}
    for name in sorted(REQUIRED_FILES):
        try:
            raw = (source / name).read_bytes()
            value = json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object, parse_constant=invalid_constant)
            if not isinstance(value, dict):
                raise AssemblyError('JSON must be an object')
            encoded = (json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False) + '\n').encode('utf-8')
            if json.loads(encoded) != value:
                raise AssemblyError('canonical encoding changed parsed values')
        except (ValueError, UnicodeError) as error:
            raise AssemblyError(f'{name}: invalid JSON: {error}') from error
        contents[name] = encoded
    contents[MANIFEST] = ''.join(f'{hashlib.sha256(contents[name]).hexdigest()}  {name}\n' for name in sorted(REQUIRED_FILES)).encode('ascii')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.evidence-assembly-', dir=output.parent) as temporary:
        stage = Path(temporary) / 'output'
        stage.mkdir()
        tree = stage / ROOT
        tree.mkdir()
        for name, data in contents.items():
            path = tree / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        entries = {ROOT: None, **{f'{ROOT}/{name}': None for name in directories},
                   **{f'{ROOT}/{name}': data for name, data in contents.items()}}
        with (stage / 'hermes-console-release-evidence.tar.gz').open('wb') as stream:
            with gzip.GzipFile(filename='', mode='wb', fileobj=stream, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as archive:
                    for name, data in sorted(entries.items()):
                        member = tarfile.TarInfo(name)
                        member.uid = member.gid = member.mtime = 0
                        member.uname = member.gname = ''
                        member.mode = 0o755 if data is None else 0o644
                        member.type = tarfile.DIRTYPE if data is None else tarfile.REGTYPE
                        member.size = 0 if data is None else len(data)
                        archive.addfile(member, None if data is None else io.BytesIO(data))
        stage.rename(output)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-directory', type=Path, required=True)
    parser.add_argument('--output-directory', type=Path, required=True)
    args = parser.parse_args()
    try:
        assemble(args.input_directory, args.output_directory)
    except (OSError, AssemblyError) as error:
        print(f'ERROR: evidence assembly: {error}', file=sys.stderr)
        return 1
    print('Release evidence archive assembled; run final validators before publication.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
