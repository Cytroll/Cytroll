import SwiftUI

public struct SourcesView: View {
    @StateObject private var repoManager = RepositoryManager.shared
    @StateObject private var themeManager = ThemeManager.shared
    
    @State private var showingAddSource = false
    @State private var newSourceURL = "https://"

    @State private var editingSource: Source?
    @State private var editedURL = ""
    @State private var showingValidationAlert = false
    @State private var validationMessage = ""
    
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
                    Button(action: { showingAddSource = true }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(themeManager.currentTheme.accent)
                    }
                    .disabled(repoManager.isRefreshing)
                }
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
}
