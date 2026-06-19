import Foundation

struct VoiceInfo: Identifiable, Decodable, Hashable {
    let id: String
    let lang: String
    let lang_label: String
    let gender: String
}

struct HealthInfo: Decodable {
    let status: String
    let model_loaded: Bool
    let files_present: Bool
    let models_dir: String
    let error: String?
    let sample_rate: Int
    let provider_mode: String?
    let active_providers: [String]?
    let available_providers: [String]?
}

/// Thin HTTP client for the local Kokoro backend.
struct BackendClient {
    var base = URL(string: "http://127.0.0.1:8765")!
    private var session: URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }

    func health() async -> HealthInfo? {
        var req = URLRequest(url: base.appending(path: "health"))
        req.timeoutInterval = 2
        guard let (data, _) = try? await session.data(for: req) else { return nil }
        return try? JSONDecoder().decode(HealthInfo.self, from: data)
    }

    func voices() async -> [VoiceInfo] {
        struct Resp: Decodable { let voices: [VoiceInfo] }
        let req = URLRequest(url: base.appending(path: "voices"))
        guard let (data, _) = try? await session.data(for: req),
              let r = try? JSONDecoder().decode(Resp.self, from: data) else { return [] }
        return r.voices
    }

    private func synthRequest(_ text: String, voice: String, speed: Double, wav: Bool) -> URLRequest {
        var url = base.appending(path: "synthesize")
        if wav { url.append(queryItems: [URLQueryItem(name: "format", value: "wav")]) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["text": text, "voice": voice, "speed": speed]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Stream raw int16 PCM. `onChunk` receives bytes as they arrive.
    func streamPCM(text: String, voice: String, speed: Double,
                   onChunk: @escaping (Data) -> Void) async throws {
        let req = synthRequest(text, voice: voice, speed: speed, wav: false)
        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "Murmur", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "backend HTTP \(http.statusCode)"])
        }
        var buf = Data()
        buf.reserveCapacity(16384)
        for try await b in bytes {
            buf.append(b)
            if buf.count >= 9600 { // ~0.2s of audio
                onChunk(buf)
                buf.removeAll(keepingCapacity: true)
            }
        }
        if !buf.isEmpty { onChunk(buf) }
    }

    /// Fetch a complete WAV (for export).
    func wav(text: String, voice: String, speed: Double) async throws -> Data {
        let req = synthRequest(text, voice: voice, speed: speed, wav: true)
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "Murmur", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "backend HTTP \(http.statusCode)"])
        }
        return data
    }
}
