#!/usr/bin/env python3
"""Build Sheng's volatile NativeRamBlock against Pong's Darwin 22 storage ABI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess

DEVICE = Path(__file__).resolve().parents[1]
TREE = Path('/Volumes/PongDev/build/Pong-iOS16-native/tree')
DEVELOPER = os.environ.get('DEVELOPER_DIR',
                           '/Volumes/PongDev/Applications/Xcode.app/Contents/Developer')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tree', type=Path, default=TREE)
    parser.add_argument('--developer-dir', type=Path, default=Path(DEVELOPER))
    parser.add_argument('--skip-image-verification', action='store_true')
    args = parser.parse_args()
    tree = args.tree.resolve()
    if platform.system() != 'Darwin':
        raise SystemExit('This continuation requires macOS with Xcode')
    out = tree / 'build/native-ram-block'
    out.mkdir(parents=True, exist_ok=True)
    source = DEVICE / 'drivers/NativeRamBlock/NativeRamBlock.cpp'
    framework = tree / '.cache/fakeroot/System/Library/Frameworks/Kernel.framework/Versions/A'
    env = dict(os.environ, DEVELOPER_DIR=str(args.developer_dir))
    sdk = subprocess.check_output(
        ['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True, env=env).strip()
    obj = out / 'NativeRamBlock.o'
    command = [
        'xcrun', '--sdk', 'iphoneos', 'clang++', '-target', 'arm64-apple-ios16.0',
        '-isysroot', sdk, '-mkernel', '-ffreestanding', '-fno-builtin',
        '-fno-exceptions', '-fno-rtti', '-fno-stack-check', '-std=gnu++17',
        '-fblocks', '-O2', '-DKERNEL=1', '-DKERNEL_PRIVATE=1',
        '-DXNU_KERNEL_PRIVATE=1',
        '-DPONG_RAM_BLOCK_VOLATILE_ONLY=1',
        '-I' + str(DEVICE / 'mac-build/storage-abi/include'),
        '-I' + str(tree / '.cache/xnu-work/EXTERNAL_HEADERS'),
        '-I' + str(framework / 'PrivateHeaders'), '-I' + str(framework / 'Headers'),
        '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
        '-Wno-unused-parameter', '-c', str(source), '-o', str(obj),
    ]
    result = subprocess.run(command, capture_output=True, text=True, env=env)
    (out / 'build.log').write_text(result.stdout + result.stderr)
    if result.returncode:
        raise SystemExit(result.stderr)

    # Reuse the already audited original iOS 16 IOBlockStorageDevice aliases.
    # This driver is only a concrete in-memory subclass; no new storage ABI is
    # introduced and no verified-root hashing is involved.
    ufs = json.loads((DEVICE / 'mac-build/native-ufs/bindings.json').read_text())
    bindings = ufs['bindings']
    undefined = subprocess.check_output(['xcrun', 'nm', '-u', str(obj)], text=True, env=env)
    imports = sorted({token.rstrip(',') for token in undefined.split()
                      if token.startswith('__ZN20IOBlockStorageDevice')})
    if not imports or any(name not in bindings for name in imports):
        missing = [name for name in imports if name not in bindings]
        raise SystemExit('NativeRamBlock original IOStorage imports differ: ' + repr(missing))
    assembly = out / 'original-bindings.S'
    assembly.write_text(''.join(f'.globl {name}\n.set {name}, {bindings[name]}\n'
                                for name in imports))
    alias = out / 'original-bindings.o'
    subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', '-target', 'arm64-apple-ios16.0',
                    '-Werror', '-c', str(assembly), '-o', str(alias)], check=True, env=env)
    archive = out / 'libNativeRamBlock.a'
    archive.unlink(missing_ok=True)
    subprocess.run(['xcrun', 'libtool', '-static', '-o', str(archive), str(obj), str(alias)],
                   check=True, env=env)
    report = {
        'target': 'arm64-apple-ios16.0', 'object': str(obj), 'archive': str(archive),
        'image_verification': 'skipped by request' if args.skip_image_verification else 'digest recorded',
        'original_storage_imports': imports, 'binding_source': 'mac-build/native-ufs/bindings.json',
        'bindings': {name: bindings[name] for name in imports},
        'runtime_mode': 'volatile PackedRAMDisk; seed digest skipped when no persistent UFS store exists',
    }
    if not args.skip_image_verification:
        report['archive_sha256'] = hashlib.sha256(archive.read_bytes()).hexdigest()
        report['source_sha256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in sorted(source.parent.iterdir()) if p.is_file()}
    (out / 'build-report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'Built Pong NativeRamBlock: {archive} ({len(imports)} original storage imports)')


if __name__ == '__main__':
    main()
