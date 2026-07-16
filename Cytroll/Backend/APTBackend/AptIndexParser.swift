import Foundation

public final class AptIndexParser {
    public static let shared = AptIndexParser()
    
    private var aptListsPath: String { RootlessPaths.aptListsDir + "/" }
    
    private init() {}
    
    /// Reads and parses all APT index files natively to get repo packages.
    public func parseRepoPackages() -> [Package] {
        var repoPackages: [Package] = []
        
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: aptListsPath) else {
            return repoPackages
        }
        
        // Find all _Packages files
        let packageFiles = files.filter { $0.hasSuffix("_Packages") }
        
        for file in packageFiles {
            let path = aptListsPath + file
            // `autoreleasepool` ensures the (potentially multi-MB) String for
            // this file is released before the next iteration allocates the
            // next one, instead of all of them lingering until the loop ends.
            autoreleasepool {
                guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                    return
                }

                // استخراج عنوان السورس تقريبياً من اسم الملف
                // مثال: repo.chariz.com_._Packages -> repo.chariz.com
                var sourceURLGuess: String? = nil
                if let firstUnderscoreIndex = file.firstIndex(of: "_") {
                    sourceURLGuess = "https://" + String(file[..<firstUnderscoreIndex])
                }

                // Streaming parse — avoids materializing the whole file as a
                // `[block]` array (and each block as a `[line]` array) at once.
                ControlFieldParser.forEachBlock(in: content) { fields in
                    guard let id = fields["Package"], !id.isEmpty else { return }

                    let name = fields["Name"].flatMap { $0.isEmpty ? nil : $0 } ?? id
                    let pkg = Package(
                        id: id,
                        name: name,
                        version: fields["Version"] ?? "",
                        author: fields["Author"] ?? fields["Maintainer"] ?? "",
                        architecture: fields["Architecture"] ?? "",
                        description: fields["Description"] ?? "",
                        sourceURL: sourceURLGuess,
                        section: fields["Section"] ?? "Unknown",
                        dependsGroups: ControlFieldParser.parseDependsGroups(fields["Depends"]),
                        conflicts: ControlFieldParser.parseFlatPackageList(fields["Conflicts"]),
                        installedSizeKB: fields["Installed-Size"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
                        downloadSizeBytes: fields["Size"].flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) },
                        homepageURL: fields["Homepage"].flatMap { $0.isEmpty ? nil : $0 },
                        depictionURL: (fields["Depiction"] ?? fields["SileoDepiction"]).flatMap { $0.isEmpty ? nil : $0 }
                    )
                    repoPackages.append(pkg)
                }
            }
        }
        
        return repoPackages
    }
}
