#!/usr/bin/env python3
"""Build a static prelink candidate with the input 20G81 corecrypto, no phone calls."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys

DEVICE = Path(__file__).resolve().parents[1]
ROOT = DEVICE.parent
sys.path.insert(0, str(DEVICE / 'kits/NativePrelink'))
from native_prelink import macho, exports, backed_offset, unserialize_xml
from emit_prelink import emit, COALESCED
from importlib.util import spec_from_file_location, module_from_spec


def digest(data):
    return hashlib.sha256(data).hexdigest()


def bundle_dependency_closure(entries, identifier):
    """Return one prelink bundle and its non-kernel OSBundleLibraries closure."""
    selected, pending = set(), [identifier]
    while pending:
        name = pending.pop()
        if name in selected:
            continue
        item = entries.get(name)
        if item is None:
            raise ValueError('20G81 prelink metadata lacks dependency: ' + name)
        if item.get('OSKernelResource') is True:
            continue
        selected.add(name)
        pending.extend(item.get('OSBundleLibraries') or {})
    return selected


def der(data, at):
    tag, length = data[at:at + 2]
    body = at + 2
    if length & 128:
        count = length & 127
        if not 1 <= count <= 4:
            raise ValueError('Unsupported DER length')
        length = int.from_bytes(data[body:body + count], 'big')
        body += count
    end = body + length
    if end > len(data):
        raise ValueError('DER extent outside input')
    return tag, body, end


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', required=True, type=Path)
    parser.add_argument('--native-artifact', type=Path,
                        help='completed Pong kernel artifact; defaults to mac-build/ios16-xnu-pong')
    parser.add_argument('--kernelcache', type=Path,
                        help='decompressed-input source kernelcache; defaults to apple/20G81/kernelcache.release.ipad7')
    parser.add_argument('--skip-bootimg', action='store_true',
                        help='stop after emitting the candidate and prelink plan; useful for ABI audits')
    parser.add_argument('--module', action='append', default=[], help='Additional genuine 20G81 root module; corecrypto is always included')
    parser.add_argument('--kernel-arg', action='append', default=[])
    parser.add_argument('--window-size', type=lambda value: int(value, 0), default=0x10000000,
                        help='RAM bytes for DarwinBoot to allocate from real UEFI conventional memory')
    parser.add_argument('--ufs', '--ufs-probe', dest='ufs_probe', action='store_true',
                        help='include the Pong UFS DT node; optional probes are separate boot arguments')
    parser.add_argument('--root-match-volume-uuid', default=None,
                        help='match the root IOMedia by the APFS system volume UUID')
    parser.add_argument('--development-debug', action='store_true')
    parser.add_argument('--amfi-only-platform-code', action='store_true',
                        help='carry Sheng-compatible strict AMFI policy into the Pong ADT')
    parser.add_argument('--system-volume-auth-blob', type=Path, default=None,
                        help='validated 20G81 isys payload to supply to APFS through the Pong ADT')
    parser.add_argument('--data-ramdisk', type=Path, default=None,
                        help='packed DBRDISK1 APFS scratch Data seed mounted at /private/var')
    parser.add_argument('--packed-data-ramdisk', action='store_true',
                        help='pass the supplied seed through DarwinBoot as PackedRAMDisk')
    args = parser.parse_args()
    if not 0x10000000 <= args.window_size <= 0x200000000 or args.window_size % 0x200000:
        parser.error('--window-size must be 256 MiB..8 GiB, aligned to 2 MiB')
    if args.packed_data_ramdisk != (args.data_ramdisk is not None):
        parser.error('--packed-data-ramdisk and --data-ramdisk must be supplied together')
    out = args.output_dir.resolve()
    if out.exists():
        parser.error('Preserving existing output; choose a new directory')
    artifact = (args.native_artifact or DEVICE / 'mac-build/ios16-xnu-pong').resolve()
    report = json.loads((artifact / 'PONG_BUILD_RESULT.json').read_text())
    native = (artifact / 'mach.development.pong').read_bytes()
    if not report['build_complete'] or digest(native) != report['kernel']['sha256']:
        raise ValueError('Native kernel does not match completed build')
    raw = (args.kernelcache or ROOT / 'apple/20G81/kernelcache.release.ipad7').resolve().read_bytes()
    pin = 'ddc2230e4ea9aced34c84b7ef78dc7e7564235b17a2640c718a78e0e3ca092c2'
    if digest(raw) != pin:
        raise ValueError('Input Apple kernelcache differs from board pin')
    tag, at, end = der(raw, 0)
    if tag != 0x30 or end != len(raw):
        raise ValueError('Expected one complete IM4P sequence')
    fields = []
    while at < end:
        kind, body, finish = der(raw, at)
        fields.append((kind, raw[body:finish]))
        at = finish
    if len(fields) < 4 or fields[:2] != [(0x16, b'IM4P'), (0x16, b'krnl')] or fields[3][0] != 4:
        raise ValueError('Expected a kernel IM4P payload')
    out.mkdir(parents=True)
    packed, fat = out / 'original.lzfse', out / 'original.fat'
    packed.write_bytes(fields[3][1])
    subprocess.run(['/usr/bin/compression_tool', '-decode', '-a', 'lzfse',
                    '-i', str(packed), '-o', str(fat)], check=True, capture_output=True)
    original = fat.read_bytes()
    if original[:4] == bytes.fromhex('cafebabe'):
        count = struct.unpack_from('>I', original, 4)[0]
        slices = [struct.unpack_from('>5I', original, 8 + 20 * i) for i in range(count)]
        selected = [a for a in slices if a[:2] == (0x100000c, 0)]
        if len(selected) != 1:
            raise ValueError('Expected one ordinary ARM64 slice')
        _, _, at, size, _ = selected[0]
        original = original[at:at + size]
    if digest(original) != 'd260defcc2eaac258fd3a2234454dda46791dae45e97608c5416f9ba8fd366e9':
        raise ValueError('Decompressed 20G81 ARM64 image differs from audited input')
    image = macho(original)
    prelink_info = next(s for s in image['segments'] if s['name'] == '__PRELINK_INFO')
    prelink_info_at = backed_offset(image['segments'], prelink_info['va'],
                                    prelink_info['filesize'], len(original))
    prelink_entries = {entry['CFBundleIdentifier']: entry for entry in
        unserialize_xml(original[prelink_info_at:prelink_info_at + prelink_info['filesize']])
        ['_PrelinkInfoDictionary']}
    apfs_dependency_closure = (bundle_dependency_closure(prelink_entries, 'com.apple.filesystems.apfs')
        if args.root_match_volume_uuid else set())
    old_base = min(s['va'] for s in image['segments'] if s['name'] in COALESCED and s['size'])
    native_image = macho(native)
    native_end = max(s['va'] + s['size'] for s in native_image['segments'] if s['size'])
    # Reserve a MiB for native prelink metadata before the coalesced payload.
    slide = (native_end + 0x100000 - old_base + 4095) & ~4095
    # A root-matched Pong boot calls OSKextLoadKextWithIdentifier for APFS
    # before starting the UFS controller. Keep the complete, known-good 20G81
    # APFS/storage closure in that prelink. The v26 load call returned
    # 0xdc00800a (kOSKextReturnDisabled); the v27d image, with APFS included,
    # advanced into apfs_vfsop_mountroot. The restore System volume also stores
    # launchd, dyld and many services as decmpfs, so retain both decompressors.
    root_boot_roots = ({
        'com.apple.AppleFSCompression.AppleFSCompressionTypeZlib',
        'com.apple.driver.AppleEffaceableStorage',
        'com.apple.filesystems.apfs',
        'com.apple.iokit.CoreAnalyticsFamily',
        'com.apple.iokit.IOCryptoAcceleratorFamily',
        'com.apple.iokit.IOStorageFamily',
        'com.apple.kec.Compression',
        'com.apple.kec.pthread',
        'com.apple.kext.CoreTrust',
        'com.apple.security.AppleImage4',
    } if args.root_match_volume_uuid else set())
    roots = sorted({'com.apple.kec.corecrypto', *args.module, *root_boot_roots})
    storage_bindings = None
    native_exports = {name: va for va, names in exports(native, native_image).items() for name in names}
    if '__ZN20IOBlockStorageDevice10gMetaClassE' in native_exports:
        storage_bindings = json.loads((DEVICE / 'mac-build/native-ufs/bindings.json').read_text())
        if 'com.apple.iokit.IOStorageFamily' not in roots:
            raise ValueError('Pong block driver requires the genuine storage family')
        fixed = int(storage_bindings['fixed_prelink_base'], 16)
        if fixed < native_end + 0x100000:
            raise ValueError('Fixed storage placement collides with native kernel/metadata')
        slide = fixed - old_base
        for name, value in storage_bindings['bindings'].items():
            if native_exports.get(name) != int(value, 16):
                raise ValueError('Native storage import differs from audited placement: ' + name)
    candidate, prelink = emit(native, original, roots, slide)
    missing_apfs_dependencies = apfs_dependency_closure - set(prelink['components'])
    if missing_apfs_dependencies:
        raise ValueError('APFS dependency closure is incomplete: ' +
                         ', '.join(sorted(missing_apfs_dependencies)))
    if apfs_dependency_closure:
        prelink['validated_apfs_dependency_closure'] = sorted(apfs_dependency_closure)
    if storage_bindings:
        previous = ROOT / 'build/native-xnu-probe-continue-policy'
        old_plan = json.loads((previous / 'prelink.json').read_text())
        old_candidate = (previous / 'kernel-corecrypto.macho').read_bytes()
        if digest(old_candidate) != storage_bindings['original_candidate_sha256']:
            raise ValueError('Storage ABI reference candidate identity changed')
        reference = macho(old_candidate)
        old_prelink_base = min(s['va'] for s in reference['segments'] if s['name'] in COALESCED and s['size'])
        adjustment = int(storage_bindings['fixed_prelink_base'], 16) - old_prelink_base
        # Original component code/data must back every absolute import. The
        # full original executable hash is independently checked by emit().
        emitted = macho(candidate)
        for name, value in storage_bindings['bindings'].items():
            va = int(value, 16)
            a = backed_offset(emitted['segments'], va, 4, len(candidate))
            b = backed_offset(reference['segments'], va - adjustment, 4, len(old_candidate))
            if candidate[a:a + 4] != old_candidate[b:b + 4]:
                raise ValueError('Storage import code/data differs: ' + name)
        prelink['pong_storage_bindings'] = storage_bindings
    base = min(s['va'] for s in native_image['segments'] if s['size'])
    extent = max(s['va'] + s['size'] for s in macho(candidate)['segments'] if s['size']) - base
    if extent > 0x0f000000:
        raise ValueError('Prelink exceeds owned window with diagnostic stack reserve')
    kernel = out / 'kernel-corecrypto.macho'
    kernel.write_bytes(candidate)
    (out / 'prelink.json').write_text(json.dumps(prelink, indent=2) + '\n')
    spec = spec_from_file_location('pong_build', DEVICE / 'scripts/build-ios16-pong-macos.py')
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    report['base_kernel'] = report['kernel']
    report['kernel'] = module.audit_kernel(kernel)
    report['prelink'] = {'components': prelink['components'], 'report': 'prelink.json',
        'validated_apfs_dependency_closure': prelink.get('validated_apfs_dependency_closure', []),
        'original_im4p_sha256': pin, 'original_macho_sha256': digest(original),
        'original_executable_sha256': prelink['original_executable_sha256'],
        'base_kernel_sha256': digest(native), 'virtual_span_bytes': extent,
        'runtime_qualified': False, 'crypto_selftests_passed': False,
        'symbol_kernel_scope': 'Base native kernel; component addresses and bindings are in prelink.json'}
    (out / 'PONG_BUILD_RESULT.json').write_text(json.dumps(report, indent=2) + '\n')
    symbol_kernel = Path(report['tree']) / 'build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/mach.development.pong.unstripped'
    if digest(symbol_kernel.read_bytes()) != report['unstripped_kernel']['sha256']:
        raise ValueError('Base symbol kernel differs from build report')
    shutil.copyfile(symbol_kernel, out / symbol_kernel.name)
    shutil.copytree(DEVICE / 'patches/xnu', out / 'xnu-patches')
    if report['settings'].get('XNU_PONG_EARLY_TRACE') == '1':
        shutil.copyfile(ROOT / 'evidence/pong-early-trace-stages.json', out / 'pong-early-trace-stages.json')
    # The qualified loader scans at most 128 MiB. This candidate carries only
    # corecrypto, with zero-filled coalesced gaps and no root filesystem.
    if not args.skip_bootimg:
        fat_mib = 64 if len(candidate) + 0x400000 < 64 * 1024 * 1024 else 96
        subprocess.run([sys.executable, str(DEVICE / 'scripts/build-native-bootimg-local.py'),
            '--kernel', str(kernel), '--result', str(out / 'PONG_BUILD_RESULT.json'),
            '--fat-mib', str(fat_mib), '--output-dir', str(out),
            '--window-size', hex(args.window_size),
            *(['--ufs-probe'] if args.ufs_probe else []),
            *(['--root-match-volume-uuid', args.root_match_volume_uuid]
              if args.root_match_volume_uuid else []),
            *(['--development-debug'] if args.development_debug else []),
            *(['--amfi-only-platform-code'] if args.amfi_only_platform_code else []),
            *(['--system-volume-auth-blob', str(args.system_volume_auth_blob)]
              if args.system_volume_auth_blob else []),
            *(['--data-ramdisk', str(args.data_ramdisk.resolve()), '--packed-data-ramdisk']
              if args.data_ramdisk else []),
            *[f'--kernel-arg={value}' for value in args.kernel_arg]], check=True)
    print('Prelink SHA-256:', digest(candidate))
    print('Owned-window virtual span:', hex(extent))


if __name__ == '__main__':
    main()
