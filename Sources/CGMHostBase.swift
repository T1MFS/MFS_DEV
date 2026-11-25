import Foundation
import HealthKit
import LoopKit

/// Read-only CGM delegate shared by the G7 host and the development mock host.
class CGMHostBase: NSObject, CGMManagerDelegate {
    let feed: GlucoseFeed
    let queue: DispatchQueue
    private let lock = NSLock()
    private var latestDate: Date?

    init(feed: GlucoseFeed, queueLabel: String) {
        self.feed = feed
        self.queue = DispatchQueue(label: queueLabel)
        super.init()
    }

    var credentialPrefix: String { "MFS" }

    func handle(_ result: CGMReadingResult) {
        guard case .newData(let samples) = result else { return }
        let new = samples.map { GlucoseReading(date: $0.date, milligramsPerDeciliter: $0.quantity.doubleValue(for: .milligramsPerDeciliter)) }
        lock.lock()
        if let newest = new.map(\.date).max() {
            latestDate = max(latestDate ?? newest, newest)
        }
        lock.unlock()
        DispatchQueue.main.async { self.feed.merge(new) }
    }

    func stateDidChange(_ manager: CGMManager) {}

    func statusDidChange(_ status: CGMManagerStatus) {}

    func wantsDeletion(_ manager: CGMManager) {}

    // MARK: CGMManagerDelegate

    func startDateToFilterNewData(for manager: CGMManager) async -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return latestDate
    }

    func cgmManager(_ manager: CGMManager, hasNew readingResult: CGMReadingResult) async {
        handle(readingResult)
    }

    func cgmManager(_ manager: CGMManager, hasNew events: [PersistedCgmEvent]) async {}

    func cgmManagerWantsDeletion(_ manager: CGMManager) async {
        wantsDeletion(manager)
    }

    func cgmManagerDidUpdateState(_ manager: CGMManager) async {
        stateDidChange(manager)
    }

    func credentialStoragePrefix(for manager: CGMManager) -> String {
        credentialPrefix
    }

    func cgmManager(_ manager: CGMManager, didUpdate status: CGMManagerStatus) {
        statusDidChange(status)
    }

    // MARK: DeviceManagerDelegate

    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {
        completion?(nil)
    }

    @MainActor func issueAlert(_ alert: Alert) async {}

    @MainActor func retractAlert(identifier: Alert.Identifier) async {}

    func doesIssuedAlertExist(identifier: Alert.Identifier) async throws -> Bool { false }

    func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }

    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }

    func recordRetractedAlert(_ alert: Alert, at date: Date) async throws {}
}
