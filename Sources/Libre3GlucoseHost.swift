import Foundation
import LibreLoop
import LoopKit

/// Hosts LibreLoop's direct BLE FreeStyle Libre 3/3+ CGM manager.
final class Libre3GlucoseHost: CGMHostBase, ObservableObject, DeviceConnection {
    @Published private(set) var isEnabled = false
    @Published private(set) var pairingInProgress = false
    @Published private(set) var pairingError: String?
    private let store: DeviceStateStore
    private(set) var manager: LibreLoopCGMManager

    init(feed: GlucoseFeed, store: DeviceStateStore = DeviceStateStore(key: "MFS.LibreLoop.rawState")) {
        self.store = store
        if let rawState = store.load(), let restored = LibreLoopCGMManager(rawState: rawState) {
            manager = restored
        } else {
            manager = LibreLoopCGMManager()
        }
        super.init(feed: feed, queueLabel: "MFS.Libre3GlucoseHost")
        manager.cgmManagerDelegate = self
        store.save(manager.rawState)
        isEnabled = manager.state.sensorSerial != nil
        manager.scanner // Start LibreLoop's restoration/reconnect listener.
    }

    var hasConnectedDevice: Bool { isEnabled }

    func disconnect() {
        manager.discardSensor()
        isEnabled = false
    }

    func beginPairing() {
        guard !pairingInProgress else { return }
        pairingInProgress = true
        pairingError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let service = LibreLoopPairingService()
                let outcome = try await service.pair(
                    mode: .fresh,
                    scanner: manager.scanner,
                    onNFCResponse: { [manager] response in
                        manager.applyNFCResponse(response)
                    }
                )
                try manager.applyPairingOutcome(outcome)
                store.save(manager.rawState)
                isEnabled = true
            } catch {
                pairingError = String(describing: error)
            }
            pairingInProgress = false
        }
    }

    func fetchNewData() {
        manager.scanner
    }

    override func handle(_ result: CGMReadingResult) {
        super.handle(result)
        store.save(manager.rawState)
    }

    override func stateDidChange(_ manager: CGMManager) {
        store.save(manager.rawState)
    }

    override func wantsDeletion(_ manager: CGMManager) {
        store.clear()
    }
}
