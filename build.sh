#!/usr/bin/env bash
# Build GankList.zip with ONLY the files WoW loads (toc + lua), under a GankList/
# folder so it extracts straight into AddOns. Docs/build files stay out of the zip.
# After changing the addon: bump ## Version in the toc, run this, then upload the
# zip to a new release (the README's download link always points at the latest one).
set -e
cd "$(dirname "$0")"
rm -f GankList.zip
python3 - <<'PY'
import zipfile
files = ["GankList/GankList.toc", "GankList/GankList.lua"]
with zipfile.ZipFile("GankList.zip", "w", zipfile.ZIP_DEFLATED) as z:
    for f in files:
        z.write(f)
print("Built GankList.zip:")
for n in zipfile.ZipFile("GankList.zip").namelist():
    print("  " + n)
PY
