#!/usr/bin/env python3
"""Build the flashable Magisk zip for tab-dp-watchdog.

    python3 tools/build.py            -> dist/tab-dp-watchdog-v<version>.zip

Why a script: Windows checkouts (core.autocrlf=true) hand you CRLF files, and a
CRLF shell script does not run on Android ("/system/bin/sh^M: bad interpreter").
Everything except binary assets is therefore normalised to LF on the way into
the archive, and the module version is read from module.prop so the filename can
never drift from the metadata.
"""
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'tab-dp-watchdog')
DIST = os.path.join(ROOT, 'dist')
BINARY_EXT = ('.png', '.jpg', '.jpeg', '.webp', '.gz', '.zip')

EXEC = ('.sh',)


def module_version():
    with open(os.path.join(SRC, 'module.prop'), encoding='utf-8') as f:
        for line in f:
            m = re.match(r'^version=(.+)$', line.strip())
            if m:
                return m.group(1).strip()
    raise SystemExit('module.prop: no version= line')


def main():
    ver = module_version()
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, 'tab-dp-watchdog-%s.zip' % ver)

    entries = []
    for dirpath, dirnames, filenames in os.walk(SRC):
        dirnames.sort()
        for fn in sorted(filenames):
            p = os.path.join(dirpath, fn)
            arc = os.path.relpath(p, ROOT).replace(os.sep, '/')
            entries.append((p, arc))

    crlf_fixed = []
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for p, arc in entries:
            with open(p, 'rb') as f:
                data = f.read()
            if not arc.lower().endswith(BINARY_EXT):
                if b'\r\n' in data:
                    crlf_fixed.append(arc)
                    data = data.replace(b'\r\n', b'\n')
            zi = zipfile.ZipInfo(arc, date_time=(2026, 1, 1, 0, 0, 0))
            zi.create_system = 3                       # unix -> attr honoured
            zi.external_attr = (0o755 if arc.endswith(EXEC) else 0o644) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)

    print('built %s (%d files, %d bytes)' % (out, len(entries), os.path.getsize(out)))
    if crlf_fixed:
        print('normalised CRLF -> LF in:')
        for a in crlf_fixed:
            print('  ' + a)
    return 0


if __name__ == '__main__':
    sys.exit(main())
