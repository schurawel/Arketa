#!/bin/bash
# Vagrant wrapper script to use source-built version

VAGRANT_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/vagrant-src" && pwd)"
PROJECT_DIR="$(dirname "${BASH_SOURCE[0]}")"

export VAGRANT_HOME="${HOME}/.vagrant.d"
export VAGRANT_DISABLE_VBOXSYMLINKCREATE=1

# Save current directory and ensure we're in project directory
ORIGINAL_DIR="$(pwd)"

# If not already in project directory, change to it
if [ "$(realpath "$PWD")" != "$(realpath "$PROJECT_DIR")" ]; then
    cd "$PROJECT_DIR"
fi

# Run Vagrant from source but in project directory
BUNDLE_GEMFILE="$VAGRANT_SOURCE_DIR/Gemfile" bundle exec "$VAGRANT_SOURCE_DIR/bin/vagrant" "$@"
