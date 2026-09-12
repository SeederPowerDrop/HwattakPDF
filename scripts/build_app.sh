#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
BUILD_DIRECTORY="${PROJECT_DIRECTORY}/.build"
OUTPUT_DIRECTORY="${HWATTAK_OUTPUT_DIRECTORY:-${PROJECT_DIRECTORY}/outputs}"
APP_NAME="HwattakPDF"
BUILD_EXECUTABLE_NAME="VibePDF"
BUNDLE_EXECUTABLE_NAME="HwattakPDF"
APP_BUNDLE="${OUTPUT_DIRECTORY}/${APP_NAME}.app"
PACKAGE_TEMPORARY="${PROJECT_DIRECTORY}/work/package-${APP_NAME}.app"
MODULE_CACHE="${PROJECT_DIRECTORY}/work/module-cache"
SWIFTPM_CACHE="${PROJECT_DIRECTORY}/work/swiftpm-cache"
INFO_PLIST="${PROJECT_DIRECTORY}/Resources/Info.plist"
LOCALIZATION_DIRECTORY="${PROJECT_DIRECTORY}/Resources/Localization"
EXPECTED_LOCALIZATIONS=(ko en fr de es ja zh-Hans ar pt vi)
EXPECTED_ENTITLEMENTS=(
    com.apple.security.app-sandbox
    com.apple.security.files.bookmarks.app-scope
    com.apple.security.files.user-selected.read-write
    com.apple.security.network.client
)
TARGET_ARCHITECTURE="arm64"

mkdir -p "${MODULE_CACHE}" "${SWIFTPM_CACHE}" "${OUTPUT_DIRECTORY}" "${PROJECT_DIRECTORY}/work"

plutil -lint "${INFO_PLIST}"
SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "${INFO_PLIST}")"
BUILD_VERSION="$(plutil -extract CFBundleVersion raw -o - "${INFO_PLIST}")"
ARCHIVE_NAME="${APP_NAME}-${SHORT_VERSION}-macOS-${TARGET_ARCHITECTURE}.zip"
ARCHIVE_PATH="${OUTPUT_DIRECTORY}/${ARCHIVE_NAME}"
ARCHIVE_CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"
ARCHIVE_TEMPORARY="${PROJECT_DIRECTORY}/work/${ARCHIVE_NAME}.tmp"

# A failed build must not leave a previous archive looking like fresh output.
rm -f "${ARCHIVE_PATH}" "${ARCHIVE_CHECKSUM_PATH}" "${ARCHIVE_TEMPORARY}"

VERIFICATION_DIRECTORY="$(mktemp -d "${PROJECT_DIRECTORY}/work/verify-${APP_NAME}.XXXXXX")"

cleanup() {
    if [[ -e "${PACKAGE_TEMPORARY}" ]]; then
        rm -rf "${PACKAGE_TEMPORARY}"
    fi
    if [[ -e "${ARCHIVE_TEMPORARY}" ]]; then
        rm -f "${ARCHIVE_TEMPORARY}"
    fi
    if [[ -e "${VERIFICATION_DIRECTORY}" ]]; then
        rm -rf "${VERIFICATION_DIRECTORY}"
    fi
}
trap cleanup EXIT

env \
    CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}" \
    SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE}" \
    XDG_CACHE_HOME="${SWIFTPM_CACHE}" \
    swift build \
        --package-path "${PROJECT_DIRECTORY}" \
        --configuration release \
        --disable-sandbox \
        -Xswiftc -file-prefix-map \
        -Xswiftc "${PROJECT_DIRECTORY}=." \
        -Xswiftc -debug-prefix-map \
        -Xswiftc "${PROJECT_DIRECTORY}=."

if [[ -e "${PACKAGE_TEMPORARY}" ]]; then
    rm -rf "${PACKAGE_TEMPORARY}"
fi

mkdir -p "${PACKAGE_TEMPORARY}/Contents/MacOS" "${PACKAGE_TEMPORARY}/Contents/Resources"
cp "${INFO_PLIST}" "${PACKAGE_TEMPORARY}/Contents/Info.plist"
cp "${BUILD_DIRECTORY}/release/${BUILD_EXECUTABLE_NAME}" "${PACKAGE_TEMPORARY}/Contents/MacOS/${BUNDLE_EXECUTABLE_NAME}"
chmod 755 "${PACKAGE_TEMPORARY}/Contents/MacOS/${BUNDLE_EXECUTABLE_NAME}"
strip -S -x "${PACKAGE_TEMPORARY}/Contents/MacOS/${BUNDLE_EXECUTABLE_NAME}"

