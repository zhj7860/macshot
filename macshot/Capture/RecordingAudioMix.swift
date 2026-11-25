import Foundation

/// Publishing policy for a take that recorded system audio and the microphone
/// at the same time. Both sources stay separate in the durable original, where
/// nothing can be lost; the delivered file gets one mixed AAC track that every
/// player decodes, and it is saved through the same path as any other take.
enum RecordingAudioMix {
    /// GIF takes drop audio, so mixing them would only add work.
    static func shouldMix(systemAudio: Bool, microphone: Bool, isGIF: Bool) -> Bool {
        systemAudio && microphone && !isGIF
    }

    /// Each source is normalized against the sum, matching the volume sliders'
    /// 1.0/1.0 default before they were replaced by the single option.
    static let volumes: [Float] = [1, 1]

    /// The mixed copy lives in the take's own folder until delivery publishes
    /// it to the recording save folder.
    static func destination(beside source: URL) -> URL {
        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
        return source.deletingLastPathComponent()
            .appendingPathComponent(source.deletingPathExtension().lastPathComponent + " (mixed)")
            .appendingPathExtension(ext)
    }
}
