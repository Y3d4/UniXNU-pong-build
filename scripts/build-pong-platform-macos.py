#!/usr/bin/env python3
"""Compile the generic DT platform against the current Darwin 22 kernel SDK."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

DEVICE = Path(__file__).resolve().parents[1]
TREE = Path('/Volumes/PongDev/build/Pong-iOS16-native/tree')
DEVELOPER = os.environ.get('DEVELOPER_DIR',
                           '/Volumes/PongDev/Applications/Xcode.app/Contents/Developer')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tree', type=Path, default=TREE)
    parser.add_argument('--skip-image-verification', action='store_true')
    args = parser.parse_args()
    tree = args.tree.resolve()
    if platform.system() != 'Darwin':
        raise SystemExit('This continuation requires macOS with Xcode')
    out = tree / 'build/armdt-platform'
    out.mkdir(parents=True, exist_ok=True)
    source = DEVICE / 'drivers/ArmDTPlatform/ArmDTPlatform.cpp'
    framework = tree / '.cache/fakeroot/System/Library/Frameworks/Kernel.framework/Versions/A'
    if not (framework / 'PrivateHeaders/IOKit/IOPlatformExpert.h').exists():
        raise SystemExit('First build the native PONG kernel SDK')
    env = dict(os.environ, DEVELOPER_DIR=DEVELOPER)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True, env=env).strip()
    obj = out / 'ArmDTPlatform.o'
    command = ['xcrun', '--sdk', 'iphoneos', 'clang++', '-target', 'arm64-apple-ios16.0',
        '-isysroot', sdk, '-mkernel', '-ffreestanding', '-fno-builtin', '-fno-exceptions',
        '-fno-rtti', '-fno-stack-check', '-std=gnu++17', '-fblocks', '-O2',
        '-DKERNEL=1', '-DKERNEL_PRIVATE=1', '-DXNU_KERNEL_PRIVATE=1',
        '-DARM64_BOARD_CONFIG_PONG=1', '-Xclang', '-target-feature', '-Xclang', '+pan',
        '-DXNU_PONG_ADRENO_PLATFORM='+env.get('XNU_PONG_ADRENO_PLATFORM','0'),
        '-I' + str(framework / 'PrivateHeaders'), '-I' + str(framework / 'Headers'),
        '-Wno-deprecated-declarations', '-c', str(source), '-o', str(obj)]
    result = subprocess.run(command, capture_output=True, text=True, env=env)
    (out / 'build.log').write_text(result.stdout + result.stderr)
    if result.returncode:
        raise SystemExit(result.stderr)
    archive = out / 'libArmDTPlatform.a'
    subprocess.run(['xcrun', 'libtool', '-static', '-o', str(archive), str(obj)], check=True, env=env)
    report = {'host': platform.machine(), 'target': 'arm64-apple-ios16.0',
        'source': str(source), 'archive': str(archive),
        'image_verification': 'skipped by request',
        'command': command, 'runtime_qualified': False,
        'hardware_access': 'DT-driven nub publication; no fixed SoC register addresses'}
    (out / 'build-report.json').write_text(json.dumps(report, indent=2) + '\n')
    export = DEVICE / 'mac-build/armdt-platform'
    export.mkdir(parents=True, exist_ok=True)
    for name in ['libArmDTPlatform.a', 'build-report.json', 'build.log']:
        shutil.copyfile(out / name, export / name)
    print('Compiled generic DT platform archive:', archive)


if __name__ == '__main__':
    main()
