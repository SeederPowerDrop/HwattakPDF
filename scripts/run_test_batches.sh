#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
TEST_DIRECTORY="${PROJECT_DIRECTORY}/Tests/HwattakPDFTests"

typeset -a presentation_tests=(
    AboutContentTests
    AppAppearanceTests
    AppEditCommandRouterTests
    AppExternalFileOpenCoordinatorTests
    AppFileCommandRouterTests
    AppMenuRegistrationTests
    AIAssistantWindowPresentationTests
    DefaultPDFApplicationTests
    HelpTutorialContentTests
    LocalizationAndIconSettingsTests
    OCRExportDestinationTests
    OCRLanguageTests
    OCRPageSelectionTests
    PDFComparisonConfigurationTests
    PDFExportPermissionPresentationTests
    PDFGridLayoutModeTests
    PDFGridPagingEdgeCaseTests
    PDFMainPageNavigationTests
    PDFPageDisplayRangeTests
    PDFPageDragPayloadTests
    PDFPageFitModeTests
    PDFPageJumpRequestTests
    PDFShareNoteTests
    PDFViewportScrollInteractionTests
    PageScrollHUDStateTests
    PageSidebarKeyboardNavigationTests
    PageSidebarLayoutModeTests
    ResourceMonitorTests
    SearchNavigatorPresentationTests
    SignatureCaptureConfigurationTests
)

typeset -a document_tests=(
    DocumentConversionTests
    DocumentStabilizationTests
    AdvancedStabilizationTests
    HTMLPDFConversionTests
    InlineTextEditingTests
    PDFAnnotationPrivacyTests
    PDFDocumentSearchTests
    PDFEditHistoryTests
    PDFExternalModificationConflictTests
    PDFPageOperationsTests
    PDFOfficeBoundsTests
    PDFOCRApplicationTests
    OCRExportSaveTests
    OCRTextRepairTests
    OCRPartialExportTests
    OCRPageScopeWorkspaceTests
    PDFRegionTextSelectionTests
    PDFNativeSelectionProxyTests
    PressureInkCopyTests
    RecoverySchedulingTests
    PDFSecurityTests
    PDFWorkspaceSafetyTests
    SecureSignatureStoreTests
    StudyUnderlineRenderingTests
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

# Region selection yields to MainActor while live PDFViews are mounted. Even
# different methods in this class can flush stale offscreen PDFKit tile surfaces
# on macOS 15, so the runner below gives each method its own test process.
typeset -a region_interaction_tests=(
    PDFRegionSelectionInteractionTests
)

# Native AcroForm tests also construct live PDFView/field-editor hierarchies.
# Keep them out of the document batch so process-global PDFKit editor state from
# unrelated classes cannot terminate the host before assertions complete.
typeset -a native_form_interaction_tests=(
    PDFNativeFormInputBoundaryTests
)

# Held-key navigation uses AppKit windows, event monitors and live PDFView
# hierarchies. Isolate their lifetime from the AcroForm and document batches.
typeset -a keyboard_interaction_tests=(
    PDFArrowKeyRepeaterTests
    PDFKeyboardNavigationInteractionTests
)

typeset -a workspace_tests=(
    MultiDocumentEncryptedBatchTests
    MultiDocumentWorkspaceStateTests
    PDFTabGroupTests
    PDFTabMemoryManagerTests
    PDFWorkspaceModeTests
    RecentDocumentsStoreTests
    WorkspaceSessionStoreTests
    RecoveryLifecycleTests
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
    PageTranslationTests
    PageTranslationExportPolicyTests
    LocalTranslationServiceTests
    PluginSystemTests
    PluginAuthoringTests
    PluginWebURLPolicyTests
    PDFPermissionBoundaryTests
)

typeset -A listed_classes
for class_name in \
    "${presentation_tests[@]}" \
    "${image_interaction_tests[@]}" \
    "${region_interaction_tests[@]}" \
    "${native_form_interaction_tests[@]}" \
    "${keyboard_interaction_tests[@]}" \
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
if [[ -n "${HWATTAK_TEST_WORK_DIRECTORY:-}" ]]; then
    # Keep an explicitly chosen work directory for reproducing host failures
    # without recompiling the whole app. SwiftPM still rebuilds changed inputs.
    TEST_TEMPORARY="${HWATTAK_TEST_WORK_DIRECTORY:A}"
    mkdir -p "${TEST_TEMPORARY}"
else
    TEST_TEMPORARY="$(mktemp -d "${PROJECT_DIRECTORY}/work/test-batches.XXXXXX")"
fi
cleanup() {
    if [[ -z "${HWATTAK_TEST_WORK_DIRECTORY:-}" ]]; then
        rm -rf "${TEST_TEMPORARY}"
    fi
}
trap cleanup EXIT

BUILD_PATH="${TEST_TEMPORARY}/build"
MODULE_CACHE="${TEST_TEMPORARY}/module-cache"
SWIFTPM_CACHE="${TEST_TEMPORARY}/swiftpm-cache"
mkdir -p "${BUILD_PATH}" "${MODULE_CACHE}" "${SWIFTPM_CACHE}"
TEST_PROCESS_COUNT=0

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
    TEST_PROCESS_COUNT=$((TEST_PROCESS_COUNT + 1))
    echo "Running test batch: ${name}"
    env \
        CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}" \
        SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE}" \
        XDG_CACHE_HOME="${SWIFTPM_CACHE}" \
        swift test "${arguments[@]}" | tee "${TEST_TEMPORARY}/last-batch.log"
    if [[ "${name}" == region-interaction:* ]]; then
        grep -Eq 'Executed 1 test,.*0 failures' "${TEST_TEMPORARY}/last-batch.log" \
            || { echo "Region interaction filter did not run exactly one test: ${filter}" >&2; exit 1; }
    fi
}

run_region_interactions() {
    local class_name test_name
    local -a test_names
    for class_name in "${region_interaction_tests[@]}"; do
        test_names=("${(@f)$(
            sed -n -E 's/^    func (test[A-Za-z0-9_]+)\(.*/\1/p' \
                "${TEST_DIRECTORY}/${class_name}.swift"
        )}")
        (( ${#test_names[@]} > 0 )) \
            || { echo "No region interaction tests discovered: ${class_name}" >&2; exit 1; }
        for test_name in "${test_names[@]}"; do
            run_batch "region-interaction: ${test_name}" "^HwattakPDFTests[.]${class_name}/${test_name}$"
        done
    done
}

# Each batch gets its own xctest process. This contains PDFKit/AppKit host
# lifetime issues while sharing one deterministic compile output.
run_batch presentation "${presentation_tests[@]}"
run_batch image-interaction "${image_interaction_tests[@]}"
run_region_interactions
run_batch native-form-interaction "${native_form_interaction_tests[@]}"
run_batch keyboard-interaction "${keyboard_interaction_tests[@]}"
run_batch document "${document_tests[@]}"
run_batch workspace "${workspace_tests[@]}"
run_batch assistant "${assistant_tests[@]}"
run_batch plugins "${plugin_tests[@]}"

echo "All ${#discovered_classes[@]} test classes passed in nine batches (${TEST_PROCESS_COUNT} isolated test processes)"
