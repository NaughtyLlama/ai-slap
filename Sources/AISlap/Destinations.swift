import Foundation

/// The list of AI apps a handoff can go to, read from the same file as the rules.
///
/// It lives in a JSON file beside the binary rather than compiled in, because the
/// details most likely to break are the ones that belong to other people: a vendor
/// renames a bundle, ships a second app, or changes the keystroke that starts a new
/// chat. Those should be an edit, not a new build.
///
/// This decodes only the destinations, so a malformed rule cannot cost you the ability
/// to hand anything off at all.
enum Destinations {
    struct File: Decodable {
        let schemaVersion: Int
        let destinations: [AIDestination]
    }

    static let supportedSchemaVersion = 1

    /// Falling back to a built-in list matters more than it looks: a missing or broken
    /// file would otherwise mean an app that launches, shows a menu, and can't do the
    /// one thing it does.
    static func load() -> [AIDestination] {
        guard let url = Bundle.main.url(forResource: "rulebook", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.schemaVersion <= supportedSchemaVersion,
              !file.destinations.isEmpty
        else { return fallback }
        return file.destinations
    }

    static let fallback: [AIDestination] = [
        AIDestination(id: "claude", name: "Claude", bundleId: "com.anthropic.claudefordesktop",
                      webURL: "https://claude.ai/new", newChatShortcut: "cmd+n", acceptsPastedImage: true),
        AIDestination(id: "chatgpt", name: "ChatGPT", bundleId: "com.openai.chat",
                      webURL: "https://chatgpt.com", newChatShortcut: "cmd+n", acceptsPastedImage: true),
        AIDestination(id: "gemini", name: "Gemini", bundleId: "com.google.GeminiMacOS",
                      webURL: "https://gemini.google.com/app", newChatShortcut: "cmd+n", acceptsPastedImage: true),
    ]
}
