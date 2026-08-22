import Foundation

struct StreamPrefs: Equatable {
    var quality: StreamQuality
    var audio: Bool

    static let audioDefaultsKey = "playMacAudio"

    static func decoded(quality: String?, audio: Bool?) -> StreamPrefs {
        StreamPrefs(quality: StreamQuality.resolved(stored: quality), audio: audio ?? false)
    }
}
