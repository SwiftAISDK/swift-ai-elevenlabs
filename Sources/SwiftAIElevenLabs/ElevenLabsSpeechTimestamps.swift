import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities

func elevenLabsHTTPStatusError(provider: String, response: AIHTTPResponse) -> AIError {
    var error = AIAPICallError(provider: provider, statusCode: response.statusCode,
                              responseHeaders: response.headers, responseBody: response.bodyText)
    if let raw = try? response.jsonValue() {
        if let detail = raw["detail"] {
            if let text = detail.stringValue { error.message = text }
            else if let issues = detail.arrayValue, issues.allSatisfy({ issue in
                guard issue["msg"]?.stringValue != nil else { return false }
                if let type = issue["type"], type != .null, type.stringValue == nil { return false }
                if let loc = issue["loc"], loc != .null {
                    guard let path = loc.arrayValue, path.allSatisfy({ $0.stringValue != nil || $0.doubleValue != nil }) else { return false }
                }
                return true
            }) {
                error.message = issues.map { issue in
                    let path = issue["loc"]?.arrayValue?.compactMap(jsonScalarString).joined(separator: ".") ?? ""
                    return (path.isEmpty ? "" : path + ": ") + issue["msg"]!.stringValue!
                }.joined(separator: "; ")
            } else if let message = detail["message"]?.stringValue,
                      ["code", "status", "type", "request_id", "param"].allSatisfy({ key in
                          detail[key] == nil || detail[key] == .null || detail[key]?.stringValue != nil
                      }) {
                error.message = message + (detail["code"]?.stringValue.map { " (\($0))" } ?? "")
            }
        } else if raw["error"]?["code"]?.doubleValue != nil { error.message = raw["error"]?["message"]?.stringValue }
    }
    return .apiCall(error)
}

func elevenLabsDecodeSpeechResponse(_ response: AIHTTPResponse, withTimestamps: Bool = false,
                                   musicTimestamps: Bool = false) throws -> (audio: Data, metadata: [String: JSONValue], raw: JSONValue?) {
    if musicTimestamps { return try elevenLabsMusicTimestamps(response) }
    guard withTimestamps else { return (response.body, [:], nil) }
    let raw = try response.jsonValue()
    guard let base64 = raw["audio_base64"]?.stringValue, let audio = Data(base64Encoded: base64) else {
        throw AIError.invalidResponse(provider: "elevenlabs", message: "Timestamped speech response must contain valid audio_base64.")
    }
    var metadata: [String: JSONValue] = [:]
    for (key, wire) in [("alignment", "alignment"), ("normalizedAlignment", "normalized_alignment")] {
        guard let value = raw[wire], value != .null else { continue }
        guard let characters = value["characters"]?.arrayValue, characters.allSatisfy({ $0.stringValue != nil }),
              let starts = value["character_start_times_seconds"]?.arrayValue, starts.allSatisfy({ $0.doubleValue != nil }),
              let ends = value["character_end_times_seconds"]?.arrayValue, ends.allSatisfy({ $0.doubleValue != nil }) else {
            throw AIError.invalidResponse(provider: "elevenlabs", message: "Invalid speech alignment metadata.")
        }
        metadata[key] = ["characters": .array(characters), "characterStartTimesSeconds": .array(starts), "characterEndTimesSeconds": .array(ends)]
    }
    if let value = raw["voice_segments"], value != .null {
        guard let segments = value.arrayValue else { throw AIError.invalidResponse(provider: "elevenlabs", message: "Invalid voice segments.") }
        metadata["voiceSegments"] = .array(try segments.map { segment in
            guard let voice = segment["voice_id"]?.stringValue else { throw AIError.invalidResponse(provider: "elevenlabs", message: "Invalid voice segment voice_id.") }
            var result: [String: JSONValue] = ["voiceId": .string(voice)]
            for (key, wire) in [("startTimeSeconds", "start_time_seconds"), ("endTimeSeconds", "end_time_seconds"),
                                ("characterStartIndex", "character_start_index"), ("characterEndIndex", "character_end_index"), ("dialogueInputIndex", "dialogue_input_index")] {
                guard let value = segment[wire], value.doubleValue != nil else { throw AIError.invalidResponse(provider: "elevenlabs", message: "Invalid voice segment \(wire).") }
                result[key] = value
            }
            return .object(result)
        })
    }
    return (audio, metadata, raw)
}

