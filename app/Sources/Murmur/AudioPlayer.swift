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
    // feed() runs on the background streaming thread; transport (pause/resume/
    // stop/start) and the schedule-completion callback run on other threads. This
    // lock guards the shared counters/flags below. AVAudioEngine calls (play/
    // pause/…) are made OUTSIDE the lock so they never block under it.
    private let lock = NSLock()
    private var scheduledFrames: AVAudioFrameCount = 0
    // Pre-buffer: hold playback until this much audio is queued, so transient
    // slow chunks (HD generates near real-time) don't cause silence gaps.
    private var primeFrames: AVAudioFrameCount = 8400  // ~0.35s default
    private var primed = false
    // User paused. While set, incoming chunks still buffer but never (re)start
    // the node — otherwise the next streamed chunk silently un-pauses playback.
    private var paused = false
    // Stream finished (flush called). Lets resume() tell "paused mid-stream"
    // (let feed re-prime, preserving the cushion) from "paused after the stream
    // ended" (play the sub-cushion remainder now, since no more audio is coming).
    private var ended = false

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

    /// Begin a fresh playback session. `cushionSeconds` of audio is buffered
    /// before playback starts (larger for slower engines = smoother streaming).
    func start(volume: Float, pitchCents: Float, rate: Float, cushionSeconds: Double = 0.35) {
        stop()
        set(volume: volume, pitchCents: pitchCents)
        setRate(rate)
        lock.withLock { primeFrames = AVAudioFrameCount(max(0.05, cushionSeconds) * 24000); primed = false; ended = false }
        do {
            if !engine.isRunning { try engine.start() }
            // engine running but the node waits for the cushion (see feed/flush)
        } catch {
            NSLog("audio engine start failed: \(error)")
        }
    }

    /// Start playback now even if the cushion isn't full (call when the stream
    /// ends, so short clips below the cushion still play).
    func flush() {
        var shouldPlay = false
        lock.withLock {
            ended = true
            if !paused && !primed && scheduledFrames > 0 { primed = true; shouldPlay = true }
        }
        if shouldPlay { player.play() }
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
        lock.withLock { scheduledFrames += buffer.frameLength }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.scheduledFrames -= buffer.frameLength }
        }
        // Start once the cushion is full; after that, keep the node playing —
        // unless the user paused, in which case keep buffering but stay stopped.
        var shouldPlay = false
        lock.withLock {
            if paused { return }
            if !primed {
                if scheduledFrames >= primeFrames { primed = true; shouldPlay = true }
            } else {
                shouldPlay = true   // already primed; ensure the node keeps going
            }
        }
        if shouldPlay && !player.isPlaying { player.play() }
    }

    func pause() {
        lock.withLock { paused = true }
        player.pause()
    }
    func resume() {
        var shouldPlay = false
        lock.withLock {
            paused = false
            if primed {
                shouldPlay = true                       // was playing before pause
            } else if ended && scheduledFrames > 0 {
                primed = true; shouldPlay = true        // stream done: play remainder
            }
            // else paused mid-prime, stream still live: leave unprimed so feed()
            // refills the cushion before starting — avoids an undersized buffer.
        }
        if !engine.isRunning { try? engine.start() }
        if shouldPlay { player.play() }
    }

    func stop() {
        player.stop()
        player.reset()
        lock.withLock { primed = false; paused = false; ended = false; scheduledFrames = 0 }
        leftoverByte = nil
    }

    /// Approximate: is anything still queued?
    var hasQueued: Bool { lock.withLock { scheduledFrames > 0 } }
}
