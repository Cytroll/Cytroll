import SwiftUI

public struct ChangesView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var queueManager = QueueManager.shared
    @StateObject private var viewModel = ChangesViewModel()

    public init() {}

    public var body: some View {
        NavigationView {
            ZStack {
                themeManager.backgroundGradient().ignoresSafeArea()

                if viewModel.updates.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 60))
                            .foregroundColor(themeManager.currentTheme.accent.opacity(0.8))
                        Text(viewModel.isRefreshing ? "Checking for Updates..." : "All Packages are Up to Date")
                            .font(.headline)
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                    }
                } else {
                    List {
                        Section(header: Text("Available Updates").foregroundColor(themeManager.currentTheme.textSecondary)) {
                            ForEach(viewModel.updates) { update in
                                HStack {
                                    // Package Icon
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(themeManager.currentTheme.cardBackground)
                                            .frame(width: 44, height: 44)
                                        Image(systemName: "shippingbox.fill")
                                            .foregroundColor(themeManager.currentTheme.accent)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(update.name)
                                            .font(.headline)
                                            .foregroundColor(themeManager.currentTheme.textPrimary)
                                        HStack(spacing: 4) {
                                            Text(update.installedVersion)
                                                .font(.caption)
                                                .foregroundColor(themeManager.currentTheme.textSecondary)
                                            Image(systemName: "arrow.right")
                                                .font(.caption2)
                                                .foregroundColor(themeManager.currentTheme.accent)
                                            Text(update.candidateVersion)
                                                .font(.caption.bold())
                                                .foregroundColor(themeManager.currentTheme.accent)
                                        }
                                    }
                                    Spacer()

                                    Button(action: {
                                        withAnimation(.spring()) {
                                            queueManager.addOrUpdate(package: update.repoPackage, action: .upgrade)
                                        }
                                    }) {
                                        Text("GET")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(themeManager.currentTheme.accent.opacity(0.15))
                                            .foregroundColor(themeManager.currentTheme.accent)
                                            .cornerRadius(12)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .refreshable {
                await withCheckedContinuation { continuation in
                    viewModel.loadUpdates {
                        continuation.resume()
                    }
                }
            }
            .navigationTitle("Changes")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !viewModel.updates.isEmpty {
                        Button(action: upgradeAll) {
                            Text("Upgrade All")
                                .font(.headline)
                                .foregroundColor(themeManager.currentTheme.accent)
                        }
                    }
                }
            }
        }
    }

    private func upgradeAll() {
        withAnimation(.spring()) {
            for update in viewModel.updates {
                queueManager.addOrUpdate(package: update.repoPackage, action: .upgrade)
            }
        }
    }
}
