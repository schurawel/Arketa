#!/bin/bash
# HPC Stack Validation Script
# Validates that all components are properly installed and configured

set -e

echo "🔍 HPC Stack Validation"
echo "======================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

validate_component() {
    local component="$1"
    local command="$2"
    local expected="$3"
    
    echo -n "Checking $component... "
    if eval "$command" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ OK${NC}"
        if [ -n "$expected" ]; then
            echo "   $(eval "$command" 2>/dev/null | head -1)"
        fi
        return 0
    else
        echo -e "${RED}❌ FAILED${NC}"
        return 1
    fi
}

validate_file() {
    local description="$1"
    local filepath="$2"
    
    echo -n "Checking $description... "
    if [ -f "$filepath" ]; then
        echo -e "${GREEN}✅ Found${NC}"
        return 0
    else
        echo -e "${RED}❌ Missing${NC}"
        return 1
    fi
}

echo "🔧 System Components:"
validate_component "Build tools" "gcc --version"
validate_component "Git" "git --version"
validate_component "Python 3" "python3 --version"
validate_component "Make" "make --version"

echo ""
echo "🚀 HPC Software:"
validate_component "Go" "go version"
validate_component "Apptainer" "apptainer --version"

echo ""
echo "🐍 Python Packages:"
validate_component "NumPy" "python3 -c 'import numpy; print(numpy.__version__)'"
validate_component "SciPy" "python3 -c 'import scipy; print(scipy.__version__)'"
validate_component "Matplotlib" "python3 -c 'import matplotlib; print(matplotlib.__version__)'"
validate_component "Pandas" "python3 -c 'import pandas; print(pandas.__version__)'"

echo ""
echo "⚙️ Slurm Components:"
if validate_component "Slurm" "/opt/slurm/bin/sinfo --version" 2>/dev/null; then
    validate_file "Slurm config" "/etc/slurm/slurm.conf"
    validate_file "Slurm controller" "/opt/slurm/sbin/slurmctld"
    validate_file "Slurm daemon" "/opt/slurm/sbin/slurmd"
else
    echo -e "   ${YELLOW}⚠️ Slurm not installed (source may not have been available)${NC}"
fi

echo ""
echo "👤 System Users:"
validate_component "Slurm user" "id slurm"

echo ""
echo "📁 Important Directories:"
validate_file "Scripts directory" "/opt/hpc-scripts"
validate_file "Sample jobs" "/opt/hpc-sample-jobs"

echo ""
echo "🌍 Environment:"
validate_file "Go environment" "/etc/profile.d/go.sh"
if [ -f "/etc/profile.d/slurm.sh" ]; then
    validate_file "Slurm environment" "/etc/profile.d/slurm.sh"
fi
validate_file "HPC base marker" "/etc/hpc-base-version"

echo ""
echo "📋 Summary:"
if [ -f "/etc/hpc-base-version" ]; then
    echo "   HPC Base Version: $(cat /etc/hpc-base-version)"
fi
if [ -f "/etc/slurm-base-version" ]; then
    echo "   Slurm Base Version: $(cat /etc/slurm-base-version)"
fi

echo ""
echo -e "${GREEN}✅ HPC Stack validation complete!${NC}"
