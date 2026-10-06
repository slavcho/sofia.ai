#!/bin/sh
# Bring the Mac mini to the latest main: pull, install new requirements
# and restart the web app. The poller picks up the new code on its next
# run. Changes under db/ are not applied: they are listed, to run by hand.
set -e
cd "$(dirname "$0")/.."
old=$(git rev-parse HEAD)
git pull --ff-only
.venv/bin/pip install -q -r requirements.txt
launchctl kickstart -k "gui/$(id -u)/com.sofia.web"
git log --oneline "$old..HEAD"
if ! git diff --quiet "$old" HEAD -- db/; then
    echo "db/ changed, apply by hand:"
    git diff --stat "$old" HEAD -- db/
fi
