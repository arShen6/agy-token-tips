"""Build the standalone Dock launcher for the current Mac architecture."""
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def build_launcher(directory):
    app = directory / 'AGY-Token-Tips.app'
    contents = app / 'Contents'
    executable = contents / 'MacOS' / 'AGY-Token-Tips'
    executable.parent.mkdir(parents=True, exist_ok=True)
    resources = contents / 'Resources'
    resources.mkdir(exist_ok=True)
    shutil.copyfile(ROOT / 'macos/icon.icns', resources / 'icon.icns')
    shutil.copyfile(ROOT / 'macos/Info.plist', contents / 'Info.plist')
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-mmacosx-version-min=11.0',
                    '-framework', 'AppKit', str(ROOT / 'macos/Launcher.m'), '-o', str(executable)],
                   check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
    return app


if __name__ == '__main__':
    print(build_launcher(Path(sys.argv[1])))
