import Foundation

private let sharedQueue = DispatchQueue(label: "MFS.HistoryStore", qos: .utility)

/// Keeps a list of records in a JSON file in Application Support, which survives app updates and new builds.
/// Writes are atomic and happen off the main thread; the file is never deleted by the app.
struct HistoryStore<Element: Codable> {
    let url: URL
    // Shared so writes from any instance to the same file stay ordered and flush() waits for all of them.
    private static var queue: DispatchQueue { sharedQueue }

    init(filename: String, directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent(filename)
    }

    func load() -> [Element] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Element].self, from: data)) ?? []
    }

    func save(_ elements: [Element]) {
        let url = url
        Self.queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(elements) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Waits for queued writes; for tests.
    func flush() { Self.queue.sync {} }
}
