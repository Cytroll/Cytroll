import SwiftUI

public struct ChangesView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var queueManager = QueueManager.shared
    
    // Mock updates for UI demonstration. In production, this links to DpkgStatusParser comparing with AptIndexParser
    @State private var updatablePackages: [Package] = [
        Package(id: "com.ellekit.ellekit", name: "ElleKit", version: "1.1.2", description: "Tweak Injection framework.", architecture: "iphoneos-arm64", author: "evelyneee", section: "System"),
        Package(id: "org.coolstar.sileo", name: "Sileo", version: "2.5", description: "Modern package manager.", architecture: "iphoneos-arm64", author: "Sileo Team", section: "System")
    ]
    
    public init() {}
    
    public var body: some View {
        NavigationView {
            ZStack {
                themeManager.backgroundGradient().ignoresSafeArea()
                
                if updatablePackages.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 60))
                            .foregroundColor(themeManager.currentTheme.accent.opacity(0.8))
                        Text("All Packages are Up to Date")
                            .font(.headline)
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                    }
                } else {
                    List {
                        Section(header: Text("Available Updates").foregroundColor(themeManager.currentTheme.textSecondary)) {
                            ForEach(updatablePackages) { pkg in
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
                                        Text(pkg.name)
                                            .font(.headline)
                                            .foregroundColor(themeManager.currentTheme.textPrimary)
                                        HStack(spacing: 4) {
                                            Text(pkg.version) // Current mock version
                                                .font(.caption)
                                                .foregroundColor(themeManager.currentTheme.textSecondary)
                                            Image(systemName: "arrow.right")
                                                .font(.caption2)
                                                .foregroundColor(themeManager.currentTheme.accent)
                                            Text("\(pkg.version)-1") // Updated version mock
                                                .font(.caption.bold())
                                                .foregroundColor(themeManager.currentTheme.accent)
                                        }
                                    }
                                    Spacer()
                                    
                                    Button(action: {
                                        queueManager.enqueue(package: pkg, action: .upgrade)
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
            .navigationTitle("Changes")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !updatablePackages.isEmpty {
                        Button(action: { upgradeAll() }) {
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
        for pkg in updatablePackages {
            queueManager.enqueue(package: pkg, action: .upgrade)
        }
    }
}
