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
                .scrollContentBackground(.hidden)
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
    
    public var body: some View {
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
                Text(package.name)
                    .font(.headline)
                    .foregroundColor(theme.textPrimary)
                Text("\(package.version) • \(package.author)")
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
                Text(package.description)
                    .font(.caption2)
                    .foregroundColor(theme.textSecondary.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer()
            
            Menu {
                Button(action: { onQueueAction(.install) }) {
                    Label("Install", systemImage: "arrow.down.circle")
                }
                Button(action: { onQueueAction(.upgrade) }) {
                    Label("Upgrade", systemImage: "arrow.up.circle")
                }
                Button(action: { onQueueAction(.reinstall) }) {
                    Label("Reinstall", systemImage: "arrow.triangle.2.circlepath")
                }
                Button(role: .destructive, action: { onQueueAction(.remove) }) {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Text("GET")
                    .font(.caption.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(theme.accent)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
        .padding(.vertical, 6)
    }
}
