@testable import SwiftAIElevenLabs
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

// Translated from packages/elevenlabs/src/elevenlabs-speech-model.test.ts
// (doGenerate, native output formats, dialogue, music and sound effects).

private let parityAlignment: JSONValue = [
    "characters": ["H", "i"],
    "character_start_times_seconds": [0, 0.123456789],
    "character_end_times_seconds": [0.123456789, 0.4]
]
private let parityAlignmentMetadata: JSONValue = [
    "characters": ["H", "i"],
    "characterStartTimesSeconds": [0, 0.123456789],
    "characterEndTimesSeconds": [0.123456789, 0.4]
]
private let generationAudio = Data([0xff, 0xfb, 0x90, 0x64, 1, 2, 3, 4])

private func binaryAudio(_ data: Data = generationAudio, type: String = "audio/mpeg") -> AIHTTPResponse {
    AIHTTPResponse(statusCode: 200, headers: ["content-type": type], body: data)
}

private func speechModel(_ id: String, _ response: AIHTTPResponse) throws -> (any SpeechModel, RecordingTransport) {
    let transport = RecordingTransport(response: response)
    let provider = try AIProviders.elevenLabs(configuration: .init(apiKey: "test-api-key", transport: transport))
    return (try provider.speechModel(id), transport)
}

