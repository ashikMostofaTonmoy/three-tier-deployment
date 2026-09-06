#!/usr/bin/env bash
# Remove every AWS resource the lab created. This is a thin wrapper around
# infra/teardown.sh so there is one obvious "undo everything" command.
#
#   scripts/cleanup.sh
#
exec bash "$(dirname "$0")/../infra/teardown.sh" "$@"
