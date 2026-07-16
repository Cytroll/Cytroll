import SwiftUI

public struct AppManagerView: View {
    @StateObject private var service = AppManagerService.shared
    @StateObject private var themeManager = ThemeManager.shared

    @State private var searchText = ""
    @State private var filterInjectedOnly = false
    @State private var showingConsole = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showingAlert = false

    public init() {}

    private var filtered: [ManagedApp] {
        var list = service.apps
        if filterInjectedOnly {
            list = list.filter { $0.status != .normal }
        }
        if !searchText.isEmpty {
            list = list.filter {
                $0.app.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.app.bundleID.localizedCaseInsensitiveContains(searchText)
            }
        }
        return list
    }

    public var body: some View {
        ZStack {
            themeManager.backgroundGradient().ignoresSafeArea()

            List {
                Section {
                    Toggle(isOn: $filterInjectedOnly) {
                        Text("Injected / Care only")
                            .foregroundColor(themeManager.currentTheme.textPrimary)
                    }
                    .tint(themeManager.currentTheme.accent)
                }
                .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))

                Section(header: Text("Apps (\(filtered.count))").foregroundColor(themeManager.currentTheme.textSecondary)) {
                    if service.isScanning && service.apps.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Scanning installed apps…")
                                .foregroundColor(themeManager.currentTheme.textSecondary)
                        }
                        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                    } else if filtered.isEmpty {
                        Text("No matching apps.")
                            .foregroundColor(themeManager.currentTheme.textSecondary)
                            .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                    } else {
                        ForEach(filtered) { item in
                            NavigationLink(destination: AppManagerDetailView(bundleID: item.app.bundleID)) {
                                AppManagerRow(item: item)
                            }
                            .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .cytrollHideScrollBackground()
            .searchable(text: $searchText, prompt: "Search name or bundle ID")
        }
        .navigationTitle("App Manager")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { service.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(service.isScanning || service.isBusy)
            }
        }
        .onAppear { service.refresh() }
        .fullScreenCover(isPresented: $showingConsole) {
            LiveConsoleView(
                isPresented: $showingConsole,
                isRunning: service.isBusy || AppInjectionManager.shared.isProcessing || AppDataVault.shared.isProcessing || AppSafeModeManager.shared.isProcessing,
                title: "App Manager"
            )
        }
        .alert(alertTitle, isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .environment(\.appManagerPresentConsole) { showingConsole = true }
        .environment(\.appManagerShowAlert) { title, message in
            alertTitle = title
            alertMessage = message
            showingAlert = true
        }
    }
}

// MARK: - Environment helpers for detail actions

private struct PresentConsoleKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
private struct ShowAlertKey: EnvironmentKey {
    static let defaultValue: (String, String) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var appManagerPresentConsole: () -> Void {
        get { self[PresentConsoleKey.self] }
        set { self[PresentConsoleKey.self] = newValue }
    }
    var appManagerShowAlert: (String, String) -> Void {
        get { self[ShowAlertKey.self] }
        set { self[ShowAlertKey.self] = newValue }
    }
}

// MARK: - Row

private struct AppManagerRow: View {
    let item: ManagedApp
    @StateObject private var themeManager = ThemeManager.shared
    @State private var icon: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon {
                    Image(uiImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "app.fill")
                        .foregroundColor(themeManager.currentTheme.accent)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.app.displayName)
                    .font(.headline)
                    .foregroundColor(themeManager.currentTheme.textPrimary)
                Text("\(item.app.bundleID) · v\(item.app.version)")
                    .font(.caption2)
                    .foregroundColor(themeManager.currentTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            statusBadge(item.status)
        }
        .padding(.vertical, 2)
        .onAppear {
            if icon == nil {
                DispatchQueue.global(qos: .utility).async {
                    let img = AppManagerService.shared.loadIcon(for: item.app)
                    DispatchQueue.main.async { icon = img }
                }
            }
        }
    }

    private func statusBadge(_ status: AppManagerStatus) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .normal: return ("", .clear)
            case .injected: return ("Injected", .green)
            case .needsReapply: return ("Reapply", .orange)
            case .safeMode: return ("Safe Mode", .orange)
            case .failed: return ("Failed", .red)
            }
        }()
        return Group {
            if !text.isEmpty {
                Text(text)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.2))
                    .foregroundColor(color)
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Detail

