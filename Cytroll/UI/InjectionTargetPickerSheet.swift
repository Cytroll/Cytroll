import SwiftUI

/// Identity is the tweak's ID (stable), not a fresh UUID per update — the
/// sheet is presented immediately with an empty `apps` list while
/// scanning runs in the background, then updated in place once results
/// arrive.
struct InjectionRequestContext: Identifiable {
    var id: String { tweak.id }
    let tweak: TweakInfo
    var apps: [InstalledAppInfo]
    var headerNote: String
}

/// Sheet listing candidate apps for a tweak/dylib — either the ones it
/// explicitly declares support for (`Filter -> Bundles`) or, failing
/// that, every installed app. Supports selecting multiple apps at once.
struct InjectionTargetPickerSheet: View {
    let tweak: TweakInfo
    let apps: [InstalledAppInfo]
    let headerNote: String
    let isLoading: Bool
    let onConfirm: ([InstalledAppInfo]) -> Void

    @StateObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBundleIDs: Set<String> = []
    @State private var showingConfirmation = false
    @State private var searchText = ""

    private var filteredApps: [InstalledAppInfo] {
        guard !searchText.isEmpty else { return apps }
        return apps.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                themeManager.backgroundGradient().ignoresSafeArea()

                if isLoading {
                    ProgressView("Scanning installed apps…")
                        .tint(themeManager.currentTheme.accent)
                } else if apps.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "questionmark.app")
                            .font(.system(size: 40))
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                        Text("No installed app matches this tweak's Filter.")
                            .font(.subheadline)
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    VStack(spacing: 0) {
                        List {
                            Section {
                                ForEach(filteredApps) { app in
                                    Button(action: { toggle(app) }) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(app.displayName)
                                                    .font(.headline)
                                                    .foregroundColor(themeManager.currentTheme.textPrimary)
                                                Text("\(app.bundleID) · v\(app.version)")
                                                    .font(.caption2)
                                                    .foregroundColor(themeManager.currentTheme.textSecondary)
                                            }
                                            Spacer()
                                            Image(systemName: selectedBundleIDs.contains(app.bundleID) ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(selectedBundleIDs.contains(app.bundleID) ? themeManager.currentTheme.accent : themeManager.currentTheme.textSecondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                Text(headerNote)
                            } footer: {
                                Text("Select one or more apps, then confirm. A pristine backup is taken first; the live app is only swapped after a verified rebuild.")
                            }
                            .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                        }
                        .listStyle(.insetGrouped)
                        .cytrollHideScrollBackground()
                        .searchable(text: $searchText, prompt: "Search apps")

                        Button(action: { showingConfirmation = true }) {
                            Text(selectedBundleIDs.isEmpty ? "Select at Least One App" : "Inject Into \(selectedBundleIDs.count) App\(selectedBundleIDs.count == 1 ? "" : "s")")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                        .background(selectedBundleIDs.isEmpty ? themeManager.currentTheme.textSecondary.opacity(0.3) : themeManager.currentTheme.accent)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .disabled(selectedBundleIDs.isEmpty)
                        .padding()
                    }
                }
            }
            .navigationTitle("Inject \(tweak.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert(
                "Inject Into \(selectedBundleIDs.count) App\(selectedBundleIDs.count == 1 ? "" : "s")?",
                isPresented: $showingConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Inject", role: .destructive) {
                    onConfirm(apps.filter { selectedBundleIDs.contains($0.bundleID) })
                }
            } message: {
                Text("Patches each selected app to load \(tweak.name). Restart the app after injection. Third-party apps only.")
            }
        }
    }

    private func toggle(_ app: InstalledAppInfo) {
        if selectedBundleIDs.contains(app.bundleID) {
            selectedBundleIDs.remove(app.bundleID)
        } else {
            selectedBundleIDs.insert(app.bundleID)
        }
    }
}
