import Foundation
import HealthKit
import LoopKit

/// Read-only CGM delegate shared by the G7 host and the development mock host.
class CGMHostBase: NSObject, CGMManagerDelegate {
    let feed: GlucoseFeed
    let queue: DispatchQueue
    private let lock = NSLock()
    private var latestDate: Date?

    /// Name used for this host in the diagnostics log.
    let diagnosticsName: String

    init(feed: GlucoseFeed, queueLabel: String) {
        self.feed = feed
        self.diagnosticsName = queueLabel
        self.queue = DispatchQueue(label: queueLabel)
        super.init()
    }

    var credentialPrefix: String { "MFS" }

    func handle(_ result: CGMReadingResult) {
        let name = diagnosticsName
        let log = DiagnosticsLog.shared
        guard case .newData(let samples) = result else {
            let description: String
            switch result {
            case .noData: description = "noData"
            case .unreliableData: description = "unreliableData (sensor reported unreliable values)"
            case .error(let error): description = "error: \(error)"
            case .newData: description = "newData"
            }
            log.record(name, "Reading result: \(description)")
            log.update(name) { $0.callbacks += 1; $0.lastResult = description; $0.lastResultAt = Date() }
            return
        }
        let new = samples.map { GlucoseReading(date: $0.date, milligramsPerDeciliter: $0.quantity.doubleValue(for: .milligramsPerDeciliter)) }
        lock.lock()
        if let newest = new.map(\.date).max() {
            latestDate = max(latestDate ?? newest, newest)
        }
        lock.unlock()
        let newest = new.map(\.date).max()
        log.record(name, "newData: \(new.count) sample(s), newest \(newest.map { $0.formatted(date: .omitted, time: .standard) } ?? "none")")
        log.update(name) {
            $0.callbacks += 1
            $0.samplesReceived += new.count
            $0.lastResult = "newData (\(new.count))"
            $0.lastResultAt = Date()
            if let newest { $0.newestSampleDate = max($0.newestSampleDate ?? newest, newest) }
        }
        DispatchQueue.main.async {
            let before = self.feed.readings.count
            self.feed.merge(new)
            let added = self.feed.readings.count - before
            log.update(name) { $0.samplesMerged += added }
            if added < new.count { log.record(name, "\(new.count - added) sample(s) skipped as duplicates by timestamp") }
        }
    }

    func stateDidChange(_ manager: CGMManager) {}

    func statusDidChange(_ status: CGMManagerStatus) {
        DiagnosticsLog.shared.record(diagnosticsName, "Status: \(status)")
    }

    func wantsDeletion(_ manager: CGMManager) {}

    // MARK: CGMManagerDelegate

    func startDateToFilterNewData(for manager: CGMManager) async -> Date? {
        lock.lock()
        defer { lock.unlock() }
        DiagnosticsLog.shared.record(diagnosticsName, "Manager asked for the filter start date: \(latestDate.map { $0.formatted() } ?? "none")")
        return latestDate
    }

    func cgmManager(_ manager: CGMManager, hasNew readingResult: CGMReadingResult) async {
        handle(readingResult)
    }

    func cgmManager(_ manager: CGMManager, hasNew events: [PersistedCgmEvent]) async {
        DiagnosticsLog.shared.record(diagnosticsName, "Received \(events.count) CGM event(s)")
    }

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
        DiagnosticsLog.shared.record(diagnosticsName, "Device log (\(type)): \(message)")
        completion?(nil)
    }

    @MainActor func issueAlert(_ alert: Alert) async {}

    @MainActor func retractAlert(identifier: Alert.Identifier) async {}

    func doesIssuedAlertExist(identifier: Alert.Identifier) async throws -> Bool { false }

    func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }

    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }

    func recordRetractedAlert(_ alert: Alert, at date: Date) async throws {}
}