public struct AppManagerDetailView: View {
    let bundleID: String

    @StateObject private var service = AppManagerService.shared
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var vault = AppDataVault.shared
    @StateObject private var safeMode = AppSafeModeManager.shared

    @Environment(\.appManagerPresentConsole) private var presentConsole
    @Environment(\.appManagerShowAlert) private var showAlert
    @Environment(\.presentationMode) private var presentationMode

    @State private var entitlementsText: String?
    @State private var showingEntitlements = false
    @State private var showingDeleteConfirm = false
    @State private var showingRestoreConfirm = false
    @State private var icon: UIImage?

    private var item: ManagedApp? { service.managed(for: bundleID) }

    public var body: some View {
        ZStack {
            themeManager.backgroundGradient().ignoresSafeArea()

            if let item {
                List {
                    headerSection(item)
                    pathsSection(item)
                    actionsSection(item)
                    careSection(item)
                    dangerSection(item)
                }
                .listStyle(.insetGrouped)
                .cytrollHideScrollBackground()
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading…")
                        .foregroundColor(themeManager.currentTheme.textSecondary)
                }
            }
        }
        .navigationTitle(item?.app.displayName ?? "App")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if service.managed(for: bundleID) == nil {
                service.refresh()
            }
            if let app = item?.app {
                DispatchQueue.global(qos: .utility).async {
                    let img = service.loadIcon(for: app)
                    DispatchQueue.main.async { icon = img }
                }
            }
        }
        .sheet(isPresented: $showingEntitlements) {
            NavigationView {
                ScrollView {
                    Text(entitlementsText ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Entitlements")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showingEntitlements = false }
                    }
                }
            }
        }
        .alert("Delete App?", isPresented: $showingDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard let app = item?.app else { return }
                run(console: true) { done in
                    service.deleteApp(app) { result in
                        done(result)
                        if case .success = result {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
            }
        } message: {
            Text("Removes \(item?.app.displayName ?? "this app"), its data container, and Cytroll injection state. This cannot be undone.")
        }
        .alert("Restore App Data?", isPresented: $showingRestoreConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Restore", role: .destructive) {
                guard let app = item?.app else { return }
                run(console: true) { done in
                    service.restoreLatestData(app, completion: done)
                }
            }
        } message: {
            Text("Overwrites Documents and Preferences from the latest Data Vault snapshot.")
        }
    }

    private func headerSection(_ item: ManagedApp) -> some View {
        Section {
            HStack(spacing: 14) {
                Group {
                    if let icon {
                        Image(uiImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "app.fill")
                            .font(.largeTitle)
                            .foregroundColor(themeManager.currentTheme.accent)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.app.displayName)
                        .font(.title3.bold())
                        .foregroundColor(themeManager.currentTheme.textPrimary)
                    Text("v\(item.app.version)")
                        .font(.subheadline)
                        .foregroundColor(themeManager.currentTheme.textSecondary)
                    Text(statusLabel(item.status))
                        .font(.caption.bold())
                        .foregroundColor(statusColor(item.status))
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
    }

    private func pathsSection(_ item: ManagedApp) -> some View {
        Section(header: Text("Paths & Size").foregroundColor(themeManager.currentTheme.textSecondary)) {
            labeled("Bundle ID", item.app.bundleID)
            labeled("Bundle", item.app.bundlePath)
            labeled("Data", item.dataContainerPath ?? "Not found")
            labeled("Bundle size", ByteCountFormatter.string(fromByteCount: item.bundleSizeBytes, countStyle: .file))
            labeled("Data size", ByteCountFormatter.string(fromByteCount: item.dataSizeBytes, countStyle: .file))
            if item.injectedTweakCount > 0 {
                labeled("Injected tweaks", "\(item.injectedTweakCount)")
            }
        }
        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
    }

    private func actionsSection(_ item: ManagedApp) -> some View {
        Section(header: Text("Actions").foregroundColor(themeManager.currentTheme.textSecondary)) {
            actionButton("Kill App", systemImage: "xmark.octagon") {
                run(console: true) { done in service.killApp(item.app, completion: done) }
            }
            actionButton("Refresh Icon (uicache)", systemImage: "app.badge") {
                run(console: true) { done in service.refreshIcon(item.app, completion: done) }
            }
            actionButton("Copy Data Path", systemImage: "doc.on.doc") {
                switch service.copyDataPath(item.app) {
                case .success(let path):
                    showAlert("Copied", path)
                case .failure(let error):
                    showAlert("Failed", error.localizedDescription)
                }
            }
            actionButton("Open Data in Filza", systemImage: "folder") {
                switch service.openDataInFilza(item.app) {
                case .success:
                    break
                case .failure(let error):
                    showAlert("Data Path", error.localizedDescription)
                }
            }
            actionButton("Dump Entitlements", systemImage: "doc.text.magnifyingglass") {
                run(console: false) { done in
                    service.readEntitlements(for: item.app) { result in
                        switch result {
                        case .success(let text):
                            entitlementsText = text
                            showingEntitlements = true
                            done(.success(()))
                        case .failure(let error):
                            done(.failure(error))
                        }
                    }
                }
            }
            NavigationLink(destination: TweaksManagerView()) {
                Label("Manage Injections…", systemImage: "syringe.fill")
                    .foregroundColor(themeManager.currentTheme.accent)
            }
        }
        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
        .foregroundColor(themeManager.currentTheme.accent)
    }

    private func careSection(_ item: ManagedApp) -> some View {
        let vaultCount = vault.backups(for: item.app.bundleID).count
        let paused = safeMode.isPaused(bundleID: item.app.bundleID)

        return Section(header: Text("Care").foregroundColor(themeManager.currentTheme.textSecondary)) {
            actionButton("Backup Data", systemImage: "externaldrive.badge.plus") {
                run(console: true) { done in service.backupData(item.app, completion: done) }
            }
            if vaultCount > 0 {
                actionButton("Restore Data (\(vaultCount))", systemImage: "externaldrive.badge.timemachine") {
                    showingRestoreConfirm = true
                }
            }
            if item.status != .normal || paused {
                if paused {
                    actionButton("Resume Tweaks", systemImage: "play.fill") {
                        run(console: true) { done in service.resumeTweaks(item.app, completion: done) }
                    }
                } else if item.injectedTweakCount > 0 {
                    actionButton("Pause Tweaks (Safe Mode)", systemImage: "pause.fill") {
                        run(console: true) { done in service.pauseTweaks(item.app, completion: done) }
                    }
                }
                if item.injectedTweakCount > 0 {
                    actionButton("Restore Original (Strip Tweaks)", systemImage: "arrow.uturn.backward") {
                        run(console: true) { done in service.stripInjections(item.app, completion: done) }
                    }
                }
            }
        }
        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
        .foregroundColor(themeManager.currentTheme.accent)
    }

    private func dangerSection(_ item: ManagedApp) -> some View {
        Section(header: Text("Danger Zone").foregroundColor(.red)) {
            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                Label("Delete App", systemImage: "trash.fill")
            }
            .disabled(service.isBusy || CytrollOperationGate.shared.isBusy)
        }
        .listRowBackground(themeManager.currentTheme.cardBackground.opacity(0.6))
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(themeManager.currentTheme.textSecondary)
            Text(value)
                .font(.caption.monospaced())
                .foregroundColor(themeManager.currentTheme.textPrimary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .disabled(service.isBusy || CytrollOperationGate.shared.isBusy)
    }

    private func run(console: Bool, work: @escaping (@escaping (Result<Void, Error>) -> Void) -> Void) {
        if console {
            ConsoleManager.shared.clear()
            presentConsole()
        }
        work { result in
            if case .failure(let error) = result {
                showAlert("Operation Failed", error.localizedDescription)
            }
        }
    }

    private func statusLabel(_ status: AppManagerStatus) -> String {
        switch status {
        case .normal: return "Not injected"
        case .injected: return "Injected"
        case .needsReapply: return "Needs Reapply"
        case .safeMode: return "Per-app Safe Mode"
        case .failed: return "Injection Failed"
        }
    }

    private func statusColor(_ status: AppManagerStatus) -> Color {
        switch status {
        case .normal: return themeManager.currentTheme.textSecondary
        case .injected: return .green
        case .needsReapply, .safeMode: return .orange
        case .failed: return .red
        }
    }
}
