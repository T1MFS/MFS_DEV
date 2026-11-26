import Foundation

/// The user's standing approval to stream biometrics to DigitalMe. Approved once, then it applies until stopped.
struct BiometricStreamConsent: Codable, Equatable {
    /// What may be sent. Nothing outside this set is ever read for the stream.
    var approved: Set<HealthDataKind> = []
    /// The DigitalMe connection the approval was given for.
    var connectionID: UUID?
    var approvedAt: Date?
    /// Set when the stream stopped itself (security changed, upload refused). The approval stays; the user resumes it.
    var pausedReason: String?

    var isActive: Bool { !approved.isEmpty && connectionID != nil }
    var isStreaming: Bool { isActive && pausedReason == nil }
}

/// Streams approved Apple Health data to DigitalMe at the pace of the glucose readings.
/// Call `readingArrived()` for every new glucose reading. Each call sends whatever is new for the approved kinds:
/// heart rate and HRV may be zero, one or many samples per reading, and a sleep night goes out once it has ended.
/// State (Health anchors) is saved only after DigitalMe accepts a batch, so a failed send is repeated with the next reading.
final class BiometricStream: ObservableObject {
    typealias Reader = (Set<HealthDataKind>, BiometricSyncState) async throws -> BiometricBatch
    typealias Uploader = (ServiceConnection, [[String: Any]]) async throws -> Void

    @Published private(set) var consent: BiometricStreamConsent { didSet { saveConsent() } }
    @Published private(set) var lastSent: Date?
    @Published private(set) var lastSentCount = 0
    @Published private(set) var lastError: String?

    /// Where the connections come from; set once the stores exist.
    var connections: () -> [ServiceConnection] = { [] }
    static let chunkSize = 500

    private let read: Reader
    private let upload: Uploader
    private let defaults: UserDefaults
    private var syncState: BiometricSyncState
    private var running = false
    private var rerun = false
    private static let consentKey = "MFS.BiometricStreamConsent"

    init(defaults: UserDefaults = .standard, read: @escaping Reader, upload: Uploader? = nil) {
        self.defaults = defaults
        self.read = read
        // Standing approval is the user's confirmation, and `readingArrived` checks it before every send.
        self.upload = upload ?? { connection, records in
            try await DigitalMeUploadClient(connection: connection).upload(records: records, to: .biometrics, userConfirmed: true)
        }
        syncState = BiometricSyncState.load(from: defaults)
        if let data = defaults.data(forKey: Self.consentKey), let saved = try? JSONDecoder().decode(BiometricStreamConsent.self, from: data) {
            consent = saved
        } else {
            consent = BiometricStreamConsent()
        }
    }

    /// Approves or withdraws one kind. The first approval records the connection and the time.
    @MainActor func setApproved(_ kind: HealthDataKind, _ on: Bool, connectionID: UUID) {
        var next = consent
        if on {
            if next.connectionID != connectionID { next.approved = [] }
            next.approved.insert(kind)
            next.connectionID = connectionID
            next.approvedAt = next.approvedAt ?? Date()
            next.pausedReason = nil
        } else {
            next.approved.remove(kind)
            if next.approved.isEmpty { next = BiometricStreamConsent() }
        }
        consent = next
    }

    /// Ends the approval and forgets what was sent, so approving again starts from the normal first-sync window.
    @MainActor func stop() {
        consent = BiometricStreamConsent()
        syncState = BiometricSyncState()
        syncState.save(to: defaults)
        lastError = nil
    }

    @MainActor func resume() {
        guard consent.isActive else { return }
        consent.pausedReason = nil
        lastError = nil
    }

    @MainActor func readingArrived() async {
        guard consent.isStreaming else { return }
        // Readings can arrive while a send is running; fold them into one more pass.
        if running { rerun = true; return }
        running = true
        defer { running = false }
        repeat {
            rerun = false
            await syncOnce()
        } while rerun && consent.isStreaming
    }

    @MainActor private func syncOnce() async {
        let started = consent
        guard let id = started.connectionID,
              let connection = connections().first(where: { $0.id == id && $0.enabled }) else {
            consent.pausedReason = "The DigitalMe connection is missing or disabled."
            return
        }
        do {
            let batch = try await read(started.approved, syncState)
            let records = batch.records
            var start = 0
            while start < records.count {
                let end = min(start + Self.chunkSize, records.count)
                try await upload(connection, Array(records[start..<end]))
                start = end
            }
            // Withdrawn or changed during the send: keep the old state; DigitalMe ignores any repeat.
            guard consent == started else { return }
            syncState = batch.pendingState
            syncState.save(to: defaults)
            lastError = nil
            if !records.isEmpty {
                lastSent = Date()
                lastSentCount = records.count
            }
        } catch let error as DigitalMeUploadError {
            lastError = error.errorDescription
            if !error.isRetryable { consent.pausedReason = error.errorDescription ?? "Upload refused." }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func saveConsent() {
        if let data = try? JSONEncoder().encode(consent) { defaults.set(data, forKey: Self.consentKey) }
    }
}
