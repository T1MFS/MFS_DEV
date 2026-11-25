import Foundation

enum DeviceCategory: String, CaseIterable, Identifiable {
    case sensors, pumps

    var id: String { rawValue }
    var title: String { self == .sensors ? "Sensors" : "Pumps" }
}

/// Every pairable device. Add a case here, then give it a screen in DevicePairingView.
enum DeviceKind: String, CaseIterable, Identifiable {
    case dexcomG7, freestyleLibre3, omnipodDash

    var id: String { rawValue }

    var category: DeviceCategory {
        switch self {
        case .dexcomG7, .freestyleLibre3: return .sensors
        case .omnipodDash: return .pumps
        }
    }

    var title: String {
        switch self {
        case .dexcomG7: return "Dexcom G7 / Stelo"
        case .freestyleLibre3: return "FreeStyle Libre 3"
        case .omnipodDash: return "Omnipod DASH"
        }
    }

    /// Device-specific steps shown above the pairing flow.
    var guidance: [String] {
        switch self {
        case .dexcomG7:
            return ["Keep Bluetooth on and this phone next to the sensor.",
                    "Close the Dexcom app first so it does not take the sensor.",
                    "Start a new G7, ONE+ or Stelo sensor; no code is needed."]
        case .freestyleLibre3:
            return ["Keep Bluetooth on. Pairing uses NFC, so hold the top of the phone against the sensor when asked.",
                    "Close the FreeStyle Libre app first so it does not take the sensor."]
        case .omnipodDash:
            return ["Have a new pod, a filled pod cartridge and your basal settings ready.",
                    "Stay close to the pod while it pairs."]
        }
    }
}
