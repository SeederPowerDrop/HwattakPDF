// SPDX-License-Identifier: MPL-2.0

import Foundation
import Vision

/// A language actually available to the installed offline Vision engine.
/// Keep Vision's identifier (including regional variants) for recognition;
/// display names come from the app locale and the language's own locale.
struct OCRRecognitionLanguage: Identifiable, Hashable {
    let id: String
    let localizedName: String
    let nativeName: String
    let shortCode: String

    func matches(query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [id, localizedName, nativeName, shortCode].contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static func supportedLanguages(
        quality: OCRRecognitionQuality = .accurate,
        locale: Locale = L10n.currentLanguage.locale
    ) throws -> [Self] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = quality == .fast ? .fast : .accurate
        return catalog(identifiers: try request.supportedRecognitionLanguages(), locale: locale)
    }

    static func catalog(identifiers: [String], locale: Locale) -> [Self] {
        let identifiers = Set(identifiers.map(normalizedIdentifier).filter { !$0.isEmpty })
        let displayGroups = Dictionary(grouping: identifiers, by: displayIdentifier)

        return identifiers.map { identifier in
            let baseIdentifier = displayIdentifier(identifier)
            // Show a region only when it distinguishes two supported variants.
            let nameIdentifier = displayGroups[baseIdentifier, default: []].count > 1
                ? identifier : baseIdentifier
            let nativeLocale = Locale(identifier: identifier)
            let languageCode = nativeLocale.language.languageCode?.identifier ?? identifier
            let localizedName = locale.localizedString(forIdentifier: nameIdentifier)
                ?? locale.localizedString(forLanguageCode: languageCode)
                ?? identifier
            let nativeName = nativeLocale.localizedString(forIdentifier: nameIdentifier)
                ?? nativeLocale.localizedString(forLanguageCode: languageCode)
                ?? localizedName
            return Self(
                id: identifier,
                localizedName: localizedName,
                nativeName: nativeName,
                shortCode: languageCode.uppercased()
            )
        }.sorted { lhs, rhs in
            let comparison = lhs.localizedName.compare(
                rhs.localizedName, options: [.caseInsensitive, .diacriticInsensitive], locale: locale
            )
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }

    /// Intersect an explicit selection with support, without inventing a choice.
    /// Preserve its priority: Vision processes languages in the requested order.
    static func selectedIdentifiers(from selection: [String], available: [Self]) -> [String] {
        let supported = Set(available.map(\.id))
        var seen = Set<String>()
        return selection.map(normalizedIdentifier).filter {
            supported.contains($0) && seen.insert($0).inserted
        }
    }

    /// Used only when first presenting the picker, never to silently replace
    /// the user's language selection when recognition starts.
    static func initialSelection(
        preferred: [String],
        available: [Self],
        preferredSystemLanguages: [String] = Locale.preferredLanguages
    ) -> [String] {
        let selected = selectedIdentifiers(from: preferred, available: available)
        if !selected.isEmpty { return selected }

        for preference in preferredSystemLanguages {
            let exact = selectedIdentifiers(from: [preference], available: available)
            if !exact.isEmpty { return exact }
            let baseIdentifier = displayIdentifier(normalizedIdentifier(preference))
            if let match = available.first(where: { displayIdentifier($0.id) == baseIdentifier }) {
                return [match.id]
            }
        }
        if let english = available.first(where: { $0.id == "en-US" }) { return [english.id] }
        return available.first.map { [$0.id] } ?? []
    }

    private static func normalizedIdentifier(_ identifier: String) -> String {
        Locale.canonicalLanguageIdentifier(
            from: identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func displayIdentifier(_ identifier: String) -> String {
        let components = identifier.split(separator: "-")
        guard let language = components.first else { return identifier }
        // Retain explicit script distinctions such as zh-Hans/zh-Hant and
        // yue-Hans/yue-Hant, but do not infer a script for every language.
        let script = components.dropFirst().first { $0.count == 4 }
        return script.map { "\(language)-\($0)" } ?? String(language)
    }
}
