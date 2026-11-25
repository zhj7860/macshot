import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Records system audio and/or the microphone without a visible screen take.
/// The writer still owns a tiny 64×64/1 fps video track so the proven
/// `MP4WriterSession` audio path (timestamps, pauses, silence fill) is reused
/// unchanged; the delivered file is the mixed `.m4a` produced on stop.
@MainActor
final class AudioRecordingEngine {
    typealias State = RecordingLifecycle.State
    private var lifecycle = RecordingLifecycle()
    var state: State { lifecycle.state }

    var onProgress: ((Int) -> Void)?
    var onPauseChanged: ((Bool) -> Void)?
    var onCompletion: ((URL?, Error?) -> Void)?

    private var setupTask: Task<Void, Never>?
    private var captureError: Error?
    private var stream: SCStream?
    private var streamStartAttempted = false
    private var streamOutput: AudioStreamOutput?
    private let recordingQueue = DispatchQueue(label: "macshot.audio-recording")
    private var writerSession: MP4WriterSession?
    private var storedSession: RecordingSessionStore?
    private var microphoneCapture: MicrophoneCapture?
    private var recordingClock = RecordingClock()
    private var progressTimer: Timer?
    private var recordingActivity: NSObjectProtocol?

    enum AudioRecordingError: LocalizedError {
        case noDisplay, noAudioSource, stoppedBeforeStart
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "Could not find a display for audio capture."
            case .noAudioSource: return "Audio recording needs a microphone or macOS 13 for system audio."
            case .stoppedBeforeStart: return "The audio recording was stopped before it started."
            }
        }
    }

    func startRecording() {
        guard let sessionID = lifecycle.begin() else { return }
        captureError = nil
        recordingClock = RecordingClock()
        setupTask = Task { [weak self] in
            guard let self = self else { return }
            let microphone = await Self.microphoneAvailable()
            guard self.lifecycle.isPreparing(sessionID) else { return }
            await self.beginCapture(sessionID: sessionID, microphone: microphone)
        }
    }

    func pauseRecording() {
        guard lifecycle.pause() else { return }
        recordingClock.pause(at: ProcessInfo.processInfo.systemUptime)
        updateProgress()
        writerSession?.pause()
        progressTimer?.invalidate()
        progressTimer = nil
        onPauseChanged?(true)
    }

    func resumeRecording() {
        guard lifecycle.resume() else { return }
        let pausedFor = recordingClock.resume(at: ProcessInfo.processInfo.systemUptime)
        writerSession?.resume(addingPausedDuration: pausedFor)
        startProgressTimer()
        onPauseChanged?(false)
    }

    func stopRecording() {
        stopRecording(error: nil)
    }

    private func stopRecording(error: Error?) {
        guard lifecycle.sessionID != nil else { return }
        captureError = captureError ?? error
        guard let sessionID = lifecycle.requestStop() else { return }
        writerSession?.requestStop()
        progressTimer?.invalidate()
        progressTimer = nil
        let startingTask = setupTask
        if stream == nil && writerSession == nil {
            startingTask?.cancel()
            Task { [weak self] in
                guard let self = self, self.lifecycle.isCurrent(sessionID) else { return }
                self.complete(sessionID: sessionID, url: nil,
                              error: self.captureError ?? AudioRecordingError.stoppedBeforeStart)
            }
            return
        }
        Task { [weak self] in
            await startingTask?.value
            guard let self = self, self.lifecycle.isCurrent(sessionID) else { return }
            self.setupTask = nil
            await self.finalizeCapture(sessionID: sessionID)
        }
    }

    // MARK: - Setup

    private static func microphoneAvailable() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    private func beginCapture(sessionID: UUID, microphone: Bool) async {
        do {
            var systemAudio = true
            if #unavailable(macOS 13.0) { systemAudio = false }
            guard systemAudio || microphone else { throw AudioRecordingError.noAudioSource }

            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard lifecycle.isPreparing(sessionID) else { return }
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
                throw AudioRecordingError.noDisplay
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            // Tiny frames only keep the writer's media clock advancing; audio
            // is the product and the delivered file drops this track.
            config.width = 64
            config.height = 64
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.scalesToFit = true
            config.showsCursor = false
            if #available(macOS 14.0, *) {
                config.colorSpaceName = CGColorSpace.sRGB
            }
            if #available(macOS 13.0, *) {
                config.capturesAudio = systemAudio
                config.excludesCurrentProcessAudio = true
            }

            let defaults = UserDefaults.standard
            let template = defaults.string(forKey: FilenameFormatter.recordingUserDefaultsKey)
                ?? FilenameFormatter.defaultRecordingTemplate
            let stored = try RecordingSessionStore(
                filename: RecordingEngine.takeFilename(template: template, appName: nil))
            guard lifecycle.isPreparing(sessionID) else {
                recordingQueue.async { stored.removeIfEmpty() }
                return
            }
            storedSession = stored
            let mediaURL = stored.mediaURL
            recordingActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Audio recording")

            let writer = try MP4WriterSession.make(
                queue: recordingQueue, url: mediaURL, width: 64, height: 64, fps: 1,
                recordSystemAudio: systemAudio, recordMicAudio: microphone,
                onFailure: { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self = self, self.lifecycle.isCurrent(sessionID) else { return }
                        self.stopRecording(error: error)
                    }
                })
            writerSession = writer

            let output = AudioStreamOutput()
            output.onFrame = { pixelBuffer, presentationTime in
                writer.handleFrame(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
            }
            output.onAudioSample = { writer.handleSystemAudioSample($0) }
            output.onStopped = { [weak self] error in
                guard let self = self, self.lifecycle.isCurrent(sessionID) else { return }
                if self.state == .stopping { return }
                self.stopRecording(error: error)
            }
            streamOutput = output

            let stream = SCStream(filter: filter, configuration: config, delegate: output)
            self.stream = stream
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: recordingQueue)
            if #available(macOS 13.0, *), systemAudio {
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: recordingQueue)
            }

            if microphone {
                microphoneCapture = try await MicrophoneCapture.start(
                    deviceID: defaults.string(forKey: "selectedMicDeviceUID"),
                    sampleQueue: recordingQueue,
                    onSample: { writer.handleMicSample($0) },
                    onFailure: { [weak self] error in
                        DispatchQueue.main.async {
                            guard let self = self, self.lifecycle.isCurrent(sessionID) else { return }
                            self.stopRecording(error: error)
                        }
                    })
            }

            guard lifecycle.isPreparing(sessionID) else { return }
            streamStartAttempted = true
            try await stream.startCapture()
            guard lifecycle.didStart(sessionID) else { return }
            writer.captureDidStart()
            recordingClock.start(at: ProcessInfo.processInfo.systemUptime)
            startProgressTimer()
        } catch {
            guard lifecycle.isCurrent(sessionID) else { return }
            stopRecording(error: error)
        }
    }

    private func finalizeCapture(sessionID: UUID) async {
        if let stream = stream {
            if streamStartAttempted {
                do { try await stream.stopCapture() }
                catch { captureError = captureError ?? error }
            }
            self.stream = nil
        }
        streamStartAttempted = false
        streamOutput = nil
        await microphoneCapture?.stop()
        microphoneCapture = nil

        guard let writer = writerSession, let stored = storedSession else {
            complete(sessionID: sessionID, url: nil,
                     error: captureError ?? AudioRecordingError.stoppedBeforeStart)
            return
        }
        let mediaURL = stored.mediaURL
        let audioURL = mediaURL.deletingPathExtension().appendingPathExtension("m4a")
        do {
            try await writer.finish()
            writerSession = nil
        } catch {
            writerSession = nil
            complete(sessionID: sessionID, url: mediaURL, error: captureError ?? error)
            return
        }

        let trackCount = (try? await AVAsset(url: mediaURL).loadTracks(withMediaType: .audio).count) ?? 0
        guard trackCount > 0 else {
            complete(sessionID: sessionID, url: nil, error: captureError ?? AudioRecordingError.noAudioSource)
            return
        }
        do {
            try await AudioTrackMixer.exportAudioOnly(
                source: mediaURL, destination: audioURL,
                volumes: Array(repeating: 1, count: trackCount))
            complete(sessionID: sessionID, url: audioURL, error: captureError)
        } catch {
            // The tiny-video take still contains both tracks; deliver it rather
            // than losing the recording, and report the mix failure.
            complete(sessionID: sessionID, url: mediaURL, error: error)
        }
    }

    private func complete(sessionID: UUID, url: URL?, error: Error?) {
        guard lifecycle.finish(sessionID) else { return }
        progressTimer?.invalidate()
        progressTimer = nil
        if let activity = recordingActivity { ProcessInfo.processInfo.endActivity(activity) }
        recordingActivity = nil
        setupTask = nil
        if let stored = storedSession {
            storedSession = nil
            recordingQueue.async {
                try? stored.update(status: error == nil ? "complete" : "interrupted", error: error)
                stored.removeIfEmpty()
            }
        }
        onCompletion?(url, error)
    }

    // MARK: - Progress

    private func updateProgress() {
        let elapsed = recordingClock.elapsed(at: ProcessInfo.processInfo.systemUptime)
        onProgress?(SafeNumerics.int(elapsed.rounded(.down)))
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
        updateProgress()
    }
}

/// Delivers screen/audio samples on the recording queue. The stream keeps a
/// screen output because that path already proves audio capture works; the
/// tiny frames only clock the writer.
private final class AudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudioSample: ((CMSampleBuffer) -> Void)?
    var onStopped: ((Error) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        if type == .screen {
            guard RecordingSampleValidation.isCompleteFrame(sampleBuffer),
                  let pixelBuffer = sampleBuffer.imageBuffer else { return }
            onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        } else if #available(macOS 13.0, *), type == .audio {
            onAudioSample?(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onStopped?(error) }
    }
}
