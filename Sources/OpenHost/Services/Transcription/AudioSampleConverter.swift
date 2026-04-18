import Foundation
import AVFoundation
import CoreMedia

enum AudioSampleConverter {
    static let targetRate: Double = 16000

    static func extract16kMono(from buffer: CMSampleBuffer) -> [Float] {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return [] }

        let sourceRate = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard frames > 0 else { return [] }

        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: 0, mData: nil)
        )
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let ptr = abl.mBuffers.mData else { return [] }

        let monoSamples = extractFloat32Mono(
            ptr: ptr,
            byteSize: Int(abl.mBuffers.mDataByteSize),
            channels: channels,
            asbd: asbd
        )
        return linearResample(monoSamples, fromRate: sourceRate, toRate: targetRate)
    }

    static func extractFloat32Mono(ptr: UnsafeMutableRawPointer, byteSize: Int, channels: Int, asbd: AudioStreamBasicDescription) -> [Float] {
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bitDepth = Int(asbd.mBitsPerChannel)
        let bytesPerSample = bitDepth / 8
        guard bytesPerSample > 0 else { return [] }
        let sampleCount = byteSize / bytesPerSample
        var out: [Float] = []
        out.reserveCapacity(sampleCount / max(1, channels))

        if isFloat && bitDepth == 32 {
            let buf = ptr.bindMemory(to: Float.self, capacity: sampleCount)
            if channels == 1 {
                out.append(contentsOf: UnsafeBufferPointer(start: buf, count: sampleCount))
            } else {
                var i = 0
                while i + channels <= sampleCount {
                    var sum: Float = 0
                    for c in 0..<channels { sum += buf[i + c] }
                    out.append(sum / Float(channels))
                    i += channels
                }
            }
        } else if bitDepth == 16 {
            let buf = ptr.bindMemory(to: Int16.self, capacity: sampleCount)
            if channels == 1 {
                for i in 0..<sampleCount { out.append(Float(buf[i]) / 32767.0) }
            } else {
                var i = 0
                while i + channels <= sampleCount {
                    var sum: Float = 0
                    for c in 0..<channels { sum += Float(buf[i + c]) / 32767.0 }
                    out.append(sum / Float(channels))
                    i += channels
                }
            }
        }
        return out
    }

    static func linearResample(_ input: [Float], fromRate src: Double, toRate dst: Double) -> [Float] {
        guard src > 0, dst > 0, !input.isEmpty else { return input }
        if abs(src - dst) < 1 { return input }
        let ratio = src / dst
        let count = Int(Double(input.count) / ratio)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let sx = Double(i) * ratio
            let i0 = Int(sx)
            let i1 = min(i0 + 1, input.count - 1)
            let frac = Float(sx - Double(i0))
            out[i] = input[i0] * (1 - frac) + input[i1] * frac
        }
        return out
    }
}
