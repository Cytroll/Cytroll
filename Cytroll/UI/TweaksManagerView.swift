import SwiftUI

public struct TweaksManagerView: View {
    @StateObject private var tweakManager = TweakInjectionManager.shared
    @StateObject private var themeManager = ThemeManager.shared
    
    public init() {}
    
    public var body: some View {
        ZStack {
            themeManager.backgroundGradient().ignoresSafeArea()
            
            if tweakManager.installedTweaks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 50))
                        .foregroundColor(themeManager.currentTheme.textSecondary)
                    Text("No Tweaks Found")
                        .font(.headline)
                        .foregroundColor(themeManager.currentTheme.textPrimary)
                    Text("Install tweaks from the Packages tab.")
                        .font(.subheadline)
                        .foregroundColor(themeManager.currentTheme.textSecondary)
                }
            } else {
                List {
                    ForEach(tweakManager.installedTweaks) { tweak in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tweak.name)
                                    .font(.headline)
                                    .foregroundColor(themeManager.currentTheme.textPrimary)
                                Text(tweak.isEnabled ? "Enabled" : "Disabled")
                                    .font(.caption)
                                    .foregroundColor(tweak.isEnabled ? .green : .red)
                            }
                            
                            Spacer()
                            
                            Toggle("", isOn: Binding(
                                get: { tweak.isEnabled },
                                set: { newValue in
                                    tweakManager.toggleTweak(tweak, enable: newValue) { _ in }
                                }
                            ))
                            .tint(themeManager.currentTheme.accent)
                            .disabled(tweakManager.isProcessing)
                        }
                        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Tweak Injector")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            tweakManager.refreshTweaks()
        }
    }
}
