import SwiftUI
import UniformTypeIdentifiers

public struct SourcesView: View {
    @StateObject private var repoManager = RepositoryManager.shared
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var queueManager = QueueManager.shared
    
    @State private var showingAddSource = false
    @State private var newSourceURL = "https://"

    @State private var editingSource: Source?
    @State private var editedURL = ""
    @State private var showingValidationAlert = false
    @State private var validationMessage = ""
    @State private var showingSourcesExporter = false
    @State private var showingSourcesImporter = false
    @State private var sourcesBackupDocument: AptSourcesBackupDocument?
    @State private var sourcesAlertTitle = ""
    @State private var sourcesAlertMessage = ""
    @State private var showingSourcesAlert = false

    private var isSystemBusy: Bool {
        queueManager.isProcessing || repoManager.isRefreshing || CytrollOperationGate.shared.isBusy
    }
    
    public init() {}
    
    public var body: some View {
        NavigationView {
            ZStack {
                themeManager.backgroundGradient().ignoresSafeArea()
                
                List {
                    ForEach(repoManager.sources) { source in
                        HStack(spacing: 16) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.white.opacity(0.1))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "server.rack")
                                    .foregroundColor(themeManager.currentTheme.accent)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name)
                                    .font(.headline)
                                    .foregroundColor(themeManager.currentTheme.textPrimary)
                                Text(source.url)
                                    .font(.caption)
                                    .foregroundColor(themeManager.currentTheme.textSecondary)
                            }
                            Spacer()
                            Text("\(source.packageCount)")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(themeManager.currentTheme.accent.opacity(0.2))
                                .foregroundColor(themeManager.currentTheme.accent)
                                .cornerRadius(8)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                repoManager.removeSource(source)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                editedURL = source.url
                                editingSource = source
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(themeManager.currentTheme.accent)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .cytrollHideScrollBackground()
                .refreshable {
                    await withCheckedContinuation { continuation in
                        repoManager.refreshAll {
                            continuation.resume()
                        }
                    }
                }
            }
            .navigationTitle("Sources")
            .onAppear {
                // Merge any missing essentials (Procursus / ElleKit / Havoc /
                // Chariz) without touching sources the user already has.
                repoManager.ensureEssentialSources()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Menu {
                            Button {
                                AptSourcesBackupManager.shared.createBackup { document in
                                    if document.backup.files.isEmpty {
                                        presentSourcesAlert(
                                            title: "Nothing to Backup",
                                            message: "No APT source files were found."
                                        )
                                        return
                                    }
                                    sourcesBackupDocument = document
                                    showingSourcesExporter = true
                                }
                            } label: {
                                Label("Backup Sources", systemImage: "externaldrive.fill.badge.plus")
                            }
                            .disabled(isSystemBusy)

                            Button {
                                showingSourcesImporter = true
                            } label: {
                                Label("Restore Sources", systemImage: "externaldrive.fill.badge.timemachine")
                            }
                            .disabled(isSystemBusy)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .foregroundColor(themeManager.currentTheme.accent)
                        }

                        Button(action: { showingAddSource = true }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundColor(themeManager.currentTheme.accent)
                        }
                        .disabled(repoManager.isRefreshing)
                    }
                }
            }
            .fileExporter(
                isPresented: $showingSourcesExporter,
                document: sourcesBackupDocument,
                contentType: .json,
                defaultFilename: "Cytroll_APT_Sources_Backup"
            ) { result in
                switch result {
                case .success:
                    let count = sourcesBackupDocument?.backup.files.count ?? 0
                    presentSourcesAlert(title: "Sources Backup Saved", message: "Exported \(count) APT source file(s).")
                case .failure(let error):
                    presentSourcesAlert(title: "Backup Failed", message: error.localizedDescription)
                }
            }
            .fileImporter(
                isPresented: $showingSourcesImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let data = try Data(contentsOf: url)
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        let backup = try decoder.decode(AptSourcesBackup.self, from: data)
                        guard backup.kind == AptSourcesBackup.kindIdentifier else {
                            presentSourcesAlert(
                                title: "Wrong Backup Type",
                                message: "This file is not an APT sources backup."
                            )
                            return
                        }
                        DispatchQueue.global(qos: .userInitiated).async {
                            let summary = AptSourcesBackupManager.shared.restore(backup)
                            DispatchQueue.main.async {
                                if summary.writtenFiles == 0 {
                                    presentSourcesAlert(
                                        title: "Nothing Restored",
                                        message: "No source files were written from this backup."
                                    )
                                } else {
                                    var message = "Wrote \(summary.writtenFiles) source file(s) and ran apt-get update."
                                    if summary.skippedInvalid > 0 {
                                        message += " \(summary.skippedInvalid) skipped."
                                    }
                                    presentSourcesAlert(title: "Sources Restored", message: message)
                                }
                            }
                        }
                    } catch {
                        presentSourcesAlert(title: "Restore Failed", message: error.localizedDescription)
                    }
                case .failure(let error):
                    presentSourcesAlert(title: "Import Failed", message: error.localizedDescription)
                }
            }
            .alert(sourcesAlertTitle, isPresented: $showingSourcesAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(sourcesAlertMessage)
            }
            .alert("Add Source", isPresented: $showingAddSource) {
                TextField("URL", text: $newSourceURL)
                    .keyboardType(.URL)
                Button("Add", action: {
                    let trimmed = newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard isValidSourceURL(trimmed) else {
                        validationMessage = "Enter a valid http(s) repository URL (e.g. https://havoc.app/)."
                        showingValidationAlert = true
                        return
                    }
                    repoManager.addSource(url: trimmed)
                    newSourceURL = "https://"
                })
                Button("Cancel", role: .cancel, action: {
                    newSourceURL = "https://"
                })
            } message: {
                Text("Enter the APT repository URL (e.g. https://havoc.app/).")
            }
            .alert("Edit Source", isPresented: Binding(
                get: { editingSource != nil },
                set: { if !$0 { editingSource = nil } }
            )) {
                TextField("URL", text: $editedURL)
                    .keyboardType(.URL)
                Button("Save", action: {
                    guard isValidSourceURL(editedURL) else {
                        validationMessage = "Enter a valid http(s) repository URL."
                        showingValidationAlert = true
                        return
                    }
                    if let source = editingSource {
                        repoManager.editSource(oldURL: source.url, newURL: editedURL)
                    }
                    editingSource = nil
                })
                Button("Cancel", role: .cancel, action: {
                    editingSource = nil
                })
            } message: {
                Text("Update the APT repository URL.")
            }
            .alert("Invalid URL", isPresented: $showingValidationAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage)
            }
        }
    }

    private func isValidSourceURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 10,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return false }
        return true
    }

    private func presentSourcesAlert(title: String, message: String) {
        sourcesAlertTitle = title
        sourcesAlertMessage = message
        showingSourcesAlert = true
    }
}