DEFAULT_ICON_MASTER="${PROJECT_DIRECTORY}/Resources/AppIcon-FoldWorkspace.png"
ICON_VARIANTS=(
    "AppIcon-StackAndSelect.png"
    "AppIcon-PrecisionMarkup.png"
    "AppIcon-FoldWorkspace.png"
)
ABOUT_IMAGE="AboutAuthor-SeederPowerDrop-UserProvided.jpg"
BUNDLED_PLUGIN_NAMES=(
    "TranslationCompanion.hwattakplugin"
    "WebBrowser.hwattakplugin"
    "StudyMarkup.hwattakplugin"
    "TabletTools.hwattakplugin"
    "ReadingNavigation.hwattakplugin"
)
SOURCE_ONLY_PLUGIN_NAMES=(
    "YouTubeStudy.hwattakplugin"
)
LEGAL_DOCUMENTS=(
    "LICENSE"
    "NOTICE"
    "ASSETS.md"
    "TRADEMARKS.md"
)

if [[ ! -f "${DEFAULT_ICON_MASTER}" ]]; then
    echo "Missing app icon: ${DEFAULT_ICON_MASTER}" >&2
    exit 1
fi
cp "${DEFAULT_ICON_MASTER}" "${PACKAGE_TEMPORARY}/Contents/Resources/AppIcon.png"

for icon_name in "${ICON_VARIANTS[@]}"; do
    icon_path="${PROJECT_DIRECTORY}/Resources/${icon_name}"
    if [[ ! -f "${icon_path}" ]]; then
        echo "Missing alternate app icon: ${icon_path}" >&2
        exit 1
    fi
    cp "${icon_path}" "${PACKAGE_TEMPORARY}/Contents/Resources/${icon_name}"
done

ABOUT_IMAGE_PATH="${PROJECT_DIRECTORY}/Resources/${ABOUT_IMAGE}"
if [[ ! -f "${ABOUT_IMAGE_PATH}" ]]; then
    echo "Missing About artwork: ${ABOUT_IMAGE_PATH}" >&2
    exit 1
fi
cp "${ABOUT_IMAGE_PATH}" "${PACKAGE_TEMPORARY}/Contents/Resources/${ABOUT_IMAGE}"

mkdir -p "${PACKAGE_TEMPORARY}/Contents/Resources/Legal"
for legal_document in "${LEGAL_DOCUMENTS[@]}"; do
    legal_document_path="${PROJECT_DIRECTORY}/${legal_document}"
    if [[ ! -f "${legal_document_path}" ]]; then
        echo "Missing legal document: ${legal_document_path}" >&2
        exit 1
    fi
    cp "${legal_document_path}" \
        "${PACKAGE_TEMPORARY}/Contents/Resources/Legal/${legal_document}"
done
cp "${PROJECT_DIRECTORY}/Resources/AboutAuthor-UserProvided-NOTICE.txt" \
    "${PACKAGE_TEMPORARY}/Contents/Resources/Legal/AboutAuthor-UserProvided-NOTICE.txt"

mkdir -p "${PACKAGE_TEMPORARY}/Contents/Resources/BundledPlugins"
for plugin_name in "${BUNDLED_PLUGIN_NAMES[@]}"; do
    plugin_path="${PROJECT_DIRECTORY}/Examples/Plugins/${plugin_name}"
    if [[ ! -d "${plugin_path}" ]]; then
        echo "Missing bundled plugin: ${plugin_path}" >&2
        exit 1
    fi
    cp -R "${plugin_path}" "${PACKAGE_TEMPORARY}/Contents/Resources/BundledPlugins/"
done
for plugin_name in "${SOURCE_ONLY_PLUGIN_NAMES[@]}"; do
    if [[ -e "${PACKAGE_TEMPORARY}/Contents/Resources/BundledPlugins/${plugin_name}" ]]; then
        echo "Source-only plugin must not be packaged: ${plugin_name}" >&2
        exit 1
    fi
done

