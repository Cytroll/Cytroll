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

            let isInstalled = status.contains("install ok installed")
            let isHalfInstalled = status.contains("half-installed")
            let isHalfConfigured = status.contains("half-configured")
            let isUnpacked = status.contains("unpacked")

            // تجاهل الحزم غير المثبتة بالكامل أو المحذوفة
            guard isInstalled || isHalfInstalled || isHalfConfigured || isUnpacked else {
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
                isInstalled: true,
                isBroken: !isInstalled // If it passed the guard but is not 'install ok installed', it's broken
            )
            installedPackages.append(pkg)
        }

        return installedPackages
    }
}
