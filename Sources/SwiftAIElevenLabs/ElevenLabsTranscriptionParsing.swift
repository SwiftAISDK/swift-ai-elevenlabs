import SwiftAIProvider
import SwiftAIProviderUtilities
import Foundation


/// Upstream maps every word (including spacing and empty text) to a segment.
func elevenLabsTranscriptionSegments(from raw: JSONValue) -> [TranscriptionSegment] {
    raw["words"]?.arrayValue?.compactMap { item in
        guard let text = item["text"]?.stringValue else { return nil }
        return TranscriptionSegment(
            text: text,
            startSecond: item["start"]?.doubleValue ?? 0,
            endSecond: item["end"]?.doubleValue ?? 0
        )
    } ?? []
}


func elevenLabsTranscriptionDuration(from raw: JSONValue) -> Double? {
    raw["words"]?.arrayValue?.last?["end"]?.doubleValue
}

/// Projects a response word onto the upstream zod schema, which strips
/// unknown keys (for example `logprob`) from `providerMetadata.elevenlabs.words`.
func elevenLabsSchemaWord(_ word: JSONValue) -> JSONValue {
    guard let object = word.objectValue else { return word }
    var output: [String: JSONValue] = [:]
    for key in ["text", "type", "start", "end", "speaker_id"] { if let value = object[key] { output[key] = value } }
    if let characters = object["characters"] {
        output["characters"] = characters.arrayValue.map { items in
            .array(items.map { character in
                guard let fields = character.objectValue else { return character }
                return .object(fields.filter { ["text", "start", "end"].contains($0.key) })
            })
        } ?? characters
    }
    return .object(output)
}
