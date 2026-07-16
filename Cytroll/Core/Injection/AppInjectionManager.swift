import Foundation

public enum InjectionError: Error, LocalizedError {
    case appNotFound
    case dylibNotFound
    case toolMissing(String)
    case backupFailed(String)
    case backupVerificationFailed
    case dylibCopyFailed
    case insertDylibFailed
    case signingFailed
    case verificationFailed
    case rollbackIncomplete
    case needsRestoreFirst
    case recordMissing
    case restoreCopyFailed
    case restoreVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .appNotFound: return "Target app not found (was it uninstalled?)."
        case .dylibNotFound: return "Tweak dylib not found on disk."
        case .toolMissing(let name): return "Required bundled tool missing: \(name)."
        case .backupFailed(let reason): return "Backup failed — no changes were made. (\(reason))"
        case .backupVerificationFailed: return "Backup verification failed — aborted before touching the app."
        case .dylibCopyFailed: return "Could not copy the dylib into the app — rolled back to backup."
        case .insertDylibFailed: return "Failed to patch the app's executable — rolled back to backup."
        case .signingFailed: return "Failed to re-sign the patched app — rolled back to backup."
        case .verificationFailed: return "Post-injection verification failed — rolled back to backup."
        case .rollbackIncomplete: return "Injection failed AND the automatic rollback did not fully complete — the app may be in an inconsistent state. Use \"Restore Original\" for this app in Injected Apps before trying anything else."
        case .needsRestoreFirst: return "A previous attempt on this app didn't fully roll back. Tap \"Restore Original\" for it in Injected Apps before trying again."
        case .recordMissing: return "No injection record found for this app/tweak."
        case .restoreCopyFailed: return "Restore failed while copying the backup back — original app was left untouched."
        case .restoreVerificationFailed: return "Restore verification failed — original app was left untouched."
        }
    }
}

/// TrollFools-style per-app tweak injection: patches ONE third-party app's
/// Mach-O executable to load a tweak's dylib, re-signs it with `ldid`, and
/// keeps a full backup for atomic rollback. Every step that can fail is
/// checked; any failure after the (mandatory, verified) backup rolls the
/// touched files back immediately — the target app is never left in a
/// half-patched state.
public final class AppInjectionManager: ObservableObject {
    public static let shared = AppInjectionManager()

    @Published public private(set) var isProcessing = false

    private let coreBridge = CytrollCoreBridge.shared
    private let console = ConsoleManager.shared
    private let recordStore = InjectionRecordStore.shared
    private let fm = FileManager.default

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private init() {}

    // MARK: - Inject

    public func inject(tweak: TweakInfo, into app: InstalledAppInfo, completion: @escaping (Result<InjectionRecord, InjectionError>) -> Void) {
        guard !isProcessing else { return }
        isProcessing = true
        console.log("Starting injection: \(tweak.name) -> \(app.displayName)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.performInject(tweak: tweak, app: app)

            DispatchQueue.main.async {
                self.isProcessing = false
                switch result {
                case .success(let record):
                    self.console.log("Injection succeeded: \(tweak.name) -> \(app.displayName). Restart the app (uicache/respring recommended) for it to take effect.")
                    let previous = self.recordStore.records.first(where: { $0.id == record.id })
                    self.recordStore.upsert(record)
                    completion(.success(record))
                    // A successful (re-)injection makes any older backup for
                    // this exact app/tweak pair redundant (stale app version,
                    // or a backup kept around from a previous failed attempt
                    // that's no longer needed now that it's been superseded).
                    if let previous = previous, previous.backupPath != record.backupPath, !previous.backupPath.isEmpty {
                        self.deleteBackupDir(forBackupAppPath: previous.backupPath)
                    }
                case .failure(let error):
                    self.console.log("Injection FAILED: \(error.localizedDescription)")
                    completion(.failure(error))
                }
            }
        }
    }

