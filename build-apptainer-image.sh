#!/bin/bash
# build-apptainer-image.sh
# Build the Apptainer image for use in SLURM jobs

set -e

DEF_FILE="$(dirname "$0")/ubuntu_python.def"
SIF_FILE="$(dirname "$0")/ubuntu_python.sif"

if ! command -v apptainer &>/dev/null; then
    echo "[ERROR] apptainer is not installed or not in PATH."
    exit 1
fi

if [ ! -f "$DEF_FILE" ]; then
    echo "[ERROR] Definition file not found: $DEF_FILE"
    exit 1
fi

echo "[INFO] Building Apptainer image: $SIF_FILE from $DEF_FILE"
apptainer build "$SIF_FILE" "$DEF_FILE"
echo "[SUCCESS] Image built: $SIF_FILE"
