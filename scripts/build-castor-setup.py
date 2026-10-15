#!/usr/bin/env python3
"""Build a native GUI installer locally. Does not upload or bypass OS checks."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def pe_imports(path):
    """Read PE import names; the Windows loader will resolve these beside the EXE."""
    data = path.read_bytes()
    if data[:2] != b'MZ' or len(data) < 64:
        raise ValueError(f'Not a PE executable: {path.name}')
    header = struct.unpack_from('<I', data, 60)[0]
    if data[header:header+4] != b'PE\0\0':
        raise ValueError(f'Not a PE executable: {path.name}')
    sections, optional_size = struct.unpack_from('<H', data, header+6)[0], struct.unpack_from('<H', data, header+20)[0]
    optional = header+24
    magic = struct.unpack_from('<H', data, optional)[0]
    directories = optional+(112 if magic == 0x20b else 96 if magic == 0x10b else 0)
    if directories == optional:
        raise ValueError('Unknown PE optional header')
    import_rva, import_size = struct.unpack_from('<II', data, directories+8)
    section_table = optional+optional_size
    def offset(rva):
        for index in range(sections):
            block = section_table+index*40
            virtual_size, virtual_address, raw_size, raw_offset = struct.unpack_from('<IIII', data, block+8)
            if virtual_address <= rva < virtual_address+max(virtual_size, raw_size):
                result = raw_offset+rva-virtual_address
                if result >= len(data):
                    raise ValueError('PE offset outside file')
                return result
        raise ValueError('PE import outside sections')
    if not import_rva:
        return []
    cursor = offset(import_rva)
    imports = []
    for _ in range(min(import_size//20+1, 4096)):
        block = struct.unpack_from('<IIIII', data, cursor)
        if not any(block):
            return imports
        name_offset = offset(block[3])
        name = data[name_offset:data.index(b'\0', name_offset)].decode('ascii')
        if not name.lower().endswith('.dll') or any(c in name for c in '\\/:'):
            raise ValueError('Invalid PE import name')
        imports.append(name)
        cursor += 20
    raise ValueError('Unterminated PE import directory')


def windows_runtime(executables, output, bin_path, runtime_dirs):
    """Collect transitive Swift/C++ DLL imports, never DLLs from System32."""
    system = Path(os.environ.get("SystemRoot", r"C:\Windows"))/"System32"
    search = [bin_path, *runtime_dirs]
    swift = Path(shutil.which('swift')).resolve()
    info = __import__('json').loads(subprocess.check_output(['swift', '-print-target-info'], text=True))
    search.extend(Path(p) for p in info.get('paths', {}).get('runtimeLibraryPaths', []))
    search.extend(Path(p) for p in os.environ.get('PATH', '').split(os.pathsep) if p)
    swift_root = swift.parent
    for _ in range(4):
        if swift_root.name.lower() == 'swift':
            break
        swift_root = swift_root.parent
    runtime_root = Path(os.environ.get('ProgramFiles', r'C:\Program Files'))/'Swift'/'Runtimes'
    extra_roots = [runtime_root]
    redist = os.environ.get('VCToolsRedistDir')
    if redist:
        extra_roots.append(Path(redist))
    vswhere=Path(os.environ.get('ProgramFiles(x86)',r'C:\Program Files (x86)'))/'Microsoft Visual Studio/Installer/vswhere.exe'
    if vswhere.is_file():
        location=subprocess.check_output([str(vswhere),'-latest','-products','*','-property','installationPath'],text=True).strip()
        if location:
            extra_roots.append(Path(location)/'VC/Redist/MSVC')
    for base in extra_roots:
        if base.is_dir():
            search.extend(sorted({p.parent for p in base.rglob('*.dll')}))
    inventory = {}
    for directory in search:
        if directory.is_dir() and directory.resolve() != system.resolve():
            for dll in directory.glob('*.dll'):
                # Runtime trees may contain other architectures as well.
                try:
                    data = dll.read_bytes()
                    header = struct.unpack_from('<I', data, 60)[0]
                    if data[header:header+4] == b'PE\0\0' and struct.unpack_from('<H',data,header+4)[0] == 0x8664:
                        inventory.setdefault(dll.name.lower(), dll)
                except (OSError, struct.error):
                    continue
    system = Path(os.environ.get('SystemRoot', r'C:\Windows'))/'System32'
    pending = []
    for executable in executables:
        shutil.copy2(bin_path/executable, output/executable)
        pending.append(output/executable)
    copied = set()
    while pending:
        for name in pe_imports(pending.pop()):
            key = name.lower()
            if key in copied or key.startswith(('api-ms-', 'ext-ms-')):
                continue
            source = inventory.get(key)
            if source:
                shutil.copy2(source, output/name)
                copied.add(key);pending.append(output/name)
            elif (system/name).is_file() and not key.startswith(('vcruntime', 'msvcp', 'concrt')):
                continue
            else:
                raise ValueError(f'Missing redistributable DLL: {name}. Add its approved runtime directory with --runtime-dir.')
    if 'swiftcore.dll' not in copied:
        raise ValueError('Swift runtime was not collected.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New external output folder')
    parser.add_argument('--scratch', type=Path, required=True)
    parser.add_argument('--arch', choices=['arm64', 'x86_64'], default='arm64')
    parser.add_argument('--runtime-dir', type=Path, action='append', default=[])
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() or output == ROOT or ROOT in output.parents:
        parser.error('Choose a new output folder outside the checkout.')
    try:
        command = ['swift', 'build', '--package-path', str(ROOT/'CastorDesktop'), '--scratch-path', str(args.scratch), '-c', 'release', '--product', 'CastorSetup']
        if sys.platform == 'darwin':
            command += ['--arch', args.arch,
                '-Xswiftc','-debug-prefix-map','-Xswiftc',str(ROOT)+'=/Castor',
                '-Xswiftc','-file-prefix-map','-Xswiftc',str(ROOT)+'=/Castor']
        subprocess.run(command, check=True)
        bin_command = ['swift', 'build', '--package-path', str(ROOT/'CastorDesktop'), '--scratch-path', str(args.scratch), '-c', 'release', '--show-bin-path']
        if sys.platform == 'darwin':
            bin_command += ['--arch', args.arch]
        bin_path = Path(subprocess.check_output(bin_command, text=True).strip())
        output.mkdir(parents=True)
        if sys.platform == 'darwin':
            app = output/'CastorSetup.app'/'Contents'
            (app/'MacOS').mkdir(parents=True); (app/'Resources').mkdir()
            shutil.copy2(bin_path/'CastorSetup', app/'MacOS'/'CastorSetup')
            shutil.copy2(ROOT/'assets/icon/Castor.icns', app/'Resources'/'Castor.icns')
            subprocess.run(['/usr/bin/strip','-S','-x',str(app/'MacOS'/'CastorSetup')],check=True)
            info = {'CFBundleExecutable':'CastorSetup', 'CFBundleIdentifier':'dev.castor.setup', 'CFBundleName':'Castor Setup',
                    'CFBundlePackageType':'APPL', 'CFBundleVersion':'1', 'CFBundleShortVersionString':'0.1.0', 'LSMinimumSystemVersion':'26.5', 'NSHighResolutionCapable':True,
                    'CFBundleIconFile':'Castor'}
            (app/'Info.plist').write_bytes(plistlib.dumps(info))
            # Development build only. Production signing/notarization is a separate gate.
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(output/'CastorSetup.app')], check=True)
        elif sys.platform == 'win32':
            windows_runtime(['CastorSetup.exe'], output, bin_path, args.runtime_dir)
        else:
            raise ValueError('Only Mac and Windows can build the native installer.')
        for name in ('LICENSE','THIRD_PARTY_NOTICES.md'):
            shutil.copy2(ROOT/name, output/name)
        print(f'Prepared GUI setup in {output}. Developer build; no public Release or upload.')
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'error: {error}\n')


if __name__ == '__main__':
    main()