private func elevenLabsMusicTimestamps(_ response: AIHTTPResponse) throws -> (audio: Data, metadata: [String: JSONValue], raw: JSONValue?) {
    let type = response.headerValue("content-type") ?? ""
    let regex = try NSRegularExpression(pattern: #"(?:^|;)\s*boundary=(?:"([^"]+)"|([^;\s]+))"#, options: .caseInsensitive)
    let source = type as NSString
    guard type.range(of: #"^multipart/mixed\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
          let match = regex.firstMatch(in: type, range: NSRange(location: 0, length: source.length)) else {
        throw AIError.invalidResponse(provider: "elevenlabs", message: "Music response is missing a multipart boundary.")
    }
    let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
    let delimiter = Data(("--" + source.substring(with: range)).utf8)
    let bytes = response.body
    func boundary(from start: Int) -> Int? {
        var start = start
        while start <= bytes.count, let found = bytes.range(of: delimiter, in: start..<bytes.count) {
            let i = found.lowerBound, end = found.upperBound
            let lineStart = i == 0 || (i >= 2 && bytes[i - 2] == 13 && bytes[i - 1] == 10)
            let lineEnd = end + 1 < bytes.count && ((bytes[end] == 13 && bytes[end + 1] == 10) || (bytes[end] == 45 && bytes[end + 1] == 45))
            if lineStart && lineEnd { return i }
            start = i + 1
        }
        return nil
    }
    var position = boundary(from: 0), audio: Data?, raw: JSONValue?, closed = false
    while let current = position {
        let start = current + delimiter.count
        if start + 1 < bytes.count, bytes[start] == 45, bytes[start + 1] == 45 { closed = true; break }
        guard let next = boundary(from: start + 2) else { break }
        let end = next - 2
        guard start + 2 <= end,
              let headerEnd = bytes.range(of: Data([13, 10, 13, 10]), in: (start + 2)..<end) else {
            throw AIError.invalidResponse(provider: "elevenlabs", message: "Music response contains malformed part headers.")
        }
        let headers = String(decoding: bytes[(start + 2)..<headerEnd.lowerBound], as: UTF8.self)
        let partType = headers.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-type:") }?
            .dropFirst("content-type:".count).split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let body = bytes.subdata(in: headerEnd.upperBound..<end)
        if partType == "application/json" {
            guard raw == nil else { throw AIError.invalidResponse(provider: "elevenlabs", message: "Music response contains multiple metadata parts.") }
            raw = try decodeJSONBody(body)
        } else if partType?.hasPrefix("audio/") == true {
            guard audio == nil else { throw AIError.invalidResponse(provider: "elevenlabs", message: "Music response contains multiple audio parts.") }
            audio = body
        }
        position = next
    }
    guard closed, let audio, let raw, raw.objectValue != nil else {
        throw AIError.invalidResponse(provider: "elevenlabs", message: "Music response must contain complete metadata and audio parts.")
    }
    var metadata: [String: JSONValue] = [:]
    if let value = raw["words_timestamps"], value != .null {
        guard let words = value.arrayValue else { throw AIError.invalidResponse(provider: "elevenlabs", message: "Invalid lyric word timestamps.") }
        metadata["wordTimestamps"] = .array(try words.map { word in
            guard let text = word["word"]?.stringValue, let start = word["start_ms"]?.doubleValue, let end = word["end_ms"]?.doubleValue else {
                throw AIError.invalidResponse(provider: "elevenlabs", message: "Invalid lyric word timestamp.")
            }
            return ["word": .string(text), "startMs": .number(start), "endMs": .number(end)]
        })
    }
    return (audio, metadata, raw)
}
