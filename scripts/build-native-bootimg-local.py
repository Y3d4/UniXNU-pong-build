#!/usr/bin/env python3
"""Stage the audited PONG Mach-O with DarwinBoot22 in the qualified boot image.

This creates an initial XNU bring-up image, without Apple prelink or a root OS.
It never calls adb or fastboot and does not modify the template firmware.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import zlib

from pong_adt_contract import audit_adt

ROOT = Path(__file__).resolve().parents[2]
DEVICE = Path(__file__).resolve().parents[1]
SYSTEM_VOLUME_AUTH_BLOB_SHA256 = '561fe1614aab837773acd9c692cc31ed4999607c98468b710c6428f11b03d2e9'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cpus', type=int, choices=range(1, 9), default=1)
    parser.add_argument('--kernel', type=Path, default=DEVICE / 'mac-build/ios16-xnu-pong/mach.development.pong')
    parser.add_argument('--result', type=Path, default=DEVICE / 'mac-build/ios16-xnu-pong/PONG_BUILD_RESULT.json')
    parser.add_argument('--loader', type=Path, default=DEVICE / 'mac-build/darwinboot22/DarwinBoot22.efi')
    parser.add_argument('--template', type=Path, default=ROOT / 'images/pong-window-vectors.img')
    parser.add_argument('--output-dir', type=Path, default=ROOT / 'build/native-xnu-initial')
    parser.add_argument('--fat-mib', type=int, default=32)
    parser.add_argument('--window-size', type=lambda value: int(value, 0), default=0x10000000,
                        help='RAM bytes for DarwinBoot to allocate from real UEFI conventional memory')
    parser.add_argument('--menu-timeout', type=int, default=3,
                        help='UniXNU menu timeout in seconds; use 0 to boot the default entry immediately')
    parser.add_argument('--kernel-arg', action='append', default=[])
    parser.add_argument('--verbose-console', action='store_true',
                        help='opt in to -v screen text; default keeps the graphical boot path')
    parser.add_argument('--ufs', '--ufs-probe', dest='ufs_probe', action='store_true')
    parser.add_argument('--root-match-volume-uuid', default=None)
    parser.add_argument('--development-debug', action='store_true')
    parser.add_argument('--amfi-only-platform-code', action='store_true')
    parser.add_argument('--system-volume-auth-blob', type=Path, default=None)
    parser.add_argument('--data-ramdisk', type=Path, default=None,
                        help='packed DBRDISK1 APFS scratch Data seed passed as DarwinBoot initrd')
    parser.add_argument('--packed-data-ramdisk', action='store_true',
                        help='publish the supplied Data seed as PackedRAMDisk')
    parser.add_argument('--skip-image-verification', action='store_true',
                        help='package without image hashes, comparisons or output audits')
    args = parser.parse_args()
    if args.menu_timeout < 0:
        parser.error('--menu-timeout must be non-negative')
    if not 0x10000000 <= args.window_size <= 0x200000000 or args.window_size % 0x200000:
        parser.error('--window-size must be 256 MiB..8 GiB, aligned to 2 MiB')
    if args.packed_data_ramdisk != (args.data_ramdisk is not None):
        parser.error('--packed-data-ramdisk and --data-ramdisk must be supplied together')
    data_ramdisk = args.data_ramdisk.resolve() if args.data_ramdisk else None
    if data_ramdisk and not args.skip_image_verification:
        packed_data = data_ramdisk.read_bytes()
        if not 32 <= len(packed_data) <= 256 * 1024 * 1024 or packed_data[:8] != b'DBRDISK1':
            parser.error('--data-ramdisk must be a DBRDISK1 image within DarwinBoot\'s 256 MiB bound')
    if args.fat_mib < 32 or args.fat_mib > 112 or args.fat_mib % 16:
        parser.error('--fat-mib must be a multiple of 16 in [32, 112] within the qualified 128 MiB scan limit')
    report = json.loads(args.result.read_text())
    kernel = args.kernel.read_bytes() if not args.skip_image_verification else None
    if not args.skip_image_verification and (not report['build_complete'] or report['machine_config'] != 'PONG' or
            report['kernel']['sha256'] != hashlib.sha256(kernel).hexdigest() or
            report['unstripped_kernel']['raspberry_pi_hardware_symbols']):
        raise ValueError('Kernel does not match the audited PONG result')
    if args.root_match_volume_uuid and not args.skip_image_verification:
        prelink = report.get('prelink')
        if not prelink:
            raise ValueError('Root-matched APFS boot requires a prelinked Darwin 22 kernel')
        components = set(prelink.get('components', []))
        required = {'com.apple.filesystems.apfs', 'com.apple.iokit.IOStorageFamily',
                    'com.apple.kec.Compression',
                    'com.apple.AppleFSCompression.AppleFSCompressionTypeZlib'}
        missing = required - components
        if missing:
            raise ValueError('Root-matched APFS boot is missing prelinked components: ' +
                             ', '.join(sorted(missing)))
        closure = set(prelink.get('validated_apfs_dependency_closure', []))
        if not closure:
            raise ValueError('Root-matched APFS boot lacks the pinned 20G81 dependency-closure attestation')
        if not closure <= components:
            raise ValueError('Prelinked APFS dependency attestation exceeds component list')
    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    boot = out / 'pong-xnu-initial.img'
    if boot.exists():
        parser.error('Preserving the existing image; choose another --output-dir')
    payload = out / 'stage/EFI/UniXNU'
    payload.mkdir(parents=True, exist_ok=True)
    auth_blob_path = args.system_volume_auth_blob
    if auth_blob_path is not None and not auth_blob_path.is_absolute():
        auth_blob_path = ROOT / auth_blob_path
    auth_blob = auth_blob_path.read_bytes() if auth_blob_path else None
    if not args.skip_image_verification and auth_blob is not None and (len(auth_blob) != 208 or
            hashlib.sha256(auth_blob).hexdigest() != SYSTEM_VOLUME_AUTH_BLOB_SHA256 or
            struct.unpack_from('<4I', auth_blob) != (2, 0, 1, 32)):
        raise ValueError('System volume auth blob differs from the verified iOS 20G81 component')
    shutil.copyfile(args.kernel, payload / 'kernel.macho')
    shutil.copyfile(args.loader, payload / 'DarwinBoot22.efi')
    if data_ramdisk:
        (payload / 'Payloads').mkdir(parents=True, exist_ok=True)
        shutil.copyfile(data_ramdisk, payload / 'Payloads/scratch-data.img')
    # Describe the real development boot payload. This unsigned manifest binds
    # the supplied inputs; it is not an Apple IM4M or a personalization ticket.
    values = [v for value in args.kernel_arg for v in value.split() if v != '-v']
    boot_args = ('-v ' if args.verbose_console else '') + f'keepsyms=1 cpus={args.cpus}'
    boot_args += ''.join(' ' + value for value in values)
    boot_manifest = json.dumps({
        'format': 'pong-development-boot-manifest-v1',
        'apple_personalization': False,
        'development_debug': args.development_debug,
        'amfi_only_platform_code': args.amfi_only_platform_code,
        'system_volume_auth_blob_sha256': hashlib.sha256(auth_blob).hexdigest() if auth_blob is not None and not args.skip_image_verification else None,
        'kernel_sha384': hashlib.sha384(kernel).hexdigest() if not args.skip_image_verification else None,
        'loader_sha384': hashlib.sha384((payload / 'DarwinBoot22.efi').read_bytes()).hexdigest() if not args.skip_image_verification else None,
        'board': 'Nothing Phone (2) / Pong / SM8475',
        'boot_args': boot_args,
        'root_volume_uuid': args.root_match_volume_uuid,
        'requested_memory_window_bytes': args.window_size,
    }, sort_keys=True, separators=(',', ':')).encode() + b'\n'
    manifest_path = payload / 'pong-boot-manifest.json'
    manifest_path.write_bytes(boot_manifest)
    subprocess.run([sys.executable, str(DEVICE / 'scripts/make-pong-adt.py'),
        '--cpus', str(args.cpus),
        '--dram-size', '0x300000000', '--window-size', hex(args.window_size),
        '--output', str(payload / 'kernel.macho.adt'),
        '--boot-manifest', str(manifest_path),
        *(['--skip-image-verification'] if args.skip_image_verification else []),
        *(['--development-debug'] if args.development_debug else []),
        *(['--amfi-only-platform-code'] if args.amfi_only_platform_code else []),
        *(['--system-volume-auth-blob', str(auth_blob_path)] if auth_blob is not None else []),
        *(['--packed-data-ramdisk'] if data_ramdisk else []),
        *(['--ufs-probe'] if args.ufs_probe else []),
        *(['--root-match-volume-uuid', args.root_match_volume_uuid]
          if args.root_match_volume_uuid else [])], check=True)
    adt_audit = ({'status': 'skipped by request'} if args.skip_image_verification else
                 audit_adt((payload / 'kernel.macho.adt').read_bytes(), boot_manifest=boot_manifest))
    (out / 'adt-audit.json').write_text(json.dumps(adt_audit, indent=2) + '\n')
    initrd_line = 'initrd = "Payloads/scratch-data.img"\n' if data_ramdisk else ''
    (payload / 'unixnu.toml').write_text(f'version = 1\n[boot]\ntimeout = {args.menu_timeout}\n'
        'default = "pong-xnu"\n[kits]\nautoload = false\n[[driver]]\n'
        'path = "DarwinBoot22.efi"\nconnect = false\n[[entry]]\n'
        'id = "pong-xnu"\ntitle = "Pong iOS 16 native XNU initial bring-up"\n'
        'type = "xnu"\npath = "kernel.macho"\n' + initrd_line + 'args = "' + boot_args + '"\n')
    fat = out / 'payload-fat.img'
    env = dict(os.environ, MTOOLS_SKIP_CHECK='1', TZ='UTC')
    subprocess.run(['mformat', '-C', '-T', str(args.fat_mib * 2048), '-v', 'PONGXNU16', '-i', str(fat), '::'], check=True, env=env)
    subprocess.run(['mcopy', '-i', str(fat), '-s', str(out / 'stage/EFI'), '::/'], check=True, env=env)
    raw = fat.read_bytes()
    header = bytearray(4096)
    struct.pack_into('<8sIIQII', header, 0, b'PONGFAT1', 1, 4096, len(raw), zlib.crc32(raw), 0)
    ramdisk = bytes(header) + raw
    (out / 'payload.ramdisk').write_bytes(ramdisk)
    template = args.template.read_bytes()
    if not args.skip_image_verification and (template[:8] != b'ANDROID!' or struct.unpack_from('<I', template, 40)[0] != 4):
        raise ValueError('Expected Android boot v4')
    kernel_size, old_size = struct.unpack_from('<2I', template, 8)
    page = lambda size: (size + 4095) & ~4095
    ramdisk_at = 4096 + page(kernel_size)
    signature_at = ramdisk_at + page(old_size)
    if not args.skip_image_verification and (len(template) != signature_at + 4096 or any(template[signature_at:])):
        raise ValueError('Unexpected unsigned signature area')
    image = bytearray(template[:ramdisk_at])
    struct.pack_into('<I', image, 12, len(ramdisk))
    image += ramdisk + bytes(page(len(ramdisk)) - len(ramdisk)) + template[signature_at:]
    if not args.skip_image_verification:
        assert image[4096:ramdisk_at] == template[4096:ramdisk_at]
    boot.write_bytes(image)
    result = {'contains_xnu': True, 'prelinked': bool(report.get('prelink')), 'root_os_included': False,
        'adt_audit': adt_audit, 'hardware_tested': False, 'partition_writes': False, 'image_bytes': len(image),
        'image_sha256': hashlib.sha256(image).hexdigest() if not args.skip_image_verification else None,
        'kernel_sha256': report['kernel'].get('sha256'),
        'loader_sha256': hashlib.sha256(args.loader.read_bytes()).hexdigest() if not args.skip_image_verification else None,
        'template_sha256': hashlib.sha256(template).hexdigest() if not args.skip_image_verification else None,
        'image_verification': 'skipped by request' if args.skip_image_verification else 'performed',
        'firmware_and_dtb_unchanged': True, 'boot_args_abi': 'Darwin 22',
        'allocated_window_bytes': args.window_size, 'fat_mib': args.fat_mib,
        'cpu_count': args.cpus}
    if args.root_match_volume_uuid:
        result['root_match_volume_uuid'] = args.root_match_volume_uuid
    result['amfi_only_platform_code'] = args.amfi_only_platform_code
    result['system_volume_auth_blob_sha256'] = hashlib.sha256(auth_blob).hexdigest() if auth_blob is not None and not args.skip_image_verification else None
    result['data_ramdisk_bytes'] = data_ramdisk.stat().st_size if data_ramdisk else 0
    result['packed_data_ramdisk'] = bool(data_ramdisk)
    if report.get('prelink'):
        result['prelink'] = report['prelink']
    (out / 'build.json').write_text(json.dumps(result, indent=2) + '\n')
    print(boot)


if __name__ == '__main__':
    main()
