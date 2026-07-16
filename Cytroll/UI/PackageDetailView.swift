import SwiftUI
import Combine

/// Full Cydia-style package info screen: description, size, maintainer,
/// section, Depends/Conflicts, other available versions (with per-version
/// pinned install), hold/pin toggle, and a link into the rich HTML
/// depiction page when the package/repo provides one.
public struct PackageDetailView: View {
    @State private var package: Package

    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var queueManager = QueueManager.shared
    @StateObject private var holdManager = PackageHoldManager.shared
    @StateObject private var packageIndex = PackageIndexStore.shared
    @StateObject private var injectionManager = AppInjectionManager.shared
    @StateObject private var tweakManager = TweakInjectionManager.shared

    @State private var showingDepiction = false
    @State private var versionsExpanded: Bool
    @State private var injectionRequest: InjectionRequestContext?
    @State private var isLoadingCandidates = false
    @State private var showingInjectionConsole = false
    @State private var lastInjectionErrorMessage: String?
    @State private var showingInjectionError = false

    public init(package: Package) {
        self._package = State(initialValue: package)
        self._versionsExpanded = State(initialValue: PackageManagerSettings.shared.showAllVersions)
    }

    private var injectableTweak: TweakInfo? {
        guard package.isInstalled else { return nil }
        return PackageTweakResolver.resolveTweak(forPackageID: package.id)
    }

    /// Every other version of this package found across configured
    /// sources, newest first, deduplicated (the same version can appear in
    /// more than one repo).
    private var otherVersions: [Package] {
        var seenVersions = Set<String>([package.version])
        var result: [Package] = []
        for candidate in packageIndex.repoPackagesSnapshot() where candidate.id == package.id {
            guard !seenVersions.contains(candidate.version) else { continue }
            seenVersions.insert(candidate.version)
            result.append(candidate)
        }
        return result.sorted { DpkgVersionComparator.compare($0.version, $1.version) > 0 }
    }

    private var isHeld: Bool { holdManager.isHeld(package.id) }

