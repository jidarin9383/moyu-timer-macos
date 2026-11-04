import Foundation
import Darwin

/// The registrable domain under an ICANN suffix, e.g. docs.example.co.uk → example.co.uk.
/// Private hosting suffixes intentionally collapse to the hosting provider's main domain.
enum WebsiteDomain {
    private struct Rules {
        var exact: Set<String> = []
        var wildcard: Set<String> = []
        var exceptions: Set<String> = []
    }

    private static let rules: Rules = {
        let file = ProcessInfo.processInfo.environment["MOYU_PUBLIC_SUFFIX_LIST"].map {
            URL(fileURLWithPath: $0)
        } ?? Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat")
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else {
            preconditionFailure("Missing bundled Public Suffix List")
        }
        var result = Rules()
        for line in text.components(separatedBy: .newlines) {
            if line.contains("===END ICANN DOMAINS===") { break }
            guard !line.isEmpty, !line.hasPrefix("//") else { continue }
            var rule = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let exception = rule.hasPrefix("!")
            let wildcard = rule.hasPrefix("*.")
            if exception { rule.removeFirst() }
            if wildcard { rule.removeFirst(2) }
            // Canonical ASCII makes Unicode and punycode hosts share the same key.
            let canonical = URL(string: "https://\(rule)")?.host?.lowercased() ?? rule.lowercased()
            if exception { result.exceptions.insert(canonical) }
            else if wildcard { result.wildcard.insert(canonical) }
            else { result.exact.insert(canonical) }
        }
        return result
    }()

    static func mainDomain(_ hostname: String) -> String {
        let trimmed = hostname.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        if trimmed.contains(":") { return trimmed }
        let host = URL(string: "https://\(trimmed)")?.host?.lowercased() ?? trimmed
        // Local names and IP addresses are not registrable DNS domains.
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 { return host }
        let labels = host.split(separator: ".")
        guard labels.count > 1 else { return host }
        var suffixCount = 1
        for index in labels.indices {
            let candidate = labels[index...].joined(separator: ".")
            let count = labels.count - index
            if rules.exceptions.contains(candidate) { return candidate }
            if rules.exact.contains(candidate) { suffixCount = max(suffixCount, count) }
            if index > 0, rules.wildcard.contains(candidate) {
                suffixCount = max(suffixCount, count + 1)
            }
        }
        return labels.suffix(min(labels.count, suffixCount + 1)).joined(separator: ".")
    }
}
