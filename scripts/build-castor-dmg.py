#!/usr/bin/env python3
"""Package a built Castor.app as a drag-to-Applications disk image. Never uploads.

    python3 scripts/build-castor-dmg.py --app /path/to/Castor.app --version v1.0.0 \
        --output /path/outside/checkout/Castor-v1.0.0-macos_arm64.dmg

Needs dmgbuild (`python3 -m pip install dmgbuild`). The window shows the app,
an Applications link and a background explaining the one-time
"Open Anyway" step for unsigned builds. Signing and notarization, when they
exist, are applied to the app before this step and to the image after it.
"""
import argparse
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REQUIRED_MODELS = (
    'Arils_ArilsFaceInference.bundle/Contents/Resources/AnimeFaceModels/AnimeFaceBoxHead.mlmodelc',
    'Arils_ArilsFaceInference.bundle/Contents/Resources/AnimeFaceModels/AnimeFaceFeatures.mlmodelc',
    'Arils_ArilsFaceInference.bundle/Contents/Resources/AnimeFaceModels/AnimeFaceLandmarks.mlmodelc',
    'Arils_ArilsSubjectInference.bundle/Contents/Resources/AnimeSegmentationModel/AnimeSegmentation.mlmodelc',
)


def check_app(app: Path):
    if app.name != 'Castor.app' or not app.is_dir():
        raise ValueError('Expected a built Castor.app.')
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    if info.get('CFBundleExecutable') != 'Castor':
        raise ValueError('Unexpected app executable.')
    missing = [m for m in REQUIRED_MODELS if not (app/'Contents/Resources'/m).is_dir()]
    if missing:
        # Without them face review silently falls back to a much weaker estimator.
        raise ValueError('Castor.app is missing Core ML models: ' + ', '.join(Path(m).name for m in missing))


def verify_image(image: Path):
    """Mount the result read-only and check the copied app still verifies."""
    attached = plistlib.loads(subprocess.check_output(
        ['hdiutil', 'attach', '-nobrowse', '-readonly', '-plist', str(image)]))
    mount = next(e['mount-point'] for e in attached['system-entities'] if 'mount-point' in e)
    try:
        check_app(Path(mount)/'Castor.app')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(Path(mount)/'Castor.app')], check=True)
        if not (Path(mount)/'Applications').is_symlink():
            raise ValueError('The Applications link is missing.')
    finally:
        subprocess.run(['hdiutil', 'detach', mount, '-quiet'], check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        import dmgbuild
    except ImportError:
        parser.exit(1, 'error: dmgbuild is required: python3 -m pip install dmgbuild\n')
    app, output = args.app.resolve(), args.output.resolve()
    try:
        check_app(app)
        if output.exists() or ROOT in output.parents:
            raise ValueError('Choose a new output path outside the checkout.')
        if output.suffix != '.dmg':
            raise ValueError('The output must end with .dmg.')
        assets = ROOT/'assets'
        settings = {
            'format': 'ULFO',                      # LZFSE, readable on every supported macOS
            'filesystem': 'APFS',
            'files': [str(app)],
            'symlinks': {'Applications': '/Applications'},
            'icon': str(assets/'icon/Castor.icns'),
            'background': str(assets/'dmg/background.tiff'),
            'window_rect': ((200, 160), (660, 400)),
            'default_view': 'icon-view',
            'show_status_bar': False, 'show_tab_view': False, 'show_toolbar': False,
            'show_pathbar': False, 'show_sidebar': False,
            'arrange_by': None, 'icon_size': 112, 'text_size': 13,
            # Do not set hide_extensions: it writes Finder info into the app
            # bundle, which breaks its code signature ("detritus").
            'icon_locations': {'Castor.app': (175, 205), 'Applications': (485, 205)},
        }
        output.parent.mkdir(parents=True, exist_ok=True)
        dmgbuild.build_dmg(str(output), f'Castor {args.version}', settings=settings)
        verify_image(output)
        print(f'Prepared {output}. No Release, upload or signing was changed.')
    except (OSError, ValueError, StopIteration, subprocess.CalledProcessError) as error:
        parser.exit(1, f'error: {error}\n')


if __name__ == '__main__':
    sys.exit(main())
