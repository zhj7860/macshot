import AVFoundation

enum AudioTrackMixer {
    enum MixError: LocalizedError {
        case invalidTracksOrVolumes, originalWouldBeOverwritten
        var errorDescription: String? {
            switch self {
            case .invalidTracksOrVolumes: return "The recording's audio tracks or mix volumes are invalid."
            case .originalWouldBeOverwritten: return "An audio mix must be saved separately from the original recording."
            }
        }
    }

    private struct Prepared: @unchecked Sendable {
        let save: AtomicMediaSave
        let pump: MediaExportPump
    }

    /// Decode/mix only audio. Compressed video samples and orientation pass
    /// through unchanged, avoiding a second video encode for a long recording.
    /// Volumes share headroom when their sum exceeds unity to prevent clipping.
    nonisolated static func export(source: URL, destination: URL, volumes: [Float],
                                  cancellation: MediaExportCancellation = MediaExportCancellation(),
                                  progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await run(source: source, destination: destination, volumes: volumes,
                      includeVideo: true, cancellation: cancellation, progress: progress)
    }

    /// Mixes the take's audio tracks into one AAC track and writes an `.m4a`.
    /// Used by audio-only recordings: the tiny video track kept beside the
    /// durable original is dropped so the delivered file is audio only.
    nonisolated static func exportAudioOnly(source: URL, destination: URL, volumes: [Float],
                                            cancellation: MediaExportCancellation = MediaExportCancellation(),
                                            progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await run(source: source, destination: destination, volumes: volumes,
                      includeVideo: false, cancellation: cancellation, progress: progress)
    }

    nonisolated private static func run(source: URL, destination: URL, volumes: [Float],
                                        includeVideo: Bool,
                                        cancellation: MediaExportCancellation,
                                        progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        try cancellation.check()
        guard source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() else {
            throw MixError.originalWouldBeOverwritten
        }
        let prepared: Prepared = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try prepare(source: source, destination: destination,
                                                               volumes: volumes, includeVideo: includeVideo,
                                                               progress: progress) })
            }
        }
        try await withTaskCancellationHandler(operation: {
            try cancellation.check()
            try await prepared.pump.run()
            try await MediaExportIO.perform {
                try prepared.save.commit(overwritingExisting: false, beforePublish: cancellation.beginPublication)
            }
        }, onCancel: {
            cancellation.cancel()
            prepared.pump.cancel()
        })
    }

    nonisolated private static func prepare(source: URL, destination: URL, volumes: [Float],
                                            includeVideo: Bool,
                                            progress: @escaping @Sendable (Double) -> Void) throws -> Prepared {
        let asset = AVAsset(url: source)
        let audioTracks = asset.tracks(withMediaType: .audio)
        let video = includeVideo ? asset.tracks(withMediaType: .video).first : nil
        var sourceVideo: (track: AVAssetTrack, format: CMFormatDescription)?
        if let video, let formats = video.formatDescriptions as? [CMFormatDescription], let format = formats.first {
            sourceVideo = (video, format)
        }
        guard !audioTracks.isEmpty, volumes.count == audioTracks.count,
              volumes.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              includeVideo == (sourceVideo != nil),
              asset.duration.isNumeric, CMTimeCompare(asset.duration, .zero) > 0 else {
            throw MixError.invalidTracksOrVolumes
        }
        let save = try AtomicMediaSave(destinationURL: destination)
        let reader = try AVAssetReader(asset: asset)
        let range = CMTimeRange(start: .zero, duration: asset.duration)
        reader.timeRange = range
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        audioOutput.alwaysCopiesSampleData = false
        let mix = AVMutableAudioMix()
        let divisor = max(1, volumes.reduce(0, +))
        mix.inputParameters = zip(audioTracks, volumes).map { track, volume in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(volume / divisor, at: .zero)
            return parameters
        }
        audioOutput.audioMix = mix
        guard reader.canAdd(audioOutput) else { throw MediaExportPump.ExportError.invalidSetup }
        reader.add(audioOutput)
        var videoOutput: AVAssetReaderTrackOutput?
        if let sourceVideo {
            let output = AVAssetReaderTrackOutput(track: sourceVideo.track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw MediaExportPump.ExportError.invalidSetup }
            reader.add(output)
            videoOutput = output
        }

        let fileType: AVFileType = includeVideo ? .mp4
            : (destination.pathExtension.lowercased() == "m4a" ? .m4a : .mp4)
        let writer = try AVAssetWriter(outputURL: save.stagingURL, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true   // fast start (#452)
        if let cadence = VideoFrameCadence.declaredDuration(in: asset.metadata) {
            writer.metadata = VideoFrameCadence.metadata(for: cadence)
        }
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
        ])
        guard writer.canAdd(audioInput) else { throw MediaExportPump.ExportError.invalidSetup }
        writer.add(audioInput)
        var tracks: [MediaExportPump.Track] = [
            .init(output: audioOutput, input: audioInput, requiresSamples: true),
        ]
        if let sourceVideo, let videoOutput {
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                                sourceFormatHint: sourceVideo.format)
            videoInput.mediaTimeScale = sourceVideo.track.naturalTimeScale > 0
                ? sourceVideo.track.naturalTimeScale : VideoFrameCadence.captureTimeScale
            videoInput.transform = sourceVideo.track.preferredTransform
            guard writer.canAdd(videoInput) else { throw MediaExportPump.ExportError.invalidSetup }
            writer.add(videoInput)
            tracks.append(.init(output: videoOutput, input: videoInput, requiresSamples: true))
        }
        let pump = MediaExportPump(reader: reader, writer: writer, tracks: tracks,
                                   timeRange: range, progress: progress)
        return Prepared(save: save, pump: pump)
    }
}
