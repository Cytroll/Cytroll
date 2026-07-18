import SwiftUI
import UniformTypeIdentifiers

public struct HomeView: View {
    @StateObject private var themeManager = ThemeManager.shared
    // Singleton — ObservedObject (not StateObject) so we always track the shared instance.
    @ObservedObject private var bootstrapManager = BootstrapManager.shared
    @State private var showingBootstrapConsole = false
    @State private var showingOfflineArchiveImporter = false
    @State private var offlineImportAlertTitle = ""
    @State private var offlineImportAlertMessage = ""
    @State private var showingOfflineImportAlert = false
    
    public init() {}
    
    public var body: some View {
        NavigationView {
            ZStack {
                // MARK: - Dynamic Background
                themeManager.backgroundGradient().ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        if bootstrapManager.health != .healthy {
                            bootstrapGatekeeper
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            smartDashboard
                                .transition(.slide.combined(with: .opacity))
                            recentActivitySection
                                .transition(.slide.combined(with: .opacity))
                        }
                    }
                    .padding()
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: bootstrapManager.health)
                }
            }
            .navigationTitle("Cytroll")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showingBootstrapConsole) {
                LiveConsoleView(
                    isPresented: $showingBootstrapConsole,
                    isRunning: bootstrapManager.isBusy,
                    title: bootstrapManager.isDownloading ? "Downloading Bootstrap" : "Bootstrap"
                )
            }
            .fileImporter(
                isPresented: $showingOfflineArchiveImporter,
                allowedContentTypes: Self.offlineBootstrapContentTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let preserve = bootstrapManager.health == .broken
                    bootstrapManager.importOfflineArchiveAndBootstrap(
                        from: url,
                        preferredVersion: selectedBootstrapVersion,
                        preserveExisting: preserve
                    ) { importResult in
                        switch importResult {
                        case .success:
                            showingBootstrapConsole = true
                        case .failure(let error):
                            offlineImportAlertTitle = "Offline Import Failed"
                            offlineImportAlertMessage = error.localizedDescription
                            showingOfflineImportAlert = true
                        }
                    }
                case .failure(let error):
                    offlineImportAlertTitle = "Could Not Open File"
                    offlineImportAlertMessage = error.localizedDescription
                    showingOfflineImportAlert = true
                }
            }
            .alert(offlineImportAlertTitle, isPresented: $showingOfflineImportAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(offlineImportAlertMessage)
            }
        }
    }

    private static var offlineBootstrapContentTypes: [UTType] {
        var types: [UTType] = [.data, .archive]
        if let zst = UTType(filenameExtension: "zst") {
            types.insert(zst, at: 0)
        }
        if let tarZst = UTType(filenameExtension: "tar.zst") {
            types.insert(tarZst, at: 0)
        }
        return types
    }
    
    // MARK: - Bootstrap Gatekeeper Subview
    @State private var selectedBootstrapVersion: BootstrapVersion = BootstrapVersion.forCurrentOS()
    @State private var markAppeared = false

    /// Depends on `localArchiveRevision` so the CTA flips after download.
    private var hasLocalArchive: Bool {
        _ = bootstrapManager.localArchiveRevision
        return bootstrapManager.hasLocalArchive(for: selectedBootstrapVersion)
    }
    
    private var bootstrapGatekeeper: some View {
        VStack(spacing: 28) {
            // Glyph-style mark (transparent background) — same placement as
            // the old shield SF Symbol, not a nested app-icon tile.
            Image("CytrollMark")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 72, height: 72)
                .scaleEffect(markAppeared ? 1 : 0.86)
                .opacity(markAppeared ? 1 : 0)
                .allowsHitTesting(false)
            
            VStack(spacing: 8) {
                Text("Welcome to Cytroll")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(themeManager.currentTheme.textPrimary)
                
                Text("Procursus rootless bootstrap for your device.")
                    .font(.subheadline)
                    .foregroundColor(themeManager.currentTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(themeManager.currentTheme.textPrimary)
            }
            
            if bootstrapManager.isBusy {
                VStack(spacing: 14) {
                    ProgressView(value: bootstrapManager.progress, total: 1.0)
                        .tint(themeManager.currentTheme.accent)
                    
                    Text("\(Int(bootstrapManager.progress * 100))%")
                        .font(.headline)
                        .foregroundColor(themeManager.currentTheme.accent)
                    
                    Text(bootstrapManager.logs.last ?? (bootstrapManager.isDownloading ? "Downloading…" : "Bootstrapping…"))
                        .font(.caption.monospaced())
                        .foregroundColor(themeManager.currentTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)

                    Button("Open Live Console") {
                        showingBootstrapConsole = true
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(themeManager.currentTheme.accent)
                }
                .padding(.top, 4)
            } else {
                VStack(spacing: 16) {
                    Picker("Select Version", selection: $selectedBootstrapVersion) {
                        ForEach(BootstrapVersion.allCases) { version in
                            Text(version.rawValue).tag(version)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 4)

                    if bootstrapManager.health == .broken {
                        Text("A rootless tree exists at \(RootlessPaths.effectivePrefix) but is missing apt/dpkg. Repair re-extracts in place.")
                            .font(.caption)
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    bootstrapPrimaryButton
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                markAppeared = true
            }
        }
    }

    @ViewBuilder
    private var bootstrapPrimaryButton: some View {
        VStack(spacing: 10) {
            if !hasLocalArchive {
                VStack(spacing: 8) {
                    bootstrapCTAButton(
                        title: "Bootstrap",
                        color: themeManager.currentTheme.accent
                    ) {
                        showingBootstrapConsole = true
                        // No local archive — download from Procursus, then extract
                        // into /var/jb (full real install, not cache-only).
                        bootstrapManager.setupBootstrap(version: selectedBootstrapVersion)
                    }
                    Text("Downloads from apt.procurs.us, then installs into \(RootlessPaths.prefix)")
                        .font(.caption2)
                        .foregroundColor(themeManager.currentTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            } else if bootstrapManager.health == .broken {
                bootstrapCTAButton(
                    title: "Repair Bootstrap",
                    color: .orange
                ) {
                    showingBootstrapConsole = true
                    // Prefer local; fall back to download if the archive vanished.
                    bootstrapManager.repairBootstrap(version: selectedBootstrapVersion)
                }
            } else {
                bootstrapCTAButton(
                    title: "Bootstrap",
                    color: themeManager.currentTheme.accent
                ) {
                    showingBootstrapConsole = true
                    // Local first, network fallback — same reliable path as before the split.
                    bootstrapManager.setupBootstrap(version: selectedBootstrapVersion)
                }
            }

            // Offline path: pick a pre-downloaded Procursus archive from Files
            // without growing the .tipa.
            Button {
                showingOfflineArchiveImporter = true
            } label: {
                Text(bootstrapManager.health == .broken
                     ? "Repair from Offline Archive…"
                     : "Use Offline Archive…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(themeManager.currentTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .disabled(bootstrapManager.isBusy || CytrollOperationGate.shared.isBusy)

            Text("Choose bootstrap_\(selectedBootstrapVersion.rawValue).tar.zst from Files / AirDrop when the network is weak.")
                .font(.caption2)
                .foregroundColor(themeManager.currentTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private func bootstrapCTAButton(
        title: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline.bold())
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(color)
                .cornerRadius(14)
                // Entire colored rect must be tappable — not just the text glyphs.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(bootstrapManager.isBusy)
    }

    private var statusColor: Color {
        switch bootstrapManager.health {
        case .healthy: return .green
        case .broken: return .orange
        case .missing: return .red
        }
    }

    private var statusText: String {
        switch bootstrapManager.health {
        case .healthy: return "Ready (\(RootlessPaths.effectivePrefix))"
        case .broken: return "Detected but Incomplete"
        case .missing: return "Not Found / Missing"
        }
    }
    
    // MARK: - Smart Dashboard Subview
    @StateObject private var queueManager = QueueManager.shared
    @StateObject private var diagnostics = DiagnosticsManager.shared
    @StateObject private var packageIndex = PackageIndexStore.shared
    @ObservedObject private var jailbreakUtils = JailbreakUtilities.shared
    @State private var showingMaintenanceConsole = false
    @State private var showingEnterSafeModeConfirm = false
    @State private var showingExitSafeModeConfirm = false

    /// Smart Maintenance and a queued install/remove transaction both drive
    /// dpkg — running them at the same time risks two dpkg processes
    /// fighting over its lock (or a package half-configured mid-transaction).
    private var isSystemBusy: Bool {
        queueManager.isProcessing || diagnostics.isRepairing || CytrollOperationGate.shared.isBusy
    }

    private var smartDashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SMART DASHBOARD")
                .font(.caption.bold())
                .foregroundColor(themeManager.currentTheme.textSecondary)
                .tracking(1.5)
            
            HStack(spacing: 16) {
                DashboardMetric(
                    title: "Status",
                    value: jailbreakUtils.tweaksEnabled ? "Active" : "Safe Mode",
                    icon: jailbreakUtils.tweaksEnabled ? "checkmark.circle.fill" : "shield.fill",
                    color: jailbreakUtils.tweaksEnabled ? .green : .orange
                )
                DashboardMetric(title: "Packages", value: "\(packageIndex.installedPackages.count)", icon: "shippingbox.fill", color: themeManager.currentTheme.accent)
            }

            // Global Safe Mode — first-class stability escape hatch.
            Button(action: {
                if jailbreakUtils.tweaksEnabled {
                    showingEnterSafeModeConfirm = true
                } else {
                    showingExitSafeModeConfirm = true
                }
            }) {
                HStack(spacing: 12) {
                    Image(systemName: jailbreakUtils.tweaksEnabled ? "shield.slash.fill" : "shield.checkered")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(jailbreakUtils.isUpdatingSafeMode
                              ? "Updating…"
                              : (jailbreakUtils.tweaksEnabled ? "Enter Safe Mode" : "Safe Mode Active"))
                            .font(.headline)
                        Text(jailbreakUtils.tweaksEnabled
                              ? "Disable all Substrate/ElleKit tweaks instantly"
                              : "Tweaks are off — tap to re-enable")
                            .font(.caption2)
                            .opacity(0.9)
                    }
                    Spacer()
                    if jailbreakUtils.isUpdatingSafeMode {
                        ProgressView().tint(.white)
                    }
                }
                .foregroundColor(.white)
                .padding()
                .background(jailbreakUtils.tweaksEnabled ? Color.orange : Color.green.opacity(0.85))
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .disabled(jailbreakUtils.isUpdatingSafeMode)
            .contentShape(Rectangle())
            
            NavigationLink(destination: AppManagerView()) {
                HStack {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.title3)
                    Text("App Manager")
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

            NavigationLink(destination: StorageHealthView()) {
                HStack {
                    Image(systemName: "internaldrive.fill")
                        .font(.title3)
                    Text("Storage & Health")
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

            Button(action: {
                guard !isSystemBusy else { return }
                ConsoleManager.shared.clear()
                showingMaintenanceConsole = true
                // Full repair: dpkg --configure -a then apt --fix-broken
                diagnostics.runFullDiagnostics { _ in }
            }) {
                HStack {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.title3)
                    Text(diagnostics.isRepairing ? "Running..." : "Smart Maintenance")
                        .font(.headline)
                    Spacer()
                    if !isSystemBusy {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.bold))
                    }
                }
                .foregroundColor(themeManager.currentTheme.accent)
                .padding()
                .background(themeManager.currentTheme.accent.opacity(0.15))
                .cornerRadius(12)
            }
            .disabled(isSystemBusy)
            .opacity(isSystemBusy ? 0.6 : 1.0)

            if queueManager.isProcessing {
                Text("A package transaction is running — maintenance will be available once it finishes.")
                    .font(.caption2)
                    .foregroundColor(themeManager.currentTheme.textSecondary)
            }
        }
        .padding(20)
        .glassCard(theme: themeManager.currentTheme)
        .onAppear {
            packageIndex.ensureLoaded()
            jailbreakUtils.refreshTweaksState()
            // Keep essential repos present even if the user installed an
            // older Cytroll build that only seeded Procursus (+ ElleKit).
            RepositoryManager.shared.ensureEssentialSources()
        }
        .fullScreenCover(isPresented: $showingMaintenanceConsole) {
            LiveConsoleView(
                isPresented: $showingMaintenanceConsole,
                isRunning: diagnostics.isRepairing,
                title: "Smart Maintenance"
            )
        }
        .confirmationDialog(
            "Enter Global Safe Mode?",
            isPresented: $showingEnterSafeModeConfirm,
            titleVisibility: .visible
        ) {
            Button("Safe Mode + Respring", role: .destructive) {
                jailbreakUtils.enterGlobalSafeMode(thenRespring: true)
            }
            Button("Safe Mode Only") {
                jailbreakUtils.enterGlobalSafeMode(thenRespring: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Disables all Substrate/ElleKit tweaks via \(RootlessPaths.disableTweaksFlag). Respring applies it immediately.")
        }
        .confirmationDialog(
            "Exit Safe Mode?",
            isPresented: $showingExitSafeModeConfirm,
            titleVisibility: .visible
        ) {
            Button("Enable Tweaks + Respring") {
                jailbreakUtils.exitGlobalSafeMode(thenRespring: true)
            }
            Button("Enable Tweaks Only") {
                jailbreakUtils.exitGlobalSafeMode(thenRespring: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Re-enables global tweak injection. Respring to load tweaks again.")
        }
    }
    
    // MARK: - Activity Log Subview
    @StateObject private var activityLogManager = ActivityLogManager.shared

    private var recentActivitySection: some View {
        let recentEntries = Array(activityLogManager.entries.prefix(5))

        return VStack(alignment: .leading, spacing: 16) {
            Text("ACTIVITY LOG")
                .font(.caption.bold())
                .foregroundColor(themeManager.currentTheme.textSecondary)
                .tracking(1.5)

            if recentEntries.isEmpty {
                Text("No package actions yet. Installs, removes, and upgrades will show up here.")
                    .font(.caption)
                    .foregroundColor(themeManager.currentTheme.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(recentEntries.enumerated()), id: \.element.id) { index, entry in
                        ActivityRow(action: entry.action, package: entry.packageName, time: relativeTime(entry.timestamp), isSuccess: entry.success)
                        if index < recentEntries.count - 1 {
                            Divider().background(Color.white.opacity(0.1))
                        }
                    }
                }
            }
        }
        .padding(20)
        .glassCard(theme: themeManager.currentTheme)
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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
