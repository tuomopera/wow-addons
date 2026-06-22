#!/usr/bin/env bash
# Build GankList.zip from the GankList/ folder, ready to attach to a GitHub release.
# After changing the addon: bump ## Version in the toc, run this, then upload the
# zip to a new release (the README's download link always points at the latest one).
set -e
cd "$(dirname "$0")"
rm -f GankList.zip
python3 -c "import shutil; shutil.make_archive('GankList','zip','.','GankList')"
echo "Rebuilt GankList.zip:"
python3 -c "import zipfile; print('\n'.join('  '+n for n in zipfile.ZipFile('GankList.zip').namelist()))"
