import Foundation

/// Capture-resolution / bitrate trade-off. The virtual display always runs at
/// native size: only the captured/encoded stream is scaled, so lower presets
/// cut encode, transmit, and decode time at the cost of sharpness.
enum StreamQuality: String, CaseIterable {
    case best, balanced, fast

    static let defaultsKey = "quality"

    static func resolved(stored: String?) -> StreamQuality {
        StreamQuality(rawValue: stored ?? "") ?? .best
    }

    var scale: Double {
        switch self {
        case .best: return 1.0
        case .balanced: return 0.75
        case .fast: return 0.5
        }
    }

    var bitrate: Int {
        switch self {
        case .best: return 18_000_000
        case .balanced: return 10_000_000
        case .fast: return 6_000_000
        }
    }

    var label: String {
        switch self {
        case .best: return "Best (native)"
        case .balanced: return "Balanced (75%)"
        case .fast: return "Fast (50%)"
        }
    }

    var explanation: String {
        switch self {
        case .best: return "Pixel-perfect at the device's native resolution. Highest bandwidth and latency."
        case .balanced: return "75% capture resolution, noticeably lower latency, slight softness."
        case .fast: return "Half resolution, lowest latency and bandwidth, visibly softer. Good for WiFi."
        }
    }
}
