#!/usr/bin/env bash
set -euo pipefail
trap 'echo "build-xnu-4k-baseline.sh: line $LINENO: $BASH_COMMAND failed" >&2' ERR
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
# Pong iOS 16 derivative of the successfully returned Mac build script.
# First console build uses MACHINE_CONFIGS=PONG; preserve the original baseline artifact.
XNU_TAG=${UNIXNU_XNU_TAG:-xnu-8796.141.3}
XNU_COMMIT=${UNIXNU_XNU_COMMIT:-1b191cb58250d0705d8a51287127505aa4bc0789}
XNU_DARWIN=${UNIXNU_XNU_DARWIN:-22.6.0}
XNU_VERSION=${UNIXNU_XNU_VERSION:-8796.141.3}
LIBPLATFORM_TAG=${UNIXNU_LIBPLATFORM_TAG:-libplatform-292.100.1}
LIBDISPATCH_TAG=${UNIXNU_LIBDISPATCH_TAG:-libdispatch-1325.120.2}
AVAILABILITY_TAG=${UNIXNU_AVAILABILITYVERSIONS_TAG:-AvailabilityVersions-121}
if [ ! -d refer/xnu/.git ]; then
  git clone --depth 1 --branch "$XNU_TAG" https://github.com/apple-oss-distributions/xnu.git refer/xnu
fi
if [ "$(git -C refer/xnu rev-parse HEAD)" != "$XNU_COMMIT" ]; then
  echo 'error: unexpected XNU reference revision' >&2
  exit 1
fi
if [ ! -d .cache/xnu-work/.git ]; then
  git clone --shared refer/xnu .cache/xnu-work
fi
if [ "$(git -C .cache/xnu-work rev-parse HEAD)" != "$XNU_COMMIT" ]; then
  echo 'error: existing XNU work tree is another version; use a fresh output directory' >&2
  exit 1
fi
if [ ! -x .cache/fakeroot/usr/local/libexec/availability.pl ]; then
  if [ ! -d refer/AvailabilityVersions/.git ]; then
    git clone --depth 1 --branch "$AVAILABILITY_TAG" https://github.com/apple-oss-distributions/AvailabilityVersions.git refer/AvailabilityVersions
  fi
  mkdir -p .cache/fakeroot
  make -C refer/AvailabilityVersions install -j"${JOBS:-4}" \
    OBJROOT="$ROOT/build/availability" SYMROOT="$ROOT/build/availability" \
    DSTROOT="$ROOT/.cache/fakeroot" CMAKE="$(command -v cmake)" NINJA="$(command -v ninja)"
fi
# The optional observation hooks overlap existing root/exec patch context.
# Remove them first so earlier independent patches retain their idempotent checks.
# The same holds for the boot-time GPU addon mount (zzy), which edits the owner Data mount function inside the systemos patch.
# Reverse newest first; the loop below re-applies them in name order.
python3 - <<'PY_PATCH_TIMES'
from pathlib import Path
import hashlib, json
work = Path('.cache/xnu-work')
snapshot = {}
for patch in Path('patches/xnu').glob('*.patch'):
    for line in patch.read_text().splitlines():
        if line.startswith('+++ b/'):
            relative = line[6:].split('\t', 1)[0]
            path = work / relative
            if path.is_file():
                info = path.stat()
                snapshot[relative] = [hashlib.sha256(path.read_bytes()).hexdigest(),
                                      info.st_atime_ns, info.st_mtime_ns]
Path('.cache/xnu-patch-times.json').write_text(json.dumps(snapshot))
PY_PATCH_TIMES
while IFS= read -r LATE_PATCH; do
  if git -C .cache/xnu-work apply --reverse --check "$LATE_PATCH" >/dev/null 2>&1; then
    git -C .cache/xnu-work apply --reverse "$LATE_PATCH"
  fi