for language in "${EXPECTED_LOCALIZATIONS[@]}"; do
    localization_path="${LOCALIZATION_DIRECTORY}/${language}.lproj"
    strings_path="${localization_path}/Localizable.strings"
    if [[ ! -f "${strings_path}" ]]; then
        echo "Missing localization: ${strings_path}" >&2
        exit 1
    fi
    plutil -lint "${strings_path}"
    cp -R "${localization_path}" "${PACKAGE_TEMPORARY}/Contents/Resources/"
done

if LC_ALL=C strings -a "${PACKAGE_TEMPORARY}/Contents/MacOS/${BUNDLE_EXECUTABLE_NAME}" \
    | grep -E '/Users/|/private/var/folders/|/var/folders/' >/dev/null; then
    echo "Release executable contains a local build path" >&2
    exit 1
fi

codesign \
    --force \
    --sign - \
    --entitlements "${PROJECT_DIRECTORY}/Resources/VibePDF.entitlements" \
    "${PACKAGE_TEMPORARY}"

if [[ -e "${APP_BUNDLE}" ]]; then
    rm -rf "${APP_BUNDLE}"
fi
mv "${PACKAGE_TEMPORARY}" "${APP_BUNDLE}"

plutil -lint "${APP_BUNDLE}/Contents/Info.plist"
codesign --verify --deep --strict "${APP_BUNDLE}"

for icon_name in "${ICON_VARIANTS[@]}"; do
    test -f "${APP_BUNDLE}/Contents/Resources/${icon_name}"
done
test -f "${APP_BUNDLE}/Contents/Resources/${ABOUT_IMAGE}"
for legal_document in "${LEGAL_DOCUMENTS[@]}"; do
    test -f "${APP_BUNDLE}/Contents/Resources/Legal/${legal_document}"
done
test -f "${APP_BUNDLE}/Contents/Resources/Legal/AboutAuthor-UserProvided-NOTICE.txt"
for plugin_name in "${BUNDLED_PLUGIN_NAMES[@]}"; do
    test -f "${APP_BUNDLE}/Contents/Resources/BundledPlugins/${plugin_name}/manifest.json"
done
for language in "${EXPECTED_LOCALIZATIONS[@]}"; do
    test -f "${APP_BUNDLE}/Contents/Resources/${language}.lproj/Localizable.strings"
done

PACKAGED_SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "${APP_BUNDLE}/Contents/Info.plist")"
PACKAGED_BUILD_VERSION="$(plutil -extract CFBundleVersion raw -o - "${APP_BUNDLE}/Contents/Info.plist")"
if [[ "${PACKAGED_SHORT_VERSION}" != "${SHORT_VERSION}" || "${PACKAGED_BUILD_VERSION}" != "${BUILD_VERSION}" ]]; then
    echo "Packaged version does not match ${SHORT_VERSION} (${BUILD_VERSION})" >&2
    exit 1
fi

BINARY_ARCHITECTURES="$(lipo -archs "${APP_BUNDLE}/Contents/MacOS/${BUNDLE_EXECUTABLE_NAME}")"
if [[ "${BINARY_ARCHITECTURES}" != "${TARGET_ARCHITECTURE}" ]]; then
    echo "Expected ${TARGET_ARCHITECTURE} binary, found: ${BINARY_ARCHITECTURES}" >&2
    exit 1
fi

COPYFILE_DISABLE=1 ditto \
    -c \
    -k \
    --norsrc \
    --noextattr \
    --keepParent \
    "${APP_BUNDLE}" \
    "${ARCHIVE_TEMPORARY}"

COPYFILE_DISABLE=1 ditto -x -k --norsrc --noextattr \
    "${ARCHIVE_TEMPORARY}" "${VERIFICATION_DIRECTORY}"
VERIFIED_APP="${VERIFICATION_DIRECTORY}/${APP_NAME}.app"
VERIFIED_ENTITLEMENTS="${VERIFICATION_DIRECTORY}/verified-entitlements.plist"
if find "${VERIFICATION_DIRECTORY}" \( -name '._*' -o -name '__MACOSX' \) \
    -print -quit | grep -q .; then
    echo "Archive contains AppleDouble metadata" >&2
    exit 1
