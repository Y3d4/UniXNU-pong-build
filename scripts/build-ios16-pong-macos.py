#!/usr/bin/env python3
"""Create a fresh Pong build beside the successful Mac baseline, then build XNU.

The baseline tree, SDK installation and Apple reference checkouts are reused
read-only. Object files and the fakeroot SDK are never shared with BCM2837.
This script does not call adb, fastboot, prelink, or any partition operation.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys
import tomllib

DEVICE = Path(__file__).resolve().parents[1]
PROFILE = 'Pong-iOS16-heartbeat-single-core-20261021'


def link(source, destination):
    source = source.resolve()
    if destination.is_symlink():
        if destination.resolve() != source:
            raise SystemExit(f'Existing link differs: {destination}')
        return
    if destination.exists():
        raise SystemExit(f'Preserving existing path; choose another build tree: {destination}')
    destination.symlink_to(source, target_is_directory=True)


def audit_kernel(path):
    raw = path.read_bytes()
    header = struct.unpack_from('<8I', raw)
    if header[:4] != (0xfeedfacf, 0x100000c, 0, 2) or not header[6] & 1:
        raise RuntimeError('Expected ARM64 MH_EXECUTE with NOUNDEFS')
    offset = 32
    symbols = None
    entry = None
    segments = []
    for _ in range(header[4]):
        command, size = struct.unpack_from('<II', raw, offset)
        if command == 0x19:
            name, va, length = struct.unpack_from('<16sQQ', raw, offset + 8)
            segments.append({'name': name.rstrip(b'\0').decode(), 'va': hex(va), 'size': hex(length)})
        elif command == 2:
            symbols = struct.unpack_from('<4I', raw, offset + 8)
        elif command == 5:
            entry = struct.unpack_from('<Q', raw, offset + 272)[0]
        offset += size
    if not symbols or entry is None:
        raise RuntimeError('Kernel lacks symbol table or thread entry')
    symoff, count, stroff, strsize = symbols
    forbidden = []
    for index in range(count):
        name_at = struct.unpack_from('<I', raw, symoff + index * 16)[0]
        end = raw.find(b'\0', stroff + name_at, stroff + strsize)
        name = raw[stroff + name_at:end].decode(errors='replace')
        if 'pi3_uart' in name or 'pi3_gpio' in name or 'pi3_aux' in name:
            forbidden.append(name)
    if forbidden:
        raise RuntimeError('Raspberry Pi hardware symbols remain: ' + ', '.join(forbidden))
    return {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(), 'entry': hex(entry),
            'segments': segments, 'raspberry_pi_hardware_symbols': forbidden, 'NOUNDEFS': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-tree', type=Path,
                        default=Path('/Volumes/PongDev/build/UniXNU-XNU-iOS16/pong/tree'))
    parser.add_argument('--tree', type=Path,
                        default=Path('/Volumes/PongDev/build/Pong-iOS16-native/tree'))
    parser.add_argument('--developer-dir', type=Path,
                        default=Path('/Volumes/PongDev/Applications/Xcode.app/Contents/Developer'))
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--artifact-dir', type=Path,
                        help='export this development build separately from the known bootable kernel')
    parser.add_argument('--bootstrap-storage-abi', action='store_true',
                        help='build a temporary kernel without NativeUfs or owner Data mounts for ABI qualification')
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--skip-image-verification', action='store_true',
                        help='build without hashing or auditing the resulting kernel images')
    args = parser.parse_args()
    old, tree = args.baseline_tree.resolve(), args.tree.resolve()
    if tree == old or old in tree.parents:
        parser.error('The new build must be outside the successful baseline tree')
    if not (old / 'scripts/prepare-xnu-source.py').is_file():
        parser.error('The full successful scratch tree is required, not just its exported kernel folder')
    if not args.prepare_only and platform.system() != 'Darwin':
        parser.error('Compilation requires macOS and full Xcode; --prepare-only does not compile')
    marker = tree / '.pong-ios16-profile'
    if tree.exists() and (not marker.is_file() or marker.read_text().strip() != PROFILE):
        parser.error('Existing output has another profile; choose a fresh --tree')

    feeds = tomllib.loads((DEVICE / 'feeds.toml').read_text())['source']
    refs = {}
    # Check all reference pins before creating or changing the destination.
    for source in feeds:
        path = old / 'refer' / source['name']
        actual = subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip()
        if actual != source['commit']:
            parser.error(f'{path}: expected {source["commit"]}, got {actual}')
        refs[source['name']] = actual
    tree.mkdir(parents=True, exist_ok=True)
    marker.write_text(PROFILE + '\n')
    shutil.copytree(old / 'scripts', tree / 'scripts', dirs_exist_ok=True)
    for name in ('build-xnu-4k-baseline.sh', 'build-firehose.sh', 'save-xnu-patch.py',
                 'prepare-xnu-source.py'):
        shutil.copyfile(DEVICE / 'scripts' / name, tree / 'scripts' / name)
    for name in ('drivers', 'kits', 'package'):
        if (old / name).exists():
            link(old / name, tree / name)
    (tree / 'refer').mkdir(exist_ok=True)
    for source in feeds:
        link(old / 'refer' / source['name'], tree / 'refer' / source['name'])
    (tree / 'patches').mkdir(exist_ok=True)
    for module in (old / 'patches').iterdir():
        if module.name != 'xnu' and module.is_dir():
            link(module, tree / 'patches' / module.name)
    link(DEVICE / 'patches/xnu', tree / 'patches/xnu')
    for name in ('build', '.cache'):
        (tree / name).mkdir(exist_ok=True)
    storage_abi = old / 'build/storage-abi'
    if storage_abi.is_dir():
        shutil.copytree(storage_abi, tree / 'build/storage-abi', dirs_exist_ok=True)

    env = {k: v for k, v in os.environ.items() if not k.startswith(('XNU_', 'UNIXNU_'))}
    env['PATH'] = str(Path(sys.executable).parent) + ':/opt/local/bin:/opt/local/sbin:' + env.get('PATH', '')
    env['DEVELOPER_DIR'] = str(args.developer_dir)
    env['JOBS'] = str(args.jobs)
    env['PONG_NATIVE_DRIVER_SOURCE'] = str(DEVICE)
    # Normal builds do not invoke the optional static analyzer. Avoid Xcode's
    # slow scan-build discovery on the external toolchain volume.
    env['SCAN_BUILD'] = ''
    for optional_tool in ('CTFINSERT', 'CTFCONVERT', 'CTFMERGE', 'CTFDUMP'):
        env[optional_tool] = ''
    env['DO_CTFMERGE'] = '0'
    prefixes = {'xnu': 'XNU', 'libplatform': 'LIBPLATFORM', 'libdispatch': 'LIBDISPATCH',
                'AvailabilityVersions': 'AVAILABILITYVERSIONS'}
    for source in feeds:
        prefix = prefixes[source['name']]
        env[f'UNIXNU_{prefix}_TAG'] = source['ref']
        env[f'UNIXNU_{prefix}_COMMIT'] = source['commit']
        if source['name'] == 'xnu':
            for key, name in [('darwin', 'XNU_DARWIN'), ('version', 'XNU_VERSION'),
                              ('driverkit_tag', 'DRIVERKIT_TAG'), ('trustcache_tag', 'TRUSTCACHE_TAG')]:
                env['UNIXNU_' + name] = source[key]
    env['UNIXNU_IOS_TARGET'] = '16.0'
    for line in (DEVICE / 'configs/pong_defconfig').read_text().splitlines():
        if line.startswith('CONFIG_XNU_'):
            key, value = line.removeprefix('CONFIG_').split('=', 1)
            env[key] = {'y': '1', 'n': '0'}.get(value, value.strip('"'))
    if args.bootstrap_storage_abi:
        # The ABI candidate must come from a kernel that does not itself link
        # NativeUfs.  Otherwise the audit would depend on the bindings it is
        # supposed to derive.  Disable the coupled owner mount policy too.
        for key in ('XNU_NATIVE_UFS', 'XNU_OWNER_DATA_UFS', 'XNU_OWNER_DATA_MOUNT',
                    'XNU_OWNER_CACHE_MOUNT', 'XNU_OWNER_CACHE_STARTUP',
                    'XNU_PONG_APFS_DEBUG', 'XNU_PONG_ADRENO_PLATFORM'):
            env[key] = '0'
        env['XNU_STORAGE_ABI_BOOTSTRAP'] = '1'
    # Pong's complete SM8475 GMU/CP/BO/IRQ/Metal provider is linked through
    # XNU_PONG_ADRENO_PLATFORM. Disable the generic A740/Redwood board owners
    # to avoid duplicate power/SMMU ownership; this does not disable Pong GPU.
    forbidden_gpu = ('XNU_NATIVE_ADRENO', 'XNU_NATIVE_OFFLINE_GPU',
                     'XNU_ADRENO_FIRMWARE_PROBE', 'XNU_ADRENO_PM4_PROBE')
    for key in forbidden_gpu:
        if env.get(key, '0') != '0':
            parser.error(f'{key} conflicts with the Pong SM8475 GPU owner')
        env[key] = '0'
    settings = {k: v for k, v in env.items() if k.startswith(('XNU_', 'UNIXNU_'))}
    report = {'profile': PROFILE, 'baseline_tree': str(old), 'tree': str(tree),
              'host': {'system': platform.system(), 'machine': platform.machine(),
                       'python': sys.version, 'developer_dir': str(args.developer_dir)},
              'machine_config': 'PONG', 'reference_commits': refs, 'settings': settings,
              'source_patch_sha256': {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                                     for path in sorted((DEVICE / 'patches/xnu').glob('*.patch'))},
              'hardware_tested': False, 'partition_writes': False, 'build_complete': False}
    result = tree.parent / 'PONG_BUILD_RESULT.json'
    result.write_text(json.dumps(report, indent=2) + '\n')
    if args.prepare_only:
        print(f'Prepared {tree}; compilation has not run')
        return
    for command in (['xcodebuild', '-version'], ['xcrun', '--sdk', 'iphoneos', '--show-sdk-path']):
        subprocess.run(command, check=True, env=env)
    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    log = tree.parent / f'build-pong-{timestamp}.log'
    print(f'Building DEVELOPMENT_ARM64_PONG; full log: {log}', flush=True)
    with log.open('w') as output:
        process = subprocess.run(['bash', str(tree / 'scripts/build-xnu-4k-baseline.sh')],
                                 cwd=tree, env=env, stdout=output, stderr=subprocess.STDOUT)
    report['returncode'] = process.returncode
    report['log'] = str(log)
    result.write_text(json.dumps(report, indent=2) + '\n')
    if process.returncode:
        try:
            print(log.read_text(errors='replace')[-12000:], file=sys.stderr)
        except OSError:
            pass
        raise SystemExit(f'Build failed; retained full log: {log}')
    kernel = tree / 'build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/mach.development.pong'
    unstripped = kernel.with_name(kernel.name + '.unstripped')
    if args.skip_image_verification:
        report['unstripped_kernel'] = {'path': str(unstripped), 'bytes': unstripped.stat().st_size}
        report['kernel'] = {'path': str(kernel), 'bytes': kernel.stat().st_size}
        report['image_verification'] = 'skipped by request'
    else:
        report['unstripped_kernel'] = audit_kernel(unstripped)
        report['kernel'] = audit_kernel(kernel)
    if not args.skip_image_verification and settings.get('XNU_PONG_EARLY_TRACE') == '1':
        # Check markers emitted by the Pong-specific guarded call sites.
        # Validate the unstripped Mach-O where compiled call-site literals remain.
        raw = unstripped.read_bytes()
        markers = ['PongEarly: PE_init_platform returned',
                   'PongEarly: bootstrap %s', 'PongEarly: thread %s']
        missing = [value for value in markers if value.encode() + b'\n\0' not in raw]
        if missing:
            raise SystemExit('Missing compiled Pong early-trace markers: ' + ', '.join(missing))
        report['early_trace_markers'] = markers
    if not args.skip_image_verification and settings.get('XNU_PONG_VOLATILE_PANIC_LOG') == '1':
        if b'_pong_volatile_panic_log\0' not in unstripped.read_bytes():
            raise SystemExit('Requested volatile panic buffer was not compiled into the kernel')
        report['volatile_panic_buffer_compiled'] = True
    report['build_complete'] = True
    artifact = (args.artifact_dir.resolve() if args.artifact_dir else
                DEVICE / 'mac-build/ios16-xnu-pong')
    artifact.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(kernel, artifact / 'mach.development.pong')
    shutil.copyfile(log, artifact / 'build.log')
    for destination in (result, artifact / 'PONG_BUILD_RESULT.json'):
        destination.write_text(json.dumps(report, indent=2) + '\n')
    print(f'Built {artifact / "mach.development.pong"}')
    if not args.skip_image_verification:
        print('SHA-256: ' + report['kernel']['sha256'])


if __name__ == '__main__':
    main()
