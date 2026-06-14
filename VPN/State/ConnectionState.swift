import Foundation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var isBusy: Bool { self == .connecting }
    var isConnected: Bool { self == .connected }

    var label: String {
        switch self {
        case .disconnected:   return "Disconnected"
        case .connecting:     return "Connecting…"
        case .connected:      return "Connected"
        case .error(let m):   return "Error: \(m)"
        }
    }
}