private func sentBody(_ transport: RecordingTransport) async throws -> JSONValue {
    try decodeJSONBody(try #require(await transport.requests().first?.body))
}

private func sentURL(_ transport: RecordingTransport) async -> String? {
    await transport.requests().first?.url.absoluteString
}

@Suite("ElevenLabs speech doGenerate parity")
struct ElevenLabsSpeechGenerateParityTests {
    @Test(arguments: [false, true])
    func preservesBinaryAudioWithoutTimestamps(_ explicitFalse: Bool) async throws {
        let (model, transport) = try speechModel("eleven_multilingual_v2", binaryAudio(Data(count: 100)))
        let result = try await model.speak(.init(text: "Hi", providerOptions: ["elevenlabs": explicitFalse ? ["withTimestamps": false] : [:]]))
        #expect(result.audio == Data(count: 100))
        #expect(result.providerMetadata == ["elevenlabs": ["outputFormat": "mp3_44100_128"]])
        #expect(await sentURL(transport) == "https://api.elevenlabs.io/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM?output_format=mp3_44100_128")
    }

    @Test func returnsTimestampedAudioAndMetadataFromTextToSpeech() async throws {
        let body: JSONValue = ["audio_base64": "AQID", "alignment": parityAlignment, "normalized_alignment": parityAlignment]
        let (model, transport) = try speechModel("eleven_multilingual_v2", jsonResponse(String(decoding: try encodeJSONBody(body), as: UTF8.self), headers: ["request-id": "tts-request"]))
        let result = try await model.speak(.init(text: "Hi", voice: "test-voice", format: "pcm_24000", providerOptions: ["elevenlabs": ["withTimestamps": true, "seed": 0, "enableLogging": false]], headers: ["custom-header": "custom-value"]))
        #expect(await sentURL(transport) == "https://api.elevenlabs.io/v1/text-to-speech/test-voice/with-timestamps?output_format=pcm_24000&enable_logging=false")
        #expect(try await sentBody(transport) == ["text": "Hi", "model_id": "eleven_multilingual_v2", "seed": 0])
        #expect(await transport.requests().first?.headers["custom-header"] == "custom-value")
        #expect(result.audio == Data([1, 2, 3]))
        #expect(result.providerMetadata == ["elevenlabs": ["outputFormat": "pcm_24000", "alignment": parityAlignmentMetadata, "normalizedAlignment": parityAlignmentMetadata]])
        #expect(result.responseMetadata.headers["request-id"] == "tts-request")
    }

    @Test(arguments: [#"{"audio_base64":"AQID"}"#, #"{"audio_base64":"AQID","alignment":null,"normalized_alignment":null,"voice_segments":null}"#])
    func acceptsAbsentOrNullTimestampMetadata(_ json: String) async throws {
        let (model, _) = try speechModel("eleven_multilingual_v2", jsonResponse(json))
        let result = try await model.speak(.init(text: "Hi", providerOptions: ["elevenlabs": ["withTimestamps": true]]))
        #expect(result.audio == Data([1, 2, 3]))
        #expect(result.providerMetadata == ["elevenlabs": ["outputFormat": "mp3_44100_128"]])
    }

    @Test(arguments: [false, true])
    func routesElevenV4ToTextToDialogue(_ withTimestamps: Bool) async throws {
        let response = withTimestamps
            ? jsonResponse(String(decoding: try encodeJSONBody(["audio_base64": "AQID", "alignment": parityAlignment, "normalized_alignment": parityAlignment]), as: UTF8.self))
            : binaryAudio(Data([1, 2, 3]))
        let (model, transport) = try speechModel("eleven_v4", response)
        var options: [String: JSONValue] = ["voiceSettings": ["stability": 0, "similarityBoost": 0.75]]
        if withTimestamps { options["withTimestamps"] = true }
        let result = try await model.speak(.init(text: "Hi", voice: "test-voice", format: "mp3_192", providerOptions: ["elevenlabs": .object(options)]))
        #expect(await sentURL(transport) == "https://api.elevenlabs.io/v1/text-to-dialogue\(withTimestamps ? "/with-timestamps" : "")?output_format=mp3_44100_192")
        #expect(try await sentBody(transport) == ["inputs": [["text": "Hi", "voice_id": "test-voice"]], "model_id": "eleven_v4", "settings": ["stability": 0, "similarity": 0.75]])
        #expect(result.audio == Data([1, 2, 3]))
        #expect(result.warnings.isEmpty)
    }

    @Test func soundEffectsWarnAboutTimestampsWithoutChangingEndpoint() async throws {
        let (model, transport) = try speechModel("eleven_text_to_sound_v2", binaryAudio())
        let result = try await model.speak(.init(text: "A short sound.", providerOptions: ["elevenlabs": ["withTimestamps": true]]))
        #expect(await sentURL(transport) == "https://api.elevenlabs.io/v1/sound-generation?output_format=mp3_44100_128")
        #expect(result.audio == generationAudio)
        #expect(result.warnings.contains { $0.type == "unsupported" && $0.feature == "providerOptions.elevenlabs.withTimestamps" })
    }

    @Test func warnsAboutAndIgnoresStreamingAndDialogueOptions() async throws {
        let (model, transport) = try speechModel("eleven_multilingual_v2", binaryAudio())
        let result = try await model.speak(.init(text: "Hello, world!", providerOptions: ["elevenlabs": ["streaming": ["autoMode": true], "dialogue": ["voices": ["a"]]]]))
        #expect(result.warnings == [
            AIWarning(type: "unsupported", feature: "providerOptions.elevenlabs.streaming", message: "Streaming options apply only to streaming speech (experimental_streamSpeech) and were ignored."),
            AIWarning(type: "unsupported", feature: "providerOptions.elevenlabs.dialogue", message: "Dialogue options apply only to streaming speech (experimental_streamSpeech) and were ignored.")
        ])
        let url = try #require(await transport.requests().first?.url)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "auto_mode" } == false)
    }

    @Test(arguments: [("wav", "wav_44100"), ("wav_24000", "wav_24000")])
    func mapsHTTPOutputFormat(_ format: String, _ native: String) async throws {
        let (model, transport) = try speechModel("eleven_multilingual_v2", binaryAudio(Data(count: 100), type: "audio/wav"))
        let result = try await model.speak(.init(text: "Hello, world!", format: format))
        #expect(await sentURL(transport) == "https://api.elevenlabs.io/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM?output_format=\(native)")
        #expect(result.providerMetadata["elevenlabs"]?["outputFormat"] == .string(native))
    }

    @Test func passesProviderSpecificOptionsAndReportsOutputFormat() async throws {
        let (model, transport) = try speechModel("eleven_multilingual_v2", binaryAudio())
        let result = try await model.speak(.init(text: "Hello, world!", voice: "test-voice-id", format: "pcm_24000",
                                                 providerOptions: ["elevenlabs": ["voiceSettings": ["stability": 0.5, "similarityBoost": 0.75], "seed": 123]]))
        #expect(try await sentBody(transport) == ["text": "Hello, world!", "model_id": "eleven_multilingual_v2", "voice_settings": ["stability": 0.5, "similarity_boost": 0.75], "seed": 123])
        #expect(result.providerMetadata == ["elevenlabs": ["outputFormat": "pcm_24000"]])
        #expect(await transport.requests().first?.headers["user-agent"]?.contains("ai-sdk-elevenlabs/") == true)
    }

    @Test(arguments: [Optional("test-voice-id"), nil])
    func sendsTheFullTextToSpeechRequest(_ voice: String?) async throws {
        let (model, transport) = try speechModel("eleven_multilingual_v2", binaryAudio())
        _ = try await model.speak(.init(text: "Hello, world!", voice: voice))
        #expect(await sentURL(transport) == "https://api.elevenlabs.io/v1/text-to-speech/\(voice ?? "21m00Tcm4TlvDq8ikWAM")?output_format=mp3_44100_128")
        #expect(try await sentBody(transport) == ["text": "Hello, world!", "model_id": "eleven_multilingual_v2"])
    }

    @Test func surfacesTheElevenLabsErrorMessageAndCode() async throws {
        let body = #"{"detail":{"type":"not_found","code":"voice_not_found","message":"A voice with voice_id 'missing-voice' was not found.","status":"voice_not_found","request_id":"req_test_speech"}}"#
        let (model, _) = try speechModel("eleven_multilingual_v2", AIHTTPResponse(statusCode: 404, headers: ["content-type": "application/json"], body: Data(body.utf8)))
        do {
            _ = try await model.speak(.init(text: "Hello, world!", voice: "missing-voice"))
            Issue.record("Expected API error")
        } catch let AIError.apiCall(error) {
            #expect(error.message == "A voice with voice_id 'missing-voice' was not found. (voice_not_found)")
            #expect(error.statusCode == 404)
            #expect(error.responseBody.contains("req_test_speech"))
        }
    }

    @Test(arguments: [
        ("music_v2_5", "https://api.elevenlabs.io/v1/music", JSONValue.object([:])),
        ("eleven_text_to_sound_v2", "https://api.elevenlabs.io/v1/sound-generation", .object([:])),
        ("eleven_v3", "https://api.elevenlabs.io/v1/text-to-dialogue", JSONValue.object(["inputs": [["text": "Hello", "voiceId": "voice-a"]]]))
    ])
    func normalizesWAVForNativeEndpoints(_ modelID: String, _ url: String, _ options: JSONValue) async throws {
        let (model, transport) = try speechModel(modelID, binaryAudio())
        let result = try await model.speak(.init(text: "Hello", format: "wav", providerOptions: ["elevenlabs": options]))
        #expect(await sentURL(transport) == "\(url)?output_format=wav_44100")
        #expect(result.audio == generationAudio)
        #expect(result.providerMetadata["elevenlabs"]?["outputFormat"] == "wav_44100")
    }

    @Test(arguments: [
        ("music_v2_5", "https://api.elevenlabs.io/v1/music", "auto", JSONValue.object([:])),
        ("eleven_text_to_sound_v2", "https://api.elevenlabs.io/v1/sound-generation", "wav_24000", .object([:])),
        ("eleven_v3", "https://api.elevenlabs.io/v1/text-to-dialogue", "wav_22050", JSONValue.object(["inputs": [["text": "Knock knock", "voiceId": "voice-a"]]]))
    ])
    func passesNativeOutputFormatsThrough(_ modelID: String, _ url: String, _ format: String, _ options: JSONValue) async throws {
        let (model, transport) = try speechModel(modelID, binaryAudio())
        let result = try await model.speak(.init(text: "Hello", format: format, providerOptions: ["elevenlabs": options]))
        #expect(await sentURL(transport) == "\(url)?output_format=\(format)")
        #expect(result.providerMetadata["elevenlabs"]?["outputFormat"] == .string(format))
    }
}

@Suite("ElevenLabs dialogue, music and sound effects parity")
struct ElevenLabsAudioGenerationParityTests {
    private let inputs: JSONValue = [["text": "Knock knock", "voiceId": "voice-a"], ["text": "Who is there?", "voiceId": "voice-b"]]

    @Test func generatesDialogueFromInputs() async throws {
        let (model, transport) = try speechModel("eleven_v3", binaryAudio())
        let result = try await model.speak(.init(text: "Knock knock", format: "mp3_22050_32", language: "en", providerOptions: ["elevenlabs": [
            "inputs": inputs, "voiceSettings": ["stability": 0.4, "similarityBoost": 0.8], "nextText": "Lettuce.", "seed": 3
        ]]))
        #expect(await sentURL(transport) == "https://api.elevenlabs.io/v1/text-to-dialogue?output_format=mp3_22050_32")
        #expect(try await sentBody(transport) == [
            "inputs": [["text": "Knock knock", "voice_id": "voice-a"], ["text": "Who is there?", "voice_id": "voice-b"]],
            "model_id": "eleven_v3", "language_code": "en", "settings": ["stability": 0.4, "similarity": 0.8], "future_text": "Lettuce.", "seed": 3
        ])
        #expect(result.audio == generationAudio)
        #expect(result.warnings == [AIWarning(type: "other", message: "ElevenLabs dialogue uses providerOptions.elevenlabs.inputs; the text prompt was ignored.")])
        #expect(result.providerMetadata == ["elevenlabs": ["outputFormat": "mp3_22050_32"]])
    }

    @Test func doesNotWarnAboutEmptyPrompts() async throws {
        let (dialogue, _) = try speechModel("eleven_v3", binaryAudio())
        #expect(try await dialogue.speak(.init(text: "", providerOptions: ["elevenlabs": ["inputs": inputs]])).warnings.isEmpty)
        let (music, transport) = try speechModel("music_v2_5", binaryAudio())
        #expect(try await music.speak(.init(text: "", providerOptions: ["elevenlabs": ["compositionPlan": ["chunks": []]]])).warnings.isEmpty)
        #expect(try await sentBody(transport) == ["composition_plan": ["chunks": []], "model_id": "music_v2_5"])
    }

    @Test func warnsAboutAndIgnoresOptionsDialogueDoesNotTake() async throws {
        let (model, transport) = try speechModel("eleven_v3", binaryAudio())
        let result = try await model.speak(.init(text: "x", voice: "voice-a", speed: 1.1, providerOptions: ["elevenlabs": [
            "inputs": inputs, "voiceSettings": ["style": 0.2], "durationSeconds": 2
        ]]))
        #expect(try await sentBody(transport)["settings"] == nil)
        #expect(result.warnings.map(\.feature) == [
            "providerOptions.elevenlabs.durationSeconds", nil, "speed", "voice", "providerOptions.elevenlabs.voiceSettings.style"
        ])
        #expect(result.warnings[2].message == "ElevenLabs dialogue does not support speed; it was ignored.")
    }

    @Test func requiresADialogueModel() async throws {
        let (model, transport) = try speechModel("eleven_multilingual_v2", binaryAudio())
        await #expect(throws: AIError.invalidArgument(argument: "providerOptions.elevenlabs.inputs", message: "ElevenLabs dialogue requires an eleven_v3 or eleven_v4 model; eleven_multilingual_v2 is not one.")) {
            _ = try await model.speak(.init(text: "x", providerOptions: ["elevenlabs": ["inputs": inputs]]))
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test func warnsWhenInputsAreSentToAMusicModel() async throws {
        let (model, _) = try speechModel("music_v2", binaryAudio())
        let result = try await model.speak(.init(text: "Lo-fi beat", providerOptions: ["elevenlabs": ["inputs": inputs]]))
        #expect(result.warnings.contains { $0.feature == "providerOptions.elevenlabs.inputs" })
    }

    @Test func composesMusicFromTheTextPrompt() async throws {
        let (model, transport) = try speechModel("music_v2_5", binaryAudio())
        let result = try await model.speak(.init(text: "An upbeat synthwave intro", format: "mp3_22050_32", providerOptions: ["elevenlabs": ["musicLengthMs": 10000, "forceInstrumental": true, "enableLogging": false]]))
        #expect(await sentURL(transport) == "https://api.elevenlabs.io/v1/music?output_format=mp3_22050_32&enable_logging=false")
        #expect(try await sentBody(transport) == ["prompt": "An upbeat synthwave intro", "model_id": "music_v2_5", "music_length_ms": 10000, "force_instrumental": true])
        #expect(result.warnings.isEmpty)
        #expect(result.providerMetadata == ["elevenlabs": ["outputFormat": "mp3_22050_32", "requestedDurationMs": 10000]])
    }

    @Test func defaultsMusicOutputFormatAndLength() async throws {
        let (model, transport) = try speechModel("music_v2_5", binaryAudio())
        let result = try await model.speak(.init(text: "Lo-fi beat"))
        #expect(await sentURL(transport) == "https://api.elevenlabs.io/v1/music?output_format=mp3_44100_128")
        #expect(try await sentBody(transport) == ["prompt": "Lo-fi beat", "model_id": "music_v2_5"])
        #expect(result.providerMetadata == ["elevenlabs": ["outputFormat": "mp3_44100_128"]])
    }

    @Test func musicWarnsAboutSpeechOnlyAndSoundEffectsOptions() async throws {
        let (model, transport) = try speechModel("music_v2_5", binaryAudio())
        let result = try await model.speak(.init(text: "Lo-fi beat", voice: "test-voice-id", speed: 1.2, language: "en", instructions: "Make it calm",
                                                 providerOptions: ["elevenlabs": ["voiceSettings": ["stability": 0.5], "durationSeconds": 2, "loop": true]]))
        #expect(try await sentBody(transport) == ["prompt": "Lo-fi beat", "model_id": "music_v2_5"])
        #expect(result.warnings.map(\.feature) == [
            "instructions", "language", "speed", "voice", "providerOptions.elevenlabs.voiceSettings",
            "providerOptions.elevenlabs.durationSeconds", "providerOptions.elevenlabs.loop"
        ])
        #expect(result.warnings[0].message == "ElevenLabs music models do not support instructions; it was ignored.")
        #expect(result.warnings[4].message == "ElevenLabs music models do not support voiceSettings; it was ignored.")
    }

    @Test func sendsACompositionPlanInPlaceOfThePrompt() async throws {
        let (model, transport) = try speechModel("music_v2_5", binaryAudio())
        let plan: JSONValue = ["chunks": [["text": "[Intro]", "duration_ms": 4000, "positive_styles": ["ambient"]], ["song_id": "song-1", "range": ["start_ms": 1000, "end_ms": 3500]]]]
        let result = try await model.speak(.init(text: "ignored", providerOptions: ["elevenlabs": ["compositionPlan": plan, "seed": 7]]))
        #expect(try await sentBody(transport) == ["composition_plan": plan, "model_id": "music_v2_5", "seed": 7])
        #expect(result.warnings == [AIWarning(type: "other", message: "ElevenLabs music uses providerOptions.elevenlabs.compositionPlan; the text prompt was ignored.")])
        #expect(result.providerMetadata == ["elevenlabs": ["outputFormat": "mp3_44100_128", "requestedDurationMs": 6500]])
    }

    @Test func sumsMusicV1SectionsAndOmitsEmptyPlanDuration() async throws {
        let section: [String: JSONValue] = ["section_name": "Verse", "positive_local_styles": ["driving"], "negative_local_styles": [], "lines": ["Hello"]]
        var first = section; first["duration_ms"] = 3000
        var second = section; second["duration_ms"] = 5000
        let plan: JSONValue = ["positive_global_styles": ["rock"], "negative_global_styles": [], "sections": [.object(first), .object(second)]]
        let (v1, transport) = try speechModel("music_v1", binaryAudio())
        let result = try await v1.speak(.init(text: "ignored", providerOptions: ["elevenlabs": ["compositionPlan": plan]]))
        #expect(try await sentBody(transport) == ["composition_plan": plan, "model_id": "music_v1"])
        #expect(result.providerMetadata["elevenlabs"]?["requestedDurationMs"] == 8000)
        let (v25, _) = try speechModel("music_v2_5", binaryAudio())
        let empty = try await v25.speak(.init(text: "ignored", providerOptions: ["elevenlabs": ["compositionPlan": ["chunks": []]]]))
        #expect(empty.providerMetadata == ["elevenlabs": ["outputFormat": "mp3_44100_128"]])
    }

    @Test(arguments: [("musicLengthMs", JSONValue.number(5000)), ("forceInstrumental", .bool(false))])
    func rejectsPromptOnlyOptionsWithACompositionPlan(_ option: String, _ value: JSONValue) async throws {
        let (model, transport) = try speechModel("music_v2_5", binaryAudio())
        var options: [String: JSONValue] = ["compositionPlan": ["chunks": []]]
        options[option] = value
        let request = SpeechRequest(text: "ignored", providerOptions: ["elevenlabs": .object(options)])
        await #expect(throws: AIError.invalidArgument(argument: "providerOptions.elevenlabs.\(option)", message: "ElevenLabs music \(option) cannot be combined with compositionPlan.")) {
            _ = try await model.speak(request)
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test func rejectsInvalidPlansAndOutOfRangeLengthsBeforeHTTP() async throws {
        let (model, transport) = try speechModel("music_v2_5", binaryAudio())
        await #expect(throws: AIError.self) {
            _ = try await model.speak(.init(text: "ignored", providerOptions: ["elevenlabs": ["compositionPlan": ["chunks": [["text": "[Intro]"]]]]]))
        }
        await #expect(throws: AIError.self) {
            _ = try await model.speak(.init(text: "Lo-fi beat", providerOptions: ["elevenlabs": ["musicLengthMs": 1000]]))
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test func generatesASoundEffectFromTheText() async throws {
        let (model, transport) = try speechModel("eleven_text_to_sound_v2", binaryAudio())
        let result = try await model.speak(.init(text: "Glass shattering", format: "pcm_24000", providerOptions: ["elevenlabs": ["durationSeconds": 2, "promptInfluence": 0.6, "loop": true]]))
        #expect(await sentURL(transport) == "https://api.elevenlabs.io/v1/sound-generation?output_format=pcm_24000")
        #expect(try await sentBody(transport) == ["text": "Glass shattering", "model_id": "eleven_text_to_sound_v2", "duration_seconds": 2, "prompt_influence": 0.6, "loop": true])
        #expect(result.warnings.isEmpty)
        #expect(result.providerMetadata == ["elevenlabs": ["outputFormat": "pcm_24000", "requestedDurationMs": 2000]])
    }

    @Test func soundEffectsLeaveDurationToTheModelAndWarnAboutOtherOptions() async throws {
        let (model, transport) = try speechModel("eleven_text_to_sound_v2", binaryAudio())
        let plain = try await model.speak(.init(text: "Door creak"))
        #expect(plain.providerMetadata == ["elevenlabs": ["outputFormat": "mp3_44100_128"]])
        let result = try await model.speak(.init(text: "Door creak", providerOptions: ["elevenlabs": ["musicLengthMs": 5000, "seed": 1, "previousText": "x"]]))
        #expect(try decodeJSONBody(try #require(await transport.requests().last?.body)) == ["text": "Door creak", "model_id": "eleven_text_to_sound_v2"])
        #expect(result.warnings.map(\.feature) == ["providerOptions.elevenlabs.previousText", "providerOptions.elevenlabs.musicLengthMs", "providerOptions.elevenlabs.seed"])
        #expect(result.warnings[2].message == "ElevenLabs sound effects models do not support seed; it was ignored.")
    }
}

