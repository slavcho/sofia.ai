#!/bin/sh
# Run a command from the repository root with the virtualenv and the
# secrets in .env. launchd starts the services with no shell profile, a
# bare PATH and / as the working directory, so they all go through this.
#
#     deploy/run.sh python3 poll_live.py
set -e
cd "$(dirname "$0")/.."
. .venv/bin/activate
if [ -f .env ]; then
    set -a
    . ./.env
    set +a
fi
exec "$@"
