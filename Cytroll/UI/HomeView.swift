import SwiftUI

public struct HomeView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var bootstrapManager = BootstrapManager.shared
    
    public init() {}
    
    public var body: some View {
        NavigationView {
            ZStack {
                // MARK: - Dynamic Background
                themeManager.backgroundGradient().ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        if !bootstrapManager.isBootstrapInstalled {
                            bootstrapGatekeeper
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            smartDashboard
                                .transition(.slide.combined(with: .opacity))
                            activityLog
                                .transition(.slide.combined(with: .opacity))
                        }
                    }
                    .padding()
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: bootstrapManager.isBootstrapInstalled)
                }
            }
            .navigationTitle("Cytroll")
        }
    }
    
    // MARK: - Bootstrap Gatekeeper Subview
    @State private var selectedBootstrapVersion: BootstrapVersion = BootstrapVersion.forCurrentOS()
    
    private var bootstrapGatekeeper: some View {
        VStack(spacing: 24) {
            Image(systemName: "shield.checkerboard")
                .font(.system(size: 64, weight: .light))
                .foregroundColor(themeManager.currentTheme.accent)
            
            VStack(spacing: 8) {
                Text("Welcome to Cytroll")
                    .font(.title2.bold())
                    .foregroundColor(themeManager.currentTheme.textPrimary)
                
                Text("Rootless Environment Status")
                    .font(.subheadline)
                    .foregroundColor(themeManager.currentTheme.textSecondary)
            }
            
            HStack(spacing: 12) {
                Image(systemName: bootstrapManager.isBootstrapInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(bootstrapManager.isBootstrapInstalled ? .green : .red)
                    .font(.title3)
                
                Text(bootstrapManager.isBootstrapInstalled ? "Ready (\(RootlessPaths.effectivePrefix))" : "Not Found / Missing")
                    .font(.headline)
                    .foregroundColor(themeManager.currentTheme.textPrimary)
            }
            .padding(.vertical, 10)
            
            if !bootstrapManager.isBootstrapInstalled {
                if bootstrapManager.isInstalling {
                    VStack(spacing: 16) {
                        ProgressView(value: bootstrapManager.progress, total: 1.0)
                            .tint(themeManager.currentTheme.accent)
                            .scaleEffect(1.2, anchor: .center)
                        
                        Text("\(Int(bootstrapManager.progress * 100))%")
                            .font(.headline)
                            .foregroundColor(themeManager.currentTheme.accent)
                        
                        Text(bootstrapManager.logs.last ?? "Connecting to server...")
                            .font(.caption.monospaced())
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .padding(.top, 10)
                } else {
                    VStack(spacing: 16) {
                        Picker("Select Version", selection: $selectedBootstrapVersion) {
                            ForEach(BootstrapVersion.allCases) { version in
                                Text(version.rawValue).tag(version)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 4)
                        
                        Button(action: {
                            withAnimation {
                                bootstrapManager.setupBootstrap(version: selectedBootstrapVersion)
                            }
                        }) {
                            Text("Download & Install Bootstrap")
                                .font(.headline.bold())
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(themeManager.currentTheme.accent)
                                .cornerRadius(14)
                                .shadow(color: themeManager.currentTheme.accent.opacity(0.3), radius: 8, x: 0, y: 4)
                        }
                    }
                }
            }
        }
        .padding(24)
        .glassCard(theme: themeManager.currentTheme)
    }
    
    // MARK: - Smart Dashboard Subview
    private var smartDashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SMART DASHBOARD")
                .font(.caption.bold())
                .foregroundColor(themeManager.currentTheme.textSecondary)
                .tracking(1.5)
            
            HStack(spacing: 16) {
                DashboardMetric(title: "Status", value: "Active", icon: "checkmark.circle.fill", color: .green)
                DashboardMetric(title: "Packages", value: "142", icon: "shippingbox.fill", color: themeManager.currentTheme.accent)
            }
            
            Button(action: {
                // Smart Maintenance: dpkg --configure -a
                let bridge = CytrollCoreBridge()
                let _ = bridge.executeDpkg(arguments: ["--configure", "-a"])
            }) {
                HStack {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.title3)
                    Text("Smart Maintenance")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                }
                .foregroundColor(themeManager.currentTheme.accent)
                .padding()
                .background(themeManager.currentTheme.accent.opacity(0.15))
                .cornerRadius(12)
            }
        }
        .padding(20)
        .glassCard(theme: themeManager.currentTheme)
    }
    
    // MARK: - Activity Log Subview
    private var activityLog: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ACTIVITY LOG")
                .font(.caption.bold())
                .foregroundColor(themeManager.currentTheme.textSecondary)
                .tracking(1.5)
            
            VStack(alignment: .leading, spacing: 12) {
                ActivityRow(action: "Installed", package: "com.example.tweak", time: "2 mins ago", isSuccess: true)
                Divider().background(Color.white.opacity(0.1))
                ActivityRow(action: "Removed", package: "org.coolstar.sileo", time: "1 hr ago", isSuccess: true)
                Divider().background(Color.white.opacity(0.1))
                ActivityRow(action: "Upgraded", package: "apt", time: "Yesterday", isSuccess: true)
            }
        }
        .padding(20)
        .glassCard(theme: themeManager.currentTheme)
    }
}

// MARK: - Reusable Components
public struct DashboardMetric: View {
    @StateObject private var themeManager = ThemeManager.shared
    
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    public var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(color)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(themeManager.currentTheme.textSecondary)
                Text(value)
                    .font(.headline)
                    .foregroundColor(themeManager.currentTheme.textPrimary)
            }
            Spacer()
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }
}

public struct ActivityRow: View {
    @StateObject private var themeManager = ThemeManager.shared
    
    let action: String
    let package: String
    let time: String
    let isSuccess: Bool
    
    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(action)
                    .font(.caption.bold())
                    .foregroundColor(isSuccess ? .green : .red)
                Text(package)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(themeManager.currentTheme.textPrimary)
            }
            Spacer()
            Text(time)
                .font(.caption)
                .foregroundColor(themeManager.currentTheme.textSecondary)
        }
    }
}
