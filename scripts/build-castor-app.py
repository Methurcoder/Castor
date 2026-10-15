#!/usr/bin/env python3
"""Create a local app candidate with its GUI setup entry. Never upload.

Mac candidates use ad-hoc development signatures. Production signing and
notarization must be performed after assembling all nested resources.
"""
import argparse
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from castor_model_contract import require_source_models, require_app_models
from castor_privacy import check_private_home

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('castor_setup_builder', ROOT/'scripts/build-castor-setup.py')
SETUP = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(SETUP)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--scratch', type=Path, required=True)
    parser.add_argument('--arch', choices=('arm64','x86_64'), default='arm64')
    parser.add_argument('--neural-helper', type=Path, help='Prepared optional GUI helper root to include in the Mac candidate')
    parser.add_argument('--runtime-dir', type=Path, action='append', default=[])
    args = parser.parse_args()
    if sys.platform == 'darwin': require_source_models(ROOT)
    output = args.output.resolve()
    if output.exists() or output == ROOT or ROOT in output.parents:
        raise ValueError('Choose a new output directory outside checkout')
    output.parent.mkdir(parents=True, exist_ok=True)
    scratch = args.scratch.resolve(); scratch.mkdir(parents=True, exist_ok=True)
    setup_output = scratch/'gui-setup-candidate'
    if setup_output.exists():
        raise ValueError('Choose a new scratch folder; existing setup candidate is retained')
    subprocess.run([sys.executable, str(ROOT/'scripts/build-castor-setup.py'), '--output', str(setup_output),
                    '--scratch', str(scratch/'desktop'), '--arch', args.arch,
                    *[value for directory in args.runtime_dir for value in ('--runtime-dir',str(directory))]], check=True)
    if sys.platform == 'darwin':
        subprocess.run(['xcodebuild','-project',str(ROOT/'Castor/Castor.xcodeproj'),'-scheme','Castor',
            '-configuration','Release','-destination','generic/platform=macOS','-derivedDataPath',str(scratch/'app'),
            'ARCHS='+args.arch,'ONLY_ACTIVE_ARCH=NO','CODE_SIGNING_ALLOWED=NO',
            'CLANG_ENABLE_CODE_COVERAGE=NO','GCC_GENERATE_DEBUGGING_SYMBOLS=NO',
            'OTHER_SWIFT_FLAGS=$(inherited) -debug-prefix-map '+str(ROOT)+'=/Castor -file-prefix-map '+str(ROOT)+'=/Castor -coverage-prefix-map '+str(ROOT)+'=/Castor',
            'build'],check=True)
        built = scratch/'app/Build/Products/Release/Castor.app'
        if not built.is_dir(): raise ValueError('Mac app output is missing')
        require_app_models(built)
        stage = scratch/'app-candidate'; stage.mkdir()
        app = stage/'Castor.app'; shutil.copytree(built,app)
        resources=app/'Contents/Resources';resources.mkdir(exist_ok=True)
        # The DMG contains only the app, so its license and notices travel inside it.
        for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
            shutil.copy2(ROOT/name, resources/name)
        shutil.copytree(setup_output/'CastorSetup.app',resources/'CastorSetup.app')
        if args.neural_helper:
            helper=args.neural_helper/'CastorNeuralTTS.app'
            if not (helper/'Contents/MacOS/CastorNeuralTTS').is_file():
                raise ValueError('Prepared Mac GUI speech helper is missing')
            shutil.copytree(helper,resources/'CastorNeuralTTS.app',symlinks=False)
            subprocess.run(['/usr/bin/codesign','--force','--deep','--sign','-',str(resources/'CastorNeuralTTS.app')],check=True)
        subprocess.run(['/usr/bin/strip','-S','-x',str(app/'Contents/MacOS/Castor')],check=True)
        agent=app/'Contents/Library/Helpers/CastorAgentLauncher.app'
        if agent.is_dir():
            subprocess.run(['/usr/bin/strip','-S','-x',str(agent/'Contents/MacOS/CastorAgentLauncher')],check=True)
            subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(agent)],check=True)
        require_app_models(app)
        subprocess.run(['/usr/bin/codesign','--force','--sign','-', '--entitlements',str(ROOT/'Castor/Castor/Castor.entitlements'),str(app)],check=True)
        check_private_home(app)
        shutil.move(str(stage),output)
    elif sys.platform == 'win32':
        subprocess.run(['swift','build','--package-path',str(ROOT/'CastorDesktop'),'--scratch-path',str(scratch/'desktop'),
            '-c','release','--product','CastorPet'],check=True)
        bin_path=Path(subprocess.check_output(['swift','build','--package-path',str(ROOT/'CastorDesktop'),'--scratch-path',str(scratch/'desktop'),
            '-c','release','--show-bin-path'],text=True).strip())
        stage=scratch/'app-candidate';stage.mkdir()
        SETUP.windows_runtime(['CastorPet.exe','CastorSetup.exe'],stage,bin_path,args.runtime_dir)
        for name in ('LICENSE','THIRD_PARTY_NOTICES.md'):shutil.copy2(ROOT/name,stage/name)
        shutil.move(str(stage),output)
    else: raise ValueError('Build on Mac or Windows')
    print('Local app candidate with GUI setup:',output)
    print('No Release. Verify licenses, clean-device startup, production signing and notarization before distribution.')


if __name__ == '__main__': main()
