#!/bin/sh
# Dump what cannot be rebuilt from data/ to the NAS: the live transit
# history (schema live) and the app's own tables (schema app). The rest
# comes back from sync.py, load_db.py and load_gtfs.py. Keeps the last
# 7 dumps; run nightly by com.sofia.backup.plist.
set -e
cd "$(dirname "$0")/.."
# launchd's PATH has no Homebrew, and its postgresql@NN is keg-only.
PATH="$(ls -d /opt/homebrew/opt/postgresql@*/bin 2>/dev/null | tail -n 1):$PATH"
dir=data/_backups
mkdir -p "$dir"
f="$dir/urbandata-$(date +%Y-%m-%d).dump"
# Written under another name first, so that a failed dump never looks
# like a good one.
pg_dump -Fc -n live -n app -d urbandata -f "$f.part"
mv "$f.part" "$f"
ls -t "$dir"/urbandata-*.dump | tail -n +8 | while read -r old; do rm -- "$old"; done
echo "$(date '+%F %T') $f $(du -h "$f" | cut -f1)"
