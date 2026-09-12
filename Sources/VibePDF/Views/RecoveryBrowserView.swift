// SPDX-License-Identifier: MPL-2.0

import SwiftUI

struct RecoveryBrowserView: View {
    @ObservedObject var workspace: MultiDocumentWorkspaceState
    @State private var records: [PDFRecoveryStore.Record] = []
    @State private var error: String?
    @State private var deleting: PDFRecoveryStore.Record?
    private let store = PDFRecoveryStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("recovery.title")).font(.title2.bold())
            Text(L10n.string("recovery.help")).font(.callout).foregroundStyle(.secondary)
            List(records) { record in
                HStack {
                    VStack(alignment: .leading) {
                        Text(record.displayName)
                        Text(record.updatedAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.string("recovery.open")) {
                        // Use a separate working file so saving/discarding this
                        // copy cannot invalidate the immutable recovery record.
                        do {
                            let copy = try store.makeWorkingCopy(of: record)
                            if let id = workspace.addTab(opening: copy),
                               let tab = workspace.allTabs.first(where: { $0.id == id }) {
                                tab.workspace.markAsRecoveredCopy()
                            } else {
                                store.removeWorkingCopy(at: copy)
                                throw WorkspaceError.cannotOpen(copy)
                            }
                        } catch { self.error = error.localizedDescription }
                    }
                    Button(L10n.string("action.delete"), role: .destructive) { deleting = record }
                }.padding(.vertical, 5)
            }
            if records.isEmpty { Text(L10n.string("recovery.empty")).foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red) }
            Button(L10n.string("action.refresh")) { records = store.records() }
        }.padding(24).frame(minWidth: 560, minHeight: 380)
        .onAppear { records = store.records() }
        .confirmationDialog(L10n.string("recovery.delete_confirm"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button(L10n.string("action.delete"), role: .destructive) {
                if let deleting { store.remove(id: deleting.id) }
                records = store.records()
                deleting = nil
            }
        }
    }
}
