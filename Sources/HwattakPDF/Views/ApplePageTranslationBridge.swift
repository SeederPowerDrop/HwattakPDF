// SPDX-License-Identifier: MPL-2.0

import SwiftUI
import Translation

struct ApplePageTranslationJob: Identifiable {
    let id: UUID
    let input: PageTranslationInput
    let blocks: [TranslationBlock]
}

/// SwiftUI owns the session and cancels its task when this view disappears.
/// The session never escapes translationTask into an independently lived task.
@available(macOS 15.0, *)
@MainActor
struct ApplePageTranslationBridge: View {
    let job: ApplePageTranslationJob
    let onCompletion: (UUID, Result<PageTranslationResult, Error>) -> Void
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
            .onAppear {
                configuration = TranslationSession.Configuration(
                    source: job.input.sourceLanguageCode.map { Locale.Language(identifier: $0) },
                    target: Locale.Language(identifier: job.input.targetLanguageCode)
                )
            }
            .translationTask(configuration) { session in
                do {
                    try Task.checkCancellation()
                    let availability = LanguageAvailability()
                    let target = Locale.Language(identifier: job.input.targetLanguageCode)
                    let status: LanguageAvailability.Status
                    if let source = job.input.sourceLanguageCode {
                        status = await availability.status(from: Locale.Language(identifier: source), to: target)
                    } else {
                        status = try await availability.status(
                            for: String(job.input.sourceText.prefix(4_000)), to: target
                        )
                    }
                    guard status != .unsupported else { throw ApplePageTranslationError.unsupported }
                    let batch = job.blocks.map {
                        TranslationSession.Request(sourceText: $0.source, clientIdentifier: $0.id)
                    }
                    // translate prompts for missing language downloads itself.
                    // prepareTranslation cannot identify an automatic source language.
                    let responses = try await session.translations(from: batch)
                    try Task.checkCancellation()
                    var translated: [String: String] = [:]
                    let expectedIDs = Set(job.blocks.map(\.id))
                    for response in responses {
                        guard let id = response.clientIdentifier,
                              expectedIDs.contains(id), translated[id] == nil,
                              !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else { throw ApplePageTranslationError.incomplete }
                        translated[id] = response.targetText
                    }
                    guard translated.count == job.blocks.count else {
                        throw ApplePageTranslationError.incomplete
                    }
                    let result = PageTranslationResult(
                        blocks: job.blocks.map {
                            TranslatedPageBlock(id: $0.id, source: $0.source, translated: translated[$0.id]!)
                        },
                        sourceLanguageCode: job.input.sourceLanguageCode
                            ?? responses.first?.sourceLanguage.languageCode?.identifier,
                        targetLanguageCode: job.input.targetLanguageCode,
                        engineTitle: L10n.string("translation.engine.system", defaultValue: "macOS 번역")
                    )
                    onCompletion(job.id, .success(result))
                } catch is CancellationError {
                    // The owner has already cleared its active job.
                } catch {
                    guard !Task.isCancelled else { return }
                    onCompletion(job.id, .failure(error))
                }
            }
    }
}

private enum ApplePageTranslationError: LocalizedError {
    case unsupported
    case incomplete

    var errorDescription: String? {
        switch self {
        case .unsupported:
            L10n.string("translation.system.unsupported", defaultValue: "macOS에서 지원하지 않는 언어 조합입니다. 다른 언어 또는 번역 엔진을 선택하세요.")
        case .incomplete:
            L10n.string("translation.system.incomplete", defaultValue: "일부 문단의 번역이 누락되었습니다. 다시 번역해 주세요.")
        }
    }
}

@available(macOS 14.4, *)
@MainActor
struct AppleLegacyTranslationButton: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button(L10n.string("translation.system.popup", defaultValue: "macOS 번역 팝업 열기")) {
            isPresented = true
        }
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .translationPresentation(isPresented: $isPresented, text: text)
    }
}
