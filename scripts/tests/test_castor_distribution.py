"""Offline checks for packaging and native downloaders; no GitHub writes or app launches."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release', ROOT/'scripts/prepare-castor-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
PWSH = shutil.which('pwsh')


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='castor-distribution-test-')
        self.base = Path(self.temp.name)
        self.mac = self.base/'Castor.app'
        (self.mac/'Contents/MacOS').mkdir(parents=True)
        (self.mac/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Castor'}))
        executable = self.mac/'Contents/MacOS/Castor'
        executable.write_bytes(struct.pack('<II', 0xfeedfacf, 0x0100000c))
        executable.chmod(0o755)
        self.windows = self.base/'windows'
        self.windows.mkdir()
        data = bytearray(128)
        data[:2] = b'MZ'
        struct.pack_into('<I', data, 60, 64)
        data[64:68] = b'PE\0\0'
        struct.pack_into('<H', data, 68, 0x8664)
        (self.windows/'CastorPet.exe').write_bytes(data)
        (self.windows/'swiftCore.dll').write_bytes(b'test-runtime')
        self.output = self.base/'release'

    def tearDown(self):
        self.temp.cleanup()

    def package(self):
        release.prepare(self.output, 'local-test', {'macos_arm64': self.mac, 'windows_x86_64': self.windows})
        return json.loads((self.output/'castor-downloads.json').read_text())

    def test_packages_have_matching_hashes_architectures_licenses_and_launchers(self):
        manifest = self.package()
        for platform, asset in manifest['platforms'].items():
            data = (self.output/asset['asset']).read_bytes()
            self.assertEqual(asset['bytes'], len(data))
            self.assertEqual(asset['sha256'], hashlib.sha256(data).hexdigest())
            with zipfile.ZipFile(self.output/asset['asset']) as z:
                self.assertIn('LICENSE', z.namelist())
                self.assertIn('THIRD_PARTY_NOTICES.md', z.namelist())
                if platform.startswith('macos'):
                    self.assertTrue(z.getinfo('Castor.app/Contents/MacOS/Castor').external_attr >> 16 & 0o111)
                else:
                    self.assertIn('Start-Castor.cmd', z.namelist())
        with zipfile.ZipFile(self.output/'Castor-Downloader.zip') as z:
            self.assertEqual(len(z.namelist()), 3)
            self.assertFalse(any(n.endswith('.exe') or n.endswith('.app') for n in z.namelist()))

    def test_native_gui_setup_packages_include_their_own_runtime_and_hashes(self):
        setup_mac = self.base/'CastorSetup.app'
        (setup_mac/'Contents/MacOS').mkdir(parents=True)
        (setup_mac/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'CastorSetup'}))
        shutil.copy2(self.mac/'Contents/MacOS/Castor',setup_mac/'Contents/MacOS/CastorSetup')
        setup_windows = self.base/'setup-windows'
        setup_windows.mkdir()
        shutil.copy2(self.windows/'CastorPet.exe',setup_windows/'CastorSetup.exe')
        shutil.copy2(self.windows/'swiftCore.dll',setup_windows/'swiftCore.dll')
        release.prepare(self.output,'local-test',{'macos_arm64':self.mac,'windows_x86_64':self.windows},
                        {'macos_arm64':setup_mac,'windows_x86_64':setup_windows})
        manifest=json.loads((self.output/'castor-downloads.json').read_text())
        for platform,asset in manifest['setup'].items():
            archive=self.output/asset['asset']
            self.assertEqual(asset['sha256'],hashlib.sha256(archive.read_bytes()).hexdigest())
            with zipfile.ZipFile(archive) as z:
                self.assertIn('LICENSE',z.namelist())
                if platform.startswith('macos'):
                    self.assertIn('CastorSetup.app/Contents/MacOS/CastorSetup',z.namelist())
                else:
                    self.assertIn('CastorSetup.exe',z.namelist())
                    self.assertIn('swiftCore.dll',z.namelist())
                    self.assertNotIn('CastorPet.exe',z.namelist())

    @unittest.skipUnless(sys.platform == 'win32' and os.environ.get('CASTOR_SETUP_EXE'), 'Native Windows setup executable is required')
    def test_gui_setup_native_extraction_handles_spaces_unicode_and_quotes(self):
        archive=self.base/"Castor 日本語's package.zip"
        destination=self.base/"日本語's app folder"
        with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
            z.writestr('CastorPet.exe',b'fixture')
            z.writestr('swiftCore.dll',b'runtime fixture')
        environment=os.environ.copy()
        for key in list(environment):
            if key.upper().startswith('SWIFT') or key.upper() in {'SDKROOT','INCLUDE','LIB','LIBPATH'}:
                environment.pop(key,None)
        system=Path(os.environ.get('SystemRoot',r'C:\Windows'))
        environment['PATH']=os.pathsep.join([str(system/'System32'),str(system/'System32/WindowsPowerShell/v1.0')])
        result=subprocess.run([os.environ['CASTOR_SETUP_EXE'],'--check-extract',str(archive),str(destination)],capture_output=True,text=True,timeout=30,env=environment)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((destination/'CastorPet.exe').read_bytes(),b'fixture')
        self.assertEqual((destination/'swiftCore.dll').read_bytes(),b'runtime fixture')

    def test_rejects_wrong_cpu_before_output(self):
        with self.assertRaises(ValueError):
            release.prepare(self.output, 'test', {'macos_x86_64': self.mac})
        self.assertFalse(self.output.exists())

    def test_rejects_missing_runtime_and_personal_pet_files(self):
        (self.windows/'swiftCore.dll').unlink()
        with self.assertRaises(ValueError):
            release.prepare(self.output, 'test', {'windows_x86_64': self.windows})
        (self.windows/'swiftCore.dll').write_bytes(b'test')
        (self.windows/'CastorPet.json').write_text('{}')
        with self.assertRaises(ValueError):
            release.prepare(self.output, 'test', {'windows_x86_64': self.windows})
        self.assertFalse(self.output.exists())

    def test_rejects_symlinks_and_existing_output(self):
        (self.mac/'Contents/link').symlink_to('/tmp')
        with self.assertRaises(ValueError):
            release.prepare(self.output, 'test', {'macos_arm64': self.mac})
        (self.mac/'Contents/link').unlink()
        self.output.mkdir()
        marker = self.output/'keep'
        marker.write_text('existing')
        with self.assertRaises(ValueError):
            release.prepare(self.output, 'test', {'macos_arm64': self.mac})
        self.assertEqual(marker.read_text(), 'existing')

    def setup_release(self, corrupt=False):
        self.package()
        if corrupt:
            manifest_path = self.output/'castor-downloads.json'
            manifest = json.loads(manifest_path.read_text())
            for asset in manifest['platforms'].values():
                asset['sha256'] = '0'*64
            manifest_path.write_text(json.dumps(manifest))
        assets = ['castor-downloads.json', 'Castor-local-test-macos_arm64.zip', 'Castor-local-test-windows_x86_64.zip']
        metadata = {'tag_name': 'local-test', 'draft': False, 'prerelease': False, 'assets': [
            {'id': i+1, 'name': name, 'browser_download_url': 'https://github.com/Methurcoder/Castor/releases/download/local-test/'+name}
            for i, name in enumerate(assets)]}
        (self.output/'release.json').write_text(json.dumps(metadata))
        self.home = self.base/'home'
        self.home.mkdir()
        self.log = self.base/'fetches'

    @unittest.skipUnless(sys.platform == 'darwin', 'Native macOS launcher requires macOS')
    def test_mac_downloads_only_its_app_and_cleans_up(self):
        self.run_mac()

    @unittest.skipUnless(sys.platform == 'darwin', 'Native macOS launcher requires macOS')
    def test_mac_rejects_hash_mismatch(self):
        self.run_mac(corrupt=True)

    @unittest.skipUnless(sys.platform == 'darwin', 'Native macOS launcher requires macOS')
    def test_mac_preserves_existing_install(self):
        self.run_mac(existing=True)

    def run_mac(self, corrupt=False, existing=False):
        self.setup_release(corrupt)
        binaries = self.base/'bin'
        binaries.mkdir()
        for name, body in {'uname': 'echo Darwin', 'sw_vers': 'echo 26.5',
                           'sysctl': 'echo 1', 'open': 'exit 0'}.items():
            p = binaries/name
            p.write_text('#!/bin/sh\n'+body+'\n')
            p.chmod(0o755)
        curl = binaries/'curl'
        curl.write_text('#!'+sys.executable+'\n'+'''import os, sys, shutil
from pathlib import Path
args=sys.argv[1:]; url=next(a for a in args if a.startswith('https:'))
name='release.json' if url.endswith('/latest') else url.rsplit('/',1)[-1]
with open(os.environ['TEST_LOG'],'a') as f: f.write(name+'\\n')
shutil.copyfile(Path(os.environ['TEST_RELEASE'])/name, args[args.index('-o')+1])
''')
        curl.chmod(0o755)
        target = self.home/'Applications/Castor-local-test-macos_arm64'
        if existing:
            target.mkdir(parents=True)
            (target/'keep').write_text('existing')
        tmp = self.base/'tmp'
        tmp.mkdir()
        env = dict(os.environ, HOME=str(self.home), TMPDIR=str(tmp), PATH=str(binaries)+':/usr/bin:/bin:/usr/sbin',
                   TEST_LOG=str(self.log), TEST_RELEASE=str(self.output))
        result = subprocess.run(['/bin/bash', str(ROOT/'download/Castor-Download.command')], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, not (corrupt or existing), result.stdout+result.stderr)
        self.assertFalse(any(tmp.iterdir()))
        self.assertNotIn('windows', self.log.read_text())
        if corrupt:
            self.assertFalse(target.exists())
        elif existing:
            self.assertEqual((target/'keep').read_text(), 'existing')
        else:
            self.assertTrue((target/'Castor.app/Contents/MacOS/Castor').is_file())

    @unittest.skipUnless(PWSH, 'PowerShell runtime is required for this check')
    def test_windows_public_download_flow(self):
        self.run_windows()

    @unittest.skipUnless(PWSH, 'PowerShell runtime is required for this check')
    def test_windows_private_binary_download_flow(self):
        self.run_windows(private=True)

    @unittest.skipUnless(PWSH, 'PowerShell runtime is required for this check')
    def test_windows_rejects_hash_mismatch(self):
        self.run_windows(corrupt=True)

    @unittest.skipUnless(PWSH, 'PowerShell runtime is required for this check')
    def test_windows_preserves_existing_install(self):
        self.run_windows(existing=True)

    def run_windows(self, private=False, corrupt=False, existing=False):
        self.setup_release(corrupt)
        script = (ROOT/'download/Castor-Download.ps1').read_text()
        # Isolate just the install root for a non-Windows host; production has no test hooks.
        script = script.replace("[Environment]::GetFolderPath('LocalApplicationData')", "$env:TEST_HOME")
        copy = self.base/'download.ps1'
        copy.write_text(script)
        wrapper = self.base/'check.ps1'
        mocks = '''
$env:OS='Windows_NT'; $env:PROCESSOR_ARCHITECTURE='AMD64'; $env:PROCESSOR_ARCHITEW6432=''
function Invoke-RestMethod { param($Uri); Get-Content -Raw (Join-Path $env:TEST_RELEASE 'release.json') | ConvertFrom-Json }
function Invoke-WebRequest { param([switch]$UseBasicParsing,$Uri,$OutFile)
    $name=$Uri.Split('/')[-1]; Add-Content $env:TEST_LOG $name
    Copy-Item -LiteralPath (Join-Path $env:TEST_RELEASE $name) -Destination $OutFile
}
function Start-Process { param($FilePath,$ArgumentList); if ($FilePath -ne 'explorer.exe') { throw 'Unexpected process' } }
'''
        if private:
            mocks += '''
function gh {
    $global:LASTEXITCODE=0
    switch ($args[0]) {
        'auth' { return }
        'api' { Get-Content -Raw (Join-Path $env:TEST_RELEASE 'release.json'); return }
        'release' {
            $name=$args[[Array]::IndexOf($args,'--pattern')+1]; $dir=$args[[Array]::IndexOf($args,'--dir')+1]
            Add-Content $env:TEST_LOG $name
            Copy-Item -LiteralPath (Join-Path $env:TEST_RELEASE $name) -Destination (Join-Path $dir $name); return
        }
        default { throw 'Unexpected gh call' }
    }
}
'''
        else:
            mocks += "function Get-Command { param($Name,$ErrorAction); if ($Name -ne 'gh') { throw 'Unexpected command' } }\n"
        wrapper.write_text(mocks+"& $env:TEST_SCRIPT\nexit $LASTEXITCODE\n")
        target = self.home/'Programs/Castor/Castor-local-test-windows_x86_64'
        if existing:
            target.mkdir(parents=True)
            (target/'keep').write_text('existing')
        env = dict(os.environ, TEST_HOME=str(self.home), TEST_RELEASE=str(self.output), TEST_SCRIPT=str(copy), TEST_LOG=str(self.log))
        result = subprocess.run([PWSH, '-NoProfile', '-File', str(wrapper)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, not (corrupt or existing), result.stdout+result.stderr)
        self.assertNotIn('macos', self.log.read_text())
        if corrupt:
            self.assertFalse(target.exists())
        elif existing:
            self.assertEqual((target/'keep').read_text(), 'existing')
        else:
            self.assertEqual((target/'CastorPet.exe').read_bytes(), (self.windows/'CastorPet.exe').read_bytes())


if __name__ == '__main__':
    unittest.main()
