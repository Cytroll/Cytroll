import SwiftUI

/// Shows how much space `AppInjectionManager`'s per-app backups are using
/// — one pristine backup per currently-injected app — plus any orphaned
/// leftovers (e.g. from an app uninstalled while injected) with a
/// one-tap cleanup.
public struct InjectionBackupStorageView: View {
    @StateObject private var themeManager = ThemeManager.shared

    @State private var entries: [BackupStorageEntry] = []
    @State private var orphanedDirs: [String] = []
    @State private var isLoading = true
    @State private var isCleaning = false

    public init() {}

    public var body: some View {
        ZStack {
            themeManager.backgroundGradient().ignoresSafeArea()

            if isLoading {
                ProgressView("Scanning backups…")
                    .tint(themeManager.currentTheme.accent)
            } else {
                List {
                    Section(header: Text("Active Backups").foregroundColor(themeManager.currentTheme.textSecondary)) {
                        if entries.isEmpty {
                            Text("No apps are currently injected.")
                                .font(.subheadline)
                                .foregroundColor(themeManager.currentTheme.textSecondary)
                        } else {
                            ForEach(entries) { entry in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.displayName)
                                            .font(.subheadline.bold())
                                            .foregroundColor(themeManager.currentTheme.textPrimary)
                                        Text(entry.bundleID)
                                            .font(.caption2)
                                            .foregroundColor(themeManager.currentTheme.textSecondary)
                                    }
                                    Spacer()
                                    Text(formatted(entry.sizeBytes))
                                        .font(.caption)
                                        .foregroundColor(themeManager.currentTheme.textSecondary)
                                }
                            }
                            .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                        }
                    }

                    if !orphanedDirs.isEmpty {
                        Section(
                            header: Text("Orphaned").foregroundColor(themeManager.currentTheme.textSecondary),
                            footer: Text("Leftover backup folders with no matching active injection — most likely from an app that was uninstalled while injected. Safe to remove.")
                        ) {
                            Button(action: cleanOrphaned) {
                                HStack {
                                    if isCleaning { ProgressView().tint(.red) }
                                    Text("Clean \(orphanedDirs.count) Orphaned Folder\(orphanedDirs.count == 1 ? "" : "s")")
                                }
                            }
                            .foregroundColor(.red)
                            .disabled(isCleaning)
                        }
                        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                    }

                    Section {
                        HStack {
                            Text("Total").font(.headline).foregroundColor(themeManager.currentTheme.textPrimary)
                            Spacer()
                            Text(formatted(totalSize)).font(.headline).foregroundColor(themeManager.currentTheme.textPrimary)
                        }
                    }
                    .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Backup Storage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    private var totalSize: Int64 {
        entries.reduce(0) { $0 + $1.sizeBytes }
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func reload() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let (entries, orphaned) = InjectionBackupStorage.scan()
            DispatchQueue.main.async {
                self.entries = entries
                self.orphanedDirs = orphaned
                self.isLoading = false
            }
        }
    }

    private func cleanOrphaned() {
        isCleaning = true
        let dirs = orphanedDirs
        DispatchQueue.global(qos: .userInitiated).async {
            InjectionBackupStorage.removeOrphaned(dirs)
            DispatchQueue.main.async {
                isCleaning = false
                reload()
            }
        }
    }
}
