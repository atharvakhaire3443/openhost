import Foundation
import AVFoundation
import Combine
import CoreAudio
import AudioToolbox

enum PlaybackSource: Equatable {
    case file(URL)
    case samples([Float], sampleRate: Double)

    var duration: TimeInterval {
        switch self {
        case .file(let url):
            guard let f = try? AVAudioFile(forReading: url) else { return 0 }
            return Double(f.length) / f.processingFormat.sampleRate
        case .samples(let arr, let rate):
            return Double(arr.count) / rate
        }
    }
}

@MainActor
final class AudioPlaybackEngine: ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var lastError: String?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private var source: PlaybackSource?
    private var audioFile: AVAudioFile?
    private var sampleBuffer: AVAudioPCMBuffer?
    private var fileFormat: AVAudioFormat?
    private var startFrame: AVAudioFramePosition = 0
    private var startHostOffset: TimeInterval = 0
    private var tick: Timer?
    private var outputDeviceUID: String?

    init() {
        engine.attach(player)
    }

    func setOutputDevice(uid: String) {
        outputDeviceUID = uid
        guard let id = AudioDevices.find(byUID: uid) else { return }
        if let unit = engine.outputNode.audioUnit {
            var dev = id
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &dev,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
    }

    func load(_ source: PlaybackSource) {
        stop()
        self.source = source
        self.duration = source.duration
        self.currentTime = 0
        self.startFrame = 0
        self.audioFile = nil
        self.sampleBuffer = nil
        self.lastError = nil

        switch source {
        case .file(let url):
            do {
                let file = try AVAudioFile(forReading: url)
                audioFile = file
                fileFormat = file.processingFormat
            } catch {
                lastError = "Could not open audio: \(error.localizedDescription)"
            }
        case .samples(let arr, let rate):
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(arr.count))
            else {
                lastError = "Could not build buffer"
                return
            }
            buf.frameLength = AVAudioFrameCount(arr.count)
            if let data = buf.floatChannelData?[0] {
                for i in 0..<arr.count { data[i] = arr[i] }
            }
            sampleBuffer = buf
            fileFormat = fmt
        }
    }

    func play() {
        guard let source else { return }
        if isPlaying { return }

        guard let fmt = fileFormat else { return }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)

        if !engine.isRunning {
            do {
                if let uid = outputDeviceUID { setOutputDevice(uid: uid) }
                try engine.start()
            } catch {
                lastError = "Engine start failed: \(error.localizedDescription)"
                return
            }
        }

        switch source {
        case .file:
            guard let file = audioFile else { return }
            let remaining = AVAudioFrameCount(file.length - startFrame)
            if remaining == 0 {
                startFrame = 0
                currentTime = 0
            }
            player.stop()
            player.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: AVAudioFrameCount(file.length - startFrame),
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                Task { @MainActor in self?.handleFinish() }
            }
        case .samples:
            guard let buf = sampleBuffer else { return }
            let total = Int(buf.frameLength)
            if startFrame >= AVAudioFramePosition(total) {
                startFrame = 0
                currentTime = 0
            }
            let tailStart = Int(startFrame)
            if tailStart == 0 {
                player.stop()
                player.scheduleBuffer(buf, at: nil, options: []) { [weak self] in
                    Task { @MainActor in self?.handleFinish() }
                }
            } else {
                guard let fmt2 = buf.format as AVAudioFormat?,
                      let tail = AVAudioPCMBuffer(pcmFormat: fmt2, frameCapacity: AVAudioFrameCount(total - tailStart)),
                      let src = buf.floatChannelData, let dst = tail.floatChannelData
                else { return }
                tail.frameLength = AVAudioFrameCount(total - tailStart)
                for i in 0..<(total - tailStart) { dst[0][i] = src[0][tailStart + i] }
                player.stop()
                player.scheduleBuffer(tail, at: nil, options: []) { [weak self] in
                    Task { @MainActor in self?.handleFinish() }
                }
            }
        }

        player.play()
        startHostOffset = Date().timeIntervalSince1970 - currentTime
        isPlaying = true
        startTick()
    }

    func pause() {
        guard isPlaying else { return }
        player.pause()
        let pos = position()
        startFrame = AVAudioFramePosition(pos * (fileFormat?.sampleRate ?? 16000))
        currentTime = pos
        isPlaying = false
        stopTick()
    }

    func stop() {
        player.stop()
        if engine.isRunning { engine.stop() }
        isPlaying = false
        currentTime = 0
        startFrame = 0
        stopTick()
    }

    func seek(to seconds: TimeInterval) {
        let wasPlaying = isPlaying
        let rate = fileFormat?.sampleRate ?? 16000
        startFrame = AVAudioFramePosition(max(0, seconds) * rate)
        currentTime = seconds
        if wasPlaying {
            pause()
            play()
        }
    }

    private func handleFinish() {
        stop()
    }

    private func position() -> TimeInterval {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return currentTime }
        let rate = fileFormat?.sampleRate ?? 16000
        let base = Double(startFrame) / rate
        return base + Double(playerTime.sampleTime) / rate
    }

    private func startTick() {
        stopTick()
        let t = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                let pos = self.position()
                self.currentTime = min(self.duration, max(0, pos))
            }
        }
        tick = t
    }

    private func stopTick() {
        tick?.invalidate()
        tick = nil
    }
}
