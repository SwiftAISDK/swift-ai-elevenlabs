@testable import SwiftAIElevenLabs
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

@Suite struct WeeklyElevenLabs20261025 {
    private func model(_ id: String = "eleven_flash_v2_5", socket: WeeklySpeechSocketTransport) throws -> any StreamingSpeechModel {
        let provider = try AIProviders.elevenLabs(configuration: .init(apiKey: "secret"))
        return try provider.streamingSpeechModel(id, webSocketTransport: socket)
    }

    @Test func streamBuffersWordsAuthenticatesWithoutLeakingAndCountsCodePoints() async throws {
        let socket = WeeklySpeechSocketTransport()
        let request = StreamingSpeechRequest(text: .chunks(["Hel", "lo ", "wörld 👋 "]), voice: "voice/one", outputFormat: .init(mediaType: "audio/pcm", sampleRate: 24000), speed: 1.1,
                                             providerOptions: ["elevenlabs": ["voiceSettings": ["similarityBoost": 0.8], "streaming": ["autoMode": true, "chunkLengthSchedule": [50, 120], "inactivityTimeout": 60]]], includeRawChunks: true)
        let raw = try await model(socket: socket).stream(request)
        socket.socket.open()
        #expect(await weeklySpeechWait { socket.socket.sent.count == 4 })
        let sent = socket.socket.sent
        #expect(sent[0]["text"] == " "); #expect(sent[0]["xi-api-key"] == "secret")
        #expect(sent[0]["voice_settings"]?["similarity_boost"] == 0.8)
        #expect(sent[1]["text"] == "Hello "); #expect(sent[2]["text"] == "wörld 👋 "); #expect(sent[3]["text"] == "")
        #expect(raw.requestMetadata.body?["initMessage"]?["xi-api-key"] == nil)
        let socketRequest = try #require(socket.requests.first)
        #expect(normalizeHeaders(socketRequest.headers)["xi-api-key"] == nil)
        #expect(socketRequest.url.absoluteString.contains("voice%2Fone/stream-input"))
        try socket.socket.receive(["audio": "AQI=", "alignment": ["chars": ["H"]]])
        try socket.socket.receive(["isFinal": true])
        var bytes = Data(); var chars: JSONValue?
        for try await part in raw.stream {
            if case let .audio(_, data, _, _) = part { bytes.append(data) }
            if case let .finish(usage, _) = part { chars = usage["inputCharacters"] }
        }
        #expect(bytes == Data([1, 2])); #expect(chars == 14)
    }

    @Test(arguments: ["eleven_v3", "eleven_v4"]) func dialogueRoutesAndPreservesTurns(_ id: String) async throws {
        let socket = WeeklySpeechSocketTransport()
        let parts = [SpeechTextPart(text: "Hi", voice: "a"), .init(text: " there. ", voice: "a"), .init(text: "Hello ", voice: "b"), .init(text: "again", voice: "b", providerOptions: ["elevenlabs": ["newTurn": true]])]
        let raw = try await model(id, socket: socket).stream(.init(text: .parts(parts), providerOptions: ["elevenlabs": ["dialogue": ["voices": ["a", "b"]]]]))
        socket.socket.open()
        let expected = id == "eleven_v4" ? 5 : 2
        #expect(await weeklySpeechWait { socket.socket.sent.count == expected })
        let sent = socket.socket.sent
        #expect(socket.requests.first?.url.path == "/v1/text-to-dialogue/stream-input")
        #expect(sent[0]["xi_api_key"] == "secret")
        let inputs: [JSONValue]
        if id == "eleven_v4" { inputs = sent.dropFirst().flatMap { $0["inputs"]?.arrayValue ?? [] } }
        else { inputs = sent[1]["inputs"]?.arrayValue ?? [] }
        #expect(inputs.count == 3)
        #expect(inputs[0]["text"] == "Hi there. ")
        #expect(inputs[1]["voice_id"] == "b"); #expect(inputs[1]["new_turn"] == true)
        #expect(inputs[2]["new_turn"] == true)
        try socket.socket.receive(["audio": "AQ==", "alignment": ["chars": ["H"], "char_start_times_ms": [0]]])
        try socket.socket.receive(["is_final_audio_for_turn": true]); try socket.socket.receive(["is_final": true])
        var metadataOnly = 0
        for try await part in raw.stream { if case let .audio(_, bytes, _, metadata) = part, bytes.isEmpty, metadata["elevenlabs"]?["isFinalAudioForTurn"] == true { metadataOnly += 1 } }
        #expect(metadataOnly == 1)
    }

    @Test func invalidStreamingOptionsRejectBeforeConnection() async throws {
        let socket = WeeklySpeechSocketTransport()
        let options: [[String: JSONValue]] = [
            ["streaming": ["chunkLengthSchedule": [49]]], ["streaming": ["inactivityTimeout": 181]],
            ["pronunciationDictionaryLocators": [["pronunciationDictionaryId": "dict"]]]
        ]
        for item in options {
            do { _ = try await model(socket: socket).stream(.init(text: "x", providerOptions: ["elevenlabs": .object(item)])); Issue.record("Expected validation error") } catch is AIError {}
        }
        #expect(socket.requests.isEmpty)
    }

    @Test func singleVoiceRejectsChangedSpeakerAndAbortsReleaseInput() async throws {
        let socket = WeeklySpeechSocketTransport()
        let raw = try await model(socket: socket).stream(.init(text: .parts([.init(text: "hello", voice: "other")]), voice: "selected"))
        socket.socket.open()
        do { for try await _ in raw.stream {}; Issue.record("Expected voice error") } catch is AIError {}
        #expect(await weeklySpeechWait { socket.socket.closeCount == 1 })
    }

