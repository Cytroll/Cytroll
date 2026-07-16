import SwiftUI

public struct TweaksManagerView: View {
    @StateObject private var tweakManager = TweakInjectionManager.shared
    @StateObject private var injectionManager = AppInjectionManager.shared
    @StateObject private var recordStore = InjectionRecordStore.shared
    @StateObject private var themeManager = ThemeManager.shared

    @State private var injectionSheetTweak: TweakInfo?
    @State private var candidateApps: [InstalledAppInfo] = []
    @State private var isLoadingCandidates = false

    @State private var showingInjectionConsole = false
    @State private var lastInjectionErrorMessage: String?
    @State private var showingInjectionError = false

    public init() {}

    public var body: some View {
        ZStack {
            themeManager.backgroundGradient().ignoresSafeArea()

            if tweakManager.installedTweaks.isEmpty && recordStore.records.isEmpty {
                emptyState
            } else {
                List {
                    tweaksSection
                    if !recordStore.records.isEmpty {
                        injectedAppsSection
                    }
                    perAppInjectionDisclaimer
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Tweak Injector")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            tweakManager.refreshTweaks()
            recordStore.refreshNeedsReapplyFlags()
        }
        .sheet(item: $injectionSheetTweak) { tweak in
            InjectionTargetPickerSheet(
                tweak: tweak,
                candidateApps: candidateApps,
                isLoading: isLoadingCandidates,
                onConfirm: { app in
                    injectionSheetTweak = nil
                    startInjection(tweak: tweak, app: app)
                }
            )
        }
        .fullScreenCover(isPresented: $showingInjectionConsole) {
            LiveConsoleView(
                isPresented: $showingInjectionConsole,
                isRunning: injectionManager.isProcessing,
                title: "Tweak Injection"
            )
        }
        .alert("Injection Failed", isPresented: $showingInjectionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lastInjectionErrorMessage ?? "Unknown error.")
        }
    }

    // MARK: - Sections

    private var emptyState: some View {
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
    }

    private var tweaksSection: some View {
        Section(header: Text("Installed Tweaks").foregroundColor(themeManager.currentTheme.textSecondary)) {
            ForEach(tweakManager.installedTweaks) { tweak in
                VStack(alignment: .leading, spacing: 8) {
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

                    if tweak.filterBundleIDs.isEmpty {
                        Text("No app-injection Filter found in this tweak's plist.")
                            .font(.caption2)
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                    } else {
                        Button(action: { presentInjectionSheet(for: tweak) }) {
                            HStack {
                                Image(systemName: "syringe.fill")
                                Text("Inject Into App…")
                            }
                            .font(.caption.bold())
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(tweak.isEnabled ? themeManager.currentTheme.accent : themeManager.currentTheme.textSecondary)
                        .disabled(injectionManager.isProcessing || !tweak.isEnabled)
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
            }
        }
    }

    private var injectedAppsSection: some View {
        Section(header: Text("Injected Apps").foregroundColor(themeManager.currentTheme.textSecondary)) {
            ForEach(recordStore.records) { record in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.appDisplayName)
                                .font(.subheadline.bold())
                                .foregroundColor(themeManager.currentTheme.textPrimary)
                            Text("Tweak: \(record.tweakName)")
                                .font(.caption2)
                                .foregroundColor(themeManager.currentTheme.textSecondary)
                        }
                        Spacer()
                        statusBadge(for: record.status)
                    }

                    HStack {
                        // `.failed` means AppInjectionManager's own rollback
                        // didn't fully complete and the app may be
                        // inconsistent — force "Restore Original" as the
                        // only next step rather than offering a re-inject
                        // that would just be rejected (and could otherwise
                        // stack a fresh backup on top of an unclear state).
                        if record.status == .needsReapply {
                            Button("Re-inject") {
                                reapply(record: record)
                            }
                            .font(.caption.bold())
                            .foregroundColor(themeManager.currentTheme.accent)
                            .disabled(injectionManager.isProcessing)
                        }
                        Spacer()
                        Button("Restore Original") {
                            injectionManager.restore(record) { _ in }
                        }
                        .font(.caption.bold())
                        .foregroundColor(.red)
                        .disabled(injectionManager.isProcessing)
                    }
                    if record.status == .failed {
                        Text("A previous injection attempt didn't fully undo itself. Restore this app before trying again.")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
            }
        }
    }

    private var perAppInjectionDisclaimer: some View {
        Section {
            Text("Per-app injection only works on third-party apps, breaks silently after that app updates (look for \"Needs Reapply\" above), and needs the app restarted to take effect. It never touches Apple's own apps or SpringBoard.")
                .font(.caption2)
                .foregroundColor(themeManager.currentTheme.textSecondary)
        }
        .listRowBackground(Color.clear)
    }

    private func statusBadge(for status: InjectionStatus) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .active: return ("Active", .green)
            case .needsReapply: return ("Needs Reapply", .orange)
            case .failed: return ("Failed", .red)
            }
        }()
        return Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    // MARK: - Actions

