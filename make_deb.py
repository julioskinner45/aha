#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_deb.py — AHA 移动端 .deb 打包（纯 Python 标准库，零依赖，本机直接出包）

产出 out/aha_0.1.0_iphoneos-arm64.deb，payload：
    var/jb/Library/MobileSubstrate/DynamicLibraries/AHA.dylib   (arm64 Mach-O)
    var/jb/Library/MobileSubstrate/DynamicLibraries/AHA.plist   (注入过滤)
    var/jb/share/aha/aha-panel.html                             (面板，Filza 打开即用)

dylib 来源二选一：
    默认      —— 本机合成「结构完整的 arm64 stub」（可安装、签名工具可识别，
                但不含业务逻辑；装上后插件名显示 AHA，面板文件照常可用）
    --dylib x —— 传入真编译产物（cloud-build GitHub Actions 产出 AHA.dylib），
                打出的包就是完整功能版

用法：
    python make_deb.py                       # stub 包
    python make_deb.py --dylib AHA.dylib     # 真功能包
    python make_deb.py --inspect some.deb    # 解析任意 deb 结构
"""
import io
import gzip
import math
import os
import struct
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out')
# 面板来源两种布局都认：本项目 deb/../panel 与 GitHub 仓库根 panel/
_panel_candidates = [os.path.join(HERE, 'panel', 'aha-panel.html'),
                     os.path.join(HERE, '..', 'panel', 'aha-panel.html')]
PANEL = next((p for p in _panel_candidates if os.path.exists(p)), _panel_candidates[1])

# ---- Mach-O 常量 ----
MH_MAGIC_64 = 0xfeedfacf
CPU_TYPE_ARM64 = 0x0100000c
MH_DYLIB = 6
MH_NOUNDEFS, MH_DYLDLINK, MH_TWOLEVEL = 0x1, 0x4, 0x80
LC_SEGMENT_64, LC_SYMTAB, LC_DYSYMTAB = 0x19, 0x2, 0xb
LC_ID_DYLIB, LC_LOAD_DYLINKER, LC_UUID = 0xd, 0xe, 0x1b
LC_SOURCE_VERSION, LC_BUILD_VERSION = 0x2a, 0x32
S_ATTR_PURE_INSTRUCTIONS = 0x80000000
S_ATTR_SOME_INSTRUCTIONS = 0x00000400

DYLIB_NAME = 'AHA.dylib'
PLIST_NAME = 'AHA.plist'
PKG_VER = '0.5.47'


def pad8(b):
    return b + b'\0' * ((8 - len(b) % 8) % 8)


def seg_cmd(name, vmaddr, vmsize, fileoff, filesize, maxprot, initprot, sections):
    body = struct.pack('<II16sQQQQiiII',
                       LC_SEGMENT_64, 72 + 80 * len(sections),
                       name.encode().ljust(16, b'\0'),
                       vmaddr, vmsize, fileoff, filesize,
                       maxprot, initprot, len(sections), 0)
    for s in sections:
        body += struct.pack('<16s16sQQIIIIIIII',
                            s['sectname'].encode().ljust(16, b'\0'),
                            s['segname'].encode().ljust(16, b'\0'),
                            s['addr'], s['size'], s['offset'], s['align'],
                            0, 0, s['flags'], 0, 0, 0)
    return body


def build_stub():
    """合成结构自洽的 arm64 dylib stub（__TEXT ret + __LINKEDIT symtab）"""
    text_section = dict(sectname='__text', segname='__TEXT',
                        addr=0x1000, size=4, offset=0x1000, align=2,
                        flags=S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS)
    cmds = [
        seg_cmd('__TEXT', 0, 0x4000, 0, 0x4000, 5, 5, [text_section]),
        seg_cmd('__LINKEDIT', 0x4000, 0x4000, 0x4000, 0x1000, 1, 1, []),
    ]
    name = b'@rpath/AHA.dylib\0'
    cmds.append(struct.pack('<IIIIII', LC_ID_DYLIB, 24 + len(pad8(name)),
                            24, 2, 0x10000, 0x10000) + pad8(name))
    dl = b'/usr/lib/dyld\0'
    dl = dl + b'\0' * ((8 - (12 + len(dl)) % 8) % 8)
    cmds.append(struct.pack('<III', LC_LOAD_DYLINKER, 12 + len(dl), 12) + dl)
    cmds.append(struct.pack('<II', LC_UUID, 24) + b'AHAStub000000001')  # 16 B
    cmds.append(struct.pack('<IIIIII', LC_BUILD_VERSION, 24, 2,
                            0x000E0000, 0x000E0000, 0))
    cmds.append(struct.pack('<IIIIII', LC_SYMTAB, 24, 0x4000, 1, 0x4010, 16))
    cmds.append(struct.pack('<II' + 'I' * 18, LC_DYSYMTAB, 80, *([0] * 18)))
    cmds.append(struct.pack('<IIQ', LC_SOURCE_VERSION, 16, 0x00010000))

    cmd_blob = b''.join(cmds)
    header = struct.pack('<IiiIIIII', MH_MAGIC_64, CPU_TYPE_ARM64, 0,
                         MH_DYLIB, len(cmds), len(cmd_blob),
                         MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL, 0)
    assert len(header) + len(cmd_blob) <= 0x1000

    text = bytearray(0x4000)
    text[:len(header)] = header
    text[len(header):len(header) + len(cmd_blob)] = cmd_blob
    text[0x1000:0x1004] = bytes.fromhex('c0035fd6')  # arm64 ret
    linkedit = bytearray(0x1000)
    linkedit[0:16] = struct.pack('<IBBHQ', 1, 0x0f, 1, 0, 0x1000)
    linkedit[0x10:0x20] = b'\0_AHAStub\0'.ljust(16, b'\0')
    return bytes(text) + bytes(linkedit)


def verify_macho(b):
    magic, cpu, sub, ftype, ncmds, szcmds, flags, _ = struct.unpack('<IiiIIIII', b[:32])
    assert magic == MH_MAGIC_64 and cpu == CPU_TYPE_ARM64 and ftype == MH_DYLIB
    assert b[0x1000:0x1004] == bytes.fromhex('c0035fd6')
    off, seen = 32, []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack('<II', b[off:off + 8])
        assert cmdsize % 8 == 0 and cmdsize >= 8
        seen.append(cmd)
        off += cmdsize
    assert off == 32 + szcmds
    return len(b), ncmds, seen


# ---- ar / tar / deb 组装（与参考包逐字节同构）----
DEFAULT_HDRS = [
    b'debian-binary   ' + b'0           ' + b'0     ' + b'0     ' + b'100644  ' + b'0         ' + b'`\n',
    b'control.tar.gz  ' + b'0           ' + b'0     ' + b'0     ' + b'100644  ' + b'0         ' + b'`\n',
    b'data.tar.gz     ' + b'0           ' + b'0     ' + b'0     ' + b'100644  ' + b'0         ' + b'`\n',
]


def gz(data):
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode='wb', compresslevel=9, mtime=0) as f:
        f.write(data)
    return buf.getvalue()


def make_tar(entries):
    bio = io.BytesIO()
    with tarfile.open(fileobj=bio, mode='w', format=tarfile.USTAR_FORMAT) as t:
        for name, data, mode, is_dir in entries:
            ti = tarfile.TarInfo(name)
            ti.uid, ti.gid = 0, 0
            ti.uname, ti.gname = 'root', 'root'
            ti.mtime = 0
            ti.mode = mode
            if is_dir:
                ti.type = tarfile.DIRTYPE
                t.addfile(ti)
            else:
                ti.size = len(data)
                t.addfile(ti, io.BytesIO(data))
    return gz(bio.getvalue())


def dir_entries(root_prefix):
    parts = root_prefix.split('/')
    out = [('.', b'', 0o755, True)]
    cur = ''
    for p in parts:
        cur = (cur + '/' + p) if cur else p
        out.append((cur, b'', 0o755, True))
    return out


def build_deb(dylib_bytes, plist_bytes, panel_bytes, control_text):
    ctl = control_text.rstrip('\n')
    size_kb = math.ceil((len(dylib_bytes) + len(plist_bytes) + len(panel_bytes or b'')) / 1024)
    lines = [l for l in ctl.split('\n') if not l.startswith('Installed-Size:')]
    lines.append('Installed-Size: %d' % size_kb)
    ctl_bytes = ('\n'.join(lines) + '\n').encode('utf-8')

    DL = 'var/jb/Library/MobileSubstrate/DynamicLibraries'
    SH = 'var/jb/share/aha'
    data_items = (dir_entries('var/jb/Library/MobileSubstrate/DynamicLibraries')
        + [(DL + '/' + DYLIB_NAME, dylib_bytes, 0o755, False),
           (DL + '/' + PLIST_NAME, plist_bytes, 0o644, False)])
    if panel_bytes:
        data_items += dir_entries('var/jb/share/aha') +             [(SH + '/aha-panel.html', panel_bytes, 0o644, False)]
    data_tar = make_tar(data_items)
    control_tar = make_tar([('.', b'', 0o755, True), ('./control', ctl_bytes, 0o644, False)])

    payloads = [b'2.0\n', control_tar, data_tar]
    buf = io.BytesIO()
    buf.write(b'!<arch>\n')
    for hdr, data in zip(DEFAULT_HDRS, payloads):
        h = bytearray(hdr)
        h[48:58] = ('%-10d' % len(data)).encode('ascii')
        buf.write(bytes(h))
        buf.write(data)
        if len(data) % 2:
            buf.write(b'\n')
    return buf.getvalue()


def ar_members(path):
    b = open(path, 'rb').read()
    assert b[:8] == b'!<arch>\n', 'not an ar archive'
    pos, out = 8, []
    while pos + 60 <= len(b):
        hdr = b[pos:pos + 60]
        size = int(hdr[48:58].decode('ascii', 'replace').strip() or '0')
        out.append((hdr, b[pos + 60:pos + 60 + size]))
        pos += 60 + size + (size % 2)
    return out


def inspect(path):
    print('=== %s ===' % os.path.basename(path))
    for hdr, data in ar_members(path):
        name = hdr[0:16].decode('ascii', 'replace').strip()
        print('  member %-16s size=%d' % (name, len(data)))
        if name.startswith(('control', 'data')):
            with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as t:
                for m in t.getmembers():
                    if m.isfile():
                        print('    [%s] %-64s %d B' % (
                            'control' if name.startswith('control') else 'data',
                            m.name, m.size))
                        if m.name.endswith('.dylib'):
                            head = t.extractfile(m).read(4)
                            tag = ('Mach-O 64' if head == bytes.fromhex('cffaedfe') or
                                   head == bytes.fromhex('feedfacf') else 'NOT Mach-O!')
                            print('         -> %s magic=%s' % (tag, head.hex()))
    print()


def main():
    args = sys.argv[1:]
    if '--inspect' in args:
        for p in args[args.index('--inspect') + 1:]:
            inspect(p)
        return

    dylib_path = None
    if '--dylib' in args:
        dylib_path = args[args.index('--dylib') + 1]

    if dylib_path:
        dylib = open(dylib_path, 'rb').read()
        assert dylib[:4].hex() in ('cafebabe', 'bebafeca', 'cffaedfe', 'feedfacf'), \
            'not a Mach-O: %s' % dylib[:4].hex()
        print('[+] real compiled dylib: %s (%d B)' % (dylib_path, len(dylib)))
    else:
        dylib = build_stub()
        size, ncmds, _ = verify_macho(dylib)
        print('[+] synthesized arm64 stub OK: %d B, %d load commands' % (size, ncmds))
        print('    (stub = installable structure only; use --dylib from cloud-build for logic)')

    plist = open(os.path.join(HERE, 'tweak', PLIST_NAME), 'rb').read()
    panel = open(PANEL, 'rb').read() if PANEL and os.path.exists(PANEL) else None
    ctl = open(os.path.join(HERE, 'tweak', 'control'), encoding='utf-8').read()
    blob = build_deb(dylib, plist, panel, ctl)

    os.makedirs(OUT, exist_ok=True)
    dest = os.path.join(OUT, 'aha_%s_iphoneos-arm64.deb' % PKG_VER)
    open(dest, 'wb').write(blob)
    print('[+] %s  %d B' % (dest, len(blob)))
    print()
    inspect(dest)


if __name__ == '__main__':
    main()
