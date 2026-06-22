#!/usr/bin/env bash
# Rebuild GankList.zip (the one-click download) from the GankList/ folder.
# Run this after changing the addon, then commit the updated zip.
set -e
cd "$(dirname "$0")"
rm -f GankList.zip
python3 -c "import shutil; shutil.make_archive('GankList','zip','.','GankList')"
echo "Rebuilt GankList.zip:"
python3 -c "import zipfile; print('\n'.join('  '+n for n in zipfile.ZipFile('GankList.zip').namelist()))"
