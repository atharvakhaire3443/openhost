import Foundation
import AVFoundation
import Combine

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var lastError: String?

    private let session = AVCaptureSession()
    private let outputQueue = DispatchQueue(label: "openhost.audio.capture", qos: .userInteractive)
    private var output: AVCaptureAudioDataOutput?
    private var delegate: SampleBufferDelegate?

    private(set) var samples: [Float] = []
    private var startTime: Date?
    private var tickTimer: Timer?

    // Whisper requires 16 kHz mono float32.
    nonisolated static let targetRate: Double = 16000

    private func setSystemDefaultInput(uid: String) {
        // Find matching CoreAudio input device by UID and set as system default input.
        guard let inputs = Optional(AudioDevices.listInputs()),
              let match = inputs.first(where: { $0.id == uid })
        else { return }
        // Re-resolve the AudioDeviceID from a full CoreAudio query (listInputs keeps uid but we need audioID)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &sz) == noErr else { return }
        let count = Int(sz) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &sz, &ids) == noErr else { return }
        for id in ids {
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidCF: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uidCF) == noErr,
                  (uidCF?.takeRetainedValue() as String?) == match.id
            else { continue }
            var devID = id
            var defaultAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectSetPropertyData(
                system, &defaultAddr, 0, nil,
                UInt32(MemoryLayout<AudioDeviceID>.size), &devID
            )
            NSLog("[openhost] AudioRecorder: set default input → %@ status=%d", match.name, status)
            return
        }
    }

    static func enumerateDevices() -> [AudioInputDevice] {
        AudioDevices.listInputs()
    }

    func start(preferredDeviceID: String?) async throws {
        guard !isRecording else { return }
        lastError = nil
        samples.removeAll(keepingCapacity: true)
        startTime = Date()
        elapsed = 0
        level = 0

        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        if let id = preferredDeviceID, !id.isEmpty {
            setSystemDefaultInput(uid: id)
        }
        let device: AVCaptureDevice? = {
            if let id = preferredDeviceID, let d = AVCaptureDevice(uniqueID: id) { return d }
            return AVCaptureDevice.default(for: .audio)
        }()
        guard let device else {
            session.commitConfiguration()
            throw NSError(domain: "OpenHost.AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio input device available"])
        }
        NSLog("[openhost] AudioRecorder: using device %@ (%@)", device.localizedName, device.uniqueID)

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw NSError(domain: "OpenHost.AudioRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Can't add input \(device.localizedName)"])
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        let delegate = SampleBufferDelegate { [weak self] buffer in
            self?.outputQueue.async { self?.handle(buffer: buffer) }
        }
        output.setSampleBufferDelegate(delegate, queue: outputQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(domain: "OpenHost.AudioRecorder", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Can't add output"])
        }
        session.addOutput(output)
        self.output = output
        self.delegate = delegate

        session.commitConfiguration()
        session.startRunning()

        isRecording = true
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startTime else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    func stop() -> [Float] {
        guard isRecording else { return [] }
        session.stopRunning()
        tickTimer?.invalidate()
        tickTimer = nil
        isRecording = false
        output = nil
        delegate = nil
        return samples
    }

    private nonisolated func handle(buffer: CMSampleBuffer) {
        let resampled = AudioSampleConverter.extract16kMono(from: buffer)
        guard !resampled.isEmpty else { return }
        var peak: Float = 0
        for v in resampled { let a = abs(v); if a > peak { peak = a } }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.samples.append(contentsOf: resampled)
            let lifted = min(1.0, peak * 1.4)
            self.level = 0.7 * self.level + 0.3 * lifted
        }
    }
}

private final class SampleBufferDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let onBuffer: @Sendable (CMSampleBuffer) -> Void
    init(onBuffer: @escaping @Sendable (CMSampleBuffer) -> Void) { self.onBuffer = onBuffer }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onBuffer(sampleBuffer)
    }
}
