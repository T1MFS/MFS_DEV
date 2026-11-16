import Foundation
import LoopKit
import G7SensorKit

/// Hosts a `G7CGMManager` and exposes its glucose readings. Read-only.
final class G7GlucoseHost: CGMHostBase, ObservableObject {
    @Published private(set) var sensorStatus: CGMManagerStatus?

    private let store: DeviceStateStore
    private(set) var manager: G7CGMManager

    init(feed: GlucoseFeed, store: DeviceStateStore = DeviceStateStore(key: "MFS.G7CGMManager.rawState")) {
        self.store = store
        if let rawState = store.load(), let restored = G7CGMManager(rawState: rawState) {
            manager = restored
        } else {
            manager = G7CGMManager()
        }
        super.init(feed: feed, queueLabel: "MFS.G7GlucoseHost")
        manager.cgmManagerDelegate = self
        manager.delegateQueue = queue
        store.save(manager.rawState)
    }

    func fetchNewData() {
        manager.fetchNewDataIfNeeded { [weak self] result in
            self?.handle(result)
        }
    }

    override var credentialPrefix: String { "MFS.G7" }

    override func handle(_ result: CGMReadingResult) {
        super.handle(result)
        store.save(manager.rawState)
    }

    override func stateDidChange(_ manager: CGMManager) {
        store.save(manager.rawState)
    }

    override func statusDidChange(_ status: CGMManagerStatus) {
        DispatchQueue.main.async { self.sensorStatus = status }
    }

    override func wantsDeletion(_ manager: CGMManager) {
        store.clear()
    }
}
