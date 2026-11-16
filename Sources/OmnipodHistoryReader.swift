import Foundation
import LoopKit
import OmnipodKit

/// Restores a previously paired Omnipod DASH manager and records its reservoir and history callbacks.
/// Read-only: this type never issues delivery commands (enforced by scripts/check_no_delivery_commands.sh).
final class OmnipodHistoryReader: NSObject, ObservableObject, PumpManagerDelegate {
    struct HistoryEvent: Hashable {
        let date: Date
        let title: String
    }

    struct ReservoirReading: ReservoirValue, Equatable {
        let startDate: Date
        let unitVolume: Double
    }

    @Published private(set) var reservoir: ReservoirReading?
    @Published private(set) var history: [HistoryEvent] = []
    @Published private(set) var lastError: String?

    private let store: DeviceStateStore
    private let queue = DispatchQueue(label: "MFS.OmnipodHistoryReader")
    private(set) var manager: OmniPumpManager?

    /// Pod pairing is not handled here; without saved state there is no manager and nothing is read.
    init(store: DeviceStateStore = DeviceStateStore(key: "MFS.OmniPumpManager.rawState")) {
        self.store = store
        super.init()
        if let rawState = store.load(), let restored = OmniPumpManager(rawState: rawState) {
            restored.pumpManagerDelegate = self
            restored.delegateQueue = queue
            manager = restored
        }
    }

    // MARK: PumpManagerDelegate

    func pumpManager(_ pumpManager: PumpManager, hasNewPumpEvents events: [NewPumpEvent], lastReconciliation: Date?, replacePendingEvents: Bool, completion: @escaping (Error?) -> Void) {
        let new = events.map { HistoryEvent(date: $0.date, title: $0.title) }
        DispatchQueue.main.async {
            let known = Set(self.history)
            self.history = (self.history + new.filter { !known.contains($0) }).sorted { $0.date < $1.date }
        }
        completion(nil)
    }

    func pumpManager(_ pumpManager: PumpManager, didReadReservoirValue units: Double, at date: Date, completion: @escaping (Result<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool), Error>) -> Void) {
        let previous = reservoir
        let value = ReservoirReading(startDate: date, unitVolume: units)
        DispatchQueue.main.async { self.reservoir = value }
        completion(.success((newValue: value, lastValue: previous, areStoredValuesContinuous: true)))
    }

    func pumpManager(_ pumpManager: PumpManager, didError error: PumpManagerError) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }

    func pumpManagerDidUpdateState(_ pumpManager: PumpManager) {
        store.save(pumpManager.rawState)
    }

    func pumpManagerWillDeactivate(_ pumpManager: PumpManager) {
        store.clear()
    }

    func startDateToFilterNewPumpEvents(for manager: PumpManager) -> Date {
        Date().addingTimeInterval(-24 * 60 * 60)
    }

    // MARK: Unused callbacks and fixed answers

    var detectedSystemTimeOffset: TimeInterval { 0 }

    var automaticDosingEnabled: Bool { false }

    func pumpManagerBLEHeartbeatDidFire(_ pumpManager: PumpManager) {}

    func pumpManagerMustProvideBLEHeartbeat(_ pumpManager: PumpManager) -> Bool { false }

    func pumpManagerPumpWasReplaced(_ pumpManager: PumpManager) {}

    func pumpManager(_ pumpManager: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents pumpRecordsBasalProfileStartEvents: Bool) {}

    func pumpManager(_ pumpManager: PumpManager, didAdjustPumpClockBy adjustment: TimeInterval) {}

    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {}

    func pumpManager(_ pumpManager: PumpManager, didRequestBasalRateScheduleChange basalRateSchedule: BasalRateSchedule, completion: @escaping (Error?) -> Void) {
        completion(NSError(domain: "MFS.OmnipodHistoryReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "MFS is read-only and does not change pump settings."]))
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
