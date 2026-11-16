import Foundation

/// Persists a device manager's `rawState` dictionary so the manager can be recreated at launch.
struct DeviceStateStore {
    let key: String
    private let defaults: UserDefaults

    init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    func save(_ rawState: [String: Any]) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: rawState, format: .binary, options: 0) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    func load() -> [String: Any]? {
        guard let data = defaults.data(forKey: key),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        return object as? [String: Any]
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
