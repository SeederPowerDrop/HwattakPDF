#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

if (( $# < 1 || $# > 2 )); then
    echo "Usage: zsh scripts/validate_plugin.sh <source.hwattakplugin | --examples> [host-version]" >&2
    exit 2
fi

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
PLUGIN_HOST_VERSION="${2:-$(plutil -extract CFBundleShortVersionString raw -o - "${PROJECT_DIRECTORY}/Resources/Info.plist")}"
PLUGIN_SOURCE=""
if [[ "$1" != "--examples" ]]; then
    # :a preserves a symlink so the native validator can reject it.
    PLUGIN_SOURCE="${1:a}"
    [[ -d "${PLUGIN_SOURCE}" ]] || { echo "Expected a package directory; unzip archives first." >&2; exit 2; }
fi

command -v swift >/dev/null || { echo "Install the macOS Swift development toolchain first." >&2; exit 2; }
PLUGIN_CHECK_WORK="${PROJECT_DIRECTORY}/work/plugin-authoring"
mkdir -p "${PLUGIN_CHECK_WORK}/module-cache" "${PLUGIN_CHECK_WORK}/swiftpm-cache"

env \
    HWATTAK_PLUGIN_VALIDATE_PATH="${PLUGIN_SOURCE}" \
    HWATTAK_PLUGIN_HOST_VERSION="${PLUGIN_HOST_VERSION}" \
    CLANG_MODULE_CACHE_PATH="${PLUGIN_CHECK_WORK}/module-cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="${PLUGIN_CHECK_WORK}/module-cache" \
    XDG_CACHE_HOME="${PLUGIN_CHECK_WORK}/swiftpm-cache" \
    swift test --package-path "${PROJECT_DIRECTORY}" --disable-sandbox \
        --filter 'PluginAuthoringTests/testCommunityPackagesAndOptionalAuthorPackage'
