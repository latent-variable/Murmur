import AVFoundation

/// Convert an arbitrary audio file into a Chatterbox reference clip:
/// mono, 24 kHz, 16-bit WAV, trimmed to a sane length.
enum AudioImport {
    enum Err: Error { case open, convert, write }

    static func toReferenceWAV(src: URL, dest: URL, maxSeconds: Double = 20) throws {
        let inFile = try AVAudioFile(forReading: src)
        let inFormat = inFile.processingFormat

        let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: 24000, channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw Err.convert }

        try? FileManager.default.removeItem(at: dest)
        let outFile = try AVAudioFile(forWriting: dest, settings: outFormat.settings)

        let maxFrames = AVAudioFramePosition(maxSeconds * inFormat.sampleRate)
        let chunk: AVAudioFrameCount = 16384
        var done = false
        var written: AVAudioFramePosition = 0

        while !done && written < maxFrames {
            let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk)!
            try inFile.read(into: inBuf, frameCount: chunk)
            if inBuf.frameLength == 0 { break }
            written += AVAudioFramePosition(inBuf.frameLength)

            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
            let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap)!
            var fed = false
            var err: NSError?
            converter.convert(to: outBuf, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return inBuf
            }
            if err != nil { throw Err.convert }
            if outBuf.frameLength > 0 { try outFile.write(from: outBuf) }
            if inFile.framePosition >= inFile.length { done = true }
        }
        if written == 0 { throw Err.write }
    }
}
