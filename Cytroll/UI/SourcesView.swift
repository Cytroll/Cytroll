import SwiftUI

public struct SourcesView: View {
    @StateObject private var repoManager = RepositoryManager.shared
    @StateObject private var themeManager = ThemeManager.shared
    
    @State private var showingAddSource = false
    @State private var newSourceURL = "https://"
    
    public init() {}
    
    public var body: some View {
        NavigationView {
            ZStack {
                themeManager.backgroundGradient().ignoresSafeArea()
                
                List {
                    ForEach(repoManager.sources) { source in
                        HStack(spacing: 16) {
                            // Source Icon Placeholder
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
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .refreshable {
                    // Simulating a fast APT index update process
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) {
                            // In a real scenario, this would trigger AptIndexParser to refresh sources
                            DispatchQueue.main.async {
                                continuation.resume()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sources")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingAddSource = true }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(themeManager.currentTheme.accent)
                    }
                }
            }
            .alert("Add Source", isPresented: $showingAddSource) {
                TextField("URL", text: $newSourceURL)
                    .keyboardType(.URL)
                Button("Add", action: {
                    repoManager.addSource(url: newSourceURL)
                    newSourceURL = "https://"
                })
                Button("Cancel", role: .cancel, action: {
                    newSourceURL = "https://"
                })
            } message: {
                Text("Enter the APT repository URL.")
            }
        }
    }
}
