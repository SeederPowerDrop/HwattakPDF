#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
INFO_PLIST="${PROJECT_DIRECTORY}/Resources/Info.plist"
ENTITLEMENTS="${PROJECT_DIRECTORY}/Resources/VibePDF.entitlements"
LOCALIZATION_DIRECTORY="${PROJECT_DIRECTORY}/Resources/Localization"
EXPECTED_LOCALIZATIONS=(ko en fr de es ja zh-Hans ar pt vi)
REQUIRED_RESOURCES=(
    AboutAuthor-SeederPowerDrop-UserProvided.jpg
    AppIcon-FoldWorkspace.png
    AppIcon-PrecisionMarkup.png
    AppIcon-StackAndSelect.png
)
EXAMPLE_PLUGIN_NAMES=(
    TranslationCompanion.hwattakplugin
    YouTubeStudy.hwattakplugin
    WebBrowser.hwattakplugin
    StudyMarkup.hwattakplugin
    TabletTools.hwattakplugin
    ReadingNavigation.hwattakplugin
    CommunityStarter.hwattakplugin
    OfflineChecklist.hwattakplugin
)
CURRENT_VERSION_DOCUMENTS=(
    README.md
    Documentation/README.md
    Documentation/PRODUCT.md
    Documentation/ARCHITECTURE.md
    Documentation/PLUGINS.md
    Documentation/QUALITY_REPORT.md
)

fail() {
    echo "validation failed: $*" >&2
    exit 1
}

require_file() {
    [[ -f "$1" ]] || fail "missing file: ${1}"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

require_command plutil
require_command jq
require_command swift
require_command sort
require_command sed
require_command uniq
require_command cmp
require_command find
require_command head

require_file "${PROJECT_DIRECTORY}/Package.swift"
require_file "${INFO_PLIST}"
require_file "${ENTITLEMENTS}"
require_file "${PROJECT_DIRECTORY}/LICENSE"
require_file "${PROJECT_DIRECTORY}/NOTICE"
require_file "${PROJECT_DIRECTORY}/ASSETS.md"
require_file "${PROJECT_DIRECTORY}/TRADEMARKS.md"
require_file "${PROJECT_DIRECTORY}/Documentation/RELEASE-NOTES-0.8.0.md"
require_file "${PROJECT_DIRECTORY}/Resources/AboutAuthor-UserProvided-NOTICE.txt"

grep -Fq "Mozilla Public License Version 2.0" "${PROJECT_DIRECTORY}/LICENSE" \
    || fail "LICENSE is not the MPL-2.0 text"
grep -Fq "Copyright 2026 SeederPowerDrop" "${PROJECT_DIRECTORY}/NOTICE" \
    || fail "NOTICE copyright is missing or stale"
grep -Fq "Mozilla Public License 2.0" \
    "${PROJECT_DIRECTORY}/Resources/AboutAuthor-UserProvided-NOTICE.txt" \
    || fail "About artwork license notice is missing"
grep -Fq "// SPDX-License-Identifier: MPL-2.0" "${PROJECT_DIRECTORY}/Package.swift" \
    || fail "Package.swift SPDX notice is missing"

while IFS= read -r source_file; do
    [[ "$(head -n 1 "${source_file}")" == "// SPDX-License-Identifier: MPL-2.0" ]] \
        || fail "Swift source SPDX notice is missing: ${source_file}"
done < <(find "${PROJECT_DIRECTORY}/Sources" "${PROJECT_DIRECTORY}/Tests" -type f -name '*.swift' -print)

plutil -lint "${INFO_PLIST}" >/dev/null
plutil -lint "${ENTITLEMENTS}" >/dev/null

SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "${INFO_PLIST}")"
BUILD_VERSION="$(plutil -extract CFBundleVersion raw -o - "${INFO_PLIST}")"
MINIMUM_SYSTEM="$(plutil -extract LSMinimumSystemVersion raw -o - "${INFO_PLIST}")"
BUNDLE_EXECUTABLE="$(plutil -extract CFBundleExecutable raw -o - "${INFO_PLIST}")"
BUNDLE_COPYRIGHT="$(plutil -extract NSHumanReadableCopyright raw -o - "${INFO_PLIST}")"

[[ "${SHORT_VERSION}" == <->.<->.<-> ]] \
    || fail "CFBundleShortVersionString must use semantic x.y.z form"
[[ "${BUILD_VERSION}" == <-> ]] \
    || fail "CFBundleVersion must be a positive integer"
(( BUILD_VERSION > 0 )) || fail "CFBundleVersion must be greater than zero"
[[ "${MINIMUM_SYSTEM}" == "14.0" ]] \
    || fail "Info.plist minimum macOS must remain 14.0"
[[ "${BUNDLE_EXECUTABLE}" == "HwattakPDF" ]] \
    || fail "unexpected bundle executable: ${BUNDLE_EXECUTABLE}"
[[ "${BUNDLE_COPYRIGHT}" == "Copyright © 2026 SeederPowerDrop" ]] \
    || fail "unexpected bundle copyright: ${BUNDLE_COPYRIGHT}"
