import Foundation
import Testing
@testable import SwiftAIElevenLabs
import SwiftAIProvider
import SwiftAITransport

@Suite struct Weekly20261101SpeechTests {
    @Test func timestampedSpeechPreservesAlignmentAndRawMetadata() async throws {
        let raw: JSONValue = ["audio_base64": "AQID", "alignment": ["characters": ["H", "i"], "character_start_times_seconds": [0, 0.123456789], "character_end_times_seconds": [0.123456789, 0.4]]]
        let transport = RecordingTransport(response: AIHTTPResponse(statusCode: 200, headers: ["content-type": "application/json", "request-id": "tts-request"], body: try encodeJSONBody(raw)))
        let provider = try ElevenLabsProvider(configuration: .init(apiKey: "key", transport: transport))
        let result = try await provider.speechModel("eleven_multilingual_v2").speak(.init(text: "Hi", voice: "voice/slash", format: "pcm_24000", providerOptions: ["elevenlabs": ["withTimestamps": true, "seed": 0, "enableLogging": false]]))
        #expect(result.audio == Data([1, 2, 3]))
        #expect(result.contentType == "audio/pcm")
        #expect(result.providerMetadata["elevenlabs"]?["alignment"]?["characterStartTimesSeconds"] == [0, 0.123456789])
        #expect(result.responseMetadata.body == raw)
        let request = try #require(await transport.requests().first)
        #expect(request.url.absoluteString.contains("voice%2Fslash/with-timestamps?"))
        #expect(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "enable_logging", value: "false")) == true)
        let body = try decodeJSONBody(try #require(request.body))
        #expect(body == ["text": "Hi", "model_id": "eleven_multilingual_v2", "seed": 0])
    }

    @Test func v4AutomaticallyUsesSingleVoiceDialogueAndWavMapping() async throws {
        let transport = RecordingTransport(response: AIHTTPResponse(statusCode: 200, body: Data([1, 2])))
        let provider = try ElevenLabsProvider(configuration: .init(apiKey: "key", transport: transport))
        let result = try await provider.speechModel("eleven_v4").speak(.init(text: "Hi", voice: "voice-a", format: "wav", providerOptions: ["elevenlabs": ["voiceSettings": ["stability": 0, "similarityBoost": 0.75]]]))
        let request = try #require(await transport.requests().first)
        #expect(request.url.path == "/v1/text-to-dialogue")
        #expect(request.url.query == "output_format=wav_44100")
        #expect(try decodeJSONBody(try #require(request.body)) == ["model_id": "eleven_v4", "inputs": [["text": "Hi", "voice_id": "voice-a"]], "settings": ["stability": 0, "similarity": 0.75]])
        #expect(result.warnings.isEmpty)
        #expect(result.audio == Data([1, 2]))
    }

    @Test func timestampEnvelopeHandlesNullEmptyAndRejectsMalformedMetadata() throws {
        for raw: JSONValue in [["audio_base64": "", "alignment": ["characters": [], "character_start_times_seconds": [], "character_end_times_seconds": []]], ["audio_base64": "", "alignment": .null, "normalized_alignment": .null, "voice_segments": .null]] {
            let result = try elevenLabsDecodeSpeechResponse(.init(statusCode: 200, body: try encodeJSONBody(raw)), withTimestamps: true)
            #expect(result.audio.isEmpty)
        }
        for raw: JSONValue in [["audio_base64": 3], ["audio_base64": "AQ==", "alignment": ["characters": [1]]], ["audio_base64": "AQ==", "voice_segments": [["voice_id": "a"]]]] {
            #expect(throws: (any Error).self) { _ = try elevenLabsDecodeSpeechResponse(.init(statusCode: 200, body: try encodeJSONBody(raw)), withTimestamps: true) }
        }
    }

    @Test func dialogueTimestampVoiceSegmentsAndStreamingWarningArePreserved() async throws {
        let raw: JSONValue = ["audio_base64": "AQI=", "voice_segments": [["voice_id": "voice-a", "start_time_seconds": 0, "end_time_seconds": 0.4, "character_start_index": 0, "character_end_index": 2, "dialogue_input_index": 0]]]
        let transport = RecordingTransport(response: .init(statusCode: 200, body: try encodeJSONBody(raw)))
        let provider = try ElevenLabsProvider(configuration: .init(apiKey: "key", transport: transport))
        let result = try await provider.speechModel("eleven_v4").speak(.init(text: "", providerOptions: ["elevenlabs": ["withTimestamps": true, "inputs": [["text": "Hi", "voiceId": "voice-a"]]]]))
        #expect(result.providerMetadata["elevenlabs"]?["voiceSegments"] == [["voiceId": "voice-a", "startTimeSeconds": 0, "endTimeSeconds": 0.4, "characterStartIndex": 0, "characterEndIndex": 2, "dialogueInputIndex": 0]])
        #expect((await transport.requests()).first?.url.path == "/v1/text-to-dialogue/with-timestamps")
        let socket = WeeklySpeechSocketTransport()
        let model = try provider.streamingSpeechModel("eleven_flash_v2_5", webSocketTransport: socket)
        let streaming = try await model.stream(.init(text: .text("Hi"), providerOptions: ["elevenlabs": ["withTimestamps": true]], headers: ["Xi-Api-Key": "override-key"]))
        socket.socket.open()
        #expect(await weeklySpeechWait { !socket.socket.sent.isEmpty })
        #expect(socket.socket.sent.first?["xi-api-key"] == "override-key")
        #expect(socket.requests.first?.headers.keys.contains { $0.caseInsensitiveCompare("xi-api-key") == .orderedSame } == false)
        #expect(streaming.requestMetadata.body?["initMessage"]?["xi-api-key"] == nil)
        var iterator = streaming.stream.makeAsyncIterator()
        if case let .streamStart(warnings) = try await iterator.next() {
            #expect(warnings.contains { $0.feature == "providerOptions.elevenlabs.withTimestamps" })
        } else { Issue.record("Expected streaming warnings") }
        streaming.cancel()
    }

    @Test func detailedMusicPreservesBinaryAndUnicodeInEitherPartOrder() async throws {
        let audio = Data([255, 0, 128, 13, 10]) + Data("--music-boundary-extra".utf8) + Data([0, 255, 13, 10])
        let metadata: JSONValue = ["words_timestamps": [["word": "Hello 🌍", "start_ms": 120, "end_ms": 945]]]
        for reverse in [false, true] {
            let response = try musicResponse(audio: audio, metadata: metadata, reverse: reverse)
            let transport = RecordingTransport(response: response)
            let provider = try ElevenLabsProvider(configuration: .init(apiKey: "key", transport: transport))
            let result = try await provider.speechModel("music_v2_5").speak(.init(text: "song", providerOptions: ["elevenlabs": ["withTimestamps": true, "musicLengthMs": 3000]]))
            #expect(result.audio == audio)
            #expect(result.contentType == "audio/mpeg")
            #expect(result.providerMetadata["elevenlabs"]?["wordTimestamps"] == [["word": "Hello 🌍", "startMs": 120, "endMs": 945]])
            #expect(result.responseMetadata.body == metadata)
            #expect(result.responseMetadata.headers["song-id"] == "song")
            let request = try #require(await transport.requests().first)
            #expect(request.url.path == "/v1/music/detailed")
            #expect(try decodeJSONBody(try #require(request.body))["with_timestamps"] == true)
        }
    }

    @Test func musicMultipartRejectsMissingPartsOrInvalidMetadata() throws {
        for metadata: JSONValue in [[:], ["words_timestamps": .null], ["words_timestamps": []]] {
            let decoded = try elevenLabsDecodeSpeechResponse(try musicResponse(audio: Data(), metadata: metadata), musicTimestamps: true)
            #expect(decoded.audio.isEmpty)
        }
        for missing in ["audio", "metadata", "close"] {
            #expect(throws: (any Error).self) { _ = try elevenLabsDecodeSpeechResponse(try musicResponse(audio: Data([1]), metadata: [:], missing: missing), musicTimestamps: true) }
        }
        #expect(throws: (any Error).self) { _ = try elevenLabsDecodeSpeechResponse(try musicResponse(audio: Data([1]), metadata: ["words_timestamps": [["word": "Hi", "start_ms": "invalid", "end_ms": 1]]]), musicTimestamps: true) }
    }

    @Test func nativeMusicFactorySharesDetailedResponseAndTranscriptionSharesErrors() async throws {
        let response = try musicResponse(audio: Data([1, 2]), metadata: ["words_timestamps": []])
        let transport = RecordingTransport(response: response)
        let provider = try ElevenLabsProvider(configuration: .init(apiKey: "key", transport: transport))
        let music = try await provider.music("music_v2_5").generateAudio(.init(prompt: "Song", providerOptions: ["elevenlabs": ["withTimestamps": true]]))
        #expect(music.audio == Data([1, 2]))
        #expect(music.providerMetadata["elevenlabs"]?["wordTimestamps"] == [])
        let raw: JSONValue = ["detail": ["message": "Unknown model", "code": "model_not_found", "request_id": "req_1"]]
        let failed = RecordingTransport(response: .init(statusCode: 404, body: try encodeJSONBody(raw)))
        let transcription = try ElevenLabsProvider(configuration: .init(apiKey: "key", transport: failed)).transcriptionModel("scribe_v1")
        do { _ = try await transcription.transcribe(.init(audio: Data([1]))); Issue.record("Expected failure") }
        catch AIError.apiCall(let error) {
            #expect(error.message == "Unknown model (model_not_found)")
            #expect(try secureJSONParse(error.responseBody) == raw)
        }
    }

    @Test func errorsPreserveRawBodyAndMapAllPublishedDetailShapes() throws {
        let cases: [(JSONValue, String)] = [
            (["detail": ["message": "Voice absent", "code": "voice_not_found", "request_id": "req_1"]], "Voice absent (voice_not_found)"),
            (["detail": ["message": "Corrupt audio", "code": .null]], "Corrupt audio"),
            (["detail": [["loc": ["body", "voice_settings", "stability", 0], "msg": "Too high"], ["msg": "Invalid"]]], "body.voice_settings.stability.0: Too high; Invalid"),
            (["detail": "Not authenticated"], "Not authenticated"),
            (["error": ["message": "Quota exceeded", "code": 429]], "Quota exceeded")
        ]
        for (raw, expected) in cases {
            let response = AIHTTPResponse(statusCode: 422, headers: ["request-id": "request"], body: try encodeJSONBody(raw))
            guard case let .apiCall(error) = elevenLabsHTTPStatusError(provider: "elevenlabs.speech", response: response) else { Issue.record("Expected typed API error"); continue }
            #expect(error.message == expected)
            #expect(error.responseBody == response.bodyText)
            #expect(error.responseHeaders["request-id"] == "request")
            #expect(error.statusCode == 422)
        }
    }
}

private func musicResponse(audio: Data, metadata: JSONValue, reverse: Bool = false, missing: String? = nil) throws -> AIHTTPResponse {
    var parts: [Data] = []
    if missing != "metadata" { parts.append(Data("--music-boundary\r\nContent-Type: application/json\r\n\r\n".utf8) + (try encodeJSONBody(metadata)) + Data([13, 10])) }
    if missing != "audio" { parts.append(Data("--music-boundary\r\nContent-Type: audio/mpeg\r\n\r\n".utf8) + audio + Data([13, 10])) }
    if reverse { parts.reverse() }
    var body = parts.reduce(Data(), +)
    if missing != "close" { body += Data("--music-boundary--\r\n".utf8) }
    return AIHTTPResponse(statusCode: 200, headers: ["content-type": "Multipart/Mixed; boundary=\"music-boundary\"; charset=utf-8", "song-id": "song"], body: body)
}