fi
plutil -lint "${VERIFIED_APP}/Contents/Info.plist"
codesign --verify --deep --strict "${VERIFIED_APP}"
codesign -d --entitlements - --xml "${VERIFIED_APP}" \
    > "${VERIFIED_ENTITLEMENTS}" 2>/dev/null
plutil -lint "${VERIFIED_ENTITLEMENTS}"
for entitlement_name in "${EXPECTED_ENTITLEMENTS[@]}"; do
    # plutil treats periods as key-path separators unless they are escaped.
    entitlement_key_path="${entitlement_name//./\\.}"
    entitlement_value="$(
        plutil -extract "${entitlement_key_path}" raw -o - "${VERIFIED_ENTITLEMENTS}"
    )"
    if [[ "${entitlement_value}" != "true" && "${entitlement_value}" != "1" ]]; then
        echo "Archived app is missing entitlement: ${entitlement_name}" >&2
        exit 1
    fi
done
for icon_name in "${ICON_VARIANTS[@]}"; do
    test -f "${VERIFIED_APP}/Contents/Resources/${icon_name}"
done
test -f "${VERIFIED_APP}/Contents/Resources/${ABOUT_IMAGE}"
for legal_document in "${LEGAL_DOCUMENTS[@]}"; do
    test -f "${VERIFIED_APP}/Contents/Resources/Legal/${legal_document}"
done
test -f "${VERIFIED_APP}/Contents/Resources/Legal/AboutAuthor-UserProvided-NOTICE.txt"
for plugin_name in "${BUNDLED_PLUGIN_NAMES[@]}"; do
    test -f "${VERIFIED_APP}/Contents/Resources/BundledPlugins/${plugin_name}/manifest.json"
done
for plugin_name in "${SOURCE_ONLY_PLUGIN_NAMES[@]}"; do
    if [[ -e "${VERIFIED_APP}/Contents/Resources/BundledPlugins/${plugin_name}" ]]; then
        echo "Archived app contains source-only plugin: ${plugin_name}" >&2
        exit 1
    fi
done
for language in "${EXPECTED_LOCALIZATIONS[@]}"; do
    verified_strings="${VERIFIED_APP}/Contents/Resources/${language}.lproj/Localizable.strings"
    test -f "${verified_strings}"
    plutil -lint "${verified_strings}"
done

VERIFIED_SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "${VERIFIED_APP}/Contents/Info.plist")"
VERIFIED_BUILD_VERSION="$(plutil -extract CFBundleVersion raw -o - "${VERIFIED_APP}/Contents/Info.plist")"
VERIFIED_ARCHITECTURES="$(lipo -archs "${VERIFIED_APP}/Contents/MacOS/${BUNDLE_EXECUTABLE_NAME}")"
if [[ "${VERIFIED_SHORT_VERSION}" != "${SHORT_VERSION}" || "${VERIFIED_BUILD_VERSION}" != "${BUILD_VERSION}" ]]; then
    echo "Archived version does not match ${SHORT_VERSION} (${BUILD_VERSION})" >&2
    exit 1
fi
if [[ "${VERIFIED_ARCHITECTURES}" != "${TARGET_ARCHITECTURE}" ]]; then
    echo "Archived binary is not ${TARGET_ARCHITECTURE}: ${VERIFIED_ARCHITECTURES}" >&2
    exit 1
fi
if LC_ALL=C strings -a "${VERIFIED_APP}/Contents/MacOS/${BUNDLE_EXECUTABLE_NAME}" \
    | grep -E '/Users/|/private/var/folders/|/var/folders/' >/dev/null; then
    echo "Archived executable contains a local build path" >&2
    exit 1
fi

mv -f "${ARCHIVE_TEMPORARY}" "${ARCHIVE_PATH}"
ARCHIVE_SHA256="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}')"
printf '%s  %s\n' "${ARCHIVE_SHA256}" "${ARCHIVE_NAME}" \
    > "${ARCHIVE_CHECKSUM_PATH}"
grep -Fqx "${ARCHIVE_SHA256}  ${ARCHIVE_NAME}" "${ARCHIVE_CHECKSUM_PATH}"

echo "Built ${APP_BUNDLE}"
echo "Version ${SHORT_VERSION} (${BUILD_VERSION}), architecture ${TARGET_ARCHITECTURE}"
echo "Archived ${ARCHIVE_PATH}"
echo "SHA-256 ${ARCHIVE_SHA256}"
