#!/usr/bin/env python3
"""Developer-only bundle builder. End users receive a GUI, never pip commands.

Builds locally with an explicitly selected, prepared Python environment. Models
are not downloaded or embedded. No signing, Release, upload or account change.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MODULES = ('qwen_tts', 'torch', 'transformers', 'soundfile', 'librosa', 'numpy', 'accelerate', 'safetensors')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python', type=Path, required=True, help='Prepared build environment Python')
    parser.add_argument('--output', type=Path, required=True, help='New output folder outside checkout')
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() or output == ROOT or ROOT in output.parents:
        raise ValueError('Choose a new output folder outside the checkout')
    python = str(args.python.resolve())
    metadata_code = '''
import importlib.util, importlib.metadata as m, json, platform, sys
required = %r
missing = [name for name in required if importlib.util.find_spec(name) is None]
items = []
for dist in m.distributions():
    licenses = [str(dist.locate_file(f)) for f in dist.files or []
                if ('.dist-info/licenses/' in str(f).lower() or
                    ('.dist-info/' in str(f).lower() and f.name.lower().startswith(('license','copying','notice'))))
                and dist.locate_file(f).is_file()]
    items.append({'name':dist.metadata.get('Name','unknown'), 'version':dist.version, 'files':licenses})
print(json.dumps({'missing':missing,'system':platform.system(),'machine':platform.machine(), 'packages':items}))
''' % (MODULES + ('PyInstaller', 'tkinter'),)
    inventory = json.loads(subprocess.check_output([python, '-c', metadata_code], text=True))
    if inventory['missing']:
        raise ValueError('Build environment lacks: ' + ', '.join(inventory['missing']))
    if inventory['system'] not in ('Windows', 'Darwin') or inventory['machine'].lower() not in ('amd64','x86_64','arm64','aarch64'):
        raise ValueError('Build on the matching supported OS/CPU')
    if inventory['system'] == 'Windows' and inventory['machine'].lower() not in ('amd64','x86_64'):
        raise ValueError('Windows helper requires native x64')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='castor-neural-build-', dir=output.parent) as temp:
        stage = Path(temp)
        command = [python, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir', '--windowed',
            '--name', 'CastorNeuralTTS', '--distpath', str(stage/'dist'), '--workpath', str(stage/'work'),
            '--specpath', str(stage/'spec')]
        for module in MODULES:
            command += ['--collect-all', module]
        command += [str(ROOT/'scripts/windows_neural_tts_server.py')]
        subprocess.run(command, check=True)
        mac = inventory['system'] == 'Darwin'
        built = stage/'dist'/('CastorNeuralTTS.app' if mac else 'CastorNeuralTTS')
        if not built.is_dir(): raise ValueError('Helper output was not generated')
        final = stage/'candidate'; final.mkdir()
        payload = final/'CastorNeuralTTS.app' if mac else final
        # Freeze symlink resources as regular files before signature/ZIP checks.
        if mac: shutil.copytree(built, payload, symlinks=False)
        else: shutil.copytree(built, final, dirs_exist_ok=True, symlinks=False)
        licenses = (payload/'Contents/Resources/licenses' if mac else final/'licenses')
        licenses.mkdir(parents=True, exist_ok=True)
        records = []
        for item in inventory['packages']:
            name = item['name']
            if not name or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-' for c in name):
                raise ValueError('Unexpected distribution name')
            files = []
            for index, original in enumerate(item['files']):
                source = Path(original)
                relative = Path(name)/('%03d-%s' % (index, source.name))
                destination = licenses/relative; destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination); files.append(relative.as_posix())
            records.append({'name':name,'version':item['version'],'licenseFiles':files,'reviewRequired':not bool(files)})
        (licenses/'inventory.json').write_text(json.dumps(records, indent=2)+'\n', encoding='utf-8')
        shutil.copy2(ROOT/'LICENSE', final/'LICENSE'); shutil.copy2(ROOT/'THIRD_PARTY_NOTICES.md', final/'THIRD_PARTY_NOTICES.md')
        expected = payload/'Contents/MacOS/CastorNeuralTTS' if mac else final/'CastorNeuralTTS.exe'
        if not expected.is_file(): raise ValueError('GUI helper executable is missing')
        shutil.move(str(final), output)
    print('Prepared local GUI helper:', output)
    print('No models, signing or Release. Review license inventory and verify on a clean device before distribution.')


if __name__ == '__main__': main()
