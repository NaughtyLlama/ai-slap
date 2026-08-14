import Foundation

/// The rulebook: what a context *is*. Deliberately generic — patterns come from
/// published window-title formats, not from any individual's log.
///
/// What is unusual *for a given person* is not in here. That is the Personaliser's
/// job, and keeping the two apart is what lets the rulebook become a shared remote
/// artifact (docs/03) while the adaptation stays entirely on the device.
struct Rulebook: Decodable {
    let schemaVersion: Int
    let version: String
    let aiContexts: AIContexts
    let browserBundleIds: [String]
    let rules: [Rule]

    struct AIContexts: Decodable {
        /// Native AI clients, matched exactly on bundle ID.
        let bundleIds: [String]
        /// Consulted **only for browser windows**, where the title is the page
        /// `<title>`. Matching these against any window would let a document named
        /// after a model silence the whole product.
        let browserTitlePatterns: [String]
    }

    struct Rule: Decodable {
        let id: String
        let enabled: Bool
        let category: String
        let match: Match
        let condition: Condition
        let confidence: Double
        let cooldownMs: Double
        let nudge: Nudge

        /// Every field is optional in the JSON. Swift's synthesised `Decodable` does
        /// *not* fall back to a property's default when a key is absent — it throws —
        /// so the decoding is written out by hand. This matters more than it looks:
        /// once the rulebook is fetched remotely, a rule omitting one optional key
        /// would otherwise fail the whole document and leave the client with no rules.
        struct Match: Decodable {
            var useBrowserBundles = false
            var extraBundleIds: [String] = []
            var titlePatterns: [String] = []
            var excludeTitlePatterns: [String] = []
            var matchesAnything = false

            private enum CodingKeys: String, CodingKey {
                case useBrowserBundles, extraBundleIds, titlePatterns
                case excludeTitlePatterns, matchesAnything
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                useBrowserBundles = try container.decodeIfPresent(
                    Bool.self, forKey: .useBrowserBundles) ?? false
                extraBundleIds = try container.decodeIfPresent(
                    [String].self, forKey: .extraBundleIds) ?? []
                titlePatterns = try container.decodeIfPresent(
                    [String].self, forKey: .titlePatterns) ?? []
                excludeTitlePatterns = try container.decodeIfPresent(
                    [String].self, forKey: .excludeTitlePatterns) ?? []
                matchesAnything = try container.decodeIfPresent(
                    Bool.self, forKey: .matchesAnything) ?? false
            }
        }

        struct Condition: Decodable {
            let dwellMs: Double
            let noAiContextForMs: Double
            var repeatCount: Int?
            var repeatWithinMs: Double?
        }

        struct Nudge: Decodable {
            let copy: String
            let promptTemplate: String
        }
    }

    /// Client pins a schema version and ignores what it doesn't understand, so an
    /// old client degrades instead of breaking (docs/03).
    static let supportedSchemaVersion = 1

    static func loadBundled() throws -> Rulebook {
        guard let url = Bundle.main.url(forResource: "rulebook", withExtension: "json")
        else { throw RulebookError.missing }

        let data = try Data(contentsOf: url)
        let book = try JSONDecoder().decode(Rulebook.self, from: data)
        guard book.schemaVersion <= supportedSchemaVersion else {
            throw RulebookError.unsupportedSchema(book.schemaVersion)
        }
        return book
    }

    enum RulebookError: LocalizedError {
        case missing
        case unsupportedSchema(Int)

        var errorDescription: String? {
            switch self {
            case .missing:
                return "rulebook.json is missing from the app bundle."
            case .unsupportedSchema(let version):
                return "Rulebook schema v\(version) is newer than this app understands."
            }
        }
    }
}

/// A rule with its regexes compiled once at load rather than per context change.
struct CompiledRule {
    let rule: Rulebook.Rule
    let bundleIDs: Set<String>
    let titlePatterns: [NSRegularExpression]
    let excludePatterns: [NSRegularExpression]

    var id: String { rule.id }
    var category: String { rule.category }

    init(rule: Rulebook.Rule, browserBundleIds: [String]) {
        self.rule = rule
        var ids = Set(rule.match.extraBundleIds)
        if rule.match.useBrowserBundles {
            ids.formUnion(browserBundleIds)
        }
        self.bundleIDs = ids
        self.titlePatterns = rule.match.titlePatterns.compactMap(Self.compile)
        self.excludePatterns = rule.match.excludeTitlePatterns.compactMap(Self.compile)
    }

    static func compile(_ pattern: String) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            // A malformed pattern disables its own rule rather than crashing the app.
            // This matters more once the rulebook is fetched remotely.
            NSLog("AISlap: bad rulebook pattern \(pattern) — \(error.localizedDescription)")
            return nil
        }
    }

    func matches(_ context: WindowContext) -> Bool {
        guard rule.enabled else { return false }
        if rule.match.matchesAnything { return true }

        if !bundleIDs.isEmpty && !bundleIDs.contains(context.bundleID) {
            return false
        }
        guard let title = context.title else {
            // No title means tier 0 only. Firing a content rule on an app name alone
            // is exactly the false positive that gets the app uninstalled.
            return false
        }
        if excludePatterns.contains(where: { $0.matches(title) }) { return false }
        if titlePatterns.isEmpty { return true }
        return titlePatterns.contains { $0.matches(title) }
    }
}

extension NSRegularExpression {
    func matches(_ string: String) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return firstMatch(in: string, range: range) != nil
    }
}
