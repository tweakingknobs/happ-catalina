import Foundation

/// Errors surfaced to the UI. Messages are user-facing.
enum VPNError: LocalizedError {
    case badURL
    case network(String)
    case badResponse(Int)
    case emptyBody
    case unknownFormat
    case clashUnsupported
    case noNodes
    case deviceLimited([String])
    case binaryMissing
    case launchFailed(String)
    case notReady
    case noProfiles

    var errorDescription: String? {
        switch self {
        case .badURL:               return "That doesn't look like a valid subscription URL."
        case .network(let m):       return "Network error: \(m)"
        case .badResponse(let c):   return "Server returned HTTP \(c)."
        case .emptyBody:            return "The subscription response was empty."
        case .unknownFormat:        return "Unrecognized subscription format."
        case .clashUnsupported:     return "Clash YAML subscriptions aren't supported yet."
        case .noNodes:              return "No usable servers were found in this subscription."
        case .deviceLimited(let m):
            let extra = m.first.map { " (\($0))" } ?? ""
            return "Device limit reached for this subscription\(extra). Free a slot in the provider's app, or reset the device ID."
        case .binaryMissing:        return "The bundled proxy core is missing from the app."
        case .launchFailed(let m):  return "Failed to start the proxy core: \(m)"
        case .notReady:             return "Couldn't establish a connection through any server. Try another region."
        case .noProfiles:           return "No subscription configured yet."
        }
    }
}
