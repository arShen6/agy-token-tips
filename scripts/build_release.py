#!/usr/bin/env python3
"""Build standalone AGY installers using a native, verified Node runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

from build_macos_launcher import build_launcher

ROOT = Path(__file__).resolve().parents[1]
FILES = ['bin/agy-metrics.mjs', 'bin/desktop.mjs', 'src/cdp.mjs', 'src/database.mjs',
         'src/desktop-install.mjs', 'src/metrics.mjs', 'src/paths.mjs', 'src/messages.mjs',
         'src/widget-source.mjs', 'src/platform-services.mjs', 'ui/widget.js',
         'README.md', 'README.en.md', 'README.zh-CN.md', 'CONTRIBUTING.md', 'docs/protocol.md',
         'assets/agy-preview.png', 'LICENSE']
LAUNCHERS = {
    'darwin': ['start.sh','start.command','install.command','install-en.command','install-zh.command','uninstall.command','status.command'],
    'linux': ['start.sh','install.sh','install-en.sh','install-zh.sh','uninstall.sh','status.sh','start-antigravity.sh'],
    'win32': ['run.cmd','start.cmd','install.cmd','install-en.cmd','install-zh.cmd','uninstall.cmd','status.cmd','start-antigravity.cmd'],
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node', required=True, type=Path)
    parser.add_argument('--node-license', required=True, type=Path)
    args = parser.parse_args()
    runtime = json.loads(subprocess.check_output([str(args.node), '-p',
        'JSON.stringify({version:process.versions.node,platform:process.platform,arch:process.arch})'], text=True))
    version_parts = tuple(map(int, runtime['version'].split('.')[:2]))
    if runtime['platform'] not in LAUNCHERS or runtime['arch'] not in ['arm64','x64'] or version_parts < (22, 16):
        parser.error('The runtime must be native Windows/Linux/macOS x64/arm64 Node >=22.16')
    if not args.node_license.is_file():
        parser.error('The Node license is required')
    metadata = json.loads((ROOT / 'package.json').read_text())
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    sums = []
    platform_name = {'darwin':'macos','win32':'windows','linux':'linux'}[runtime['platform']]
    binary = 'node.exe' if runtime['platform']=='win32' else 'node'
    launchers = LAUNCHERS[runtime['platform']]
    executables = [] if runtime['platform']=='win32' else launchers + [f'runtime/{binary}']
    for language in ['zh-CN', 'en']:
        name = f"agy-token-tips-{metadata['version']}-{platform_name}-{runtime['arch']}-{language}"
        with tempfile.TemporaryDirectory(prefix='build-', dir=dist) as temp:
            folder = Path(temp) / name
            for relative in FILES + launchers:
                target = folder / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, target)
            if runtime['platform'] == 'darwin':
                build_launcher(folder)
            (folder / 'runtime').mkdir()
            shutil.copy2(args.node, folder / f'runtime/{binary}')
            shutil.copy2(args.node_license, folder / 'runtime/LICENSE')
            package = {'name':metadata['name'], 'version':metadata['version'], 'type':'module',
                       'license':'MIT', 'private':True, 'tokenTips':{'language':language}}
            (folder / 'package.json').write_text(json.dumps(package, indent=2) + '\n')
            for relative in executables:
                (folder / relative).chmod(0o755)
            subprocess.run([str(folder / f'runtime/{binary}'), 'bin/agy-metrics.mjs', 'help'],
                           cwd=folder, check=True, stdout=subprocess.DEVNULL)
            subprocess.run([str(folder / f'runtime/{binary}'), '--input-type=module', '-e',
                            "await import('./src/database.mjs'); await import('./src/cdp.mjs');"],
                           cwd=folder, check=True, stdout=subprocess.DEVNULL)
            launcher = ['cmd.exe','/d','/c','run.cmd','help'] if runtime['platform']=='win32' else ['bash','start.sh','help']
            subprocess.run(launcher, cwd=folder, check=True, stdout=subprocess.DEVNULL)
            temp_zip = Path(temp) / 'release.zip'
            with zipfile.ZipFile(temp_zip, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
                for path in sorted(folder.rglob('*')):
                    if path.is_file():
                        archive.write(path, path.relative_to(folder.parent))
            with zipfile.ZipFile(temp_zip) as archive:
                if archive.testzip() is not None:
                    raise RuntimeError('Corrupt ZIP')
                for relative in executables:
                    if not (archive.getinfo(f'{name}/{relative}').external_attr >> 16 & 0o111):
                        raise RuntimeError(f'Not executable: {relative}')
            output = dist / f'{name}.zip'
            os.replace(temp_zip, output)
        digest = hashlib.sha256(output.read_bytes()).hexdigest()
        sums.append(f'{digest}  {output.name}')
        print(f'{output.name}: {output.stat().st_size} bytes')
    (dist / 'SHA256SUMS.txt').write_text('\n'.join(sums) + '\n')

if __name__ == '__main__':
    main()
