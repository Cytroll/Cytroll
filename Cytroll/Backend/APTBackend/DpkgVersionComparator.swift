import Foundation

/// Faithful subset of dpkg's version comparison algorithm
/// (`epoch:upstream_version-debian_revision`), used to detect real
/// available updates by comparing an installed package version against
/// the version found in APT repo indices — the same logic `apt`/`dpkg`
/// use under the hood, reimplemented natively so the UI can show
/// "Changes" without shelling out.
public enum DpkgVersionComparator {

    /// Returns -1, 0, or 1, matching the semantics of `dpkg --compare-versions`.
    public static func compare(_ lhs: String, _ rhs: String) -> Int {
        let (lEpoch, lRest) = splitEpoch(lhs)
        let (rEpoch, rRest) = splitEpoch(rhs)

        if lEpoch != rEpoch {
            return lEpoch < rEpoch ? -1 : 1
        }

        let (lUpstream, lRevision) = splitRevision(lRest)
        let (rUpstream, rRevision) = splitRevision(rRest)

        let upstreamCmp = verrevcmp(lUpstream, rUpstream)
        if upstreamCmp != 0 { return upstreamCmp }

        return verrevcmp(lRevision, rRevision)
    }

    /// Convenience for update detection: true when `candidate` (repo) is strictly newer than `installed`.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) > 0
    }

    // MARK: - Parsing

    private static func splitEpoch(_ version: String) -> (Int, String) {
        guard let colonIndex = version.firstIndex(of: ":") else { return (0, version) }
        let epochString = String(version[version.startIndex..<colonIndex])
        let rest = String(version[version.index(after: colonIndex)...])
        return (Int(epochString) ?? 0, rest)
    }

    private static func splitRevision(_ version: String) -> (String, String) {
        guard let dashIndex = version.lastIndex(of: "-") else { return (version, "0") }
        let upstream = String(version[version.startIndex..<dashIndex])
        let revision = String(version[version.index(after: dashIndex)...])
        return (upstream, revision)
    }

    // MARK: - verrevcmp (dpkg's character-class ordering algorithm)

    /// dpkg orders '~' before nothing, nothing before letters/digits, and
    /// everything else after letters by ASCII value.
    private static func order(_ c: Character?) -> Int {
        guard let c = c else { return 0 }
        if c == "~" { return -1 }
        if c.isNumber { return 0 }
        if let ascii = c.asciiValue, c.isLetter { return Int(ascii) }
        return Int(c.asciiValue ?? 0) + 256
    }

    private static func verrevcmp(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        var i = 0, j = 0

        while i < aChars.count || j < bChars.count {
            while (i < aChars.count && !aChars[i].isNumber) || (j < bChars.count && !bChars[j].isNumber) {
                let ac: Character? = i < aChars.count ? aChars[i] : nil
                let bc: Character? = j < bChars.count ? bChars[j] : nil
                let ao = order(ac)
                let bo = order(bc)
                if ao != bo { return ao < bo ? -1 : 1 }
                if i < aChars.count { i += 1 }
                if j < bChars.count { j += 1 }
            }

            while i < aChars.count, aChars[i] == "0" { i += 1 }
            while j < bChars.count, bChars[j] == "0" { j += 1 }

            var firstDiff = 0
            while i < aChars.count, j < bChars.count, aChars[i].isNumber, bChars[j].isNumber {
                if firstDiff == 0, let av = aChars[i].asciiValue, let bv = bChars[j].asciiValue, av != bv {
                    firstDiff = Int(av) - Int(bv)
                }
                i += 1
                j += 1
            }

            if i < aChars.count, aChars[i].isNumber { return 1 }
            if j < bChars.count, bChars[j].isNumber { return -1 }
            if firstDiff != 0 { return firstDiff < 0 ? -1 : 1 }
        }
        return 0
    }
}
