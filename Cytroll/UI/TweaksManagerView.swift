import SwiftUI
import UniformTypeIdentifiers

public struct TweaksManagerView: View {
    @StateObject private var tweakManager = TweakInjectionManager.shared
    @StateObject private var injectionManager = AppInjectionManager.shared
    @StateObject private var recordStore = InjectionRecordStore.shared
    @StateObject private var sideloadStore = SideloadedDylibStore.shared
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var careSettings = CytrollCareSettings.shared
    @StateObject private var autoReinject = AutoReinjectService.shared
    @StateObject private var safeMode = AppSafeModeManager.shared
    @StateObject private var dataVault = AppDataVault.shared

    @State private var injectionRequest: InjectionRequestContext?
    @State private var isLoadingCandidates = false

    @State private var showingSideloadImporter = false
    @State private var showingInjectionConsole = false
    @State private var lastInjectionErrorMessage: String?
    @State private var showingInjectionError = false
    @State private var vaultConfirmBundleID: String?
    @State private var showingVaultRestoreConfirm = false

    public init() {}

    private var injectedAppGroups: [(bundleID: String, displayName: String, records: [InjectionRecord])] {
        Dictionary(grouping: recordStore.records, by: \.bundleID)
            .map { (bundleID: $0.key, displayName: $0.value.first?.appDisplayName ?? $0.key, records: $0.value) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var pausedOnlyApps: [AppSafeModeEntry] {
        safeMode.entries.filter { $0.isPaused && recordStore.records(forBundleID: $0.bundleID).isEmpty }
    }

    public var body: some View {
        ZStack {
            themeManager.backgroundGradient().ignoresSafeArea()

            List {
                careSection
                tweaksSection
                sideloadedSection
                if !injectedAppGroups.isEmpty || !pausedOnlyApps.isEmpty {
                    injectedAppsSection
                }
                storageSection
                perAppInjectionDisclaimer
            }
            .listStyle(.insetGrouped)
            .cytrollHideScrollBackground()
        }
        .navigationTitle("Tweak Injector")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            tweakManager.refreshTweaks()
            recordStore.refreshNeedsReapplyFlags()
            injectionManager.recoverStrayTempDirectories()
            dataVault.reload()
        }
        .sheet(item: $injectionRequest) { request in
            InjectionTargetPickerSheet(
                tweak: request.tweak,
                apps: request.apps,
                headerNote: request.headerNote,
                isLoading: isLoadingCandidates,
                onConfirm: { apps in
                    injectionRequest = nil
                    startInjection(tweak: request.tweak, apps: apps)
                }
            )
        }
        .fullScreenCover(isPresented: $showingInjectionConsole) {
            LiveConsoleView(
                isPresented: $showingInjectionConsole,
                isRunning: injectionManager.isProcessing || autoReinject.isRunning || safeMode.isProcessing || dataVault.isProcessing,
                title: "Tweak Injection"
            )
        }
        .fileImporter(
            isPresented: $showingSideloadImporter,
            allowedContentTypes: Self.sideloadImportTypes,
            allowsMultipleSelection: false
        ) { result in
            handleSideloadPicked(result)
        }
        .alert("Operation Failed", isPresented: $showingInjectionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lastInjectionErrorMessage ?? "Unknown error.")
        }
        .alert("Restore App Data?", isPresented: $showingVaultRestoreConfirm) {
            Button("Cancel", role: .cancel) { vaultConfirmBundleID = nil }
            Button("Restore", role: .destructive) {
                if let id = vaultConfirmBundleID {
                    restoreLatestVault(bundleID: id)
                }
                vaultConfirmBundleID = nil
            }
        } message: {
            Text("Overwrites Documents and Preferences from the latest vault snapshot. The app will be terminated first.")
        }
    }

    // MARK: - Care

