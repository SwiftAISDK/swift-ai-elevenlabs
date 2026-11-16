@testable import SwiftAIElevenLabs
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

// Translated from the doGenerate block of
// packages/elevenlabs/src/elevenlabs-transcription-model.test.ts.
// The doStream (Scribe v2 Realtime) block is not translated: ElevenLabs
// realtime transcription is a documented deferred gap in this port.

/// Copy of src/__fixtures__/elevenlabs-transcription.json.
let elevenLabsTranscriptionFixture = #"""
{"language_code":"eng","language_probability":0.8905608654022217,"text":"Hello from the Vercel AI SDK.","words":[
{"text":"Hello","start":0.199,"end":0.479,"type":"word","speaker_id":"speaker_0","logprob":0},
{"text":" ","start":0.479,"end":0.499,"type":"spacing","speaker_id":"speaker_0","logprob":0},
{"text":"from","start":0.5,"end":0.639,"type":"word","speaker_id":"speaker_0","logprob":0},
{"text":" ","start":0.639,"end":0.66,"type":"spacing","speaker_id":"speaker_0","logprob":0},
{"text":"the","start":0.66,"end":0.759,"type":"word","speaker_id":"speaker_0","logprob":0},
{"text":" ","start":0.759,"end":0.759,"type":"spacing","speaker_id":"speaker_0","logprob":0},
{"text":"Vercel","start":0.759,"end":1.12,"type":"word","speaker_id":"speaker_0","logprob":0},
{"text":" ","start":1.12,"end":1.2,"type":"spacing","speaker_id":"speaker_0","logprob":0},
{"text":"AI","start":1.2,"end":1.519,"type":"word","speaker_id":"speaker_0","logprob":0},
{"text":" ","start":1.519,"end":1.58,"type":"spacing","speaker_id":"speaker_0","logprob":0},
{"text":"SDK.","start":1.58,"end":2.479,"type":"word","speaker_id":"speaker_0","logprob":0}],
"transcription_id":"dRgXxwt3SzzliHA3nDAQ"}
"""#

/// Non-file multipart fields in wire order.
func elevenLabsMultipartFields(_ body: Data?) -> [(String, String)] {
    guard let body else { return [] }
    let text = String(decoding: body, as: UTF8.self)
    var fields: [(String, String)] = []
    for chunk in text.components(separatedBy: "Content-Disposition: form-data; name=\"").dropFirst() {
        guard let nameEnd = chunk.firstIndex(of: "\"") else { continue }
        let name = String(chunk[..<nameEnd])
        let rest = chunk[nameEnd...]
        guard !rest.hasPrefix("\"; filename="), let valueStart = rest.range(of: "\r\n\r\n") else { continue }
        let value = rest[valueStart.upperBound...]
        fields.append((name, String(value[..<(value.range(of: "\r\n")?.lowerBound ?? value.endIndex)])))
    }
    return fields
}

private func transcriptionModel(_ id: String = "scribe_v1", _ response: AIHTTPResponse = jsonResponse(elevenLabsTranscriptionFixture)) throws -> (any TranscriptionModel, RecordingTransport) {
    let transport = RecordingTransport(response: response)
    let provider = try AIProviders.elevenLabs(configuration: .init(apiKey: "test-api-key", transport: transport))
    return (try provider.transcriptionModel(id), transport)
}

@Suite("ElevenLabs transcription doGenerate parity")
struct ElevenLabsTranscriptionParityTests {
    @Test func rejectsScribeV2RealtimeForNonStreamingTranscription() async throws {
        let (model, transport) = try transcriptionModel("scribe_v2_realtime")
        await #expect(throws: AIError.invalidArgument(argument: "model", message: "'non-streaming transcription with scribe_v2_realtime' functionality not supported.")) {
            _ = try await model.transcribe(.init(audio: Data([1]), mimeType: "audio/wav"))
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test func warnsWhenStreamingOptionsArePassedToBatchTranscription() async throws {
        let (model, transport) = try transcriptionModel()
        let result = try await model.transcribe(.init(audio: Data([1]), mimeType: "audio/wav", providerOptions: ["elevenlabs": ["streaming": ["includeTimestamps": true]]]))
        #expect(result.warnings == [AIWarning(type: "unsupported", feature: "providerOptions.elevenlabs.streaming", message: "ElevenLabs batch transcription does not support streaming options.")])
        #expect(!elevenLabsMultipartFields(await transport.requests().first?.body).contains { $0.0.contains("streaming") || $0.0.contains("include") })
        await #expect(throws: AIError.self) {
            _ = try await model.transcribe(.init(audio: Data([1]), mimeType: "audio/wav", providerOptions: ["elevenlabs": ["streaming": ["vadThreshold": 2]]]))
        }
    }

    @Test(arguments: [
        ("4.24", #"[{"text":"Hello","type":"word","start":0,"end":2.06}]"#, 4.24),
        ("4.24", "null", 4.24),
        ("0", #"[{"text":"Hello","type":"word","start":0,"end":2.06}]"#, 0),
        (nil, #"[{"text":"Hello","type":"word","start":0,"end":2.06}]"#, 2.06),
        ("null", #"[{"text":"Hello","type":"word","start":0,"end":2.06}]"#, 2.06)
    ] as [(String?, String, Double)])
    func reportsDuration(_ audioDuration: String?, _ words: String, _ expected: Double) async throws {
        let duration = audioDuration.map { #""audio_duration_secs":\#($0),"# } ?? ""
        let (model, _) = try transcriptionModel("scribe_v1", jsonResponse(#"{\#(duration)"language_code":"en","language_probability":1,"text":"Hello","words":\#(words)}"#))
        #expect(try await model.transcribe(.init(audio: Data([1]), mimeType: "audio/wav")).durationInSeconds == expected)
    }

    @Test func passesModelAndHeadersAndExtractsText() async throws {
        let transport = RecordingTransport(response: jsonResponse(elevenLabsTranscriptionFixture))
        let provider = try AIProviders.elevenLabs(configuration: .init(apiKey: "test-api-key", headers: ["Custom-Provider-Header": "provider-header-value"], transport: transport))
        let result = try await provider.transcriptionModel("scribe_v1").transcribe(.init(audio: Data([1]), mimeType: "audio/wav", headers: ["Custom-Request-Header": "request-header-value"]))
        let request = try #require(await transport.requests().first)
        let headers = normalizeHeaders(request.headers)
        #expect(headers["xi-api-key"] == "test-api-key")
        #expect(headers["custom-provider-header"] == "provider-header-value")
        #expect(headers["custom-request-header"] == "request-header-value")
        #expect(headers["content-type"]?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(headers["user-agent"]?.contains("ai-sdk-elevenlabs/") == true)
        #expect(elevenLabsMultipartFields(request.body).first! == ("model_id", "scribe_v1"))
        #expect(result.text == "Hello from the Vercel AI SDK.")
        #expect(result.language == "eng")
        #expect(result.durationInSeconds == 2.479)
        #expect(result.segments.count == 11)
        #expect(result.segments[1] == TranscriptionSegment(text: " ", startSecond: 0.479, endSecond: 0.499))
        #expect(result.responseMetadata.modelID == "scribe_v1")
        // zod strips unknown keys such as logprob from provider metadata.
        #expect(result.providerMetadata["elevenlabs"]?["words"]?[0] == ["text": "Hello", "start": 0.199, "end": 0.479, "type": "word", "speaker_id": "speaker_0"])
    }

    @Test func preservesWordMetadataInProviderMetadata() async throws {
        let words: JSONValue = [
            ["text": "hi", "type": "word", "start": 0, "end": 0.4, "speaker_id": "speaker_1"],
            ["text": " ", "type": "spacing", "start": 0.4, "end": 0.5],
            ["text": "(laughter)", "type": "audio_event", "start": 0.5, "end": 1.2, "speaker_id": "speaker_1"]
        ]
        let body: JSONValue = ["language_code": "eng", "language_probability": 1, "text": "hi (laughter)", "words": words]
        let (model, _) = try transcriptionModel("scribe_v1", jsonResponse(String(decoding: try encodeJSONBody(body), as: UTF8.self)))
        let result = try await model.transcribe(.init(audio: Data([1]), mimeType: "audio/wav", providerOptions: ["elevenlabs": ["diarize": true]]))
        #expect(result.providerMetadata == ["elevenlabs": ["words": words]])
    }

    @Test func passesProviderOptionsCorrectly() async throws {
        let (model, transport) = try transcriptionModel()
        _ = try await model.transcribe(.init(audio: Data([1]), mimeType: "audio/wav", providerOptions: ["elevenlabs": [
            "languageCode": "en", "fileFormat": "pcm_s16le_16", "tagAudioEvents": false, "numSpeakers": 2, "timestampsGranularity": "character", "diarize": true
        ]]))
        let request = try #require(await transport.requests().first)
        #expect(String(decoding: try #require(request.body), as: UTF8.self).contains("name=\"file\"; filename=\"audio.wav\""))
        let fields = elevenLabsMultipartFields(request.body)
        #expect(fields.map(\.0) == ["model_id", "diarize", "language_code", "tag_audio_events", "num_speakers", "timestamps_granularity", "file_format"])
        #expect(fields.map(\.1) == ["scribe_v1", "true", "en", "false", "2", "character", "pcm_s16le_16"])
    }

    @Test func sendsSourceURLInsteadOfAFile() async throws {
        let (model, transport) = try transcriptionModel()
        let result = try await model.transcribe(.init(audio: Data(), mimeType: "audio/mpeg", providerOptions: ["elevenlabs": ["sourceUrl": "https://example.com/audio.mp3"]]))
        let fields = elevenLabsMultipartFields(await transport.requests().first?.body)
        #expect(Dictionary(uniqueKeysWithValues: fields) == [
            "diarize": "true", "file_format": "other", "model_id": "scribe_v1", "source_url": "https://example.com/audio.mp3",
            "tag_audio_events": "true", "timestamps_granularity": "word"
        ])
        #expect(result.warnings.isEmpty)
    }

    @Test(arguments: [
        (nil, "true"),
        (JSONValue.object([:]), "true"),
        (["languageCode": "en"], "true"),
        (["diarize": false], "false")
    ] as [(JSONValue?, String)])
    func sendsDiarizeOnce(_ options: JSONValue?, _ expected: String) async throws {
        let (model, transport) = try transcriptionModel()
        _ = try await model.transcribe(.init(audio: Data([1]), mimeType: "audio/wav", providerOptions: options.map { ["elevenlabs": $0] } ?? [:]))
        let values = elevenLabsMultipartFields(await transport.requests().first?.body).filter { $0.0 == "diarize" }.map(\.1)
        #expect(values == [expected])
    }

    @Test func surfacesTheElevenLabsErrorMessageAndCode() async throws {
        let body = #"{"detail":{"type":"not_found","code":"model_not_found","message":"A model with model_id 'scribe_v1' was not found.","status":"model_not_found","request_id":"req_test_transcription"}}"#
        let (model, _) = try transcriptionModel("scribe_v1", AIHTTPResponse(statusCode: 404, headers: ["content-type": "application/json"], body: Data(body.utf8)))
        do {
            _ = try await model.transcribe(.init(audio: Data([1]), mimeType: "audio/wav"))
            Issue.record("Expected API error")
        } catch let AIError.apiCall(error) {
            #expect(error.message == "A model with model_id 'scribe_v1' was not found. (model_not_found)")
            #expect(error.statusCode == 404)
            #expect(error.responseBody.contains("req_test_transcription"))
        }
    }
}
