import SwiftAIProvider
import SwiftAIProviderUtilities
import Foundation
import SwiftAIProvider


func elevenLabsTranscriptionSegments(from raw: JSONValue) -> [TranscriptionSegment] {
    raw["words"]?.arrayValue?.compactMap { item in
        guard let text = item["text"]?.stringValue, !text.isEmpty else { return nil }
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
