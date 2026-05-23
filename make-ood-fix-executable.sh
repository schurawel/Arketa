#!/bin/bash
# Simple helper to make the OOD desktop fix script executable

# Ensure script is run from PrimedSLURM directory
if [ ! -f "README.md" ] || [ ! -d "scripts" ]; then
    echo -e "\033[0;31mError: This script must be run from the PrimedSLURM directory.\033[0m"
    echo -e "\033[1;33mPlease cd to the PrimedSLURM directory and run: ./make-ood-fix-executable.sh\033[0m"
    exit 1
fi

chmod +x ./ood-desktop-fix.sh
echo "Script is now executable. Run it with:"
echo "  sudo ./ood-desktop-fix.sh"
