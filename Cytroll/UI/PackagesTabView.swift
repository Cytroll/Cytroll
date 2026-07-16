import SwiftUI

public struct PackagesTabView: View {
    @StateObject private var viewModel = PackagesViewModel()
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var queueManager = QueueManager.shared
    
    public init() {}
    
    public var body: some View {
        NavigationView {
            ZStack {
                themeManager.backgroundGradient().ignoresSafeArea()
                
                List {
                    NavigationLink(destination: CategoriesView()) {
                        HStack {
                            Image(systemName: "square.grid.2x2.fill")
                                .foregroundColor(themeManager.currentTheme.accent)
                            Text("Browse by Category")
                                .foregroundColor(themeManager.currentTheme.textPrimary)
                        }
                    }
                    .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))

                    ForEach(viewModel.filteredPackages) { pkg in
                        PackageRow(package: pkg, theme: themeManager.currentTheme) { action in
                            // Adding to queue with animation triggers the ContentView's Floating Queue Bar dynamically
                            withAnimation(.spring()) {
                                queueManager.addOrUpdate(package: pkg, action: action)
                            }
                        }
                        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                    }
                }
                .listStyle(.insetGrouped)
                .cytrollHideScrollBackground()
                .refreshable {
                    await withCheckedContinuation { continuation in
                        viewModel.refresh { continuation.resume() }
                    }
                }
            }
            .navigationTitle("Packages")
            .searchable(text: $viewModel.searchQuery, prompt: "Search Tweaks & Apps")
        }
    }
}

// MARK: - Reusable Package Row Component
public struct PackageRow: View {
    let package: Package
    let theme: ThemeProtocol
    let onQueueAction: (QueueAction) -> Void

    @StateObject private var holdManager = PackageHoldManager.shared

    public var body: some View {
        HStack(spacing: 16) {
            NavigationLink(destination: PackageDetailView(package: package)) {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(theme.accent.opacity(0.15))
                            .frame(width: 48, height: 48)
                        Image(systemName: "shippingbox.fill")
                            .foregroundColor(theme.accent)
                            .font(.title2)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(package.name)
                                .font(.headline)
                                .foregroundColor(theme.textPrimary)

                            if package.isBroken {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption2)
                            } else if package.isInstalled {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption2)
                            }
                            if holdManager.isHeld(package.id) {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption2)
                            }
                        }

                        Text("\(package.version) • \(package.author)")
                            .font(.caption)
                            .foregroundColor(theme.textSecondary)
                        Text(package.description)
                            .font(.caption2)
                            .foregroundColor(theme.textSecondary.opacity(0.8))
                            .lineLimit(1)

                        if let source = package.sourceURL {
                            Text(source)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundColor(theme.accent.opacity(0.8))
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()
            
            Menu {
                if !package.isInstalled {
                    Button(action: { onQueueAction(.install) }) {
                        Label("Install", systemImage: "arrow.down.circle")
                    }
                } else {
                    Button(action: { onQueueAction(.reinstall) }) {
                        Label("Reinstall", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button(role: .destructive, action: { onQueueAction(.remove) }) {
                        Label("Remove", systemImage: "trash")
                    }
                }
                // Upgrade option could be conditionally added here if version comparison is implemented
            } label: {
                Text(package.isInstalled ? "MODIFY" : "GET")
                    .font(.caption.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(package.isInstalled ? theme.cardBackground : theme.accent)
                    .foregroundColor(package.isInstalled ? theme.accent : .white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(theme.accent, lineWidth: package.isInstalled ? 1 : 0)
                    )
                    .cornerRadius(12)
            }
        }
        .padding(.vertical, 6)
    }
}
