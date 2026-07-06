#!/usr/bin/env bash
# Launch WinUAE under Wine for MC68030 CPU verification
# Usage: ./run.sh [config]   (default: configs/mc68030_test.uae)

DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-configs/mc68030_test.uae}"

# Convert Unix path to Wine Z: path with backslashes
WIN_CONFIG="Z:$(echo "${DIR}/${CONFIG}" | sed 's|/|\\|g')"

# Suppress verbose Wine/MoltenVK noise; keep actual errors
exec wine "$DIR/winuae64.exe" \
    -config "$WIN_CONFIG" \
    2>&1 | grep -vE "^\s+VK_|\[mvk-info\] (The following|supports)|fixme:(uxtheme|appbar|setupapi|dwmapi|kernelbase)"
