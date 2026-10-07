import Foundation

/// Human-facing content; recovery identity lives in the Obsidian link, never in notes.
public struct ReminderContent {
    public let title: String
    public let notes: String?
    public let url: URL
    public init(task: BridgeTask, vault: String) {
        title = Self.plainTitle(task.title)
        notes = task.scheduled.map { "Scheduled: \($0)" }
        var link = URLComponents()
        link.scheme = "obsidian"; link.host = "open"
        link.queryItems = [URLQueryItem(name: "vault", value: vault), URLQueryItem(name: "file", value: task.path), URLQueryItem(name: "bridgeTask", value: task.id)]
        url = link.url!
    }
    public static func plainTitle(_ value: String) -> String {
        var text = value
        // Keep display aliases and link text, not Markdown/Obsidian syntax.
        let patterns: [(String, (String) -> String)] = [
            (#"!?\[\[([^\]]+)\]\]"#, { body in
                let parts = body.components(separatedBy: "|")
                if parts.count > 1 { return parts.last! }
                return body.components(separatedBy: "/").last ?? body
            }),
            (#"!?\[([^\]]+)\]\([^\)]+\)"#, { $0 }),
        ]
        for (pattern, render) in patterns {
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range, in: text), let body = Range(match.range(at: 1), in: text) else { continue }
                text.replaceSubrange(range, with: render(String(text[body])))
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Legacy notes are accepted during migration; contradictory identities fail closed.
public func managedTaskID(url: URL?, notes: String?) throws -> String? {
    var ids: [String] = []
    if let url, url.scheme == "obsidian", url.host == "open", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
        ids += items.filter { $0.name == "bridgeTask" }.compactMap(\.value)
    }
    ids += (notes ?? "").components(separatedBy: "\n").filter { $0.hasPrefix("obsidian-reminders-bridge:") }.map { String($0.dropFirst("obsidian-reminders-bridge:".count)) }
    guard ids.allSatisfy({ UUID(uuidString: $0) != nil }), Set(ids).count <= 1 else {
        throw BridgeError.invalid("A reminder has conflicting or invalid task links. No changes were made to it.")
    }
    return ids.first
}

/// Remove old bridge bookkeeping without changing a task's title, dates or completion.
/// This is also safe for paused/pending links: ownership is already established.
public func migrateLegacyReminder(url: URL?, notes: String?, id: String, vault: String) -> (url: URL, notes: String?)? {
    let lines = (notes ?? "").components(separatedBy: "\n")
    guard lines.contains("obsidian-reminders-bridge:\(id)") else { return nil }
    let oldPath = lines.first(where: { $0.hasPrefix("Obsidian: ") }).map { String($0.dropFirst("Obsidian: ".count)) }
    var link = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    if link?.scheme != "obsidian" || link?.host != "open" {
        guard let oldPath else { return nil }
        link = URLComponents(); link?.scheme = "obsidian"; link?.host = "open"
        link?.queryItems = [URLQueryItem(name: "vault", value: vault), URLQueryItem(name: "file", value: oldPath)]
    }
    let items = (link?.queryItems ?? []).filter { $0.name != "bridgeTask" }
    link?.queryItems = items + [URLQueryItem(name: "bridgeTask", value: id)]
    guard let newURL = link?.url else { return nil }
    let cleaned = lines.filter { $0 != "obsidian-reminders-bridge:\(id)" && (oldPath == nil || $0 != "Obsidian: \(oldPath!)") }.joined(separator: "\n")
    return (newURL, cleaned.isEmpty ? nil : cleaned)
}

/// Preserve exported Tasks order; only stale mappings use a deterministic ID order.
public func reconciliationOrder(tasks: [BridgeTask], mappedIDs: [String]) -> [String] {
    let ids = tasks.map(\.id)
    let existing = Set(ids)
    return ids + mappedIDs.filter { !existing.contains($0) }.sorted()
}
