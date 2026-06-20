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
    // feed() runs on the background streaming thread; transport (pause/resume/
    // stop/start) and the schedule-completion callback run on other threads. This
    // lock guards ALL mutable state below AND the player.play()/pause() that
    // follows a state change, so the two are atomic — a concurrent pause can't be
    // lost in the window between checking `paused` and calling play(). play/pause
    // only signal the render thread (they don't block), so holding the lock across
    // them is safe; the completion callback takes the lock only to adjust a
    // counter, never nesting.
    private let lock = NSLock()
    private var leftoverByte: UInt8?
    private var scheduledFrames: AVAudioFrameCount = 0
    // Bumped on stop()/start(). A scheduleBuffer completion from a previous
    // session carries the old epoch and is ignored, so it can't decrement (and
    // underflow, since the count is unsigned) the new session's frame counter.
    private var epoch: UInt64 = 0
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
        lock.withLock {
            primeFrames = AVAudioFrameCount(max(0.05, cushionSeconds) * 24000)
            primed = false; ended = false; leftoverByte = nil; scheduledFrames = 0
            epoch &+= 1
        }
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
        lock.withLock {
            ended = true
            if !paused && !primed && scheduledFrames > 0 { primed = true; player.play() }
        }
    }

    /// Feed raw int16 little-endian PCM bytes.
    func feed(_ data: Data) {
        var bytes = data
        let myEpoch: UInt64 = lock.withLock {
            if let lo = leftoverByte { bytes.insert(lo, at: 0); leftoverByte = nil }
            if bytes.count % 2 == 1 { leftoverByte = bytes.last; bytes.removeLast() }
            return epoch
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
        let frames = buffer.frameLength
        lock.withLock {
            scheduledFrames += frames
            // Start once the cushion is full; after that, keep the node playing —
            // unless paused, in which case keep buffering but stay stopped. Done
            // under the lock so a concurrent pause() can't be lost.
            if !paused {
                if !primed {
                    if scheduledFrames >= primeFrames { primed = true; player.play() }
                } else if !player.isPlaying {
                    player.play()
                }
            }
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock {
                // ignore completions from a previous session; clamp so the
                // unsigned counter can never underflow
                guard myEpoch == self.epoch else { return }
                self.scheduledFrames = self.scheduledFrames >= frames ? self.scheduledFrames - frames : 0
            }
        }
    }

    func pause() {
        lock.withLock { paused = true; player.pause() }
    }
    func resume() {
        if !engine.isRunning { try? engine.start() }
        lock.withLock {
            paused = false
            if primed {
                player.play()                                 // was playing before pause
            } else if ended && scheduledFrames > 0 {
                primed = true; player.play()                  // stream done: play remainder
            }
            // else paused mid-prime, stream still live: leave unprimed so feed()
            // refills the cushion before starting — avoids an undersized buffer.
        }
    }

    func stop() {
        player.stop()
        player.reset()
        lock.withLock {
            primed = false; paused = false; ended = false
            scheduledFrames = 0; leftoverByte = nil
            epoch &+= 1   // invalidate in-flight completion callbacks
        }
    }

    /// Approximate: is anything still queued?
    var hasQueued: Bool { lock.withLock { scheduledFrames > 0 } }
}