// Translated rejection cases from packages/elevenlabs/src/elevenlabs-music-response.test.ts.
@Suite("ElevenLabs music timestamp response parity")
struct ElevenLabsMusicResponseParityTests {
    private func body(json: String = #"{"words_timestamps":[{"word":"Hello 🌍","start_ms":120,"end_ms":945}]}"#) -> Data {
        Data("--music-boundary\r\nContent-Type: application/json\r\n\r\n\(json)\r\n--music-boundary\r\nContent-Type: audio/mpeg\r\nContent-Disposition: attachment; filename=\"music.mp3\"\r\n\r\n".utf8)
            + Data([255, 0, 128]) + Data("\r\n--music-boundary--\r\n".utf8)
    }

    @Test(arguments: ["application/json", "multipart/mixed", "multipart/mixed; boundary=\"wrong\""])
    func rejectsInvalidMultipartContentTypes(_ contentType: String) {
        #expect(throws: (any Error).self) {
            _ = try elevenLabsDecodeSpeechResponse(AIHTTPResponse(statusCode: 200, headers: ["content-type": contentType], body: body()), musicTimestamps: true)
        }
    }

    @Test(arguments: ["{", #"{"words_timestamps":[{"word":"Hello","start_ms":"invalid","end_ms":1}]}"#])
    func rejectsMalformedLyricMetadata(_ json: String) {
        #expect(throws: (any Error).self) {
            _ = try elevenLabsDecodeSpeechResponse(AIHTTPResponse(statusCode: 200, headers: ["content-type": "multipart/mixed; boundary=music-boundary"], body: body(json: json)), musicTimestamps: true)
        }
    }

    @Test func returnsLyricTimestampsFromMusicGeneration() async throws {
        let response = AIHTTPResponse(statusCode: 200, headers: ["content-type": "multipart/mixed; boundary=music-boundary"], body: body())
        let (model, transport) = try speechModel("music_v2_5", response)
        let result = try await model.speak(.init(text: "A short song.", providerOptions: ["elevenlabs": ["withTimestamps": true, "musicLengthMs": 3000]]))
        #expect(await sentURL(transport) == "https://api.elevenlabs.io/v1/music/detailed?output_format=mp3_44100_128")
        #expect(try await sentBody(transport) == ["prompt": "A short song.", "model_id": "music_v2_5", "music_length_ms": 3000, "with_timestamps": true])
        #expect(result.audio == Data([255, 0, 128]))
        #expect(result.providerMetadata == ["elevenlabs": ["outputFormat": "mp3_44100_128", "requestedDurationMs": 3000, "wordTimestamps": [["word": "Hello 🌍", "startMs": 120, "endMs": 945]]]])
        #expect(result.responseMetadata.body == ["words_timestamps": [["word": "Hello 🌍", "start_ms": 120, "end_ms": 945]]])
        #expect(result.warnings.isEmpty)
    }
}