grep -q '\.macOS(\.v14)' "${PROJECT_DIRECTORY}/Package.swift" \
    || fail "Package.swift minimum macOS does not match Info.plist"

CURRENT_VERSION_LABEL="${SHORT_VERSION} (build ${BUILD_VERSION})"
for document_name in "${CURRENT_VERSION_DOCUMENTS[@]}"; do
    document_path="${PROJECT_DIRECTORY}/${document_name}"
    require_file "${document_path}"
    grep -Fq "${CURRENT_VERSION_LABEL}" "${document_path}" \
        || fail "current version is missing or stale in ${document_name}"
done

typeset -a discovered_localizations
for localization_path in "${LOCALIZATION_DIRECTORY}"/*.lproj(N); do
    discovered_localizations+=("${${localization_path:t}%.lproj}")
done
typeset -a sorted_discovered_localizations sorted_expected_localizations
sorted_discovered_localizations=("${(@on)discovered_localizations}")
sorted_expected_localizations=("${(@on)EXPECTED_LOCALIZATIONS}")
[[ "${(j: :)sorted_discovered_localizations}" == "${(j: :)sorted_expected_localizations}" ]] \
    || fail "localization directories do not match the release manifest"

mkdir -p "${PROJECT_DIRECTORY}/work"
VALIDATION_TEMPORARY="$(mktemp -d "${PROJECT_DIRECTORY}/work/validation.XXXXXX")"
REFERENCE_KEYS="${VALIDATION_TEMPORARY}/reference-keys.txt"
TEMPORARY_KEYS="${VALIDATION_TEMPORARY}/locale-keys.txt"
cleanup() {
    rm -rf "${VALIDATION_TEMPORARY}"
}
trap cleanup EXIT

for language in "${EXPECTED_LOCALIZATIONS[@]}"; do
    strings_file="${LOCALIZATION_DIRECTORY}/${language}.lproj/Localizable.strings"
    require_file "${strings_file}"
    plutil -lint "${strings_file}" >/dev/null
    sed -n 's/^"\([^"]*\)"[[:space:]]*=.*/\1/p' "${strings_file}" \
        | sort > "${TEMPORARY_KEYS}"
    [[ -s "${TEMPORARY_KEYS}" ]] || fail "no localization keys in ${strings_file}"
    if [[ -n "$(uniq -d "${TEMPORARY_KEYS}")" ]]; then
        fail "duplicate localization key in ${strings_file}"
    fi
    if [[ "${language}" == "ko" ]]; then
        cp "${TEMPORARY_KEYS}" "${REFERENCE_KEYS}"
    elif ! cmp -s "${REFERENCE_KEYS}" "${TEMPORARY_KEYS}"; then
        fail "localization key parity mismatch: ${language} differs from ko"
    fi
done

for resource_name in "${REQUIRED_RESOURCES[@]}"; do
    require_file "${PROJECT_DIRECTORY}/Resources/${resource_name}"
done

for plugin_name in "${EXAMPLE_PLUGIN_NAMES[@]}"; do
    plugin_directory="${PROJECT_DIRECTORY}/Examples/Plugins/${plugin_name}"
    require_file "${plugin_directory}/manifest.json"
    require_file "${plugin_directory}/README.md"
    jq -e . "${plugin_directory}/manifest.json" >/dev/null \
        || fail "invalid JSON manifest: ${plugin_directory}/manifest.json"
done

[[ -s "${PROJECT_DIRECTORY}/Resources/AboutAuthor-SeederPowerDrop-UserProvided.jpg" ]] \
    || fail "About artwork is empty"

if git -C "${PROJECT_DIRECTORY}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    tracked_junk="$(
        git -C "${PROJECT_DIRECTORY}" ls-files \
            | sed -n -E '/(^|\/)\.DS_Store$|(^|\/)\.build\/|(^|\/)work\/|(^|\/)outputs\//p'
    )"
    [[ -z "${tracked_junk}" ]] || fail "generated files are tracked:\n${tracked_junk}"
fi

mkdir -p \
    "${VALIDATION_TEMPORARY}/module-cache" \
    "${VALIDATION_TEMPORARY}/swiftpm-cache"
env \
    CLANG_MODULE_CACHE_PATH="${VALIDATION_TEMPORARY}/module-cache" \
    SWIFTPM_MODULECACHE_OVERRIDE="${VALIDATION_TEMPORARY}/module-cache" \
    XDG_CACHE_HOME="${VALIDATION_TEMPORARY}/swiftpm-cache" \
    swift package \
        --package-path "${PROJECT_DIRECTORY}" \
        --disable-sandbox \
        dump-package >/dev/null
zsh -n "${PROJECT_DIRECTORY}/scripts/build_app.sh"
zsh -n "${PROJECT_DIRECTORY}/scripts/run_test_batches.sh"
zsh -n "${PROJECT_DIRECTORY}/scripts/validate_plugin.sh"

echo "Static validation passed"
echo "Version ${SHORT_VERSION} (${BUILD_VERSION}), macOS ${MINIMUM_SYSTEM}+"
echo "Localization parity: ${#EXPECTED_LOCALIZATIONS[@]} languages"