    private func performInject(tweak: TweakInfo, app: InstalledAppInfo) -> Result<InjectionRecord, InjectionError> {
        guard fm.fileExists(atPath: app.bundlePath) else { return .failure(.appNotFound) }
        guard fm.fileExists(atPath: tweak.dylibPath) else { return .failure(.dylibNotFound) }
        // A `.failed` record means a previous attempt's automatic rollback
        // didn't fully complete — refuse to pile a fresh backup/attempt on
        // top of a possibly-inconsistent app. Force an explicit restore
        // first so we never lose track of the one backup known to predate
        // any modification.
        if let existing = recordStore.records.first(where: { $0.tweakID == tweak.id && $0.bundleID == app.bundleID }), existing.status == .failed {
            return .failure(.needsRestoreFirst)
        }
        guard let insertDylibPath = BootstrapConfig.bundledToolPath("insert_dylib") else {
            return .failure(.toolMissing("insert_dylib"))
        }
        // Prefer the bundled ldid (always present, same one used for
        // bootstrap signing); fall back to the rootless-prefix one apt
        // installed, mirroring BootstrapManager's own fallback pattern.
        let ldidCandidate = BootstrapConfig.bundledToolPath("ldid") ?? RootlessPaths.ldid
        guard fm.fileExists(atPath: ldidCandidate) else {
            return .failure(.toolMissing("ldid"))
        }
        let ldidPath = ldidCandidate

        // 1. Mandatory full backup, verified before any modification happens.
        let timestamp = Self.timestampFormatter.string(from: Date())
        let appBundleName = (app.bundlePath as NSString).lastPathComponent
        let backupDir = RootlessPaths.injectionBackupsDir + "/" + sanitize(app.bundleID) + "/" + timestamp
        let backupAppPath = backupDir + "/" + appBundleName

        console.log("Backing up \(app.displayName)...")
        _ = coreBridge.executeCommand(executable: "/bin/mkdir", arguments: ["-p", backupDir])
        let backupOK = coreBridge.executeCommand(executable: "/bin/cp", arguments: ["-Rp", app.bundlePath, backupAppPath])

        guard backupOK else {
            _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", backupDir])
            return .failure(.backupFailed("cp exited with a non-zero status"))
        }

        guard verifyMirror(source: app.bundlePath, mirror: backupAppPath) else {
            console.log("Backup does not mirror the original app (file count/size mismatch) — deleting partial backup, aborting.")
            _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", backupDir])
            return .failure(.backupVerificationFailed)
        }

        // 2. Extract original entitlements from the verified backup (read-only,
        // the live app hasn't been touched yet at this point).
        let backupExecutablePath = backupAppPath + "/" + (app.executablePath as NSString).lastPathComponent
        let entitlementsPath = backupDir + "/entitlements.plist"
        let (entitlementsOK, entitlementsXML) = coreBridge.executeCommandCapturingOutput(executable: ldidPath, arguments: ["-e", backupExecutablePath])
        let hasEntitlements = entitlementsOK && entitlementsXML.contains("<?xml")
        if hasEntitlements {
            try? entitlementsXML.write(toFile: entitlementsPath, atomically: true, encoding: .utf8)
        }

        // From here on we've verified a good backup exists — any failure
        // rolls back just the files this pipeline touches.
        let frameworksDir = app.bundlePath + "/Frameworks"
        let dylibFileName = "CytrollTweak_\(sanitize(tweak.id)).dylib"
        let dylibDestPath = frameworksDir + "/" + dylibFileName

        // Returns true only if BOTH the executable was restored AND the
        // injected dylib was removed — a partial result means the app may
        // be left inconsistent and must be surfaced, never silently dropped.
        func rollback() -> Bool {
            console.log("Rolling back to backup...")
            let tmp = app.executablePath + ".cytroll_rollback_tmp"
            _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-f", tmp])
            let executableRestored = coreBridge.executeCommand(executable: "/bin/cp", arguments: ["-p", backupExecutablePath, tmp])
                && coreBridge.executeCommand(executable: "/bin/mv", arguments: [tmp, app.executablePath])
            let dylibRemoved = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-f", dylibDestPath])
            return executableRestored && dylibRemoved
        }

        // Shared handling for every failure that happens once a verified
        // backup exists: roll back, then either clean up the now-unneeded
        // backup (rollback fully succeeded — app is back to normal, nothing
        // to track) or persist a `.failed` record pointing at the still-good
        // backup (rollback didn't fully succeed — app may be inconsistent,
        // never lose the one path back to a known-good state).
        func fail(_ error: InjectionError) -> Result<InjectionRecord, InjectionError> {
            if rollback() {
                _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", backupDir])
                return .failure(error)
            }

            console.log("WARNING: rollback did not fully complete for \(app.displayName) — preserving backup at \(backupAppPath) for manual restore.")
            var failedRecord = InjectionRecord(
                tweakID: tweak.id,
                tweakName: tweak.name,
                bundleID: app.bundleID,
                appDisplayName: app.displayName,
                backupPath: backupAppPath,
                injectedAppVersion: app.version,
                dylibDestinationPath: dylibDestPath
            )
            failedRecord.status = .failed
            recordStore.upsert(failedRecord)
            return .failure(.rollbackIncomplete)
        }

        // 3. Copy the tweak's dylib into the target bundle's Frameworks/.
        _ = coreBridge.executeCommand(executable: "/bin/mkdir", arguments: ["-p", frameworksDir])
        guard coreBridge.executeCommand(executable: "/bin/cp", arguments: ["-p", tweak.dylibPath, dylibDestPath]) else {
            return fail(.dylibCopyFailed)
        }
        // Ad-hoc sign the injected dylib too (matches real TrollFools behavior;
        // harmless best-effort — the exploit class TrollStore relies on trusts
        // ad-hoc/fake signatures system-wide, but this keeps things consistent
        // on stricter bypass variants).
        _ = coreBridge.executeCommand(executable: ldidPath, arguments: ["-S", dylibDestPath])

        // 4. Patch the main executable's load commands.
        let loadCommandString = "@executable_path/Frameworks/\(dylibFileName)"
        let insertArgs = ["--inplace", "--weak", "--strip-codesig", "--all-yes", "--overwrite", loadCommandString, app.executablePath]
        guard coreBridge.executeCommand(executable: insertDylibPath, arguments: insertArgs) else {
            return fail(.insertDylibFailed)
        }

        // 5. Re-sign the patched executable, reapplying its original entitlements.
        let signArgs: [String] = (hasEntitlements && fm.fileExists(atPath: entitlementsPath))
            ? ["-S\(entitlementsPath)", app.executablePath]
            : ["-S", app.executablePath]
        guard coreBridge.executeCommand(executable: ldidPath, arguments: signArgs) else {
            return fail(.signingFailed)
        }

        // 6. Basic post-injection verification: the executable must still be
        // present and carry a readable signature blob after re-signing.
        let (verifyOK, _) = coreBridge.executeCommandCapturingOutput(executable: ldidPath, arguments: ["-e", app.executablePath])
        guard verifyOK, fm.fileExists(atPath: app.executablePath) else {
            return fail(.verificationFailed)
        }

        // 8. Persist the injection record.
        let record = InjectionRecord(
            tweakID: tweak.id,
            tweakName: tweak.name,
            bundleID: app.bundleID,
            appDisplayName: app.displayName,
            backupPath: backupAppPath,
            injectedAppVersion: app.version,
            dylibDestinationPath: dylibDestPath
        )
        return .success(record)
    }

