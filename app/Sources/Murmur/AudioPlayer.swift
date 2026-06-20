import AVFoundation

/// Low-latency streaming player. Accepts int16 mono PCM at 24 kHz, converts to
/// float buffers, and schedules them on an AVAudioPlayerNode as they arrive.
/// Pitch and volume run through an AVAudioUnitTimePitch node.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pitchUnit = AVAudioUnitTimePitch()
    private let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 24000, channels: 1, interleaved: false)!
    private var leftoverByte: UInt8?
    private var scheduledFrames: AVAudioFrameCount = 0

    var onFinished: (() -> Void)?

    init() {
        engine.attach(player)
        engine.attach(pitchUnit)
        engine.connect(player, to: pitchUnit, format: inFormat)
        engine.connect(pitchUnit, to: engine.mainMixerNode, format: inFormat)
    }

    func set(volume: Float, pitchCents: Float) {
        player.volume = max(0, min(1, volume))
        pitchUnit.pitch = pitchCents   // -2400...2400
    }

    /// Playback speed via time-stretch (pitch preserved). Safe to change live,
    /// even mid-playback — takes effect on the audio currently streaming.
    func setRate(_ rate: Float) {
        pitchUnit.rate = max(0.25, min(4.0, rate))
    }

    /// Begin a fresh playback session.
    func start(volume: Float, pitchCents: Float, rate: Float) {
        stop()
        set(volume: volume, pitchCents: pitchCents)
        setRate(rate)
        do {
            if !engine.isRunning { try engine.start() }
            player.play()
        } catch {
            NSLog("audio engine start failed: \(error)")
        }
    }

    /// Feed raw int16 little-endian PCM bytes.
    func feed(_ data: Data) {
        var bytes = data
        if let lo = leftoverByte {
            bytes.insert(lo, at: 0)
            leftoverByte = nil
        }
        if bytes.count % 2 == 1 {
            leftoverByte = bytes.last
            bytes.removeLast()
        }
        guard !bytes.isEmpty else { return }
        let sampleCount = bytes.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inFormat,
                                            frameCapacity: AVAudioFrameCount(sampleCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        let dst = buffer.floatChannelData![0]
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                dst[i] = Float(Int16(littleEndian: src[i])) / 32768.0
            }
        }
        scheduledFrames += buffer.frameLength
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.scheduledFrames -= buffer.frameLength
        }
        if !player.isPlaying { player.play() }
    }

    func pause() { player.pause() }
    func resume() {
        if !engine.isRunning { try? engine.start() }
        player.play()
    }

    func stop() {
        player.stop()
        player.reset()
        leftoverByte = nil
        scheduledFrames = 0
    }

    /// Approximate: is anything still queued?
    var hasQueued: Bool { scheduledFrames > 0 }
}
