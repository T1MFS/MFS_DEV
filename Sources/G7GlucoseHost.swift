import Foundation
import HealthKit
import LoopKit
import G7SensorKit

/// Hosts a `G7CGMManager` and exposes its glucose readings. Read-only.
final class G7GlucoseHost: NSObject, ObservableObject, CGMManagerDelegate {
    @Published private(set) var readings: [GlucoseReading] = []
    @Published private(set) var sensorStatus: CGMManagerStatus?

    private let store: DeviceStateStore
    private let queue = DispatchQueue(label: "MFS.G7GlucoseHost")
    private(set) var manager: G7CGMManager

    init(store: DeviceStateStore = DeviceStateStore(key: "MFS.G7CGMManager.rawState")) {
        self.store = store
        if let rawState = store.load(), let restored = G7CGMManager(rawState: rawState) {
            manager = restored
        } else {
            manager = G7CGMManager()
        }
        super.init()
        manager.cgmManagerDelegate = self
        manager.delegateQueue = queue
        store.save(manager.rawState)
    }

    func fetchNewData() {
        manager.fetchNewDataIfNeeded { [weak self] result in
            self?.handle(result)
        }
    }

    private func handle(_ result: CGMReadingResult) {
        guard case .newData(let samples) = result else { return }
        let unit = HKUnit.milligramsPerDeciliter
        let new = samples.map { GlucoseReading(date: $0.date, milligramsPerDeciliter: $0.quantity.doubleValue(for: unit)) }
        DispatchQueue.main.async {
            let known = Set(self.readings.map(\.date))
            self.readings = (self.readings + new.filter { !known.contains($0.date) }).sorted { $0.date < $1.date }
        }
        store.save(manager.rawState)
    }

    // MARK: CGMManagerDelegate

    func startDateToFilterNewData(for manager: CGMManager) -> Date? {
        readings.last?.date
    }

    func cgmManager(_ manager: CGMManager, hasNew readingResult: CGMReadingResult) {
        handle(readingResult)
    }

    func cgmManager(_ manager: CGMManager, hasNew events: [PersistedCgmEvent]) {}

    func cgmManagerWantsDeletion(_ manager: CGMManager) {
        store.clear()
    }

    func cgmManagerDidUpdateState(_ manager: CGMManager) {
        store.save(manager.rawState)
    }

    func credentialStoragePrefix(for manager: CGMManager) -> String {
        "MFS.G7"
    }

    func cgmManager(_ manager: CGMManager, didUpdate status: CGMManagerStatus) {
        DispatchQueue.main.async { self.sensorStatus = status }
    }

    // MARK: DeviceManagerDelegate

    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {
        completion?(nil)
    }

    func issueAlert(_ alert: Alert) {}

    func retractAlert(identifier: Alert.Identifier) {}

    func doesIssuedAlertExist(identifier: Alert.Identifier, completion: @escaping (Swift.Result<Bool, Error>) -> Void) {
        completion(.success(false))
    }

    func lookupAllUnretracted(managerIdentifier: String, completion: @escaping (Swift.Result<[PersistedAlert], Error>) -> Void) {
        completion(.success([]))
    }

    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String, completion: @escaping (Swift.Result<[PersistedAlert], Error>) -> Void) {
        completion(.success([]))
    }

    func recordRetractedAlert(_ alert: Alert, at date: Date) {}
}
