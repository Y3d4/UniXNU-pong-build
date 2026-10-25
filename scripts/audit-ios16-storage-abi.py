#!/usr/bin/env python3
"""Derive Darwin 22 IOBlockStorageDevice bindings from the genuine 20G81 image.
The public reference object annotates the ABI and is never linked or executed.
"""
import hashlib, json, os, re, shutil, struct, subprocess, sys
import argparse
from pathlib import Path
DEVICE = Path(__file__).resolve().parents[1]
ROOT = DEVICE.parent
sys.path.insert(0, str(DEVICE / 'kits/NativePrelink'))
import native_prelink as np
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True,
                    help='Darwin 22 IOStorageFamily checkout at the audited revision')
parser.add_argument('--candidate', type=Path, required=True,
                    help='corecrypto candidate emitted from the bootstrap Pong kernel')
parser.add_argument('--framework', type=Path, required=True,
                    help='Kernel.framework fakeroot produced by the bootstrap build')
parser.add_argument('--developer-dir', type=Path, default=None)
parser.add_argument('--output-dir', type=Path, default=DEVICE / 'mac-build/storage-abi')
args = parser.parse_args()
source = args.source.resolve()
revision = subprocess.check_output(['git', '-C', source, 'rev-parse', 'HEAD'],text=True).strip()
if revision != '609cbbdf9fa8fd5eae973d9135c7d44b47e6502e':
    raise SystemExit('Unexpected Darwin 22 storage reference source')
out = args.output_dir.resolve()
out.mkdir(parents=True, exist_ok=True)
headers = out / 'include/IOKit/storage'
headers.mkdir(parents=True, exist_ok=True)
for path in source.glob('*.h'):
    shutil.copyfile(path, headers / path.name)
obj_path = out / 'reference.o'
env = dict(os.environ)
if args.developer_dir:
    env['DEVELOPER_DIR'] = str(args.developer_dir.resolve())
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True, env=env).strip()
macsdk = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True, env=env).strip())
shutil.copyfile(macsdk / 'usr/include/TargetConditionals.h', out / 'include/TargetConditionals.h')
framework = args.framework.resolve()
command = ['xcrun', '--sdk', 'iphoneos', 'clang++', '-target', 'arm64-apple-ios16.0',
    '-isysroot', sdk, '-mkernel', '-ffreestanding', '-fno-builtin', '-fno-exceptions',
    '-fno-rtti', '-std=gnu++17', '-fblocks', '-O2', '-g',
    '-DKERNEL=1', '-DKERNEL_PRIVATE=1', '-DXNU_KERNEL_PRIVATE=1',
    '-I' + str(out / 'include'), '-I' + str(framework / 'PrivateHeaders'),
    '-I' + str(framework / 'Headers'), '-Wno-deprecated-declarations',
    '-Wno-c99-designator', '-c', str(source / 'IOBlockStorageDevice.cpp'), '-o', str(obj_path)]