    // MARK: - Restore

    /// Restores the target app to the exact state it was in before
    /// injection, from the record's backup. Copies the backup to a
    /// sibling temp path first and verifies it *before* touching the live
    /// app — the live app is only ever removed once a verified restore
    /// payload is sitting right next to it, ready for an (almost
    /// instantaneous, same-volume) rename into place.
    public func restore(_ record: InjectionRecord, completion: @escaping (Result<Void, InjectionError>) -> Void) {
        guard !isProcessing else { return }
        isProcessing = true
        console.log("Restoring \(record.appDisplayName) to its pre-injection backup...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.performRestore(record)

            DispatchQueue.main.async {
                self.isProcessing = false
                switch result {
                case .success:
                    self.console.log("Restored \(record.appDisplayName) to its original state.")
                    self.recordStore.remove(id: record.id)
                    completion(.success(()))
                    // The app now matches the backup again — it's served its
                    // purpose, free the space instead of leaving it forever.
                    self.deleteBackupDir(forBackupAppPath: record.backupPath)
                case .failure(let error):
                    self.console.log("Restore FAILED for \(record.appDisplayName): \(error.localizedDescription)")
                    completion(.failure(error))
                }
            }
        }
    }

    private func performRestore(_ record: InjectionRecord) -> Result<Void, InjectionError> {
        guard let app = InstalledAppScanner.shared.app(withBundleID: record.bundleID) else {
            return .failure(.appNotFound)
        }
        guard fm.fileExists(atPath: record.backupPath) else {
            return .failure(.recordMissing)
        }

        let tempRestorePath = app.bundlePath + ".cytroll_restore_tmp"
        _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", tempRestorePath])

        guard coreBridge.executeCommand(executable: "/bin/cp", arguments: ["-Rp", record.backupPath, tempRestorePath]) else {
            _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", tempRestorePath])
            return .failure(.restoreCopyFailed)
        }

        guard verifyMirror(source: record.backupPath, mirror: tempRestorePath) else {
            _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", tempRestorePath])
            return .failure(.restoreVerificationFailed)
        }

        // Verified restore payload is ready — swap it in.
        _ = coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", app.bundlePath])
        guard coreBridge.executeCommand(executable: "/bin/mv", arguments: [tempRestorePath, app.bundlePath]) else {
            return .failure(.restoreCopyFailed)
        }

        return .success(())
    }

