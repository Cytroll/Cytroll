import SwiftUI

/// Cydia-style category browser — groups the merged installed+repo package
/// list by the Debian `Section:` field (already parsed by both
/// `AptIndexParser`/`DpkgStatusParser`, just never surfaced anywhere until
/// now). Pushed from `PackagesTabView`'s "Browse by Category" row, so it
/// shares that view's `NavigationView` — no nested navigation bars.
public struct CategoriesView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var packageIndex = PackageIndexStore.shared

    public init() {}

    private var categories: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for pkg in packageIndex.mergedPackages {
            counts[pkg.section, default: 0] += 1
        }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    public var body: some View {
        ZStack {
            themeManager.backgroundGradient().ignoresSafeArea()

            if categories.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 48))
                        .foregroundColor(themeManager.currentTheme.textSecondary.opacity(0.6))
                    Text("No Categories Found")
                        .font(.headline)
                        .foregroundColor(themeManager.currentTheme.textSecondary)
                }
            } else {
                List {
                    ForEach(categories, id: \.name) { category in
                        NavigationLink(destination: CategoryPackagesView(categoryName: category.name)) {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(themeManager.currentTheme.accent)
                                Text(category.name)
                                    .foregroundColor(themeManager.currentTheme.textPrimary)
                                Spacer()
                                Text("\(category.count)")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(themeManager.currentTheme.accent.opacity(0.15))
                                    .foregroundColor(themeManager.currentTheme.accent)
                                    .cornerRadius(8)
                            }
                        }
                        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                    }
                }
                .listStyle(.insetGrouped)
                .cytrollHideScrollBackground()
            }
        }
        .navigationTitle("Categories")
        .onAppear { packageIndex.ensureLoaded() }
    }
}

/// Packages within a single category, reusing the shared `PackageRow` so
/// GET/MODIFY/hold state and Package Details navigation behave identically
/// to the main Packages tab.
private struct CategoryPackagesView: View {
    let categoryName: String

    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var packageIndex = PackageIndexStore.shared
    @StateObject private var queueManager = QueueManager.shared

    private var packages: [Package] {
        packageIndex.mergedPackages
            .filter { $0.section == categoryName }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var body: some View {
        ZStack {
            themeManager.backgroundGradient().ignoresSafeArea()

            List {
                ForEach(packages) { pkg in
                    PackageRow(package: pkg, theme: themeManager.currentTheme) { action in
                        withAnimation(.spring()) {
                            queueManager.addOrUpdate(package: pkg, action: action)
                        }
                    }
                    .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                }
            }
            .listStyle(.insetGrouped)
            .cytrollHideScrollBackground()
        }
        .navigationTitle(categoryName)
    }
}