    public var body: some View {
        ZStack {
            themeManager.backgroundGradient().ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    actionButtons
                    if let depictionURL = package.depictionURL, let url = URL(string: depictionURL) {
                        depictionButton(url: url)
                    }
                    descriptionCard
                    infoCard
                    if !package.dependsGroups.isEmpty { dependsCard }
                    if !package.conflicts.isEmpty { conflictsCard }
                    if !otherVersions.isEmpty { versionsCard }
                }
                .padding()
            }
        }
        .navigationTitle(package.name)
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(packageIndex.$mergedPackages) { merged in
            // Reflect fresh install/remove state without leaving the screen.
            if let updated = merged.first(where: { $0.id == package.id }) {
                package = updated
            }
        }
        .onAppear {
            if package.isInstalled {
                tweakManager.refreshTweaks()
            }
        }
        .sheet(item: $injectionRequest) { request in
            InjectionTargetPickerSheet(
                tweak: request.tweak,
                apps: request.apps,
                headerNote: request.headerNote,
                isLoading: isLoadingCandidates,
                onConfirm: { apps in
                    injectionRequest = nil
                    startPackageInjection(tweak: request.tweak, apps: apps)
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(themeManager.currentTheme.accent.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "shippingbox.fill")
                    .font(.title)
                    .foregroundColor(themeManager.currentTheme.accent)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(package.name)
                    .font(.title3.bold())
                    .foregroundColor(themeManager.currentTheme.textPrimary)

                HStack(spacing: 6) {
                    tag(package.version, color: themeManager.currentTheme.accent)
                    tag(package.section, color: themeManager.currentTheme.textSecondary)
                    if isHeld {
                        tag("Held", color: .orange)
                    }
                }

                if package.isBroken {
                    Label("Broken Install", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold())
                        .foregroundColor(.orange)
                } else if package.isInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption.bold())
                        .foregroundColor(.green)
                }
            }
            Spacer()
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(8)
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if !package.isInstalled {
                    actionButton("Get", systemImage: "arrow.down.circle.fill", filled: true) {
                        queueManager.addOrUpdate(package: package, action: .install)
                    }
                } else {
                    actionButton("Reinstall", systemImage: "arrow.triangle.2.circlepath", filled: false) {
                        queueManager.addOrUpdate(package: package, action: .reinstall)
                    }
                    actionButton("Remove", systemImage: "trash", filled: false, destructive: true) {
                        queueManager.addOrUpdate(package: package, action: .remove)
                    }
                }

                if package.isInstalled {
                    Spacer()
                    Button(action: toggleHold) {
                        Label(isHeld ? "Held" : "Hold", systemImage: isHeld ? "lock.fill" : "lock.open")
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background((isHeld ? Color.orange : themeManager.currentTheme.accent).opacity(0.15))
                            .foregroundColor(isHeld ? .orange : themeManager.currentTheme.accent)
                            .cornerRadius(10)
                    }
                }
            }

            if let tweak = injectableTweak {
                Button(action: { presentInjectionSheet(for: tweak) }) {
                    Label("Inject Into Apps…", systemImage: "syringe.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(themeManager.currentTheme.accent.opacity(0.15))
                        .foregroundColor(themeManager.currentTheme.accent)
                        .cornerRadius(12)
                }
                .disabled(injectionManager.isProcessing || !tweak.isEnabled)
            }
        }
    }

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

    private func startPackageInjection(tweak: TweakInfo, apps: [InstalledAppInfo]) {
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

    private func actionButton(_ title: String, systemImage: String, filled: Bool, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        let color: Color = destructive ? .red : themeManager.currentTheme.accent
        return Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.bold())
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(filled ? color : color.opacity(0.15))
                .foregroundColor(filled ? .white : color)
                .cornerRadius(12)
        }
    }

    private func toggleHold() {
        holdManager.setHeld(package.id, held: !isHeld) { _ in }
    }

    private func depictionButton(url: URL) -> some View {
        Button(action: { showingDepiction = true }) {
            Label("View Full Depiction Page", systemImage: "safari.fill")
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(themeManager.currentTheme.cardBackground.opacity(0.6))
                .foregroundColor(themeManager.currentTheme.accent)
                .cornerRadius(12)
        }
        .sheet(isPresented: $showingDepiction) {
            DepictionView(title: package.name, url: url)
        }
    }

    // MARK: - Info sections

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DESCRIPTION")
                .font(.caption.bold())
                .foregroundColor(themeManager.currentTheme.textSecondary)
                .tracking(1.2)
            Text(package.description.isEmpty ? "No description provided." : package.description)
                .font(.subheadline)
                .foregroundColor(themeManager.currentTheme.textPrimary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme: themeManager.currentTheme)
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("INFORMATION")
                .font(.caption.bold())
                .foregroundColor(themeManager.currentTheme.textSecondary)
                .tracking(1.2)

            infoRow("Identifier", package.id)
            infoRow("Version", package.version)
            infoRow("Maintainer", package.author.isEmpty ? "Unknown" : package.author)
            infoRow("Section", package.section)
            if let installedSize = package.installedSizeKB {
                infoRow("Installed Size", formatKB(installedSize))
            }
            if let downloadSize = package.downloadSizeBytes {
                infoRow("Download Size", formatBytes(downloadSize))
            }
            if let source = package.sourceURL {
                infoRow("Source", source)
            }
            if let homepage = package.homepageURL, let url = URL(string: homepage) {
                HStack {
                    Text("Homepage")
                        .font(.caption)
                        .foregroundColor(themeManager.currentTheme.textSecondary)
                    Spacer()
                    Link(homepage, destination: url)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme: themeManager.currentTheme)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundColor(themeManager.currentTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundColor(themeManager.currentTheme.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private var dependsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DEPENDS")
                .font(.caption.bold())
                .foregroundColor(themeManager.currentTheme.textSecondary)
                .tracking(1.2)
            ForEach(package.dependsGroups.indices, id: \.self) { idx in
                Text(package.dependsGroups[idx].joined(separator: "  |  "))
                    .font(.caption)
                    .foregroundColor(themeManager.currentTheme.textPrimary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme: themeManager.currentTheme)
    }

    private var conflictsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONFLICTS")
                .font(.caption.bold())
                .foregroundColor(themeManager.currentTheme.textSecondary)
                .tracking(1.2)
            Text(package.conflicts.joined(separator: ", "))
                .font(.caption)
                .foregroundColor(.orange)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(theme: themeManager.currentTheme)
    }

    private var versionsCard: some View {
        DisclosureGroup(isExpanded: $versionsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(otherVersions) { versionPkg in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(versionPkg.version)
                                .font(.caption.bold())
                                .foregroundColor(themeManager.currentTheme.textPrimary)
                            if let src = versionPkg.sourceURL {
                                Text(src)
                                    .font(.system(size: 10))
                                    .foregroundColor(themeManager.currentTheme.textSecondary)
                            }
                        }
                        Spacer()
                        Button("Install") { installSpecificVersion(versionPkg) }
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(themeManager.currentTheme.accent.opacity(0.15))
                            .foregroundColor(themeManager.currentTheme.accent)
                            .cornerRadius(10)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text("\(otherVersions.count) Other Version\(otherVersions.count == 1 ? "" : "s") Available")
                .font(.subheadline.bold())
                .foregroundColor(themeManager.currentTheme.textPrimary)
        }
        .padding(16)
        .glassCard(theme: themeManager.currentTheme)
        .tint(themeManager.currentTheme.accent)
    }

    private func installSpecificVersion(_ versionPkg: Package) {
        var pinned = versionPkg
        pinned.pinnedVersion = versionPkg.version
        queueManager.addOrUpdate(package: pinned, action: .install)
    }

    // MARK: - Formatting

    private func formatKB(_ kb: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .file)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