(out / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
subprocess.run(command, check=True, env=env)

def require(value, message):
    if not value:
        raise SystemExit(message)


obj = obj_path.read_bytes()
om = np.macho(obj)
require(om['kind'] == 1, 'Expected an ordinary ARM64 reference object')
dwarf = subprocess.check_output(['xcrun', 'dwarfdump', '--name=IOBlockStorageDevice', '--show-children', obj_path], text=True)
class_size = re.search(r'DW_AT_name\s+\("IOBlockStorageDevice"\)[\s\S]{0,200}?DW_AT_byte_size\s+\((0x[0-9a-f]+)\)', dwarf)
require(class_size and int(class_size[1], 16) == 0x90, 'Actual compiled public class size changed')
version_command = next(at for command, at, size in om['commands'] if command == 0x32)
require(struct.unpack_from('<II', obj, version_command + 8) == (2, 0x100000), 'Expected iOS 16 reference deployment')
sycmd = next(at for command, at, size in om['commands'] if command == 2)
symoff, count, stroff, _ = struct.unpack_from('<4I', obj, sycmd + 8)
symbols = []
for i in range(count):
    ix, kind, _, _, value = struct.unpack_from('<IBBHQ', obj, symoff + i * 16)
    symbols.append(dict(name=obj[stroff + ix:obj.index(b'\0', stroff + ix)].decode(), value=value, kind=kind))
vtable = next(s['value'] for s in symbols if s['name'] == '__ZTV20IOBlockStorageDevice')
end = min(s['value'] for s in symbols if not s['kind'] & 0xe0 and s['kind'] & 0xe == 0xe and s['value'] > vtable)
relocations = {}
for segment in om['segments']:
    for section in segment['sections']:
        if section['va'] <= vtable < section['va'] + section['size']:
            ro, rc = struct.unpack_from('<II', obj, section['command_offset'] + 56)
            for i in range(rc):
                address, word = struct.unpack_from('<II', obj, ro + i * 8)
                if word >> 27 & 1 and word >> 28 == 0 and word >> 25 & 3 == 3:
                    relocations[section['va'] + address] = symbols[word & 0xffffff]['name']
methods = []
for at in range(vtable + 16, end, 8):
    if at not in relocations:
        break
    methods.append(relocations[at])
require(len(methods) == 190 and methods.count('___cxa_pure_virtual') == 14, 'Public iOS class dispatch shape changed')
kernel_path = args.candidate.resolve()
kernel = kernel_path.read_bytes()
plan = json.loads((kernel_path.parent / 'prelink.json').read_text())
require(hashlib.sha256(kernel).hexdigest() == plan['candidate_sha256'] and
        plan['original_sha256'] == 'd260defcc2eaac258fd3a2234454dda46791dae45e97608c5416f9ba8fd366e9', 'Unexpected original candidate provenance')
native = np.macho(kernel)
exports = np.exports(kernel, native)
by_name = {name: va for va, names in exports.items() for name in names}
extents = [e for e in plan['extents'] if e['module'] == 'com.apple.iokit.IOStorageFamily']
const = next(e for e in extents if e['segment'] == '__DATA_CONST')
text = next(e for e in extents if e['segment'] == '__TEXT_EXEC')


def read(va, length):
    at = np.backed_offset(native['segments'], va, length, len(kernel))
    return kernel[at:at + length]


require(hashlib.sha256(read(text['va'], text['size'])).hexdigest() ==
        plan['original_executable_sha256']['com.apple.iokit.IOStorageFamily'], 'Original storage executable code changed')
blob = read(const['va'], const['size'])
found = []
for at in range(0, len(blob) - (len(methods) + 2) * 8 + 1, 8):
    if blob[at:at + 16] != bytes(16):
        continue
    pointers = struct.unpack_from('<' + 'Q' * len(methods), blob, at + 16)
    if all(pointers[i] == by_name[name] for i, name in enumerate(methods) if name in by_name):
        found.append((const['va'] + at, pointers))
require(len(found) == 1, 'Cannot uniquely identify the original block-storage class dispatch')
table, pointers = found[0]
matched = sum(name in by_name for name in methods)
require(matched == 176, 'Unexpected original/native kernel binding count')
for i, name in enumerate(methods):
    if name not in by_name:
        require(text['va'] <= pointers[i] < text['va'] + text['size'], 'Owned storage method outside original text')


def relative_branch(address, instruction):
    immediate = instruction & 0x3ffffff
    if immediate & 0x2000000:
        immediate -= 0x4000000
    return address + immediate * 4


def thunk_names(address):
    a, load, branch = struct.unpack('<3I', read(address, 12))
    require(a & 0x9f00001f == 0x90000010 and load & 0xffc003ff == 0xf9400210 and branch == 0xd61f0200,
            'Unqualified original native import thunk')
    immediate = ((a >> 5 & 0x7ffff) << 2) | (a >> 29 & 3)
    if immediate & 0x100000:
        immediate -= 0x200000
    slot = (address & ~4095) + immediate * 4096 + (load >> 10 & 4095) * 8
    target = struct.unpack('<Q', read(slot, 8))[0]
    return exports.get(target, [])


constructors = []
for address in range(text['va'], text['va'] + text['size'] - 32, 4):
    words = struct.unpack('<8I', read(address, 32))
    if (words[:2] != (0xa9bf7bfd, 0x910003fd) or words[2] & 0xfc000000 != 0x94000000 or
        words[3] & 0x9f00001f != 0x90000008 or words[4] & 0xffc003ff != 0x91000108 or
        words[5:] != (0xf9000008, 0xa8c17bfd, 0xd65f03c0)):
        continue
    immediate = ((words[3] >> 5 & 0x7ffff) << 2) | (words[3] >> 29 & 3)
    if immediate & 0x100000:
        immediate -= 0x200000
    stored = ((address + 12) & ~4095) + immediate * 4096 + (words[4] >> 10 & 4095)
    if stored == table + 16:
        constructors.append((address, relative_branch(address + 8, words[2])))
require(len(constructors) == 1 and '__ZN9IOServiceC2EPK11OSMetaClass' in thunk_names(constructors[0][1]),
        'Original protected block constructor does not forward to actual source IOService')
destructor = pointers[0] - 4
word = struct.unpack('<I', read(destructor, 4))[0]
require(word & 0xfc000000 == 0x14000000 and
        '__ZN9IOServiceD2Ev' in thunk_names(relative_branch(destructor, word)), 'Unqualified actual base destructor')
require(all(read(pointers[i], 4) == struct.pack('<I', 0xd4200020) for i in (0, 1)),
        'Unexpected original abstract complete-destructor behavior')
function = pointers[7]
a, add, ret = struct.unpack('<3I', read(function, 12))
require(a & 0x9f00001f == 0x90000000 and add & 0xffc003ff == 0x91000000 and ret == 0xd65f03c0,
        'Unqualified original storage metaclass getter')
immediate = ((a >> 5 & 0x7ffff) << 2) | (a >> 29 & 3)
if immediate & 0x100000:
    immediate -= 0x200000
meta = (function & ~4095) + immediate * 4096 + (add >> 10 & 4095)

# Fixed coalesced placement makes data symbols usable at static kernel link time.
# The packager rechecks every bound address after emitting the actual candidate.
coalesced_base = min(s['va'] for s in native['segments'] if s['name'].startswith('__PRELINK') and s['size'])
fixed_base = 0xfffffff00b000000
adjustment = fixed_base - coalesced_base
possible = {name: pointers[i] + adjustment for i,name in enumerate(methods)
            if name not in by_name and name != '___cxa_pure_virtual'}
possible.update({'__ZN20IOBlockStorageDeviceC2EPK11OSMetaClass': constructors[0][0] + adjustment,
                '__ZN20IOBlockStorageDeviceD2Ev': destructor + adjustment,
                '__ZN20IOBlockStorageDevice10gMetaClassE': meta + adjustment,
                '__ZTV20IOBlockStorageDevice': table + adjustment})
result = dict(public_source_revision=revision, reference_object_sha256=hashlib.sha256(obj).hexdigest(),
              reference_object_executed_or_linked=False, candidate_sha256=plan['candidate_sha256'],
              original_executable_code_unchanged=True, method_slots=len(methods), kernel_bindings=matched,
              pure_virtual_slots=methods.count('___cxa_pure_virtual'), compiled_public_class_size=int(class_size[1],16),
              fixed_prelink_base=hex(fixed_base),
              bindings={k:hex(v) for k,v in possible.items()},
              methods=[dict(slot=i, reference_name=name, kernel_names=exports.get(pointers[i],[])) for i,name in enumerate(methods)],
              actual_io_qualified=False, runtime_metadata_qualified=False)
(out / 'interface-audit.json').write_text(json.dumps(result,indent=2)+'\n')
print('PASS: original iOS 16 storage vtable, constructor, base destructor and metaclass getter; '+str(len(methods))+' slots')
