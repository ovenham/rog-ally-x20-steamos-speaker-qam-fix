#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Builds the Decky plugin and packages it as out/x20-fixes.zip, ready for Decky's
# "Install plugin from ZIP file". Needs Node.js 18+ and Python 3.
set -eu
cd "$(dirname "$0")"

(cd plugin && npm ci --no-audit --no-fund && npm run build)

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
p=$stage/x20-fixes
mkdir -p "$p/dist" "$p/py_modules" "$p/fix"
cp plugin/dist/index.js "$p/dist/"
cp plugin/main.py plugin/plugin.json plugin/package.json "$p/"
cp plugin/py_modules/*.py "$p/py_modules/"
cp speaker-fix/ally-audio-fix.sh "$p/fix/"
cp -r speaker-fix/ucm speaker-fix/patches speaker-fix/prebuilt "$p/fix/"
cp README.md LICENSE "$p/"
cp -r LICENSES "$p/"

mkdir -p out
rm -f out/x20-fixes.zip
python3 -I - "$stage" out/x20-fixes.zip <<'PY'
import os, sys, zipfile
base, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(base):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(root, name)
            info = zipfile.ZipInfo.from_file(path, os.path.relpath(path, base))
            info.external_attr = (0o755 if name.endswith(".sh") else 0o644) << 16
            with open(path, "rb") as f:
                z.writestr(info, f.read(), zipfile.ZIP_DEFLATED)
PY
echo "built out/x20-fixes.zip"