    private var careSection: some View {
        Section(
            header: Text("Care").foregroundColor(themeManager.currentTheme.textSecondary),
            footer: Text("Auto re-inject rebuilds injected apps after they update. Per-app Safe Mode and Data Vault are on each app below.")
        ) {
            Toggle(isOn: $careSettings.autoReinjectEnabled) {
                Label("Auto Re-inject After Updates", systemImage: "arrow.triangle.2.circlepath.circle.fill")
            }
            .tint(themeManager.currentTheme.accent)
            .foregroundColor(themeManager.currentTheme.textPrimary)

            if autoReinject.pendingAppCount > 0 {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(autoReinject.pendingAppCount) app(s) need re-inject")
                            .font(.subheadline.bold())
                            .foregroundColor(.orange)
                        if let summary = autoReinject.lastSummary {
                            Text(summary)
                                .font(.caption2)
                                .foregroundColor(themeManager.currentTheme.textSecondary)
                        }
                    }
                    Spacer()
                    Button("Fix All") {
                        ConsoleManager.shared.clear()
                        showingInjectionConsole = true
                        autoReinject.reapplyAllPending(triggeredByUser: true)
                    }
                    .font(.caption.bold())
                    .foregroundColor(themeManager.currentTheme.accent)
                    .disabled(autoReinject.isRunning || injectionManager.isProcessing)
                }
            }
        }
        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
    }

    // MARK: - Sections

    private var tweaksSection: some View {
        Section(header: Text("Installed Tweaks").foregroundColor(themeManager.currentTheme.textSecondary)) {
            if tweakManager.installedTweaks.isEmpty {
                Text("No apt tweaks found. Install some from the Packages tab, or add a .dylib file directly below.")
                    .font(.subheadline)
                    .foregroundColor(themeManager.currentTheme.textSecondary)
            }
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

                    if tweak.filterBundleIDs.isEmpty {
                        Text("No Filter in this tweak's plist — you'll pick from every installed app.")
                            .font(.caption2)
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
            }
        }
    }

    private var sideloadedSection: some View {
        Section(
            header: Text("Sideloaded Dylibs").foregroundColor(themeManager.currentTheme.textSecondary),
            footer: Text("Pick any .dylib from Files. Only .dylib is accepted.")
        ) {
            ForEach(sideloadStore.items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name)
                        .font(.headline)
                        .foregroundColor(themeManager.currentTheme.textPrimary)

                    Button(action: { presentInjectionSheet(for: item.asTweakInfo) }) {
                        HStack {
                            Image(systemName: "syringe.fill")
                            Text("Inject Into App…")
                        }
                        .font(.caption.bold())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(themeManager.currentTheme.accent)
                    .disabled(injectionManager.isProcessing)
                }
                .padding(.vertical, 4)
                .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                .swipeActions {
                    Button(role: .destructive) {
                        sideloadStore.remove(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            Button(action: { showingSideloadImporter = true }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Add .dylib File…")
                }
                .font(.subheadline.bold())
            }
            .buttonStyle(.plain)
            .foregroundColor(themeManager.currentTheme.accent)
            .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
        }
    }

    private var injectedAppsSection: some View {
        Section(header: Text("Injected Apps").foregroundColor(themeManager.currentTheme.textSecondary)) {
            ForEach(injectedAppGroups, id: \.bundleID) { group in
                injectedAppRow(bundleID: group.bundleID, displayName: group.displayName, records: group.records)
            }
            ForEach(pausedOnlyApps) { entry in
                pausedAppRow(entry)
            }
        }
    }

    private func injectedAppRow(bundleID: String, displayName: String, records: [InjectionRecord]) -> some View {
        let paused = safeMode.isPaused(bundleID: bundleID)
        let needsReapply = records.contains { $0.status == .needsReapply }
        let hasFailed = records.contains { $0.status == .failed }
        let vaultCount = dataVault.backups(for: bundleID).count

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.subheadline.bold())
                        .foregroundColor(themeManager.currentTheme.textPrimary)
                    Text(records.map(\.tweakName).joined(separator: ", "))
                        .font(.caption2)
                        .foregroundColor(themeManager.currentTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                if paused {
                    statusBadge(text: "Safe Mode", color: .orange)
                } else if hasFailed {
                    statusBadge(text: "Failed", color: .red)
                } else if needsReapply {
                    statusBadge(text: "Needs Reapply", color: .orange)
                } else {
                    statusBadge(text: "Active", color: .green)
                }
            }

            HStack(spacing: 12) {
                if needsReapply && !paused {
                    Button("Re-inject") {
                        reapplyApp(bundleID: bundleID, records: records)
                    }
                    .font(.caption.bold())
                    .foregroundColor(themeManager.currentTheme.accent)
                    .disabled(busy)
                }

                if paused {
                    Button("Resume Tweaks") {
                        runSafeMode { safeMode.resume(bundleID: bundleID, completion: $0) }
                    }
                    .font(.caption.bold())
                    .foregroundColor(themeManager.currentTheme.accent)
                    .disabled(busy)
                } else if !hasFailed {
                    Button("Pause Tweaks") {
                        runSafeMode { safeMode.pause(bundleID: bundleID, completion: $0) }
                    }
                    .font(.caption.bold())
                    .foregroundColor(.orange)
                    .disabled(busy)
                }

                Spacer()

                Button("Restore Original") {
                    restoreAll(records: records)
                }
                .font(.caption.bold())
                .foregroundColor(.red)
                .disabled(busy)
            }

            HStack(spacing: 12) {
                Button("Backup Data") {
                    runVaultBackup(bundleID: bundleID, displayName: displayName)
                }
                .font(.caption.bold())
                .foregroundColor(themeManager.currentTheme.accent)
                .disabled(busy)

                if vaultCount > 0 {
                    Button("Restore Data (\(vaultCount))") {
                        vaultConfirmBundleID = bundleID
                        showingVaultRestoreConfirm = true
                    }
                    .font(.caption.bold())
                    .foregroundColor(themeManager.currentTheme.accent)
                    .disabled(busy)
                }
            }

            if hasFailed {
                Text("Previous rebuild didn't fully recover. Restore Original before injecting again.")
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
    }

    private func pausedAppRow(_ entry: AppSafeModeEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.appDisplayName)
                    .font(.subheadline.bold())
                    .foregroundColor(themeManager.currentTheme.textPrimary)
                Spacer()
                statusBadge(text: "Safe Mode", color: .orange)
            }
            Text("\(entry.pausedTweakIDs.count) tweak(s) paused")
                .font(.caption2)
                .foregroundColor(themeManager.currentTheme.textSecondary)

            Button("Resume Tweaks") {
                runSafeMode { safeMode.resume(bundleID: entry.bundleID, completion: $0) }
            }
            .font(.caption.bold())
            .foregroundColor(themeManager.currentTheme.accent)
            .disabled(busy)
        }
        .padding(.vertical, 4)
        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
    }

    private var busy: Bool {
        injectionManager.isProcessing || autoReinject.isRunning || safeMode.isProcessing || dataVault.isProcessing
    }

    private var storageSection: some View {
        Section {
            NavigationLink(destination: InjectionBackupStorageView()) {
                HStack {
                    Image(systemName: "internaldrive")
                    Text("Backup Storage")
                }
                .foregroundColor(themeManager.currentTheme.textPrimary)
            }
        }
        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
    }

    private var perAppInjectionDisclaimer: some View {
        Section {
            Text("Per-app injection works on third-party apps only. After an App Store update, status becomes Needs Reapply until Care rebuilds the app. Restart the target app for changes to load.")
                .font(.caption2)
                .foregroundColor(themeManager.currentTheme.textSecondary)
        }
        .listRowBackground(Color.clear)
    }

    private func statusBadge(text: String, color: Color) -> some View {
        Text(text)
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
        let usesFullList = tweak.filterBundleIDs.isEmpty
        injectionRequest = InjectionRequestContext(
            tweak: tweak,
            apps: [],
            headerNote: usesFullList ? "No Filter declared — pick any installed app." : "Apps matching \(tweak.name)'s Filter."
        )

        if usesFullList {
            InstalledAppScanner.shared.scanInstalledApps { apps in
                injectionRequest?.apps = apps
                isLoadingCandidates = false
            }
        } else {
            tweakManager.candidateApps(for: tweak) { apps in
                injectionRequest?.apps = apps
                isLoadingCandidates = false
            }
        }
    }

    private func startInjection(tweak: TweakInfo, apps: [InstalledAppInfo]) {
        guard !apps.isEmpty else { return }
        ConsoleManager.shared.clear()
        showingInjectionConsole = true

        var failures: [String] = []
        injectionManager.injectBatch(
            tweak: tweak,
            into: apps,
            progress: { app, result in
                if case .failure(let error) = result {
                    failures.append("\(app.displayName): \(error.localizedDescription)")
                }
            },
            completion: {
                if !failures.isEmpty {
                    lastInjectionErrorMessage = failures.joined(separator: "\n\n")
                    showingInjectionError = true
                }
            }
        )
    }

    private func reapplyApp(bundleID: String, records: [InjectionRecord]) {
        let tweaks = records.compactMap { resolveTweakInfo(id: $0.tweakID) }
        guard !tweaks.isEmpty else {
            lastInjectionErrorMessage = "Tweaks for this app are no longer installed."
            showingInjectionError = true
            return
        }
        ConsoleManager.shared.clear()
        showingInjectionConsole = true
        injectionManager.applyDesiredTweaks(
            bundleID: bundleID,
            displayName: records.first?.appDisplayName ?? bundleID,
            tweaks: tweaks
        ) { result in
            if case .failure(let error) = result {
                lastInjectionErrorMessage = error.localizedDescription
                showingInjectionError = true
            }
        }
    }

    private func restoreAll(records: [InjectionRecord]) {
        guard let first = records.first else { return }
        ConsoleManager.shared.clear()
        showingInjectionConsole = true
        injectionManager.applyDesiredTweaks(
            bundleID: first.bundleID,
            displayName: first.appDisplayName,
            tweaks: []
        ) { result in
            if case .failure(let error) = result {
                lastInjectionErrorMessage = error.localizedDescription
                showingInjectionError = true
            }
        }
    }

    private func runSafeMode(_ work: (@escaping (Result<Void, Error>) -> Void) -> Void) {
        ConsoleManager.shared.clear()
        showingInjectionConsole = true
        work { result in
            if case .failure(let error) = result {
                lastInjectionErrorMessage = error.localizedDescription
                showingInjectionError = true
            }
        }
    }

    private func runVaultBackup(bundleID: String, displayName: String) {
        ConsoleManager.shared.clear()
        showingInjectionConsole = true
        dataVault.backup(bundleID: bundleID, displayName: displayName) { result in
            if case .failure(let error) = result {
                lastInjectionErrorMessage = error.localizedDescription
                showingInjectionError = true
            }
        }
    }

    private func restoreLatestVault(bundleID: String) {
        guard let latest = dataVault.backups(for: bundleID).first else { return }
        ConsoleManager.shared.clear()
        showingInjectionConsole = true
        dataVault.restore(latest) { result in
            if case .failure(let error) = result {
                lastInjectionErrorMessage = error.localizedDescription
                showingInjectionError = true
            }
        }
    }

    private func resolveTweakInfo(id: String) -> TweakInfo? {
        if let apt = tweakManager.installedTweaks.first(where: { $0.id == id }) {
            return apt
        }
        return sideloadStore.item(withID: id)?.asTweakInfo
    }

    private static var sideloadImportTypes: [UTType] {
        var types: [UTType] = [.item, .data]
        if let cytroll = UTType("com.cytroll.dylib") {
            types.insert(cytroll, at: 0)
        }
        if let byExt = UTType(filenameExtension: "dylib", conformingTo: .data) {
            types.insert(byExt, at: 0)
        }
        if let machoDylib = UTType("com.apple.mach-o-dylib") {
            types.insert(machoDylib, at: 0)
        }
        return types
    }

    private func handleSideloadPicked(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            lastInjectionErrorMessage = error.localizedDescription
            showingInjectionError = true
        case .success(let urls):
            guard let url = urls.first else { return }
            let ext = url.pathExtension.lowercased()
            guard ext == "dylib" else {
                lastInjectionErrorMessage = "Please pick a .dylib file (got “\(url.lastPathComponent)”)."
                showingInjectionError = true
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = sideloadStore.add(from: url, displayName: nil)
                DispatchQueue.main.async {
                    if case .failure(let error) = outcome {
                        lastInjectionErrorMessage = "Could not add \(url.lastPathComponent): \(error.localizedDescription)"
                        showingInjectionError = true
                    }
                }
            }
        }
    }
}