    @Test func streamAudioFormatAndWordBoundaries() throws {
        #expect(try elevenLabsStreamOutputFormat(.init(mediaType: "Audio/PCM;rate=24000", sampleRate: 24000)) == "pcm_24000")
        #expect(try elevenLabsStreamOutputFormat(.init(mediaType: "audio/ogg")) == "opus_48000_64")
        #expect(elevenLabsAudioFormat("opus_48000_64").mediaType == "audio/ogg")
        #expect(elevenLabsCompleteWords("日本語。途中").send == "日本語。")
        #expect(elevenLabsCompleteWords(String(repeating: "😀", count: 100)).hold == "")
    }

    @Test func musicAndSoundSpeechRoutesExposeRequestedDuration() async throws {
        let transport = RecordingTransport(response: .init(statusCode: 200, headers: ["content-type": "audio/mpeg"], body: Data([1])))
        let provider = try AIProviders.elevenLabs(configuration: .init(apiKey: "key", transport: transport))
        let music = try await provider.speechModel("music_v2_5").speak(.init(text: "prompt ignored", providerOptions: ["elevenlabs": ["compositionPlan": ["chunks": [
            ["text": "music", "duration_ms": 3000, "positive_styles": ["quiet"]], ["song_id": "ref", "range": ["start_ms": 100, "end_ms": 3600]]
        ]]]]))
        #expect(music.providerMetadata["elevenlabs"]?["requestedDurationMs"] == 6500)
        let request = try #require(await transport.requests().first)
        #expect(request.url.path == "/v1/music")
        let body = try decodeJSONBody(try #require(request.body))
        #expect(body["composition_plan"] != nil); #expect(body["prompt"] == nil)
        let effects = try await provider.speechModel("eleven_text_to_sound_v3").speak(.init(text: "rain", providerOptions: ["elevenlabs": ["durationSeconds": 2, "loop": true, "promptInfluence": 0.5]]))
        #expect(effects.providerMetadata["elevenlabs"]?["requestedDurationMs"] == 2000)
        #expect(await transport.requests().last?.url.path == "/v1/sound-generation")
    }

    @Test func unaryDialogueMapsSpeakerInputsAndSettings() async throws {
        let transport = RecordingTransport(response: .init(statusCode: 200, body: Data([1])))
        let provider = try AIProviders.elevenLabs(configuration: .init(apiKey: "key", transport: transport))
        _ = try await provider.speechModel("eleven_v4").speak(.init(text: "ignored", providerOptions: ["elevenlabs": ["inputs": [["text": "Hi", "voiceId": "a"]], "nextText": "future", "voiceSettings": ["stability": 0.5, "similarityBoost": 0.8]]]))
        let request = try #require(await transport.requests().first)
        #expect(request.url.path == "/v1/text-to-dialogue")
        let body = try decodeJSONBody(try #require(request.body))
        #expect(body["inputs"]?.arrayValue?.first?["voice_id"] == "a")
        #expect(body["settings"]?["similarity"] == 0.8)
        #expect(body["future_text"] == "future")
    }

    @Test func invalidPlanAndMutuallyExclusivePromptOptionsRejectBeforeHTTP() async throws {
        let transport = RecordingTransport(response: .init(statusCode: 200, body: Data()))
        let provider = try AIProviders.elevenLabs(configuration: .init(apiKey: "key", transport: transport))
        func sectionPlan(name: String, line: String) -> JSONValue {
            ["positive_global_styles": [], "negative_global_styles": [], "sections": [[
                "section_name": .string(name), "positive_local_styles": [], "negative_local_styles": [],
                "duration_ms": 3000, "lines": [.string(line)]
            ]]]
        }
        let options: [[String: JSONValue]] = [
            ["compositionPlan": ["chunks": [["text": "x", "duration_ms": 2000, "positive_styles": []]]]],
            ["compositionPlan": ["chunks": []], "forceInstrumental": true],
            ["compositionPlan": sectionPlan(name: String(repeating: "😀", count: 51), line: "text")],
            ["compositionPlan": sectionPlan(name: "intro", line: String(repeating: "😀", count: 101))]
        ]
        for item in options {
            do { _ = try await provider.speechModel("music_v2").speak(.init(text: "x", providerOptions: ["elevenlabs": .object(item)])); Issue.record("Expected invalid plan") } catch is AIError {}
        }
        #expect(await transport.requests().isEmpty)
        let valid = sectionPlan(name: String(repeating: "😀", count: 50), line: String(repeating: "😀", count: 100))
        _ = try await provider.speechModel("music_v1").speak(.init(text: "", providerOptions: ["elevenlabs": ["compositionPlan": valid]]))
        let body = try decodeJSONBody(try #require(await transport.requests().first?.body))
        #expect(body["composition_plan"] == valid)
    }

    @Test func transcriptionUsesAuthoritativeAudioDuration() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"language_code":"en","language_probability":1,"text":"hello","audio_duration_secs":12.5,"words":[{"type":"word","text":"hello","start":0,"end":1}]}"#))
        let provider = try AIProviders.elevenLabs(configuration: .init(apiKey: "key", transport: transport))
        let result = try await provider.transcriptionModel("scribe_v2").transcribe(.init(audio: Data(), mimeType: "audio/wav"))
        #expect(result.durationInSeconds == 12.5)
    }
}
