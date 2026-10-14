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


def valid_file(path, public_ca=False):
    if any(ord(char) < 32 for char in str(path)):
        raise ValueError("Control characters are not allowed in release filenames.")
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'Only regular files are allowed: {path.name}')
    if path.suffix.lower() in {'.p12', '.p8', '.pem', '.key', '.cer', '.log'} and not public_ca:
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


def prepare(output, version, apps, setups=None, neural_helpers=None):
    setups = setups or {}
    neural_helpers = neural_helpers or {}
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
                if p.name in ('CastorPet.exe','CastorSetup.exe') or p.suffix.lower() == '.dll':
                    valid_file(p)
                    files.append((p, p.name))
                elif p.name in LICENSES:
                    valid_file(p)
                else:
                    raise ValueError(f'Unexpected Windows runtime file: {p.name}')
            if not any(p.name.lower() == 'swiftcore.dll' for p, _ in files):
                raise ValueError('Include the redistributable Swift runtime DLLs beside CastorPet.exe.')
            files.extend((ROOT/'download'/name, name) for name in ('Start-Castor.cmd', 'Start-Castor.ps1'))
        files.extend((ROOT/name, name) for name in LICENSES)
        payloads[platform] = files
    setup_payloads = {}
    for platform, source in setups.items():
        if platform not in PLATFORMS:
            raise ValueError('Unexpected setup platform.')
        source = source.resolve()
        if platform.startswith('macos'):
            if source.name != 'CastorSetup.app' or plistlib.loads((source/'Contents/Info.plist').read_bytes()).get('CFBundleExecutable') != 'CastorSetup':
                raise ValueError('Expected the native CastorSetup.app.')
            check_arch(source/'Contents/MacOS/CastorSetup', platform)
            files = []
            for p in sorted(source.rglob('*')):
                if p.is_symlink():
                    raise ValueError('Setup symlinks require review.')
                if p.is_file():
                    valid_file(p);files.append((p,'CastorSetup.app/'+p.relative_to(source).as_posix()))
        else:
            check_arch(source/'CastorSetup.exe', platform)
            files = []
            for p in sorted(source.iterdir()):
                if p.name == 'CastorSetup.exe' or p.suffix.lower() == '.dll':
                    valid_file(p);files.append((p,p.name))
                elif p.name not in LICENSES:
                    raise ValueError(f'Unexpected setup runtime file: {p.name}')
            if not any(p.name.lower() == 'swiftcore.dll' for p,_ in files):
                raise ValueError('The GUI setup needs its own Swift runtime DLLs.')
        files.extend((ROOT/name,name) for name in LICENSES)
        setup_payloads[platform] = files
    helper_payloads = {}
    for helper_platform, helper_source in neural_helpers.items():
        if helper_platform not in PLATFORMS:
            raise ValueError('Unexpected helper platform')
        helper_source = helper_source.resolve()
        executable = helper_source/'CastorNeuralTTS.app/Contents/MacOS/CastorNeuralTTS' if helper_platform.startswith('macos') else helper_source/'CastorNeuralTTS.exe'
        if not helper_source.is_dir() or not executable.is_file():
            raise ValueError('Built GUI Neural TTS helper is required')
        check_arch(executable,helper_platform)
        files = []
        for file in helper_source.rglob('*'):
            if file.is_symlink(): raise ValueError('Review helper symlinks before packaging')
            if file.is_file():
                relative = file.relative_to(helper_source).as_posix()
                allowed = relative.startswith('CastorNeuralTTS.app/') if helper_platform.startswith('macos') else relative == 'CastorNeuralTTS.exe' or relative.startswith(('_internal/','licenses/'))
                if not allowed and relative not in ('LICENSE','THIRD_PARTY_NOTICES.md'):
                    raise ValueError('Unexpected helper file: '+relative)
                public_ca = relative in ('_internal/certifi/cacert.pem','CastorNeuralTTS.app/Contents/Resources/certifi/cacert.pem','CastorNeuralTTS.app/Contents/Frameworks/certifi/cacert.pem')
                if public_ca:
                    certificate = file.read_bytes()
                    if len(certificate)>1024*1024 or b'PRIVATE KEY' in certificate or b'BEGIN CERTIFICATE' not in certificate:
                        raise ValueError('Unexpected CA trust bundle')
                    import ssl
                    ssl.create_default_context(cafile=str(file))
                valid_file(file,public_ca=public_ca)
                files.append((file,relative))
        for name in ('LICENSE','THIRD_PARTY_NOTICES.md'):
            if not any(relative == name for _,relative in files): files.append((ROOT/name,name))
        helper_payloads[helper_platform] = files
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='castor-release-', dir=output.parent) as temp:
        stage = Path(temp)
        manifest = {'schema': 1, 'version': version, 'platforms': {}}
        if setup_payloads:
            manifest['setup'] = {}
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
        for platform, files in setup_payloads.items():
            name = f'CastorSetup-{version}-{platform}.zip'
            archive = stage/name
            with zipfile.ZipFile(archive, 'w') as z:
                for source, relative in files:
                    put(z,source,relative)
            manifest['setup'][platform] = {'asset':name,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'bytes':archive.stat().st_size}
        if helper_payloads:
            manifest['components'] = {'NeuralTTS': {}}
        for helper_platform, files in helper_payloads.items():
            name = f'CastorNeuralTTS-{version}-{helper_platform}.zip'
            archive = stage/name
            with zipfile.ZipFile(archive,'w') as z:
                for source, relative in files: put(z,source,relative)
            manifest['components']['NeuralTTS'][helper_platform] = {'asset':name,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'bytes':archive.stat().st_size}
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
        parser.add_argument('--neural-helper-'+p.replace('_','-'),dest='neural_helper_'+p,type=Path,help='Built GUI Neural TTS helper payload directory')
        parser.add_argument('--setup-'+p.replace('_','-'),dest='setup_'+p,type=Path,
                            help='Native GUI setup app (Mac) or setup executable + DLL directory (Windows)')
    args = parser.parse_args()
    try:
        prepare(args.output, args.version, {p: getattr(args, p) for p in PLATFORMS if getattr(args, p)},
                {p: getattr(args,'setup_'+p) for p in PLATFORMS if getattr(args,'setup_'+p)},
                {p: getattr(args,'neural_helper_'+p) for p in PLATFORMS if getattr(args,'neural_helper_'+p)})
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException) as error:
        parser.exit(1, f'error: {error}\n')


if __name__ == '__main__':
    main()