done < <(python3 - <<'PY_LATE_PATCHES'
from pathlib import Path
patches = [p.resolve() for p in Path('patches/xnu').glob('zz*pong*.patch')]
patches += [Path('patches/xnu/zzz-boot-progress.patch').resolve(),
            Path('patches/xnu/zzy-native-gpu-addon-mount.patch').resolve()]
for patch in sorted(set(patches), reverse=True):
    print(patch)
PY_LATE_PATCHES
)
PATCHES=("$ROOT"/patches/xnu/*.patch)
if [ "$XNU_VERSION" = "10063.141.1" ]; then
  PATCHES+=("$ROOT"/kits/NativePrelink/patches/*.patch)
fi
for PATCH in "${PATCHES[@]}"; do
  if [ "$(basename "$PATCH")" = "external-archive-dependencies.patch" ] && [ -z "${XNU_EXTRA_LD_ARCHIVES:-}" ]; then
    echo "Skipping external-archive-dependencies.patch: this baseline links no external archives"
    continue
  fi
  if [ "$(basename "$PATCH")" = "native-aes-personality.patch" ] && [ "${XNU_NATIVE_AES:-0}" != 1 ]; then
    echo "Skipping native-aes-personality.patch: NativeAES composite personalities are disabled"
    continue
  fi
  if [ "$(basename "$PATCH")" = "ios16-native-ufs-personality.patch" ] && \
     rg -q "'IOClass'[[:space:]]*= NativeUfs;" .cache/xnu-work/iokit/KernelConfigTables.cpp; then
    echo "Already present: NativeUfs personality in KernelConfigTables.cpp"
    continue
  fi
  if [ "$(basename "$PATCH")" = "native-ram-block-personality.patch" ] && \
     rg -q "'IOClass'[[:space:]]*= NativeRamBlock;" .cache/xnu-work/iokit/KernelConfigTables.cpp; then
    echo "Already present: NativeRamBlock personality in KernelConfigTables.cpp"
    continue
  fi
  if [ "$(basename "$PATCH")" = "offline-owner-systemos-mount.patch" ] && [ "${XNU_OWNER_CACHE_MOUNT:-0}" != 1 ]; then
    echo "Skipping offline-owner-systemos-mount.patch: owner cache mounting is disabled in this baseline"
    continue
  fi
  PATCH_NAME=$(basename "$PATCH")
  if [ "${XNU_STORAGE_ABI_BOOTSTRAP:-0}" = 1 ] && {
    [ "$PATCH_NAME" = "zzzzzz-pong-writable-data.patch" ] ||
    [[ "$PATCH_NAME" == *pong-ufs-data.patch ]] ||
    [[ "$PATCH_NAME" == *pong-systemos-shared-region.patch ]] ||
    [[ "$PATCH_NAME" == *pong-upstream-oct22.patch ]] ||
    [[ "$PATCH_NAME" == *pong-hackios-userland-abi.patch ]] ||
    [[ "$PATCH_NAME" == *pong-development-uaccess.patch ]] ||
    [[ "$PATCH_NAME" == *owner-z-air-init.patch ]];
  }; then
    echo "Skipping $PATCH_NAME: storage ABI bootstrap has no owner Data path"
    continue
  fi
  if { [ "$(basename "$PATCH")" = "offline-pgz-alignment-probe.patch" ] || [ "$(basename "$PATCH")" = "pgz-aligned-validation.patch" ]; } && [ "${XNU_ZONE_PGZ_ALIGNMENT_PROBE:-0}" != 1 ]; then
    echo "Skipping $(basename "$PATCH"): optional PGZ alignment probe is disabled in this baseline"
    continue
  fi
  if [ "$(basename "$PATCH")" = "public-entitlements-header.patch" ] && [ "$XNU_VERSION" != "10063.141.1" ]; then
    echo "Skipping public-entitlements-header.patch: web-browser entitlement keys are absent from this XNU source"
    continue
  fi
  if [ "$(basename "$PATCH")" = "published-freezer-condition.patch" ] && [ "$XNU_VERSION" != "10063.141.1" ]; then
    echo "Skipping published-freezer-condition.patch: the affected freezer source is absent from this XNU version"
    continue
  fi
  if [ "$(basename "$PATCH")" = "zzy-native-gpu-addon-mount.patch" ] && [ "${XNU_NATIVE_OFFLINE_GPU:-0}" != 1 ]; then
    echo "Skipping zzy-native-gpu-addon-mount.patch: offline GPU addon mounting is disabled in this baseline"
    continue
  fi
  if [ "$(basename "$PATCH")" = "zzz-boot-progress.patch" ] && [ "${XNU_BOOT_PROGRESS:-0}" != 1 ]; then
    echo "Skipping zzz-boot-progress.patch: optional kernel boot tracing is disabled in this baseline"
    continue
  fi
  echo "Applying XNU patch: $(basename "$PATCH")"
  if git -C .cache/xnu-work apply --reverse --check "$PATCH" >/dev/null 2>&1; then
    echo "Already applied: $(basename "$PATCH")"
  elif git -C .cache/xnu-work apply --check "$PATCH" >/dev/null 2>&1; then
    git -C .cache/xnu-work apply "$PATCH"
  elif patch --dry-run --batch --fuzz=3 -p1 -d .cache/xnu-work < "$PATCH" >/dev/null 2>&1; then
    patch --batch --fuzz=3 -p1 -d .cache/xnu-work < "$PATCH"
  else
    echo "Patch does not apply cleanly to XNU $XNU_VERSION: $PATCH" >&2
    exit 1
  fi
done
python3 - <<'PY_PATCH_TIMES'
from pathlib import Path
import hashlib, json, os
work = Path('.cache/xnu-work')
for relative, (digest, atime, mtime) in json.loads(Path('.cache/xnu-patch-times.json').read_text()).items():
    path = work / relative
    if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
        os.utime(path, ns=(atime, mtime))
PY_PATCH_TIMES
if [ "$(uname -s)" = Linux ]; then
  # Install the Linux stand-in for Apple's TargetConditionals.h before any
  # SDK consumer, such as the firehose archive, is compiled.
  python3 scripts/linux/prepare-xnu.py source
fi
export XNU_AVAILABILITY_PL=$ROOT/.cache/fakeroot/usr/local/libexec/availability.pl
python3 scripts/prepare-xnu-source.py
BOOT_PROGRESS=${XNU_BOOT_PROGRESS:-0}
if [ "$BOOT_PROGRESS" != 0 ] && [ "$BOOT_PROGRESS" != 1 ]; then
  echo 'XNU_BOOT_PROGRESS must be 0 or 1' >&2
  exit 1
fi
if [ "$BOOT_PROGRESS" = 1 ]; then
  if [ "${XNU_NATIVE_UFS:-0}" != 1 ] || [ "${XNU_OWNER_ROOT_AUDIT:-0}" != 1 ] || \
     [ "${XNU_NATIVE_VIRTIO_BLOCK:-0}" != 1 ] || [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ]; then
    echo 'Boot progress requires the audited UFS/owner-root, Virtio and source-corecrypto build' >&2
    exit 1
  fi
  python3 scripts/build-boot-progress.py
fi
python3 - "$BOOT_PROGRESS" <<'PY'
from pathlib import Path
import hashlib, sys
mode = sys.argv[1]
out = Path('build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG')
stamp = out / '.boot-progress-mode'
identity = mode + ':' + (hashlib.sha256(Path('build/boot-progress/libBootProgress.a').read_bytes()).hexdigest() if mode == '1' else 'disabled')
if not stamp.exists() or stamp.read_text() != identity:
    for directory, names in [('osfmk', ['arm_init','startup','video_console','serial_console','sleh']),
                             ('bsd', ['bsd_init','kern_exec','kern_exit']), ('pexpert', ['pe_kprintf'])]:
        for name in names:
            (out / directory / 'DEVELOPMENT' / (name + '.o')).unlink(missing_ok=True)
    (out / 'mach.development.pong.unstripped.noctf').unlink(missing_ok=True)
    out.mkdir(parents=True, exist_ok=True)
    stamp.write_text(identity)
PY
if [ ! -d refer/libplatform/.git ]; then
  git clone --depth 1 --branch "$LIBPLATFORM_TAG" https://github.com/apple-oss-distributions/libplatform.git refer/libplatform
fi
export KERNEL_SDKROOT=$ROOT/.cache/fakeroot
mkdir -p "$KERNEL_SDKROOT/usr/local/include/kernel" "$ROOT/build/xnu/obj/EXPORT_HDRS/libsa"
ditto refer/libplatform/include "$KERNEL_SDKROOT/usr/local/include"
ditto refer/libplatform/private "$KERNEL_SDKROOT/usr/local/include"
ditto refer/libplatform/private/platform "$KERNEL_SDKROOT/System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders/platform"
if [ ! -d refer/libdispatch/.git ]; then
  git clone --depth 1 --branch "$LIBDISPATCH_TAG" https://github.com/apple-oss-distributions/libdispatch.git refer/libdispatch
fi
python3 - <<'PY'
from pathlib import Path
import subprocess
output = Path('.cache/fakeroot/usr/local/include/os')
output.mkdir(parents=True, exist_ok=True)
for header in Path('refer/libdispatch/os').glob('*.h'):
    result = subprocess.run(['unifdef', '-DKERNEL=1', '-DOS_FIREHOSE_SPI=1',
                             '-DOS_VOUCHER_ACTIVITY_SPI_TYPES=1',
                             '-UOS_VOUCHER_ACTIVITY_SPI', str(header)], capture_output=True)
    if result.returncode not in (0, 1):
        raise SystemExit(result.stderr.decode())
    target = output / header.name
    if not target.exists() or target.read_bytes() != result.stdout:
        target.write_bytes(result.stdout)
PY
if [ ! -f "$KERNEL_SDKROOT/.xnu-$XNU_VERSION-headers" ] || \
   [ .cache/xnu-work/pexpert/pexpert/arm64/board_config.h -nt "$KERNEL_SDKROOT/.xnu-$XNU_VERSION-headers" ] || \
   [ .cache/xnu-work/pexpert/pexpert/arm64/PONG.h -nt "$KERNEL_SDKROOT/.xnu-$XNU_VERSION-headers" ]; then
  INSTALLHDRS_ARGS=(
    -C .cache/xnu-work installhdrs SDKROOT=macosx ARCH_CONFIGS=ARM64
    MACHINE_CONFIGS=PONG KERNEL_CONFIGS=DEVELOPMENT
    RC_DARWIN_KERNEL_VERSION="$XNU_DARWIN" RC_ProjectSourceVersion="$XNU_VERSION"
    MAKEJOBS=-j"${JOBS:-4}" OBJROOT="$ROOT/build/xnu/obj"
    SYMROOT="$ROOT/build/xnu/sym" DSTROOT="$KERNEL_SDKROOT"
  )
  if [ "$(uname -s)" = Linux ]; then
    # Linux lacks Darwin's sysctl, sw_vers, and XNU host tool defaults.
    HOST_OS_VERSION=${UNIXNU_HOST_OS_VERSION:-26.0.0}
    HOST_PHYSICAL_CPU=${UNIXNU_HOST_PHYSICAL_CPU:-$(nproc --all)}
    HOST_LOGICAL_CPU=${UNIXNU_HOST_LOGICAL_CPU:-$(nproc --all)}
    HOST_MEMORY_SIZE=$(awk '/^MemTotal:/ {printf "%.0f\n", $2 * 1024; exit}' /proc/meminfo)
    HOST_MEMORY_SIZE=${UNIXNU_HOST_MEMORY_SIZE:-$HOST_MEMORY_SIZE}
    TOOLCHAIN_ROOT=${UNIXNU_TOOLCHAIN:-/opt/unixnu-linux}
    HOST_CC=${UNIXNU_HOST_CC:-$TOOLCHAIN_ROOT/CommandLineTools/usr/bin/xnu-host-cc}
    MIG_CC=${UNIXNU_MIGCC:-$TOOLCHAIN_ROOT/CommandLineTools/usr/bin/clang}
    MIG_COM=${UNIXNU_MIGCOM:-$TOOLCHAIN_ROOT/CommandLineTools/usr/libexec/migcom}
    INSTALLHDRS_ARGS+=(
      HOST_OS_VERSION="$HOST_OS_VERSION" SYSCTL_HW_PHYSICALCPU="$HOST_PHYSICAL_CPU"
      SYSCTL_HW_LOGICALCPU="$HOST_LOGICAL_CPU" MEMORY_SIZE="$HOST_MEMORY_SIZE"
      HOST_CC="$HOST_CC" MIGCC="$MIG_CC" MIGCOM="$MIG_COM"
    )
  fi
  make "${INSTALLHDRS_ARGS[@]}"
  touch "$KERNEL_SDKROOT/.xnu-$XNU_VERSION-headers"
fi
if [ "${XNU_ARM_DT_PLATFORM:-0}" = 1 ] && [ -n "${PONG_NATIVE_DRIVER_SOURCE:-}" ]; then
  # These sources live in the active Pong project, not the old baseline's
  # drivers symlink. Build against the same freshly exported machine headers.
  python3 "$PONG_NATIVE_DRIVER_SOURCE/scripts/build-pong-platform-macos.py" \
    --tree "$ROOT" --skip-image-verification
  if [ "${XNU_ARMCPU:-0}" = 1 ]; then
    python3 "$PONG_NATIVE_DRIVER_SOURCE/scripts/build-pong-armcpu-macos.py" \
      --tree "$ROOT" --skip-image-verification
  fi
fi
if [ "${XNU_NATIVE_UFS:-0}" = 1 ] && [ -n "${PONG_NATIVE_DRIVER_SOURCE:-}" ]; then
  # The transport changes with the selected Data backend. Always compile the
  # active Pong source before linking, rather than reuse an older RAM-era .a.
  python3 "$PONG_NATIVE_DRIVER_SOURCE/scripts/build-pong-ufs-probe-macos.py" \
    --tree "$ROOT" --skip-image-verification
fi
if [ ! -f "$KERNEL_SDKROOT/usr/local/lib/kernel/libfirehose_kernel.a" ]; then
  bash scripts/build-firehose.sh
fi
if [ "$(uname -s)" = Linux ]; then
  python3 scripts/linux/prepare-xnu.py libs
fi
# The baseline builds the kernel; `all` also checks the Apple kext export ABI.
EXTRA_MAKE_ARGS=()
ARM_DT_PLATFORM=${XNU_ARM_DT_PLATFORM:-0}
if [ "$ARM_DT_PLATFORM" != 0 ] && [ "$ARM_DT_PLATFORM" != 1 ]; then
  echo 'XNU_ARM_DT_PLATFORM must be 0 or 1' >&2
  exit 1
fi
if [ "${XNU_ARMCPU:-0}" = 1 ] && [ "${XNU_ARMVIRT_PLATFORM:-0}" != 1 ] && [ "$ARM_DT_PLATFORM" != 1 ]; then
  echo 'ArmCpu requires a real platform driver' >&2
  exit 1
fi
if [ "${XNU_SOURCE_PTHREAD:-0}" = 1 ] && [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ]; then
  echo 'The current pthread source-link recipe requires XNU_SOURCE_CORECRYPTO14=1' >&2
  exit 1
fi
CRYPTO_BOOTSTRAP_MODE=${XNU_CRYPTO_BOOTSTRAP:-source}
if [ "$CRYPTO_BOOTSTRAP_MODE" != source ] && [ "$CRYPTO_BOOTSTRAP_MODE" != prelinked ]; then
  echo 'XNU_CRYPTO_BOOTSTRAP must be source or prelinked' >&2
  exit 1
fi
CRYPTO_OBJECT_DIR=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/osfmk/DEVELOPMENT
if [ -d "$CRYPTO_OBJECT_DIR" ]; then
  if [ "$(cat "$CRYPTO_OBJECT_DIR/.crypto-bootstrap-mode" 2>/dev/null || echo source)" != "$CRYPTO_BOOTSTRAP_MODE" ]; then
    rm -f "$CRYPTO_OBJECT_DIR/prng_random.o"
  fi
  printf '%s\n' "$CRYPTO_BOOTSTRAP_MODE" > "$CRYPTO_OBJECT_DIR/.crypto-bootstrap-mode"
fi
if [ "$CRYPTO_BOOTSTRAP_MODE" = prelinked ]; then
  # The original component must initialize through real OSKext startup.
  # Only this source-provider entry is omitted; no POST or missing-provider
  # failure is suppressed, and no replacement crypto callbacks are supplied.
  EXTRA_MAKE_ARGS+=("prng_random.o_CFLAGS_ADD=-UXNU_SOURCE_CORECRYPTO14")
else
  EXTRA_MAKE_ARGS+=("prng_random.o_CFLAGS_ADD=")
fi
if [ "${XNU_NATIVE_AES:-0}" = 1 ]; then
  if [ "$CRYPTO_BOOTSTRAP_MODE" != prelinked ] || [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ]; then
    echo 'NativeAES currently requires the qualified original AES/crypto prelink closure' >&2
    exit 1
  fi
  PERSONALITY_CFLAGS=-DXNU_NATIVE_AES=1
else
  PERSONALITY_CFLAGS=
fi
if [ "${XNU_NATIVE_VIRTIO_BLOCK:-0}" = 1 ]; then
  if [ "${XNU_NATIVE_AES:-0}" != 1 ]; then
    echo 'NativeVirtioBlock currently requires the qualified NativeAES/original-storage prelink baseline' >&2
    exit 1
  fi
  PERSONALITY_CFLAGS="$PERSONALITY_CFLAGS -DXNU_NATIVE_VIRTIO_BLOCK=1"
fi
NATIVE_RAM_BLOCK=${XNU_NATIVE_RAM_BLOCK:-0}
if [ "$NATIVE_RAM_BLOCK" != 0 ] && [ "$NATIVE_RAM_BLOCK" != 1 ]; then
  echo 'XNU_NATIVE_RAM_BLOCK must be 0 or 1' >&2
  exit 1
fi
if [ "$NATIVE_RAM_BLOCK" = 1 ]; then
  if [ "${XNU_NATIVE_AES:-0}" != 1 ] && [ "${XNU_PONG_APFS_DEBUG:-0}" != 1 ]; then
    echo 'NativeRamBlock requires the qualified original storage/AES prelink closure' >&2
    exit 1
  fi
  PERSONALITY_CFLAGS="$PERSONALITY_CFLAGS -DXNU_NATIVE_RAM_BLOCK=1"
fi
if [ "${XNU_NATIVE_UFS:-0}" = 1 ]; then
  PERSONALITY_CFLAGS="$PERSONALITY_CFLAGS -DXNU_NATIVE_UFS=1"
fi
NATIVE_VIRTIO_CONSOLE=${XNU_NATIVE_VIRTIO_CONSOLE:-0}
if [ "$NATIVE_VIRTIO_CONSOLE" != 0 ] && [ "$NATIVE_VIRTIO_CONSOLE" != 1 ]; then
  echo 'XNU_NATIVE_VIRTIO_CONSOLE must be 0 or 1' >&2
  exit 1
fi
if [ "$NATIVE_VIRTIO_CONSOLE" = 1 ]; then
  PERSONALITY_CFLAGS="$PERSONALITY_CFLAGS -DXNU_NATIVE_VIRTIO_CONSOLE=1"
fi
EXTRA_MAKE_ARGS+=("KernelConfigTables.cpo_CFLAGS_ADD=$PERSONALITY_CFLAGS")
TRUST_CACHE_MODE=${XNU_TRUST_CACHE_RUNTIME:-0}
if [ "$TRUST_CACHE_MODE" != 0 ] && [ "$TRUST_CACHE_MODE" != 1 ]; then
  echo 'XNU_TRUST_CACHE_RUNTIME must be 0 or 1' >&2
  exit 1
fi
if [ -d "$CRYPTO_OBJECT_DIR" ]; then
  if [ "$(cat "$CRYPTO_OBJECT_DIR/.trust-cache-mode" 2>/dev/null || echo 0)" != "$TRUST_CACHE_MODE" ]; then
    rm -f "$CRYPTO_OBJECT_DIR/startup.o"
  fi
  printf '%s\n' "$TRUST_CACHE_MODE" > "$CRYPTO_OBJECT_DIR/.trust-cache-mode"
fi
EXTRA_MAKE_ARGS+=("startup.o_CFLAGS_ADD=-DXNU_NATIVE_TRUST_CACHE=$TRUST_CACHE_MODE -DXNU_PONG_EARLY_TRACE=${XNU_PONG_EARLY_TRACE:-0}")
MOCKFS_MODE=${XNU_SOURCE_MOCKFS:-0}
if [ "$MOCKFS_MODE" != 0 ] && [ "$MOCKFS_MODE" != 1 ]; then
  echo 'XNU_SOURCE_MOCKFS must be 0 or 1' >&2
  exit 1
fi
if [ "$MOCKFS_MODE" = 1 ] && { [ "${XNU_ARMCPU:-0}" != 1 ] || [ "${XNU_SOURCE_PTHREAD:-0}" != 1 ]; }; then
  echo 'The offline executable-root fixture requires the real CPU/pthread components' >&2
  exit 1
fi
MOCKFS_OBJECT_DIR=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/bsd/DEVELOPMENT
if [ -d "$MOCKFS_OBJECT_DIR" ]; then
  if [ "$(cat "$MOCKFS_OBJECT_DIR/.source-mockfs-mode" 2>/dev/null || echo 0)" != "$MOCKFS_MODE" ]; then
    rm -f "$MOCKFS_OBJECT_DIR/vfs_conf.o"
  fi
  printf '%s\n' "$MOCKFS_MODE" > "$MOCKFS_OBJECT_DIR/.source-mockfs-mode"
fi
EXTRA_MAKE_ARGS+=("vfs_conf.o_CFLAGS_ADD=-DMOCKFS=$MOCKFS_MODE")
CS_HASH_CACHE_MODE=${XNU_NATIVE_CS_HASH_CACHE:-0}
if [ "$CS_HASH_CACHE_MODE" != 0 ] && [ "$CS_HASH_CACHE_MODE" != 1 ]; then
  echo 'XNU_NATIVE_CS_HASH_CACHE must be 0 or 1' >&2
  exit 1
fi
if [ -d "$MOCKFS_OBJECT_DIR" ]; then
  if [ "$(cat "$MOCKFS_OBJECT_DIR/.native-cs-hash-cache-mode" 2>/dev/null || echo 0)" != "$CS_HASH_CACHE_MODE" ]; then
    rm -f "$MOCKFS_OBJECT_DIR/ubc_subr.o"
  fi
  printf '%s\n' "$CS_HASH_CACHE_MODE" > "$MOCKFS_OBJECT_DIR/.native-cs-hash-cache-mode"
fi
EXTRA_MAKE_ARGS+=("ubc_subr.o_CFLAGS_ADD=-DXNU_NATIVE_CS_HASH_CACHE=$CS_HASH_CACHE_MODE")
EXTRA_CFLAGS=${XNU_EXTRA_CFLAGS:--Wno-reserved-identifier -Wno-pre-c11-compat -Wno-missing-designated-field-initializers -Wno-suggest-override -Wno-unnecessary-virtual-specifier -Wno-suggest-destructor-override -Wno-ms-bitfield-padding}
OWNER_ROOT_PROBE=${XNU_VERIFIED_ROOT_PROBE:-0}
if [ "$OWNER_ROOT_PROBE" != 0 ] && [ "$OWNER_ROOT_PROBE" != 1 ]; then
  echo 'XNU_VERIFIED_ROOT_PROBE must be 0 or 1' >&2
  exit 1
fi
PONG_APFS_DEBUG=${XNU_PONG_APFS_DEBUG:-0}
if [ "$PONG_APFS_DEBUG" != 0 ] && [ "$PONG_APFS_DEBUG" != 1 ]; then
  echo 'XNU_PONG_APFS_DEBUG must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_ROOT_PROBE" = 1 ] && { [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ] || [ "${XNU_CRYPTO_BOOTSTRAP:-source}" != prelinked ]; }; then
  echo 'The owner crypto probe requires the qualified original prelinked crypto provider' >&2
  exit 1
fi
OWNER_ROOT_AUDIT=${XNU_OWNER_ROOT_AUDIT:-0}
if [ "$OWNER_ROOT_AUDIT" != 0 ] && [ "$OWNER_ROOT_AUDIT" != 1 ]; then
  echo 'XNU_OWNER_ROOT_AUDIT must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_ROOT_AUDIT" = 1 ] && [ "$OWNER_ROOT_PROBE" != 1 ]; then
  echo 'The root-binding audit requires real owner-verified block crypto' >&2
  exit 1
fi
OWNER_ROOT_TRUST=${XNU_OWNER_ROOT_TRUST:-0}
if [ "$OWNER_ROOT_TRUST" != 0 ] && [ "$OWNER_ROOT_TRUST" != 1 ]; then
  echo 'XNU_OWNER_ROOT_TRUST must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_ROOT_TRUST" = 1 ] && { [ "$OWNER_ROOT_AUDIT" != 1 ] || [ "${XNU_NATIVE_VIRTIO_BLOCK:-0}" != 1 ]; }; then
  echo 'Owner root acceptance requires actual mounted-media binding and verified block storage' >&2
  exit 1
fi
ADRENO_FIRMWARE_PROBE=${XNU_ADRENO_FIRMWARE_PROBE:-0}
if [ "$ADRENO_FIRMWARE_PROBE" != 0 ] && [ "$ADRENO_FIRMWARE_PROBE" != 1 ]; then
  echo 'XNU_ADRENO_FIRMWARE_PROBE must be 0 or 1' >&2
  exit 1
fi
if [ "$ADRENO_FIRMWARE_PROBE" = 1 ] && [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ]; then
  echo 'The offline Adreno planner probe requires the qualified crypto build' >&2
  exit 1
fi
ADRENO_PM4_PROBE=${XNU_ADRENO_PM4_PROBE:-0}
if [ "$ADRENO_PM4_PROBE" != 0 ] && [ "$ADRENO_PM4_PROBE" != 1 ]; then
  echo 'XNU_ADRENO_PM4_PROBE must be 0 or 1' >&2
  exit 1
fi
if [ "$ADRENO_PM4_PROBE" = 1 ] && [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ]; then
  echo 'The offline PM4 fixture requires the qualified native kernel configuration' >&2
  exit 1
fi
SMMU4K_PROBE=${XNU_SMMU4K_PROBE:-0}
if [ "$SMMU4K_PROBE" != 0 ] && [ "$SMMU4K_PROBE" != 1 ]; then
  echo 'XNU_SMMU4K_PROBE must be 0 or 1' >&2
  exit 1
fi
if [ "$SMMU4K_PROBE" = 1 ] && [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ]; then
  echo 'The offline native-table fixture requires the qualified kernel configuration' >&2
  exit 1
fi
CONSTANT_UPLOADS_PROBE=${XNU_CONSTANT_UPLOADS_PROBE:-0}
if [ "$CONSTANT_UPLOADS_PROBE" != 0 ] && [ "$CONSTANT_UPLOADS_PROBE" != 1 ]; then
  echo 'XNU_CONSTANT_UPLOADS_PROBE must be 0 or 1' >&2
  exit 1
fi
if [ "$CONSTANT_UPLOADS_PROBE" = 1 ] && [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ]; then
  echo 'The offline constant upload fixture requires the qualified kernel configuration' >&2
  exit 1
fi
NATIVE_OFFLINE_GPU=${XNU_NATIVE_OFFLINE_GPU:-0}
if [ "$NATIVE_OFFLINE_GPU" != 0 ] && [ "$NATIVE_OFFLINE_GPU" != 1 ]; then
  echo 'XNU_NATIVE_OFFLINE_GPU must be 0 or 1' >&2
  exit 1
fi
if [ "$NATIVE_OFFLINE_GPU" = 1 ] && [ "$NATIVE_VIRTIO_CONSOLE" != 1 ]; then
  echo 'The private offline GPU broker requires the actual byte transport' >&2
  exit 1
fi
SHENG_PMGR=${XNU_SHENG_PMGR:-0}
if [ "$SHENG_PMGR" != 0 ] && [ "$SHENG_PMGR" != 1 ]; then
  echo 'XNU_SHENG_PMGR must be 0 or 1' >&2
  exit 1
fi
if [ "$SHENG_PMGR" = 1 ] && [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ]; then
  echo 'The sheng PMGR instrument requires the original-component kernel configuration' >&2
  exit 1
fi
SHENG_PMGR_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/.sheng-pmgr-mode
if [ "$(cat "$SHENG_PMGR_STAMP" 2>/dev/null || echo 0)" != "$SHENG_PMGR" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/bsd/DEVELOPMENT/bsd_init.o"
  printf '%s\n' "$SHENG_PMGR" > "$SHENG_PMGR_STAMP"
fi
EXTRA_MAKE_ARGS+=("bsd_init.o_CFLAGS_ADD=-DXNU_SHENG_PMGR=$SHENG_PMGR -DXNU_VERIFIED_ROOT_PROBE=$OWNER_ROOT_PROBE -DXNU_OWNER_ROOT_AUDIT=$OWNER_ROOT_AUDIT -DXNU_OWNER_ROOT_TRUST=$OWNER_ROOT_TRUST -DXNU_ADRENO_FIRMWARE_PROBE=$ADRENO_FIRMWARE_PROBE -DXNU_ADRENO_PM4_PROBE=$ADRENO_PM4_PROBE -DXNU_SMMU4K_PROBE=$SMMU4K_PROBE -DXNU_CONSTANT_UPLOADS_PROBE=$CONSTANT_UPLOADS_PROBE -DXNU_NATIVE_LEGACY_DISPLAY=${XNU_NATIVE_LEGACY_DISPLAY:-0} -DXNU_NATIVE_OFFLINE_GPU=$NATIVE_OFFLINE_GPU")
NATIVE_MOBILE_DISPLAY=${XNU_NATIVE_MOBILE_DISPLAY:-0}
if [ "$NATIVE_MOBILE_DISPLAY" != 0 ] && [ "$NATIVE_MOBILE_DISPLAY" != 1 ]; then
  echo 'XNU_NATIVE_MOBILE_DISPLAY must be 0 or 1' >&2
  exit 1
fi
NATIVE_LEGACY_DISPLAY=${XNU_NATIVE_LEGACY_DISPLAY:-0}
if [ "$NATIVE_LEGACY_DISPLAY" != 0 ] && [ "$NATIVE_LEGACY_DISPLAY" != 1 ]; then
  echo 'XNU_NATIVE_LEGACY_DISPLAY must be 0 or 1' >&2
  exit 1
fi
EXTRA_MAKE_ARGS+=("IOUserClient.cpo_CFLAGS_ADD=-DXNU_NATIVE_MOBILE_DISPLAY=$NATIVE_MOBILE_DISPLAY -DXNU_NATIVE_LEGACY_DISPLAY=$NATIVE_LEGACY_DISPLAY")
MOBILE_DISPLAY_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/.native-mobile-display-mode
if [ "$(cat "$MOBILE_DISPLAY_STAMP" 2>/dev/null || echo 0)" != "$NATIVE_MOBILE_DISPLAY:$NATIVE_LEGACY_DISPLAY" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/iokit/DEVELOPMENT/IOUserClient.cpo"
  printf '%s\n' "$NATIVE_MOBILE_DISPLAY:$NATIVE_LEGACY_DISPLAY" > "$MOBILE_DISPLAY_STAMP"
fi
OWNER_ROOT_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/.owner-root-probe-mode
if [ "$(cat "$OWNER_ROOT_STAMP" 2>/dev/null || echo 0:0:0:0:0:0)" != "$OWNER_ROOT_PROBE:$OWNER_ROOT_AUDIT:$OWNER_ROOT_TRUST:$ADRENO_FIRMWARE_PROBE:$ADRENO_PM4_PROBE:$SMMU4K_PROBE:$CONSTANT_UPLOADS_PROBE:$NATIVE_LEGACY_DISPLAY:$NATIVE_OFFLINE_GPU" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/bsd/DEVELOPMENT/bsd_init.o"
  printf '%s\n' "$OWNER_ROOT_PROBE:$OWNER_ROOT_AUDIT:$OWNER_ROOT_TRUST:$ADRENO_FIRMWARE_PROBE:$ADRENO_PM4_PROBE:$SMMU4K_PROBE:$CONSTANT_UPLOADS_PROBE:$NATIVE_LEGACY_DISPLAY:$NATIVE_OFFLINE_GPU" > "$OWNER_ROOT_STAMP"
fi
OWNER_CACHE_MOUNT=${XNU_OWNER_CACHE_MOUNT:-0}
if [ "$OWNER_CACHE_MOUNT" != 0 ] && [ "$OWNER_CACHE_MOUNT" != 1 ]; then
  echo 'XNU_OWNER_CACHE_MOUNT must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_CACHE_MOUNT" = 1 ] && [ "$OWNER_ROOT_TRUST" != 1 ] && [ "$PONG_APFS_DEBUG" != 1 ]; then
  echo 'The offline SystemOS mount requires real independent owner root enforcement' >&2
  exit 1
fi
OWNER_CACHE_STARTUP=${XNU_OWNER_CACHE_STARTUP:-0}
if [ "$OWNER_CACHE_STARTUP" != 0 ] && [ "$OWNER_CACHE_STARTUP" != 1 ]; then
  echo 'XNU_OWNER_CACHE_STARTUP must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_CACHE_STARTUP" = 1 ] && [ "$OWNER_CACHE_MOUNT" != 1 ]; then
  echo 'Owner dyld startup selection requires authenticated actual cache mounting' >&2
  exit 1
fi
OWNER_BOOT_MANIFEST=${XNU_OWNER_BOOT_MANIFEST:-0}
if [ "$OWNER_BOOT_MANIFEST" != 0 ] && [ "$OWNER_BOOT_MANIFEST" != 1 ]; then
  echo 'XNU_OWNER_BOOT_MANIFEST must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_BOOT_MANIFEST" = 1 ] && [ "$OWNER_CACHE_STARTUP" != 1 ]; then
  echo 'Owner boot metadata requires real authenticated owner root/cache startup' >&2
  exit 1
fi
EXTRA_MAKE_ARGS+=("IOKitBSDInit.cpo_CFLAGS_ADD=-DXNU_OWNER_BOOT_MANIFEST=$OWNER_BOOT_MANIFEST")
OWNER_MANIFEST_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/.owner-boot-manifest-mode
if [ "$(cat "$OWNER_MANIFEST_STAMP" 2>/dev/null || echo 0)" != "$OWNER_BOOT_MANIFEST" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/iokit/DEVELOPMENT/IOKitBSDInit.cpo"
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/bsd/DEVELOPMENT/kern_exec.o"
  printf '%s\n' "$OWNER_BOOT_MANIFEST" > "$OWNER_MANIFEST_STAMP"
fi
OWNER_DATA_MOUNT=${XNU_OWNER_DATA_MOUNT:-0}
OWNER_DATA_UFS=${XNU_OWNER_DATA_UFS:-0}
if [ "$OWNER_DATA_UFS" != 0 ] && [ "$OWNER_DATA_UFS" != 1 ]; then
  echo 'XNU_OWNER_DATA_UFS must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_DATA_UFS" = 1 ] && { [ "$NATIVE_RAM_BLOCK" != 0 ] || [ "${XNU_NATIVE_UFS:-0}" != 1 ] || [ "$OWNER_DATA_MOUNT" != 1 ]; }; then
  echo 'UFS Data requires NativeUfs, owner Data mount, and no NativeRamBlock' >&2
  exit 1
fi
if [ "$OWNER_DATA_MOUNT" != 0 ] && [ "$OWNER_DATA_MOUNT" != 1 ]; then
  echo 'XNU_OWNER_DATA_MOUNT must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_DATA_MOUNT" = 1 ] && [ "$OWNER_BOOT_MANIFEST" != 1 ]; then
  if [ "$PONG_APFS_DEBUG" != 1 ] || [ "$OWNER_CACHE_MOUNT" != 1 ] || { [ "$NATIVE_RAM_BLOCK" != 1 ] && [ "$OWNER_DATA_UFS" != 1 ]; } || {
    [ "${XNU_OWNER_UNION_SYSTEMOS:-0}" != 1 ] && [ "${XNU_OWNER_CRYPTEX_FILES:-0}" != 1 ];
  }; then
    echo 'Data requires Pong development root policy, a selected Data backend and mounted SystemOS startup' >&2
    exit 1
  fi
fi
OWNER_DATA_HEADER=$ROOT/build/xnu/owner-data-volume.h
python3 - "$OWNER_DATA_HEADER" "$OWNER_DATA_MOUNT" "$NATIVE_RAM_BLOCK" "${XNU_OWNER_DATA_VOLUME_UUID:-}" "${XNU_OWNER_CACHE_VOLUME_UUID:-}" <<'PY_DATA_UUID'
from pathlib import Path
import sys
import uuid
path = Path(sys.argv[1])
text = '/* Scratch Data IOKit selection disabled. */\n'
if sys.argv[2] == '1':
    try:
        value = str(uuid.UUID(sys.argv[4])).upper()
    except ValueError:
        raise SystemExit('Set XNU_OWNER_DATA_VOLUME_UUID to the actual observed scratch APFS volume UUID')
    text = '#define XNU_OWNER_DATA_VOLUME_UUID "' + value + '"\n'
try:
    cache = str(uuid.UUID(sys.argv[5])).upper()
except ValueError:
    raise SystemExit('Set XNU_OWNER_CACHE_VOLUME_UUID to the observed Pong SystemOS APFS UUID')
text += '#define XNU_OWNER_CACHE_VOLUME_UUID "' + cache + '"\n'
path.parent.mkdir(parents=True, exist_ok=True)
if not path.exists() or path.read_text() != text:
    path.write_text(text)
PY_DATA_UUID
OWNER_DATA_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/.owner-data-mount-mode
if [ "$(cat "$OWNER_DATA_STAMP" 2>/dev/null || echo 0)" != "$OWNER_DATA_MOUNT:$NATIVE_RAM_BLOCK:$OWNER_DATA_UFS:${XNU_OWNER_CACHE_VOLUME_UUID:-}" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/bsd/DEVELOPMENT/kern_exec.o"
  printf '%s\n' "$OWNER_DATA_MOUNT:$NATIVE_RAM_BLOCK:$OWNER_DATA_UFS:${XNU_OWNER_CACHE_VOLUME_UUID:-}" > "$OWNER_DATA_STAMP"
fi
OWNER_CRYPTEX_FILES=${XNU_OWNER_CRYPTEX_FILES:-0}
if [ "$OWNER_CRYPTEX_FILES" != 0 ] && [ "$OWNER_CRYPTEX_FILES" != 1 ]; then
  echo 'XNU_OWNER_CRYPTEX_FILES must be 0 or 1' >&2
  exit 1
fi
# Pong supplies an already mounted cache instead of an ignition-managed graft.
# dyld-1066.8 still calls ignite() after opening an override directory unless
# its commpage skipIgnition bit (0x8) is set by the owner startup hook.
if [ "$OWNER_CRYPTEX_FILES" = 1 ] && [ "$PONG_APFS_DEBUG" = 1 ] && [ "$OWNER_CACHE_STARTUP" != 1 ]; then
  echo 'Pong mounted Cryptex startup requires the dyld skipIgnition commpage flag' >&2
  exit 1
fi
OWNER_CRYPTEX_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/.owner-cryptex-files-mode
if [ "$(cat "$OWNER_CRYPTEX_STAMP" 2>/dev/null || echo 0)" != "$OWNER_CRYPTEX_FILES" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/bsd/DEVELOPMENT/kern_exec.o"
  printf '%s\n' "$OWNER_CRYPTEX_FILES" > "$OWNER_CRYPTEX_STAMP"
fi
OWNER_UNION_SYSTEMOS=${XNU_OWNER_UNION_SYSTEMOS:-0}
if [ "$OWNER_UNION_SYSTEMOS" != 0 ] && [ "$OWNER_UNION_SYSTEMOS" != 1 ]; then
  echo 'XNU_OWNER_UNION_SYSTEMOS must be 0 or 1' >&2
  exit 1
fi
if [ "$OWNER_UNION_SYSTEMOS" = 1 ] && { [ "$OWNER_CACHE_STARTUP" != 1 ] || [ "$OWNER_CRYPTEX_FILES" != 0 ]; }; then
  echo 'Owner union composition requires the owner startup path and no fallback-path experiment' >&2
  exit 1
fi
if [ "$PONG_APFS_DEBUG" = 1 ] && {
  [ "${XNU_NATIVE_UFS:-0}" != 1 ] || [ "$OWNER_CACHE_MOUNT" != 1 ] ||
  { [ "$OWNER_UNION_SYSTEMOS" != 1 ] && [ "$OWNER_CRYPTEX_FILES" != 1 ]; };
}; then
  echo 'Pong APFS debug handoff requires read-only UFS UUID binding and either SystemOS union or Cryptex files' >&2
  exit 1
fi
OWNER_UNION_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/.owner-union-systemos-mode
if [ "$(cat "$OWNER_UNION_STAMP" 2>/dev/null || echo 0)" != "$OWNER_UNION_SYSTEMOS" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/bsd/DEVELOPMENT/kern_exec.o"
  printf '%s\n' "$OWNER_UNION_SYSTEMOS" > "$OWNER_UNION_STAMP"
fi
NATIVE_AIR_INIT=${XNU_NATIVE_AIR_INIT:-0}
if [ "$NATIVE_AIR_INIT" != 0 ] && [ "$NATIVE_AIR_INIT" != 1 ]; then
  echo 'XNU_NATIVE_AIR_INIT must be 0 or 1' >&2
  exit 1
fi
if [ "$NATIVE_AIR_INIT" = 1 ] && { [ "$OWNER_CACHE_MOUNT" != 1 ] || [ "$OWNER_DATA_MOUNT" != 1 ] || [ "$OWNER_ROOT_TRUST" != 1 ]; }; then
  echo 'Offline AIR init requires the actual owner root, SystemOS and scratch Data path' >&2
  exit 1
fi
NATIVE_AIR_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/.native-air-init-mode
if [ "$(cat "$NATIVE_AIR_STAMP" 2>/dev/null || echo 0)" != "$NATIVE_AIR_INIT" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/bsd/DEVELOPMENT/kern_exec.o"
  printf '%s\n' "$NATIVE_AIR_INIT" > "$NATIVE_AIR_STAMP"
fi
EXTRA_MAKE_ARGS+=("kern_exec.o_CFLAGS_ADD=-DXNU_NATIVE_AIR_INIT=$NATIVE_AIR_INIT -DXNU_PONG_APFS_DEBUG=$PONG_APFS_DEBUG -DXNU_OWNER_CACHE_MOUNT=$OWNER_CACHE_MOUNT -DXNU_OWNER_CACHE_STARTUP=$OWNER_CACHE_STARTUP -DXNU_OWNER_BOOT_MANIFEST=$OWNER_BOOT_MANIFEST -DXNU_OWNER_DATA_MOUNT=$OWNER_DATA_MOUNT -DXNU_OWNER_DATA_UFS=$OWNER_DATA_UFS -DXNU_NATIVE_RAM_BLOCK=$NATIVE_RAM_BLOCK -DXNU_OWNER_CRYPTEX_FILES=$OWNER_CRYPTEX_FILES -DXNU_OWNER_UNION_SYSTEMOS=$OWNER_UNION_SYSTEMOS -include $OWNER_DATA_HEADER")
OWNER_CACHE_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/.owner-cache-mount-mode
if [ "$(cat "$OWNER_CACHE_STAMP" 2>/dev/null || echo 0:0:0)" != "$OWNER_CACHE_MOUNT:$OWNER_CACHE_STARTUP:$PONG_APFS_DEBUG" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/bsd/DEVELOPMENT/kern_exec.o"
  printf '%s\n' "$OWNER_CACHE_MOUNT:$OWNER_CACHE_STARTUP:$PONG_APFS_DEBUG" > "$OWNER_CACHE_STAMP"
fi
OWNER_CACHE_CARRIER=${XNU_OWNER_CACHE_CARRIER:-0}
OWNER_CACHE_CARRIER_WRONG_UUID=${XNU_OWNER_CACHE_CARRIER_WRONG_UUID:-0}
if { [ "$OWNER_CACHE_CARRIER" != 0 ] && [ "$OWNER_CACHE_CARRIER" != 1 ]; } ||
   { [ "$OWNER_CACHE_CARRIER_WRONG_UUID" != 0 ] && [ "$OWNER_CACHE_CARRIER_WRONG_UUID" != 1 ]; }; then
  echo 'Owner cache carrier selectors must be 0 or 1' >&2
  exit 1
fi
if { [ "$OWNER_CACHE_CARRIER" = 1 ] && [ "$OWNER_CACHE_STARTUP" != 1 ]; } ||
   { [ "$OWNER_CACHE_CARRIER_WRONG_UUID" = 1 ] && [ "$OWNER_CACHE_CARRIER" != 1 ]; }; then
  echo 'Owner carrier policy requires authenticated owner startup; wrong UUID is an isolated negative control' >&2
  exit 1
fi
EXTRA_MAKE_ARGS+=("vm_unix.o_CFLAGS_ADD=-DXNU_OWNER_CACHE_MOUNT=$OWNER_CACHE_MOUNT -DXNU_OWNER_CACHE_CARRIER=$OWNER_CACHE_CARRIER -DXNU_OWNER_CACHE_CARRIER_WRONG_UUID=$OWNER_CACHE_CARRIER_WRONG_UUID")
OWNER_CARRIER_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/.owner-cache-carrier-mode
if [ "$(cat "$OWNER_CARRIER_STAMP" 2>/dev/null || echo 0:0)" != "$OWNER_CACHE_CARRIER:$OWNER_CACHE_CARRIER_WRONG_UUID" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/bsd/DEVELOPMENT/vm_unix.o"
  printf '%s\n' "$OWNER_CACHE_CARRIER:$OWNER_CACHE_CARRIER_WRONG_UUID" > "$OWNER_CARRIER_STAMP"
fi
DT_PANIC_REGION=${XNU_DT_PANIC_REGION:-0}
PONG_VOLATILE_PANIC_LOG=${XNU_PONG_VOLATILE_PANIC_LOG:-0}
if [ "$DT_PANIC_REGION" != 0 ] && [ "$DT_PANIC_REGION" != 1 ]; then
  echo 'XNU_DT_PANIC_REGION must be 0 or 1' >&2
  exit 1
fi
if [ "$PONG_VOLATILE_PANIC_LOG" != 0 ] && [ "$PONG_VOLATILE_PANIC_LOG" != 1 ]; then
  echo 'XNU_PONG_VOLATILE_PANIC_LOG must be 0 or 1' >&2
  exit 1
fi
DT_PANIC_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/.dt-panic-region-mode
if [ "$(cat "$DT_PANIC_STAMP" 2>/dev/null || echo 0:0)" != "$DT_PANIC_REGION:$PONG_VOLATILE_PANIC_LOG" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/pexpert/DEVELOPMENT/pe_init.o"
  printf '%s\n' "$DT_PANIC_REGION:$PONG_VOLATILE_PANIC_LOG" > "$DT_PANIC_STAMP"
fi
ZONE_PGZ_PROBE=${XNU_ZONE_PGZ_ALIGNMENT_PROBE:-0}
if [ "$ZONE_PGZ_PROBE" != 0 ] && [ "$ZONE_PGZ_PROBE" != 1 ]; then
  echo 'XNU_ZONE_PGZ_ALIGNMENT_PROBE must be 0 or 1' >&2
  exit 1
fi
EXTRA_MAKE_ARGS+=("zalloc.o_CFLAGS_ADD=-DXNU_ZONE_PGZ_ALIGNMENT_PROBE=$ZONE_PGZ_PROBE")
ZONE_PGZ_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/.zone-pgz-probe-mode
if [ "$(cat "$ZONE_PGZ_STAMP" 2>/dev/null || echo 0)" != "$ZONE_PGZ_PROBE" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/osfmk/DEVELOPMENT/zalloc.o"
  printf '%s\n' "$ZONE_PGZ_PROBE" > "$ZONE_PGZ_STAMP"
fi
NATIVE_ARCH_TIMER=${XNU_NATIVE_ARCH_TIMER:-${XNU_ARMCPU:-0}}
if [ "$NATIVE_ARCH_TIMER" != 0 ] && [ "$NATIVE_ARCH_TIMER" != 1 ]; then
  echo 'XNU_NATIVE_ARCH_TIMER must be 0 or 1' >&2
  exit 1
fi
if [ "$NATIVE_ARCH_TIMER" = 1 ] && [ "${XNU_ARMCPU:-0}" != 1 ]; then
  echo 'Architectural timer entry requires the actual ArmCpu interrupt provider' >&2
  exit 1
fi
PONG_EARLY_TRACE=${XNU_PONG_EARLY_TRACE:-0}
if [ "$PONG_EARLY_TRACE" != 0 ] && [ "$PONG_EARLY_TRACE" != 1 ]; then
  echo 'XNU_PONG_EARLY_TRACE must be 0 or 1' >&2
  exit 1
fi
PONG_RAMOOPS_CONSOLE=${XNU_PONG_RAMOOPS_CONSOLE:-0}
if [ "$PONG_RAMOOPS_CONSOLE" != 0 ] && [ "$PONG_RAMOOPS_CONSOLE" != 1 ]; then
  echo 'XNU_PONG_RAMOOPS_CONSOLE must be 0 or 1' >&2
  exit 1
fi
# The minimal ramoops mirror is independent of the removed framebuffer and
# exception-vector tracing hooks.
EXTRA_MAKE_ARGS+=("start.o_SFLAGS_ADD=-DXNU_NATIVE_ARCH_TIMER=$NATIVE_ARCH_TIMER -DXNU_PONG_EARLY_TRACE=$PONG_EARLY_TRACE")
EXTRA_MAKE_ARGS+=("arm_init.o_CFLAGS_ADD=-DXNU_PONG_EARLY_TRACE=$PONG_EARLY_TRACE -DXNU_PONG_RAMOOPS_CONSOLE=$PONG_RAMOOPS_CONSOLE -mstrict-align -mgeneral-regs-only -march=armv8.1-a")
EXTRA_MAKE_ARGS+=("arm_vm_init.o_CFLAGS_ADD=-DXNU_PONG_EARLY_TRACE=$PONG_EARLY_TRACE")
EXTRA_MAKE_ARGS+=("machine_routines.o_CFLAGS_ADD=-DXNU_PONG_EARLY_TRACE=$PONG_EARLY_TRACE")
EXTRA_MAKE_ARGS+=("serial_console.o_CFLAGS_ADD=-DXNU_PONG_EARLY_TRACE=$PONG_EARLY_TRACE -DXNU_PONG_RAMOOPS_CONSOLE=$PONG_RAMOOPS_CONSOLE")
EXTRA_MAKE_ARGS+=("debug.o_CFLAGS_ADD=-DXNU_PONG_EARLY_TRACE=$PONG_EARLY_TRACE")
EXTRA_MAKE_ARGS+=("counter_test.o_CFLAGS_ADD=-DXNU_PONG_EARLY_TRACE=$PONG_EARLY_TRACE")
EXTRA_MAKE_ARGS+=("IOStartIOKit.cpo_CFLAGS_ADD=-DXNU_PONG_EARLY_TRACE=$PONG_EARLY_TRACE")
EXTRA_MAKE_ARGS+=("OSRuntime.cpo_CFLAGS_ADD=-DXNU_PONG_EARLY_TRACE=$PONG_EARLY_TRACE")
EXTRA_MAKE_ARGS+=("pe_init.o_CFLAGS_ADD=-DXNU_DT_PANIC_REGION=$DT_PANIC_REGION -DXNU_PONG_VOLATILE_PANIC_LOG=$PONG_VOLATILE_PANIC_LOG -DXNU_PONG_EARLY_TRACE=$PONG_EARLY_TRACE")
python3 - "$PONG_EARLY_TRACE" "$PONG_RAMOOPS_CONSOLE" <<'PY_TRACE_MODE'
from pathlib import Path
import sys
directory = Path('build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG')
stamp = directory / '.pong-early-trace-mode'
mode = sys.argv[1] + ':' + sys.argv[2] + ':minimal-ramoops-v1'
if not stamp.exists() or stamp.read_text() != mode:
    for name in ('start', 'arm_init', 'arm_vm_init', 'machine_routines', 'startup', 'serial_console', 'debug'):
        (directory / 'osfmk/DEVELOPMENT' / (name + '.o')).unlink(missing_ok=True)
    (directory / 'bsd/DEVELOPMENT/counter_test.o').unlink(missing_ok=True)
    (directory / 'iokit/DEVELOPMENT/IOStartIOKit.cpo').unlink(missing_ok=True)
    (directory / 'libkern/DEVELOPMENT/OSRuntime.cpo').unlink(missing_ok=True)
    (directory / 'pexpert/DEVELOPMENT/pe_init.o').unlink(missing_ok=True)
    stamp.write_text(mode)
PY_TRACE_MODE
NATIVE_TIMER_STAMP=$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/.native-arch-timer-mode
if [ "$(cat "$NATIVE_TIMER_STAMP" 2>/dev/null || echo 0)" != "$NATIVE_ARCH_TIMER" ]; then
  rm -f "$ROOT/build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/osfmk/DEVELOPMENT/start.o"
  printf '%s\n' "$NATIVE_ARCH_TIMER" > "$NATIVE_TIMER_STAMP"
fi
NATIVE_PAN=${XNU_NATIVE_PAN:-0}
if [ "$NATIVE_PAN" != 0 ] && [ "$NATIVE_PAN" != 1 ]; then
  echo 'XNU_NATIVE_PAN must be 0 or 1' >&2
  exit 1
fi
PONG_LEGACY_UACCESS=${XNU_PONG_LEGACY_UACCESS:-0}
if [ "$PONG_LEGACY_UACCESS" != 0 ] && [ "$PONG_LEGACY_UACCESS" != 1 ]; then
  echo 'XNU_PONG_LEGACY_UACCESS must be 0 or 1' >&2
  exit 1
fi
EXTRA_CFLAGS="$EXTRA_CFLAGS -DXNU_NATIVE_PAN=$NATIVE_PAN -DXNU_PONG_LEGACY_UACCESS=$PONG_LEGACY_UACCESS"
if [ "$NATIVE_PAN" = 1 ]; then
  EXTRA_MAKE_ARGS+=("copyio.o_CFLAGS_ADD=-march=armv8.1-a")
  EXTRA_MAKE_ARGS+=("pcb.o_CFLAGS_ADD=-march=armv8.1-a")
  EXTRA_MAKE_ARGS+=("platform_tests.o_CFLAGS_ADD=-march=armv8.1-a")
else
  EXTRA_MAKE_ARGS+=("copyio.o_CFLAGS_ADD=")
  EXTRA_MAKE_ARGS+=("pcb.o_CFLAGS_ADD=")
  EXTRA_MAKE_ARGS+=("platform_tests.o_CFLAGS_ADD=")
fi
if [ "${XNU_SOURCE_CORECRYPTO14:-0}" = 1 ]; then
  CRYPTO_ARCHIVE=$ROOT/build/corecrypto-2023/libcorecrypto_kernel_noasm-namespaced.a
  test -f "$CRYPTO_ARCHIVE"
  EXTRA_CFLAGS="$EXTRA_CFLAGS -DXNU_SOURCE_CORECRYPTO14=1"
  KERNEL_EXTRA_ARCHIVES="-L$KERNEL_SDKROOT/usr/local/lib/kernel -lfirehose_kernel $CRYPTO_ARCHIVE"
  KERNEL_ARCHIVE_DEPENDENCIES=$CRYPTO_ARCHIVE
  if [ "$ADRENO_FIRMWARE_PROBE" = 1 ]; then
    ADRENO_PROBE_ARCHIVE=$ROOT/build/adreno-firmware-probe/libAdrenoFirmwareProbe.a
    test -f "$ADRENO_PROBE_ARCHIVE"
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$ADRENO_PROBE_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $ADRENO_PROBE_ARCHIVE"
  fi
  if [ "$ADRENO_PM4_PROBE" = 1 ]; then
    PM4_PROBE_ARCHIVE=$ROOT/build/adreno-pm4-probe/libAdrenoPM4Probe.a
    test -f "$PM4_PROBE_ARCHIVE"
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$PM4_PROBE_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $PM4_PROBE_ARCHIVE"
  fi
  if [ "$SMMU4K_PROBE" = 1 ]; then
    SMMU4K_PROBE_ARCHIVE=$ROOT/build/smmu4k-probe/libArmSmmu4KProbe.a
    test -f "$SMMU4K_PROBE_ARCHIVE"
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$SMMU4K_PROBE_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $SMMU4K_PROBE_ARCHIVE"
  fi
  if [ "$CONSTANT_UPLOADS_PROBE" = 1 ]; then
    CONSTANT_UPLOADS_ARCHIVE=$ROOT/build/constant-uploads-probe/libConstantUploadsProbe.a
    test -f "$CONSTANT_UPLOADS_ARCHIVE"
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$CONSTANT_UPLOADS_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $CONSTANT_UPLOADS_ARCHIVE"
  fi
  if [ "${XNU_ARMVIRT_PLATFORM:-0}" = 1 ]; then
    ARMVIRT_ARCHIVE=$ROOT/build/armvirt-platform/libArmVirtPlatform.a
    test -f "$ARMVIRT_ARCHIVE"
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$ARMVIRT_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $ARMVIRT_ARCHIVE"
  fi
  if [ "$ARM_DT_PLATFORM" = 1 ]; then
    ARM_DT_ARCHIVE=$ROOT/build/armdt-platform/libArmDTPlatform.a
    test -f "$ARM_DT_ARCHIVE"
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$ARM_DT_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $ARM_DT_ARCHIVE"
  fi
  if [ "${XNU_ARMCPU:-0}" = 1 ]; then
    ARMCPU_ARCHIVE=$ROOT/build/armcpu/libArmCpu.a
    test -f "$ARMCPU_ARCHIVE"
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$ARMCPU_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $ARMCPU_ARCHIVE"
  fi
  if [ "${XNU_NATIVE_UFS:-0}" = 1 ]; then
    UFS_ARCHIVE=$ROOT/build/native-ufs/libNativeUfs.a
    test -f "$UFS_ARCHIVE"
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$UFS_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $UFS_ARCHIVE"
  fi
  if [ "${XNU_NATIVE_ADRENO:-0}" = 1 ]; then
    # NativeAdreno plus its kits (scripts/build-native-adreno-kits.py). No personality is installed: the
    # board probe calls NativeAdrenoGmuContextBringup directly once it has powered the GPU CX domain.
    ADRENO_ARCHIVE=$ROOT/build/native-adreno/libNativeAdreno.a
    test -f "$ADRENO_ARCHIVE"
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$ADRENO_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $ADRENO_ARCHIVE"
  fi
  if [ "$NATIVE_MOBILE_DISPLAY" = 1 ]; then
    MOBILE_DISPLAY_ARCHIVE=$ROOT/build/native-mobile-display/libNativeMobileDisplay.late.a
    test -f "$MOBILE_DISPLAY_ARCHIVE"
    python3 - "$MOBILE_DISPLAY_ARCHIVE" <<'PY_MOBILE_DISPLAY'
import hashlib, json, sys
from pathlib import Path
archive = Path(sys.argv[1])
report = json.loads(archive.with_name('build-report.json').read_text())
if hashlib.sha256(archive.read_bytes()).hexdigest() != report['archive_sha256']:
    raise SystemExit('Rebuild and qualify the exact own display archive before linking')
PY_MOBILE_DISPLAY
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$MOBILE_DISPLAY_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $MOBILE_DISPLAY_ARCHIVE"
  fi
  if [ "$NATIVE_LEGACY_DISPLAY" = 1 ]; then
    LEGACY_DISPLAY_ARCHIVE=$ROOT/build/native-legacy-display/libNativeLegacyDisplay.late.a
    test -f "$LEGACY_DISPLAY_ARCHIVE"
    python3 - "$LEGACY_DISPLAY_ARCHIVE" "$ROOT" <<'PY_LEGACY_DISPLAY'
import hashlib, json, sys
from pathlib import Path
archive=Path(sys.argv[1]);root=Path(sys.argv[2]);report=json.loads(archive.with_name('build-report.json').read_text())
if hashlib.sha256(archive.read_bytes()).hexdigest()!=report['archive_sha256']:
    raise SystemExit('Rebuild and qualify the exact owned Legacy archive before linking')
for name,digest in report['source_sha256'].items():
    if hashlib.sha256((root/name).read_bytes()).hexdigest()!=digest:
        raise SystemExit('Rebuild the owned Legacy archive after changing '+name)
PY_LEGACY_DISPLAY
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$LEGACY_DISPLAY_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $LEGACY_DISPLAY_ARCHIVE"
  fi
  if [ "${XNU_NATIVE_AES:-0}" = 1 ]; then
    AES_ARCHIVE=${XNU_NATIVE_AES_ARCHIVE:-$ROOT/build/native-aes/libNativeAES.a}
    test -f "$AES_ARCHIVE"
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$AES_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $AES_ARCHIVE"
  fi
  if [ "${XNU_NATIVE_VIRTIO_BLOCK:-0}" = 1 ]; then
    VIRTIO_ARCHIVE=${XNU_NATIVE_VIRTIO_BLOCK_ARCHIVE:-$ROOT/build/native-virtio-block/libNativeVirtioBlock.a}
    test -f "$VIRTIO_ARCHIVE"
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$VIRTIO_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $VIRTIO_ARCHIVE"
  fi
  if [ "$NATIVE_OFFLINE_GPU" = 1 ]; then
    GPU_BROKER_ARCHIVE=$ROOT/build/native-offline-gpu/libNativeOfflineGPU.late.a
    test -f "$GPU_BROKER_ARCHIVE"
    python3 - "$GPU_BROKER_ARCHIVE" "$ROOT" <<'PY_GPU_BROKER'
import hashlib,json,sys
from pathlib import Path
archive=Path(sys.argv[1]);root=Path(sys.argv[2]);report=json.loads(archive.with_name('build-report.json').read_text())
if hashlib.sha256(archive.read_bytes()).hexdigest()!=report['archive_sha256']:
    raise SystemExit('Rebuild the exact private GPU broker archive')
for name,digest in report['source_sha256'].items():
    if hashlib.sha256((root/name).read_bytes()).hexdigest()!=digest:
        raise SystemExit('Rebuild the GPU broker after changing '+name)
if hashlib.sha256((root/'build/native-virtio-console/libNativeVirtioConsole.a').read_bytes()).hexdigest()!=report['console_archive_sha256']:
    raise SystemExit('Rebuild the GPU broker against the actual byte-transport archive')
PY_GPU_BROKER
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$GPU_BROKER_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $GPU_BROKER_ARCHIVE"
  fi
  if [ "$NATIVE_VIRTIO_CONSOLE" = 1 ]; then
    CONSOLE_ARCHIVE=$ROOT/build/native-virtio-console/libNativeVirtioConsole.a
    test -f "$CONSOLE_ARCHIVE"
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$CONSOLE_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $CONSOLE_ARCHIVE"
  fi
  if [ "$NATIVE_RAM_BLOCK" = 1 ]; then
    RAM_BLOCK_ARCHIVE=$ROOT/build/native-ram-block/libNativeRamBlock.a
    test -f "$RAM_BLOCK_ARCHIVE"
    if [ "${XNU_NATIVE_UFS:-0}" = 1 ]; then
      # NativeUfs already carries these exact IOBlockStorageDevice aliases.
      # Link the RAM class object once, avoiding duplicate alias definitions.
      python3 - "$ROOT/mac-build/native-ufs/bindings.json" "$ROOT/build/native-ram-block/build-report.json" <<'PY_BINDINGS'
import json, sys
from pathlib import Path
ufs, ram = [json.loads(Path(p).read_text()) for p in sys.argv[1:]]
if any(ufs['bindings'].get(name) != value for name, value in ram['bindings'].items()):
    raise SystemExit('RAM transport imports differ from Pong NativeUfs storage bindings')
PY_BINDINGS
      RAM_BLOCK_OBJECT=$ROOT/build/native-ram-block/NativeRamBlock.o
      test -f "$RAM_BLOCK_OBJECT"
      KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES $RAM_BLOCK_OBJECT"
    else
      KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$RAM_BLOCK_ARCHIVE"
    fi
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $RAM_BLOCK_ARCHIVE"
  fi
  if [ "${XNU_SOURCE_PTHREAD:-0}" = 1 ]; then
    PTHREAD_ARCHIVE=$ROOT/build/libpthread-kernel/libpthread_kernel.a
    PTHREAD_BOOTSTRAP=$ROOT/build/libpthread-kernel/source_pthread_bootstrap.o
    test -f "$PTHREAD_ARCHIVE"
    test -f "$PTHREAD_BOOTSTRAP"
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$PTHREAD_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $PTHREAD_ARCHIVE"
  fi
  if [ "$OWNER_ROOT_PROBE" = 1 ]; then
    VERIFIED_ROOT_ARCHIVE=${XNU_VERIFIED_ROOT_ARCHIVE:-$ROOT/build/verified-root-xnu/libVerifiedRootProbe.a}
    test -f "$VERIFIED_ROOT_ARCHIVE"
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$VERIFIED_ROOT_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $VERIFIED_ROOT_ARCHIVE"
  fi
  if [ "$MOCKFS_MODE" = 1 ]; then
    MOCKFS_ARCHIVE=$ROOT/build/mockfs-fixture/libmockfs_fixture.a
    test -f "$MOCKFS_ARCHIVE"
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$MOCKFS_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $MOCKFS_ARCHIVE"
  fi
  if [ "$SHENG_PMGR" = 1 ]; then
    PMGR_ARCHIVE=$ROOT/build/sheng-platform-power/libShengPlatformPower.a
    test -f "$PMGR_ARCHIVE"
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$PMGR_ARCHIVE"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $PMGR_ARCHIVE"
  fi
  # Optional extra link inputs (e.g. a stub for an unselected offline probe hook).
  if [ "$BOOT_PROGRESS" = 1 ]; then
    KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES -Wl,-force_load,$ROOT/build/boot-progress/libBootProgress.a"
    KERNEL_ARCHIVE_DEPENDENCIES="$KERNEL_ARCHIVE_DEPENDENCIES $ROOT/build/boot-progress/libBootProgress.a"
  fi
  KERNEL_EXTRA_ARCHIVES="$KERNEL_EXTRA_ARCHIVES ${XNU_EXTRA_LD_ARCHIVES:-}"
  EXTRA_MAKE_ARGS+=("LD_KERNEL_ARCHIVES=$KERNEL_EXTRA_ARCHIVES")
  EXTRA_MAKE_ARGS+=("XNU_EXTERNAL_KERNEL_ARCHIVES=$KERNEL_ARCHIVE_DEPENDENCIES")
fi
# The generic platform is independent of the old source-corecrypto14 recipe.
# Its crypto provider comes from the separately prelinked 20G81 component.
PONG_ADRENO_PLATFORM=${XNU_PONG_ADRENO_PLATFORM:-0}
if [ "$PONG_ADRENO_PLATFORM" != 0 ] && [ "$PONG_ADRENO_PLATFORM" != 1 ]; then
  echo 'XNU_PONG_ADRENO_PLATFORM must be 0 or 1' >&2
  exit 1
fi
if [ "$PONG_ADRENO_PLATFORM" = 1 ]; then
  if [ "$ARM_DT_PLATFORM" != 1 ] || [ "${XNU_SOURCE_CORECRYPTO14:-0}" = 1 ]; then
    echo 'Pong Adreno support requires the native Pong DT profile' >&2
    exit 1
  fi
  # Complete SM8475 GMU/CP/IRQ/native-client/Metal provider. Its real
  # IOAcceleratorES initializer runs only after20G81 IOGPUFamily loads.
  # Keep foreign A740/Redwood hardware owners disabled independently.
  PONG_DRIVER_SOURCE=${PONG_NATIVE_DRIVER_SOURCE:-$ROOT}
  PONG_ADRENO_ARGS=(--output-dir "$ROOT/build/pong-adreno" --tree "$ROOT")
  if [ -n "${DEVELOPER_DIR:-}" ]; then
    PONG_ADRENO_ARGS+=(--developer-dir "$DEVELOPER_DIR")
  fi
  if [ -n "${PONG_ADRENO_FIRMWARE_DIR:-}" ]; then
    PONG_ADRENO_ARGS+=(--firmware-dir "$PONG_ADRENO_FIRMWARE_DIR")
  fi
  python3 "$PONG_DRIVER_SOURCE/scripts/build-pong-adreno-platform.py" "${PONG_ADRENO_ARGS[@]}"
fi
if [ "$ARM_DT_PLATFORM" = 1 ] && [ "${XNU_SOURCE_CORECRYPTO14:-0}" != 1 ]; then
  ARM_DT_ARCHIVE=$ROOT/build/armdt-platform/libArmDTPlatform.a
  test -f "$ARM_DT_ARCHIVE"
  PLATFORM_ARCHIVES="-L$KERNEL_SDKROOT/usr/local/lib/kernel -lfirehose_kernel -Wl,-force_load,$ARM_DT_ARCHIVE"
  PLATFORM_DEPENDENCIES=$ARM_DT_ARCHIVE
  if [ "$PONG_ADRENO_PLATFORM" = 1 ]; then
    PONG_GPU_ARCHIVE=$ROOT/build/pong-adreno/libPongAdrenoPlatform.a
    test -f "$PONG_GPU_ARCHIVE"
    PLATFORM_ARCHIVES="$PLATFORM_ARCHIVES -Wl,-force_load,$PONG_GPU_ARCHIVE -Wl,-u,_PongAdrenoGmuStart"
    PLATFORM_DEPENDENCIES="$PLATFORM_DEPENDENCIES $PONG_GPU_ARCHIVE"
  fi
  if [ "${XNU_ARMCPU:-0}" = 1 ]; then
    ARMCPU_ARCHIVE=$ROOT/build/armcpu/libArmCpu.a
    test -f "$ARMCPU_ARCHIVE"
    PLATFORM_ARCHIVES="$PLATFORM_ARCHIVES -Wl,-force_load,$ARMCPU_ARCHIVE"
    PLATFORM_DEPENDENCIES="$PLATFORM_DEPENDENCIES $ARMCPU_ARCHIVE"
  fi
  if [ "${XNU_NATIVE_UFS:-0}" = 1 ]; then
    UFS_ARCHIVE=$ROOT/build/native-ufs/libNativeUfs.a
    test -f "$UFS_ARCHIVE"
    PLATFORM_ARCHIVES="$PLATFORM_ARCHIVES -Wl,-force_load,$UFS_ARCHIVE"
    PLATFORM_DEPENDENCIES="$PLATFORM_DEPENDENCIES $UFS_ARCHIVE"
  fi
  if [ "$NATIVE_RAM_BLOCK" = 1 ]; then
    RAM_BLOCK_ARCHIVE=$ROOT/build/native-ram-block/libNativeRamBlock.a
    RAM_BLOCK_OBJECT=$ROOT/build/native-ram-block/NativeRamBlock.o
    test -f "$RAM_BLOCK_ARCHIVE" -a -f "$RAM_BLOCK_OBJECT"
    if [ "${XNU_NATIVE_UFS:-0}" = 1 ]; then
      python3 - "$ROOT/build/native-ufs/bindings.json" "$ROOT/build/native-ram-block/build-report.json" <<'PY_RAM_BLOCK_BINDINGS'
import json, sys
from pathlib import Path
ufs, ram = [json.loads(Path(p).read_text()) for p in sys.argv[1:]]
if any(ufs['bindings'].get(name) != value for name, value in ram['bindings'].items()):
    raise SystemExit('RAM transport imports differ from Pong NativeUfs storage bindings')
PY_RAM_BLOCK_BINDINGS
      PLATFORM_ARCHIVES="$PLATFORM_ARCHIVES $RAM_BLOCK_OBJECT"
    else
      PLATFORM_ARCHIVES="$PLATFORM_ARCHIVES -Wl,-force_load,$RAM_BLOCK_ARCHIVE"
    fi
    PLATFORM_DEPENDENCIES="$PLATFORM_DEPENDENCIES $RAM_BLOCK_ARCHIVE"
  fi
  EXTRA_MAKE_ARGS+=("LD_KERNEL_ARCHIVES=$PLATFORM_ARCHIVES")
  EXTRA_MAKE_ARGS+=("XNU_EXTERNAL_KERNEL_ARCHIVES=$PLATFORM_DEPENDENCIES")
fi
python3 - "${XNU_NATIVE_AES:-0}" "${XNU_NATIVE_AES_ARCHIVE:-$ROOT/build/native-aes/libNativeAES.a}" \
  "${XNU_NATIVE_VIRTIO_BLOCK:-0}" "${XNU_NATIVE_VIRTIO_BLOCK_ARCHIVE:-$ROOT/build/native-virtio-block/libNativeVirtioBlock.a}" \
  "$OWNER_ROOT_PROBE" "${XNU_VERIFIED_ROOT_ARCHIVE:-$ROOT/build/verified-root-xnu/libVerifiedRootProbe.a}" \
  "$NATIVE_RAM_BLOCK" "$ROOT/build/native-ram-block/libNativeRamBlock.a" \
  "$ADRENO_FIRMWARE_PROBE" "$ROOT/build/adreno-firmware-probe/libAdrenoFirmwareProbe.a" \
  "$ADRENO_PM4_PROBE" "$ROOT/build/adreno-pm4-probe/libAdrenoPM4Probe.a" \
  "$SMMU4K_PROBE" "$ROOT/build/smmu4k-probe/libArmSmmu4KProbe.a" \
  "$CONSTANT_UPLOADS_PROBE" "$ROOT/build/constant-uploads-probe/libConstantUploadsProbe.a" \
  "$NATIVE_VIRTIO_CONSOLE" "$ROOT/build/native-virtio-console/libNativeVirtioConsole.a" \
  "$NATIVE_OFFLINE_GPU" "$ROOT/build/native-offline-gpu/libNativeOfflineGPU.late.a" \
  "$SHENG_PMGR" "$ROOT/build/sheng-platform-power/libShengPlatformPower.a" \
  "${XNU_NATIVE_UFS:-0}" "$ROOT/build/native-ufs/libNativeUfs.a" \
  "${XNU_NATIVE_ADRENO:-0}" "$ROOT/build/native-adreno/libNativeAdreno.a" \
  "$PONG_ADRENO_PLATFORM" "$ROOT/build/pong-adreno/libPongAdrenoPlatform.a" <<'PY'
from pathlib import Path
import sys
directory = Path('build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG')
stamp = directory / '.native-aes-link-input'
identity = '|'.join(mode + ':' + (str(Path(archive).stat().st_mtime_ns) if mode == '1' else 'disabled')
                    for mode, archive in zip(sys.argv[1::2], sys.argv[2::2]))
if not stamp.exists() or stamp.read_text() != identity:
    # Make does not track selection of an older alternative external archive.
    # Rebuild the conditional personality and relink when this input changes.
    for relative in ('mach.development.pong.unstripped.noctf',
                     'iokit/DEVELOPMENT/KernelConfigTables.cpo'):
        (directory / relative).unlink(missing_ok=True)
    directory.mkdir(parents=True, exist_ok=True)
    stamp.write_text(identity)
PY
EXTRA_CFLAGS="$EXTRA_CFLAGS -DXNU_BOOT_PROGRESS=$BOOT_PROGRESS"
# XNU 8796 consumes RC_NONARCH_CFLAGS through OTHER_CFLAGS in both CFLAGS
# and SFLAGS. CFLAGS_EXTRA is not read by its makefiles: passing that name
# silently omitted PAN/uaccess policy from C, C++ and assembly alike.
python3 - "$EXTRA_CFLAGS" <<'PY_GLOBAL_FLAGS'
from pathlib import Path
import json
import sys
directory = Path('build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG')
directory.mkdir(parents=True, exist_ok=True)
stamp = directory / '.pong-global-compiler-flags'
identity = 'RC_NONARCH_CFLAGS-v1\n' + sys.argv[1] + '\n'
if not stamp.exists() or stamp.read_text() != identity:
    # Make tracks source/header timestamps, not changes to command-line flags.
    # Recompile every kernel component so saved PSTATE, SCTLR and copyio agree.
    for pattern in ('*.o', '*.cpo'):
        for path in directory.rglob(pattern):
            path.unlink()
    for path in directory.glob('mach.development.pong*'):
        if path.is_file():
            path.unlink()
    stamp.write_text(identity)
(directory / 'pong-global-compiler-flags.json').write_text(json.dumps({
    'make_variable': 'RC_NONARCH_CFLAGS',
    'consumers': ['CFLAGS_GEN', 'SFLAGS_GEN'],
    'value': sys.argv[1],
}, indent=2) + '\n')
PY_GLOBAL_FLAGS
python3 - "${EXTRA_MAKE_ARGS[@]}" <<'PY_OBJECT_FLAGS'
import sys
seen = set()
for argument in sys.argv[1:]:
    key = argument.split('=', 1)[0]
    if key.endswith(('_CFLAGS_ADD', '_SFLAGS_ADD')):
        if key in seen:
            raise SystemExit('Conflicting per-object flag assignments: ' + key)
        seen.add(key)
PY_OBJECT_FLAGS
make -C .cache/xnu-work "${XNU_BUILD_TARGET:-build}" SDKROOT="${XNU_SDKROOT:-iphoneos}" ARCH_CONFIGS=ARM64 \
  MACHINE_CONFIGS=PONG KERNEL_CONFIGS=DEVELOPMENT \
  ARCH_STRING_FOR_CURRENT_MACHINE_CONFIG=arm64 LARGE_MEMORY_DEFINE=-UARM_LARGE_MEMORY \
  ARM64_LINK_ADDR=0xfffffff007004000 ARM64_PLKSEG_ADDR=0xfffffff004004000 \
  DEPLOYMENT_TARGET_FLAGS="-miphoneos-version-min=${UNIXNU_IOS_TARGET:-16.0} -DXNU_TARGET_OS_IOS" \
  DEPLOYMENT_LINKER_FLAGS="-Wl,-ios_version_min,${UNIXNU_IOS_TARGET:-16.0}" \
  RC_DARWIN_KERNEL_VERSION="$XNU_DARWIN" RC_ProjectSourceVersion="$XNU_VERSION" \
  BUILD_LTO=0 BOUND_CHECKS=0 BUILD_WERROR="${XNU_BUILD_WERROR:-0}" MAKEJOBS=-j"${JOBS:-4}" \
  RC_NONARCH_CFLAGS="$EXTRA_CFLAGS" "${EXTRA_MAKE_ARGS[@]}" \
  OBJROOT="$ROOT/build/xnu/ios-obj" SYMROOT="$ROOT/build/xnu/ios-sym" DSTROOT="$ROOT/build/xnu/ios-dst"
if [ "${XNU_SOURCE_CORECRYPTO14:-0}" = 1 ] && [ "$CRYPTO_BOOTSTRAP_MODE" = source ]; then
  python3 scripts/seal-source-crypto-kernel.py \
    build/xnu/ios-obj/DEVELOPMENT_ARM64_PONG/mach.development.pong.unstripped.noctf
fi