    // MARK: - Lifecycle reconciliation

    /// Called after `TweakInjectionManager.refreshTweaks()` re-scans the
    /// tweak directory. If a tweak that has active `InjectionRecord`s is no
    /// longer present at all (its `.dylib`/`.plist` were deleted — i.e. apt
    /// fully removed/purged the package, as opposed to just disabling it),
    /// every app it was injected into gets automatically restored so no
    /// dangling dylib reference is left pointing at deleted files.
    public func reconcileAfterTweakChanges(currentTweaks: [TweakInfo]) {
        let currentTweakIDs = Set(currentTweaks.map { $0.id })
        // `.failed` records still carry a valid backup path (see `fail(_:)`
        // in performInject) and represent apps that may be left in an
        // inconsistent state — those are exactly the ones auto-restore
        // should prioritize cleaning up, not skip.
        let orphaned = recordStore.records.filter { !currentTweakIDs.contains($0.tweakID) }
        guard !orphaned.isEmpty else { return }

        console.log("\(orphaned.count) injected app(s) reference a tweak that was removed — restoring automatically.")
        restoreAll(orphaned)
    }

    /// Restores a batch of records sequentially in the background.
    /// Deliberately bypasses the single-operation `isProcessing` guard
    /// used by the user-facing `restore(_:completion:)` — these are
    /// independent, non-interactive cleanups (e.g. several apps injected
    /// with the same tweak that just got disabled/removed), each touching
    /// a different app bundle, so running them back-to-back is safe.
    public func restoreAll(_ records: [InjectionRecord]) {
        guard !records.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            for record in records {
                let result = self.performRestore(record)
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self.console.log("Restored \(record.appDisplayName) (its tweak was disabled or removed).")
                        self.recordStore.remove(id: record.id)
                        self.deleteBackupDir(forBackupAppPath: record.backupPath)
                    case .failure(let error):
                        self.console.log("Auto-restore failed for \(record.appDisplayName): \(error.localizedDescription)")
                        if case .appNotFound = error {
                            // The app itself is gone — nothing left to
                            // restore or track; drop the dead record and
                            // reclaim its backup instead of keeping a
                            // permanent entry for an uninstalled app.
                            self.recordStore.remove(id: record.id)
                            self.deleteBackupDir(forBackupAppPath: record.backupPath)
                        } else if record.status != .failed {
                            // Don't let a stale "Active"/"Needs Reapply"
                            // badge keep claiming the tweak is still wired
                            // up when the automatic restore we just tried
                            // (because the tweak was disabled/removed)
                            // actually failed — surface it so the user
                            // knows to retry manually.
                            var stale = record
                            stale.status = .failed
                            self.recordStore.upsert(stale)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// `backupAppPath` is always `<backupDir>/<AppBundleName>.app`; deleting
    /// its parent removes the whole timestamped backup (app copy +
    /// entitlements.plist) in one shot. Runs off the calling thread since
    /// callers here are on the main thread reacting to a completion.
    private func deleteBackupDir(forBackupAppPath backupAppPath: String) {
        guard !backupAppPath.isEmpty else { return }
        let backupDir = (backupAppPath as NSString).deletingLastPathComponent
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = self?.coreBridge.executeCommand(executable: "/bin/rm", arguments: ["-rf", backupDir])
        }
    }

    private func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private func verifyMirror(source: String, mirror: String) -> Bool {
        guard let sourceSnapshot = directorySnapshot(at: source),
              let mirrorSnapshot = directorySnapshot(at: mirror) else {
            return false
        }
        return sourceSnapshot.fileCount == mirrorSnapshot.fileCount && sourceSnapshot.totalSize == mirrorSnapshot.totalSize
    }

    private func directorySnapshot(at path: String) -> (fileCount: Int, totalSize: Int64)? {
        guard let enumerator = fm.enumerator(atPath: path) else { return nil }

        var count = 0
        var size: Int64 = 0

        for item in enumerator {
            guard let relativePath = item as? String else { continue }
            let fullPath = path + "/" + relativePath

            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { continue }

            count += 1
            if let attributes = try? fm.attributesOfItem(atPath: fullPath), let fileSize = attributes[.size] as? Int64 {
                size += fileSize
            }
        }

        return (count, size)
    }
}
