#!/usr/bin/env python3
"""Developer-only bundle builder. End users receive a GUI, never pip commands.

Builds locally with an explicitly selected, prepared Python environment. Models
are not downloaded or embedded. No production signing, Release, upload or account change.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from castor_privacy import check_private_home

ROOT = Path(__file__).resolve().parents[1]
MODULES = ('qwen_tts', 'torch', 'transformers', 'soundfile', 'librosa', 'numpy', 'accelerate', 'safetensors')


def license_sources(item, supplements):
    originals = list(item['files'])
    extra = sorted(supplements.glob('%s-%s-*.txt' % (item['name'], item['version'])))
    originals.extend(str(file) for file in extra if not item['files'] or file.name.endswith('-NOTICES.txt'))
    if not originals:
        raise ValueError('Required license text is missing: %s %s' % (item['name'], item['version']))
    return originals


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python', type=Path, required=True, help='Prepared build environment Python')
    parser.add_argument('--output', type=Path, required=True, help='New output folder outside checkout')
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() or output == ROOT or ROOT in output.parents:
        raise ValueError('Choose a new output folder outside the checkout')
    python = str(args.python.absolute())  # Preserve a venv's Python symlink path.
    modules = ('mlx_audio','mlx','mlx_lm','transformers','numpy','scipy','safetensors','huggingface_hub','tokenizers') if platform.system() == 'Darwin' and platform.machine().lower() in ('arm64','aarch64') else MODULES
    metadata_code = '''
import importlib.util, importlib.metadata as m, json, platform, sys, sysconfig
from pathlib import Path
required = %r
missing = [name for name in required if importlib.util.find_spec(name) is None]
items = []
for dist in m.distributions():
    licenses = [str(dist.locate_file(f)) for f in dist.files or []
                if ('.dist-info/licenses/' in str(f).lower() or
                    ('.dist-info/' in str(f).lower() and f.name.lower().startswith(('license','copying','notice'))))
                and dist.locate_file(f).is_file()]
    items.append({'name':dist.metadata.get('Name','unknown'), 'version':dist.version, 'files':licenses})
runtime = [str(p) for p in (Path(sysconfig.get_path('stdlib'))/'LICENSE.txt',Path(sys.base_prefix)/'LICENSE.txt') if p.is_file()]
print(json.dumps({'missing':missing,'system':platform.system(),'machine':platform.machine(), 'packages':items,'runtimeLicenses':runtime}))
''' % (modules + ('PyInstaller', 'tkinter'),)
    inventory = json.loads(subprocess.check_output([python, '-c', metadata_code], text=True))
    if inventory['missing']:
        raise ValueError('Build environment lacks: ' + ', '.join(inventory['missing']))
    if inventory['system'] not in ('Windows', 'Darwin') or inventory['machine'].lower() not in ('amd64','x86_64','arm64','aarch64'):
        raise ValueError('Build on the matching supported OS/CPU')
    if inventory['system'] == 'Windows' and inventory['machine'].lower() not in ('amd64','x86_64'):
        raise ValueError('Windows helper requires native x64')
    for item in inventory['packages']:
        item['licenseSources'] = license_sources(item, ROOT/'scripts/neural_helper_licenses')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='castor-neural-build-', dir=output.parent) as temp:
        stage = Path(temp)
        mac = inventory['system'] == 'Darwin'
        command = [python, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onefile' if mac else '--onedir', '--console' if mac else '--windowed',
            '--name', 'CastorSpeechRuntime' if mac else 'CastorNeuralTTS', '--distpath', str(stage/'dist'), '--workpath', str(stage/'work'),
            '--specpath', str(stage/'spec')]
        for module in modules:
            command += ['--collect-all', module]
        command += [str(ROOT/'scripts/windows_neural_tts_server.py')]
        # Collection imports third-party modules. Keep build hooks offline and
        # prevent any ambient Hub credential from being used during those imports.
        build_environment = os.environ.copy()
        for key in ('HF_TOKEN', 'HUGGING_FACE_HUB_TOKEN'): build_environment.pop(key, None)
        build_environment['HF_HUB_OFFLINE'] = '1'
        build_environment['HF_HUB_DISABLE_IMPLICIT_TOKEN'] = '1'
        subprocess.run(command, check=True, env=build_environment)
        final = stage/'candidate'; final.mkdir()
        payload = final/'CastorNeuralTTS.app' if mac else final
        if mac:
            scratch = stage/'swift'
            subprocess.run(['swift','build','--package-path',str(ROOT/'CastorDesktop'),'--scratch-path',str(scratch),'-c','release','--product','CastorNeuralTTS',
                '-Xswiftc','-debug-prefix-map','-Xswiftc',str(ROOT)+'=/Castor',
                '-Xswiftc','-file-prefix-map','-Xswiftc',str(ROOT)+'=/Castor'],check=True)
            binary = Path(subprocess.check_output(['swift','build','--package-path',str(ROOT/'CastorDesktop'),'--scratch-path',str(scratch),'-c','release','--show-bin-path'],text=True).strip())/'CastorNeuralTTS'
            contents = payload/'Contents'; (contents/'MacOS').mkdir(parents=True); (contents/'Resources').mkdir()
            shutil.copy2(binary, contents/'MacOS/CastorNeuralTTS')
            subprocess.run(['/usr/bin/strip','-S','-x',str(contents/'MacOS/CastorNeuralTTS')],check=True)
            shutil.copy2(stage/'dist/CastorSpeechRuntime', contents/'Resources/CastorSpeechRuntime')
            info={'CFBundleExecutable':'CastorNeuralTTS','CFBundleIdentifier':'dev.castor.neuraltts','CFBundleName':'Castor Neural TTS',
                  'CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'0.1.0','LSMinimumSystemVersion':'26.5',
                  'CFBundleIconFile':'Castor'}
            shutil.copy2(ROOT/'assets/icon/Castor.icns', contents/'Resources/Castor.icns')
            (contents/'Info.plist').write_bytes(plistlib.dumps(info))
        else:
            built = stage/'dist/CastorNeuralTTS'
            if not built.is_dir(): raise ValueError('Helper output was not generated')
            shutil.copytree(built, final, dirs_exist_ok=True, symlinks=False)
        licenses = (payload/'Contents/Resources/licenses' if mac else final/'licenses')
        licenses.mkdir(parents=True, exist_ok=True)
        records = []
        for item in inventory['packages']:
            name = item['name']
            if not name or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-' for c in name):
                raise ValueError('Unexpected distribution name')
            files = []
            originals = item['licenseSources']
            for index, original in enumerate(originals):
                source = Path(original)
                relative = Path(name)/('%03d-%s' % (index, source.name))
                destination = licenses/relative; destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination); files.append(relative.as_posix())
            records.append({'name':name,'version':item['version'],'licenseFiles':files,'reviewRequired':not bool(files)})
        if not inventory['runtimeLicenses']:
            raise ValueError('The bundled Python runtime requires its license text')
        for index, original in enumerate(inventory['runtimeLicenses']):
            shutil.copy2(original,licenses/('Python-%d-LICENSE.txt' % index))
        (licenses/'inventory.json').write_text(json.dumps(records, indent=2)+'\n', encoding='utf-8')
        shutil.copy2(ROOT/'LICENSE', final/'LICENSE'); shutil.copy2(ROOT/'THIRD_PARTY_NOTICES.md', final/'THIRD_PARTY_NOTICES.md')
        expected = payload/'Contents/MacOS/CastorNeuralTTS' if mac else final/'CastorNeuralTTS.exe'
        if not expected.is_file(): raise ValueError('GUI helper executable is missing')
        if mac:
            subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(payload)],check=True)
            check_private_home(payload)
        shutil.move(str(final), output)
    print('Prepared local GUI helper:', output)
    print('No models or public Release. Mac helper uses PyInstaller ad-hoc development signature. Review license inventory and verify on a clean device before distribution.')


if __name__ == '__main__': main()
