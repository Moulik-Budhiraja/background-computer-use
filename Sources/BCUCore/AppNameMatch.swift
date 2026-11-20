import Foundation

/// How an agent's app name ("Chrome", "Notes.app", "com.apple.Notes") is
/// matched against app names. String handling only, so it can be tested.
enum AppNameMatch {
    /// The query without surrounding spaces or a trailing ".app" (only at
    /// the end: "com.apple.Notes" keeps its ".apple").
    static func stripped(_ query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count > 4, q.lowercased().hasSuffix(".app") else { return q }
        return String(q.dropLast(4))
    }

    /// Whether two bundle ids are the same app (they're case-insensitive).
    static func sameBundleID(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// How well a name matches, best last.
    enum Rank: Int, Comparable {
        /// Anywhere inside it: "ode" in "Xcode".
        case substring
        /// The start, but not of a word: "Chrom" in "Chromium".
        case prefix
        /// Whole words of it: "Chrome" in "Google Chrome".
        case word
        /// Its first whole words: "Visual Studio" in "Visual Studio Code".
        case leadingWords
        case exact

        static func < (a: Rank, b: Rank) -> Bool { a.rawValue < b.rawValue }
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func rank(_ query: String, name: String) -> Rank? {
        let q = stripped(query).lowercased(), n = name.lowercased()
        guard !q.isEmpty else { return nil }
        if n == q { return .exact }
        let qw = words(q), nw = words(n)
        if !qw.isEmpty && nw.count >= qw.count {
            if Array(nw.prefix(qw.count)) == qw { return .leadingWords }
            for start in 0...(nw.count - qw.count) where Array(nw[start..<start + qw.count]) == qw { return .word }
        }
        if n.hasPrefix(q) { return .prefix }
        if n.contains(q) { return .substring }
        return nil
    }

    enum Outcome: Equatable {
        case none
        case one(String)
        /// More than one name matches equally well (sorted).
        case ambiguous([String])
    }

    /// The name that matches best. Names that differ only in case count once.
    static func best(_ query: String, among names: [String]) -> Outcome {
        var top: Rank?
        var hits: [String] = []
        for name in names {
            guard let r = rank(query, name: name) else { continue }
            if top == nil || r > top! {
                top = r
                hits = [name]
            } else if r == top, !hits.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                hits.append(name)
            }
        }
        switch hits.count {
        case 0: return .none
        case 1: return .one(hits[0])
        default: return .ambiguous(hits.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        }
    }
}