    private func presentInjectionSheet(for tweak: TweakInfo) {
        isLoadingCandidates = true
        candidateApps = []
        injectionSheetTweak = tweak
        tweakManager.candidateApps(for: tweak) { apps in
            candidateApps = apps
            isLoadingCandidates = false
        }
    }

    private func startInjection(tweak: TweakInfo, app: InstalledAppInfo) {
        ConsoleManager.shared.clear()
        showingInjectionConsole = true
        injectionManager.inject(tweak: tweak, into: app) { result in
            if case .failure(let error) = result {
                lastInjectionErrorMessage = error.localizedDescription
                showingInjectionError = true
            }
        }
    }

    private func reapply(record: InjectionRecord) {
        guard let tweak = tweakManager.installedTweaks.first(where: { $0.id == record.tweakID }) else {
            lastInjectionErrorMessage = "This tweak is no longer installed."
            showingInjectionError = true
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let app = InstalledAppScanner.shared.app(withBundleID: record.bundleID)
            DispatchQueue.main.async {
                guard let app = app else {
                    lastInjectionErrorMessage = "This app is no longer installed."
                    showingInjectionError = true
                    return
                }
                startInjection(tweak: tweak, app: app)
            }
        }
    }
}

/// Sheet listing ONLY the installed apps that match a tweak's `Filter`
/// (never the full installed-apps list) — per the plan's "opt-in, explicit
/// target selection" decision. Confirming an app shows a clear warning
/// before any file is touched.
private struct InjectionTargetPickerSheet: View {
    let tweak: TweakInfo
    let candidateApps: [InstalledAppInfo]
    let isLoading: Bool
    let onConfirm: (InstalledAppInfo) -> Void

    @StateObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var appPendingConfirmation: InstalledAppInfo?

    var body: some View {
        NavigationView {
            ZStack {
                themeManager.backgroundGradient().ignoresSafeArea()

                if isLoading {
                    ProgressView("Scanning installed apps…")
                        .tint(themeManager.currentTheme.accent)
                } else if candidateApps.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "questionmark.app")
                            .font(.system(size: 40))
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                        Text("No installed app matches this tweak's Filter.")
                            .font(.subheadline)
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    List {
                        Section {
                            ForEach(candidateApps) { app in
                                Button(action: { appPendingConfirmation = app }) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.displayName)
                                            .font(.headline)
                                            .foregroundColor(themeManager.currentTheme.textPrimary)
                                        Text("\(app.bundleID) · v\(app.version)")
                                            .font(.caption2)
                                            .foregroundColor(themeManager.currentTheme.textSecondary)
                                    }
                                }
                            }
                        } header: {
                            Text("Apps matching \(tweak.name)'s Filter")
                        } footer: {
                            Text("Only apps this tweak explicitly declares support for are shown.")
                        }
                        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Inject \(tweak.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert(
                "Inject Into \(appPendingConfirmation?.displayName ?? "")?",
                isPresented: Binding(
                    get: { appPendingConfirmation != nil },
                    set: { if !$0 { appPendingConfirmation = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { appPendingConfirmation = nil }
                Button("Inject", role: .destructive) {
                    if let app = appPendingConfirmation {
                        onConfirm(app)
                    }
                }
            } message: {
                Text("This patches \(appPendingConfirmation?.displayName ?? "the app")'s executable to load this tweak. A full backup is made first and restored automatically if anything fails. Works only on third-party apps, breaks silently on the app's next update, and needs the app restarted (or the device resprung) to take effect.")
            }
        }
    }
}
