#!/usr/bin/env python3
"""Compile the Pong UFS transport and optional diagnostics."""
import hashlib
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

DEVICE = Path(__file__).resolve().parents[1]
DEFAULT_TREE = Path('/Volumes/PongDev/build/Pong-iOS16-native/tree')
DEVELOPER = os.environ.get('DEVELOPER_DIR',
                           '/Volumes/PongDev/Applications/Xcode.app/Contents/Developer')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tree', type=Path, default=DEFAULT_TREE,
                        help='XNU build tree whose Darwin 22 kernel headers should be used')
    parser.add_argument('--skip-image-verification', action='store_true',
                        help='compile/link without source or archive digests')
    args = parser.parse_args()
    tree = args.tree.resolve()
    if platform.system() != 'Darwin':
        raise SystemExit('This continuation requires macOS with Xcode')
    out = tree / 'build/native-ufs'
    out.mkdir(parents=True, exist_ok=True)
    source = DEVICE / 'drivers/NativeUfs/NativeUfs.cpp'
    framework = tree / '.cache/fakeroot/System/Library/Frameworks/Kernel.framework/Versions/A'
    storage_include = tree / 'build/storage-abi/include'
    if not (storage_include / 'IOKit/storage/IOBlockStorageDevice.h').is_file():
        storage_include = DEVICE / 'mac-build/storage-abi/include'
    if not (storage_include / 'IOKit/storage/IOBlockStorageDevice.h').is_file():
        raise SystemExit('Missing prepared IOStorageFamily headers; run scripts/prepare-storage-headers.py first')
    env = dict(os.environ, DEVELOPER_DIR=DEVELOPER)
    sdk = subprocess.check_output(
        ['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True, env=env).strip()
    obj = out / 'NativeUfs.o'
    trace_enabled = 'CONFIG_XNU_PONG_EARLY_TRACE=y' in (DEVICE / 'configs/pong_defconfig').read_text().splitlines()
    command = ['xcrun', '--sdk', 'iphoneos', 'clang++', '-target', 'arm64-apple-ios16.0',
        '-isysroot', sdk, '-mkernel', '-ffreestanding', '-fno-builtin', '-fno-exceptions',
        '-fno-rtti', '-fno-stack-check', '-std=gnu++17', '-fblocks', '-O2',
        '-DKERNEL=1', '-DKERNEL_PRIVATE=1', '-DXNU_KERNEL_PRIVATE=1',
        '-DXNU_PONG_EARLY_TRACE=' + str(int(trace_enabled)),
        '-DXNU_PONG_UFS_DATA=' + str(int('CONFIG_XNU_OWNER_DATA_UFS=y' in (DEVICE/'configs/pong_defconfig').read_text().splitlines())),
        '-I' + str(storage_include),
        '-I' + str(tree / '.cache/xnu-work/EXTERNAL_HEADERS'),
        '-I' + str(framework / 'PrivateHeaders'), '-I' + str(framework / 'Headers'),
        '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
        '-Wno-unused-parameter', '-Wno-c99-designator',
        '-Wno-reorder-init-list', '-Wno-sign-conversion',
        '-Wno-unnecessary-virtual-specifier', '-c', str(source), '-o', str(obj)]
    result = subprocess.run(command, capture_output=True, text=True, env=env)
    (out / 'build.log').write_text(result.stdout + result.stderr)
    if result.returncode:
        raise SystemExit(result.stderr)
    transport = out / 'PongUfsTransport.o'
    command[command.index(str(source))] = str(source.with_name('PongUfsTransport.cpp'))
    command[-1] = str(transport)
    result = subprocess.run(command, capture_output=True, text=True, env=env)
    (out / 'transport-build.log').write_text(result.stdout + result.stderr)
    if result.returncode:
        raise SystemExit(result.stderr)
    subprocess.run([str(Path(os.sys.executable)), str(DEVICE / 'scripts/bind-ios16-storage.py'),
                    '--object', str(transport), '--output', str(out)], check=True, env=env)
    archive = out / 'libNativeUfs.a'
    archive.unlink(missing_ok=True)
    subprocess.run(['xcrun', 'libtool', '-static', '-o', str(archive), str(obj), str(transport), str(out / 'original-bindings.o')],
                   check=True, env=env)
    report = {
        'host': platform.machine(), 'target': 'arm64-apple-ios16.0',
        'build_tree': str(tree),
        'source': str(source),
        'image_verification': 'skipped by request' if args.skip_image_verification else 'digest recorded',
        'read_write_capable': True, 'runtime_write_arg': 'pong_ufs_readwrite=1',
        'write_scope': 'declared SHNGROOT OS/SystemOS/Data windows; each mount retains its own flags',
        'storage_commands': ['NOP', 'READ ATTRIBUTE', 'START STOP ACTIVE', 'TEST UNIT READY', 'READ CAPACITY', 'READ(10)', 'WRITE(10) FUA', 'SYNCHRONIZE CACHE(10)'],
        'smmu_writes': 'exclusive UFS SID 0xe0 only after queue stop',
        'optional_probes_default': 'off',
        'board': 'Nothing Phone (2) Pong / SM8475',
        'ufs_hc': '0x01d84000/0x3000', 'gcc_ufs_page': '0x00187000/0x1000',
        'stream_id': '0xe0', 'hardware_tested': False,
        'smmu_owned_context_banks': 78, 'smmu_owned_match_groups': 120,
    }
    if not args.skip_image_verification:
        report['source_sha256'] = hashlib.sha256(source.read_bytes()).hexdigest()
        report['sources_sha256'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                   for p in sorted(source.parent.iterdir()) if p.suffix in ('.h', '.cpp')}
        report['archive_sha256'] = hashlib.sha256(archive.read_bytes()).hexdigest()
    (out / 'build-report.json').write_text(json.dumps(report, indent=2) + '\n')
    export = DEVICE / 'mac-build/native-ufs'
    export.mkdir(parents=True, exist_ok=True)
    for name in ('libNativeUfs.a', 'build-report.json', 'build.log', 'bindings.json', 'transport-build.log'):
        shutil.copyfile(out / name, export / name)
    print('Compiled Pong NativeUfs read/write path (boot-arg gated):', archive)


if __name__ == '__main__':
    main()
