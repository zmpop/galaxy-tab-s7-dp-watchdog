#!/usr/bin/env python3
"""Build the flashable Magisk zip for tab-dp-watchdog.

    python3 tools/build.py            -> dist/tab-dp-watchdog-v<version>.zip

ARCHIVE LAYOUT (this is the part that used to be wrong)
------------------------------------------------------
A Magisk/KernelSU module zip must have module.prop, service.sh and
META-INF/com/google/android/update-binary at the ARCHIVE ROOT:

    module.prop
    service.sh
    screenvid.sh
    META-INF/com/google/android/update-binary
    META-INF/com/google/android/updater-script

The earlier build wrote everything under a "tab-dp-watchdog/" prefix, so after
unpacking, the manager looked for ./module.prop, found only a directory, and
answered "Unable to extract zip file" - for every zip, including the official
v1.4.0, which made it look like a broken magisk CLI. It was the archive layout.

Other guarantees kept from the previous build:
  * CRLF -> LF for every text entry (a Windows checkout otherwise ships
    "/system/bin/sh^M: bad interpreter" and nothing runs on the device).
  * version comes from module.prop, so the filename can never drift.
  * unix mode bits are stored explicitly: 0755 for scripts, 0644 for data.
"""
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'tab-dp-watchdog')
DIST = os.path.join(ROOT, 'dist')
BINARY_EXT = ('.png', '.jpg', '.jpeg', '.webp', '.gz', '.zip')

# files that must be executable on device
EXEC_NAMES = ('update-binary',)

REQUIRED = (
    'module.prop',
    'service.sh',
    'META-INF/com/google/android/update-binary',
    'META-INF/com/google/android/updater-script',
)


def module_version():
    with open(os.path.join(SRC, 'module.prop'), encoding='utf-8') as f:
        for line in f:
            m = re.match(r'^version=(.+)$', line.strip())
            if m:
                return m.group(1).strip()
    raise SystemExit('module.prop: no version= line')


def is_exec(arc):
    # web/cgi-bin/* are extension-less CGI scripts: busybox httpd needs them
    # executable, and the mode must already be right inside the archive so the
    # Web UI works even if the manager never runs customize.sh.
    return (arc.endswith('.sh')
            or arc.startswith('web/cgi-bin/')
            or os.path.basename(arc) in EXEC_NAMES)


def main():
    ver = module_version()

    missing = [r for r in REQUIRED if not os.path.isfile(os.path.join(SRC, r))]
    if missing:
        raise SystemExit('missing required module files: %s' % ', '.join(missing))

    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, 'tab-dp-watchdog-%s.zip' % ver)

    entries = []
    for dirpath, dirnames, filenames in os.walk(SRC):
        dirnames.sort()
        for fn in sorted(filenames):
            p = os.path.join(dirpath, fn)
            # relative to SRC -> archive root, NOT relative to ROOT
            arc = os.path.relpath(p, SRC).replace(os.sep, '/')
            entries.append((p, arc))

    crlf_fixed = []
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for p, arc in entries:
            with open(p, 'rb') as f:
                data = f.read()
            if not arc.lower().endswith(BINARY_EXT) and b'\r\n' in data:
                crlf_fixed.append(arc)
                data = data.replace(b'\r\n', b'\n')
            zi = zipfile.ZipInfo(arc, date_time=(2026, 1, 1, 0, 0, 0))
            zi.create_system = 3                      # unix -> attr honoured
            zi.external_attr = (0o755 if is_exec(arc) else 0o644) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)

    # ---- verify the archive really is flashable -------------------------
    with zipfile.ZipFile(out) as z:
        names = z.namelist()
        if 'module.prop' not in names:
            raise SystemExit('build produced an archive without a root module.prop')
        for r in REQUIRED:
            if r not in names:
                raise SystemExit('build produced an archive without %s' % r)
        if any(n.startswith('tab-dp-watchdog/') for n in names):
            raise SystemExit('build leaked a directory prefix into the archive')
        mode = z.getinfo('META-INF/com/google/android/update-binary').external_attr >> 16
        if not mode & 0o111:
            raise SystemExit('update-binary is not executable inside the archive')
        # module.prop must parse from inside the zip, the way the installer does it
        prop = z.read('module.prop').decode('utf-8', 'replace')
        if 'id=tab_dp_watchdog' not in prop:
            raise SystemExit('module.prop inside the archive has no id=tab_dp_watchdog')

    print('built %s (%d files, %d bytes)' % (out, len(entries), os.path.getsize(out)))
    print('layout: root module.prop + META-INF/com/google/android/update-binary (0755)')
    if crlf_fixed:
        print('normalised CRLF -> LF in:')
        for a in crlf_fixed:
            print('  ' + a)
    return 0


if __name__ == '__main__':
    sys.exit(main())
