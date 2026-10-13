#!/usr/bin/env python3
"""Package already-built apps locally; never upload or create a Release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = ('macos_arm64', 'macos_x86_64', 'windows_x86_64')
LICENSES = ('LICENSE', 'THIRD_PARTY_NOTICES.md')


def valid_file(path):
    if any(ord(char) < 32 for char in str(path)):
        raise ValueError("Control characters are not allowed in release filenames.")
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'Only regular files are allowed: {path.name}')
    if path.suffix.lower() in {'.p12', '.p8', '.pem', '.key', '.cer', '.log'}:
        raise ValueError(f'Unexpected local data or secret file: {path.name}')
    if any(part in {'.git', '.env', '__pycache__', 'xcuserdata', '.DS_Store'} for part in path.parts):
        raise ValueError('Local files must not be included in a release.')


def put(z, source, name):
    info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    mode = 0o755 if source.stat().st_mode & 0o111 or name.endswith(".command") or name == "Castor.app/Contents/MacOS/Castor" else 0o644
    info.external_attr = (stat.S_IFREG | mode) << 16
    z.writestr(info, source.read_bytes())


def check_arch(binary, platform):
    data = binary.read_bytes()
    if platform.startswith('windows'):
        if data[:2] != b'MZ' or len(data) < 64:
            raise ValueError('Expected a Windows PE executable.')
        offset = struct.unpack_from('<I', data, 60)[0]
        if data[offset:offset+4] != b'PE\0\0' or len(data) < offset + 6 or struct.unpack_from('<H', data, offset+4)[0] != 0x8664:
            raise ValueError('Expected a Windows x64 executable.')
    else:
        # Thin Mach-O only, explicit architecture to avoid claiming unbuilt support.
        expected = 0x0100000c if platform.endswith('arm64') else 0x01000007
        if data[:4] != b'\xcf\xfa\xed\xfe' or len(data) < 8 or struct.unpack_from('<I', data, 4)[0] != expected:
            raise ValueError('Expected a thin Mach-O executable matching the selected Mac CPU.')


def prepare(output, version, apps):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', version):
        raise ValueError('Version must be a simple Release name.')
    if not apps:
        raise ValueError('Provide at least one built app.')
    output = output.resolve()
    if output.exists() or output == ROOT or ROOT in output.parents:
        raise ValueError('Choose a new output folder outside the repository.')
    # Validate all inputs before creating any output.
    payloads = {}
    for platform, source in apps.items():
        source = source.resolve()
        if not source.is_dir():
            raise ValueError('App input must be a directory.')
        if platform.startswith('macos'):
            if source.name != 'Castor.app':
                raise ValueError('Expected Castor.app.')
            info = plistlib.loads((source/'Contents/Info.plist').read_bytes())
            if info.get('CFBundleExecutable') != 'Castor':
                raise ValueError('Unexpected macOS app executable.')
            check_arch(source/'Contents/MacOS/Castor', platform)
            files = []
            for p in sorted(source.rglob('*')):
                if p.is_symlink():
                    raise ValueError('Review app symlinks before packaging.')
                if p.is_file():
                    valid_file(p)
                    files.append((p, 'Castor.app/'+p.relative_to(source).as_posix()))
        else:
            check_arch(source/'CastorPet.exe', platform)
            files = []
            for p in sorted(source.iterdir()):
                # Only an explicit runtime directory: executable and DLLs, no pets/configs/debug data.
                if p.name == 'CastorPet.exe' or p.suffix.lower() == '.dll':
                    valid_file(p)
                    files.append((p, p.name))
                else:
                    raise ValueError(f'Unexpected Windows runtime file: {p.name}')
            if not any(p.name.lower() == 'swiftcore.dll' for p, _ in files):
                raise ValueError('Include the redistributable Swift runtime DLLs beside CastorPet.exe.')
            files.extend((ROOT/'download'/name, name) for name in ('Start-Castor.cmd', 'Start-Castor.ps1'))
        files.extend((ROOT/name, name) for name in LICENSES)
        payloads[platform] = files
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='castor-release-', dir=output.parent) as temp:
        stage = Path(temp)
        manifest = {'schema': 1, 'version': version, 'platforms': {}}
        for platform, files in payloads.items():
            name = f'Castor-{version}-{platform}.zip'
            archive = stage/name
            with zipfile.ZipFile(archive, 'w') as z:
                for source, relative in files:
                    put(z, source, relative)
            manifest['platforms'][platform] = {
                'asset': name, 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
                'bytes': archive.stat().st_size,
            }
        (stage/'castor-downloads.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')
        with zipfile.ZipFile(stage/'Castor-Downloader.zip', 'w') as z:
            for name in ('Castor-Download.command', 'Castor-Download.cmd', 'Castor-Download.ps1'):
                put(z, ROOT/'download'/name, name)
        # Exclusive output reservation; never merge into an existing output.
        output.mkdir()
        for p in stage.iterdir():
            os.rename(p, output/p.name)
    print(f'Prepared {len(apps)} platform(s) in {output}')
    print('No Release, upload, authentication or visibility was changed.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', type=Path, required=True, help='New folder outside the checkout')
    for p in PLATFORMS:
        parser.add_argument('--'+p.replace('_', '-'), dest=p, type=Path,
                            help='Built Castor.app (Mac) or flat executable + runtime DLL directory (Windows)')
    args = parser.parse_args()
    try:
        prepare(args.output, args.version, {p: getattr(args, p) for p in PLATFORMS if getattr(args, p)})
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException) as error:
        parser.exit(1, f'error: {error}\n')


if __name__ == '__main__':
    main()
