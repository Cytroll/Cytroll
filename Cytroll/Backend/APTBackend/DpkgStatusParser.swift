import Foundation

public final class DpkgStatusParser {
    public static let shared = DpkgStatusParser()
    
    private var statusPath: String { RootlessPaths.dpkgStatus }
    
    private init() {}
    
    /// Reads and parses the dpkg status file into an array of Package objects.
    /// Streaming (one record at a time) instead of splitting the whole file
    /// into a `[block]` array up front, to keep peak memory low.
    public func parseInstalledPackages() -> [Package] {
        var installedPackages: [Package] = []

        guard let content = try? String(contentsOfFile: statusPath, encoding: .utf8) else {
            return installedPackages
        }

        ControlFieldParser.forEachBlock(in: content) { fields in
            guard let id = fields["Package"], !id.isEmpty else { return }
            guard let status = fields["Status"] else { return }

            // dpkg's Status field is "<want> <flag> <status>", e.g.
            // "install ok installed" or "hold ok installed" for a package
            // that's fully installed but pinned via `apt-mark hold` (the
            // *want* word changes from "install" to "hold" — the actual
            // install status is always the third word). Matching on the
            // literal substring "install ok installed" used to miss held
            // packages entirely, silently dropping them from every list.
            let parts = status.split(separator: " ").map(String.init)
            let statusWord = parts.count == 3 ? parts[2] : ""

            let isFullyInstalled = statusWord == "installed"
            let isHalfInstalled = statusWord == "half-installed"
            let isHalfConfigured = statusWord == "half-configured"
            let isUnpacked = statusWord == "unpacked"

            // تجاهل الحزم غير المثبتة بالكامل أو المحذوفة
            guard isFullyInstalled || isHalfInstalled || isHalfConfigured || isUnpacked else {
                return
            }

            let name = fields["Name"].flatMap { $0.isEmpty ? nil : $0 } ?? id
            let pkg = Package(
                id: id,
                name: name,
                version: fields["Version"] ?? "",
                author: fields["Author"] ?? fields["Maintainer"] ?? "",
                architecture: fields["Architecture"] ?? "",
                description: fields["Description"] ?? "",
                section: fields["Section"] ?? "Unknown",
                dependsGroups: ControlFieldParser.parseDependsGroups(fields["Depends"]),
                conflicts: ControlFieldParser.parseFlatPackageList(fields["Conflicts"]),
                installedSizeKB: fields["Installed-Size"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
                homepageURL: fields["Homepage"].flatMap { $0.isEmpty ? nil : $0 },
                isInstalled: true,
                isBroken: !isFullyInstalled // Passed the guard but current status isn't "installed" — half-done/broken.
            )
            installedPackages.append(pkg)
        }

        return installedPackages
    }
}
