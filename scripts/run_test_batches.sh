#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
TEST_DIRECTORY="${PROJECT_DIRECTORY}/Tests/VibePDFTests"

typeset -a presentation_tests=(
    AboutContentTests
    AppEditCommandRouterTests
    AppFileCommandRouterTests
    AppMenuRegistrationTests
    AIAssistantWindowPresentationTests
    HelpTutorialContentTests
    LocalizationAndIconSettingsTests
    PDFComparisonConfigurationTests
    PDFExportPermissionPresentationTests
    PDFGridLayoutModeTests
    PDFGridPagingEdgeCaseTests
    PDFPageDisplayRangeTests
    PDFPageDragPayloadTests
    PDFPageJumpRequestTests
    PDFShareNoteTests
    PDFViewportScrollInteractionTests
    PageScrollHUDStateTests
    PageSidebarLayoutModeTests
    ResourceMonitorTests
    SearchNavigatorPresentationTests
    SignatureCaptureConfigurationTests
)

typeset -a document_tests=(
    InlineTextEditingTests
    PDFAnnotationPrivacyTests
    PDFDocumentSearchTests
    PDFEditHistoryTests
    PDFExternalModificationConflictTests
    PDFPageOperationsTests
    PDFSecurityTests
    PDFWorkspaceSafetyTests
    SecureSignatureStoreTests
    WorkspaceSaveCoordinatorTests
)

# ImageAnnotationEditingTests drives a real PDFView through live AppKit mouse
# gestures. PDFKit leaves process-global field-editor state behind on headless
# hosts, which can terminate a later AcroForm test even though both classes pass
# alone. Give this interaction-heavy class its own xctest process; this is the
# same containment strategy already used between the larger batches below.
typeset -a image_interaction_tests=(
    ImageAnnotationEditingTests
)

# Native AcroForm tests also construct live PDFView/field-editor hierarchies.
# Keep them out of the document batch so process-global PDFKit editor state from
# unrelated classes cannot terminate the host before assertions complete.
typeset -a native_form_interaction_tests=(
    PDFNativeFormInputBoundaryTests
)

typeset -a workspace_tests=(
    MultiDocumentEncryptedBatchTests
    MultiDocumentWorkspaceStateTests
    PDFTabGroupTests
    PDFTabMemoryManagerTests
    PDFWorkspaceModeTests
    RecentDocumentsStoreTests
    WorkspaceSessionStoreTests
)

typeset -a assistant_tests=(
    AIAssistantMarkupTests
    AIAssistantMathFormatterTests
    AIAssistantPageSelectionTests
    AIAssistantSessionModelTests
    AIProviderServiceTests
    PDFAIContextAndRelatedSearchTests
)

typeset -a plugin_tests=(
    PluginSystemTests
    PluginWebURLPolicyTests
)

typeset -A listed_classes
for class_name in \
    "${presentation_tests[@]}" \
    "${image_interaction_tests[@]}" \
    "${native_form_interaction_tests[@]}" \
    "${document_tests[@]}" \
    "${workspace_tests[@]}" \
    "${assistant_tests[@]}" \
    "${plugin_tests[@]}"
do
    [[ -z "${listed_classes[${class_name}]-}" ]] \
        || { echo "Duplicate test class in batch manifest: ${class_name}" >&2; exit 1; }
    listed_classes[${class_name}]=1
done

typeset -a discovered_classes
discovered_classes=("${(@f)$(
    sed -n -E 's/^final class ([A-Za-z0-9_]+Tests).*$/\1/p' \
        "${TEST_DIRECTORY}"/*.swift | sort -u
)}")

for class_name in "${discovered_classes[@]}"; do
    [[ -n "${listed_classes[${class_name}]-}" ]] \
        || { echo "Unbatched test class: ${class_name}" >&2; exit 1; }
done
[[ "${#discovered_classes[@]}" -eq "${#listed_classes[@]}" ]] \
    || { echo "Batch manifest contains a missing test class" >&2; exit 1; }

mkdir -p "${PROJECT_DIRECTORY}/work"
TEST_TEMPORARY="$(mktemp -d "${PROJECT_DIRECTORY}/work/test-batches.XXXXXX")"
cleanup() {
    rm -rf "${TEST_TEMPORARY}"
}
trap cleanup EXIT

BUILD_PATH="${TEST_TEMPORARY}/build"
MODULE_CACHE="${TEST_TEMPORARY}/module-cache"
SWIFTPM_CACHE="${TEST_TEMPORARY}/swiftpm-cache"
mkdir -p "${BUILD_PATH}" "${MODULE_CACHE}" "${SWIFTPM_CACHE}"

run_batch() {
    local name="$1"
    shift
    local filter="${(j:|:)@}"
    local -a arguments=(
        --package-path "${PROJECT_DIRECTORY}"
        --scratch-path "${BUILD_PATH}"
        --disable-sandbox
        --filter "${filter}"
    )
    if [[ "${name}" != "presentation" ]]; then
        arguments+=(--skip-build)
    fi
    echo "Running test batch: ${name}"
    env \
        CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}" \
        SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE}" \
        XDG_CACHE_HOME="${SWIFTPM_CACHE}" \
        swift test "${arguments[@]}"
}

# Each batch gets its own xctest process. This contains PDFKit/AppKit host
# lifetime issues while sharing one deterministic compile output.
run_batch presentation "${presentation_tests[@]}"
run_batch image-interaction "${image_interaction_tests[@]}"
run_batch native-form-interaction "${native_form_interaction_tests[@]}"
run_batch document "${document_tests[@]}"
run_batch workspace "${workspace_tests[@]}"
run_batch assistant "${assistant_tests[@]}"
run_batch plugins "${plugin_tests[@]}"

echo "All ${#discovered_classes[@]} test classes passed in seven isolated batches"
