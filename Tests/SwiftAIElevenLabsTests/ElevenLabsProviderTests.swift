@testable import SwiftAIElevenLabs
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

@Test func elevenLabsSpeechUsesTextToSpeechVoiceEndpoint() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(statusCode: 200, headers: ["content-type": "audio/mpeg"], body: Data("eleven-audio".utf8)))
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: transport))
    let model = try provider.speechModel("eleven_multilingual_v2")

    let result = try await model.speak(SpeechRequest(
        text: "Hello",
        voice: "voice-123",
        format: "mp3_192",
        extraBody: [
            "languageCode": "en",
            "voiceSettings": ["similarityBoost": 0.7, "useSpeakerBoost": true],
            "enableLogging": false
        ]
    ))

    #expect(result.audio == Data("eleven-audio".utf8))
    #expect(result.contentType == "audio/mpeg")
    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/voice-123?enable_logging=false&output_format=mp3_44100_192")
    #expect(request.headers["xi-api-key"] == "eleven-key")
    #expect(request.headers["user-agent"] == "ai-sdk-elevenlabs/3.0.71")
    let body = try decodeJSONBody(try #require(request.body))
    #expect(body["text"]?.stringValue == "Hello")
    #expect(body["model_id"]?.stringValue == "eleven_multilingual_v2")
    #expect(body["language_code"]?.stringValue == "en")
    #expect(body["voice_settings"]?["similarity_boost"]?.doubleValue == 0.7)
    #expect(body["voice_settings"]?["use_speaker_boost"]?.boolValue == true)
}

@Test func elevenLabsSpeechMapsOutputFormatAliasesCaseSensitivelyLikeUpstream() async throws {
    let transport = RecordingTransport(responses: [
        AIHTTPResponse(statusCode: 200, headers: ["content-type": "audio/mpeg"], body: Data("one".utf8)),
        AIHTTPResponse(statusCode: 200, headers: ["content-type": "audio/wav"], body: Data("two".utf8)),
        AIHTTPResponse(statusCode: 200, headers: ["content-type": "audio/mpeg"], body: Data("three".utf8))
    ])
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: transport))
    let model = try provider.speechModel("eleven_multilingual_v2")

    _ = try await model.speak(SpeechRequest(text: "Hello", voice: "voice-123", format: "mp3_192"))
    _ = try await model.speak(SpeechRequest(text: "Hello", voice: "voice-123", format: "pcm_16000"))
    _ = try await model.speak(SpeechRequest(text: "Hello", voice: "voice-123", format: "MP3"))

    let requests = await transport.requests()
    #expect(requests[0].url.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/voice-123?output_format=mp3_44100_192")
    #expect(requests[1].url.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/voice-123?output_format=pcm_16000")
    #expect(requests[2].url.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/voice-123?output_format=MP3")
}

@Test func elevenLabsSpeechMapsStandardLanguageSpeedAndInstructionsWarning() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(statusCode: 200, headers: ["content-type": "audio/mpeg"], body: Data("eleven-audio".utf8)))
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: transport))
    let model = try provider.speechModel("eleven_multilingual_v2")

    let result = try await model.speak(SpeechRequest(
        text: "Hola",
        voice: "voice-123",
        speed: 1.5,
        language: "es",
        instructions: "Speak slowly"
    ))

    #expect(result.warnings == [
        AIWarning(
            type: "unsupported",
            feature: "instructions",
            message: "ElevenLabs speech models do not support instructions. Instructions parameter was ignored."
        )
    ])
    let request = try #require(await transport.requests().first)
    let body = try decodeJSONBody(try #require(request.body))
    #expect(body["language_code"]?.stringValue == "es")
    #expect(body["voice_settings"]?["speed"]?.doubleValue == 1.5)
    #expect(body["instructions"] == nil)
}

@Test func elevenLabsSpeechMapsNestedExtraBodyOptionsAndMergesVoiceSettings() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(statusCode: 200, headers: ["content-type": "audio/mpeg"], body: Data("eleven-audio".utf8)))
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: transport))
    let model = try provider.speechModel("eleven_multilingual_v2")

    _ = try await model.speak(SpeechRequest(
        text: "Hello",
        voice: "voice-123",
        format: "mp3_128",
        extraBody: [
            "elevenlabs": .object([
                "languageCode": "ja",
                "speed": 0.85,
                "voiceSettings": [
                    "stability": 0.4,
                    "similarityBoost": 0.7,
                    "style": 0.2,
                    "useSpeakerBoost": true
                ],
                "pronunciationDictionaryLocators": [
                    ["pronunciationDictionaryId": "dict-1", "versionId": "v2"]
                ],
                "seed": 42,
                "previousText": "Before",
                "nextText": "After",
                "previousRequestIds": ["prev-1"],
                "nextRequestIds": ["next-1"],
                "applyTextNormalization": "auto",
                "applyLanguageTextNormalization": true,
                "enableLogging": false
            ])
        ]
    ))

    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/voice-123?enable_logging=false&output_format=mp3_44100_128")
    let body = try decodeJSONBody(try #require(request.body))
    #expect(body["language_code"]?.stringValue == "ja")
    #expect(body["voice_settings"]?["speed"]?.doubleValue == 0.85)
    #expect(body["voice_settings"]?["stability"]?.doubleValue == 0.4)
    #expect(body["voice_settings"]?["similarity_boost"]?.doubleValue == 0.7)
    #expect(body["voice_settings"]?["style"]?.doubleValue == 0.2)
    #expect(body["voice_settings"]?["use_speaker_boost"]?.boolValue == true)
    #expect(body["pronunciation_dictionary_locators"]?[0]?["pronunciation_dictionary_id"]?.stringValue == "dict-1")
    #expect(body["pronunciation_dictionary_locators"]?[0]?["version_id"]?.stringValue == "v2")
    #expect(body["seed"]?.intValue == 42)
    #expect(body["previous_text"]?.stringValue == "Before")
    #expect(body["next_text"]?.stringValue == "After")
    #expect(body["previous_request_ids"]?[0]?.stringValue == "prev-1")
    #expect(body["next_request_ids"]?[0]?.stringValue == "next-1")
    #expect(body["apply_text_normalization"]?.stringValue == "auto")
    #expect(body["apply_language_text_normalization"]?.boolValue == true)
    #expect(body["elevenlabs"] == nil)
}

@Test func elevenLabsSpeechMapsProviderOptionsNamespaceAndOverridesExtraBody() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(statusCode: 200, headers: ["content-type": "audio/mpeg"], body: Data("eleven-audio".utf8)))
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: transport))
    let model = try provider.speechModel("eleven_multilingual_v2")

    _ = try await model.speak(SpeechRequest(
        text: "Hello",
        voice: "voice-123",
        format: "mp3",
        providerOptions: [
            "elevenlabs": .object([
                "languageCode": "ja",
                "voiceSettings": [
                    "stability": 0.3,
                    "similarityBoost": 0.8,
                    "style": 0.1,
                    "useSpeakerBoost": true,
                    "ignoredSetting": "drop-me"
                ],
                "pronunciationDictionaryLocators": [
                    ["pronunciationDictionaryId": "dict-provider", "versionId": "v3", "ignored": "drop-me"]
                ],
                "seed": 123,
                "previousText": "Provider before",
                "nextText": "Provider after",
                "previousRequestIds": ["prev-provider"],
                "nextRequestIds": ["next-provider"],
                "applyTextNormalization": "on",
                "applyLanguageTextNormalization": false,
                "enableLogging": true,
                "speed": 2.5,
                "unsupportedProperty": "drop-me"
            ]),
            "openai": .object(["parallelToolCalls": true])
        ],
        extraBody: [
            "elevenlabs": .object([
                "languageCode": "en",
                "voiceSettings": ["stability": 0.9],
                "seed": 1,
                "enableLogging": false
            ])
        ]
    ))

    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/voice-123?enable_logging=true&output_format=mp3_44100_128")
    let body = try decodeJSONBody(try #require(request.body))
    #expect(body["language_code"]?.stringValue == "ja")
    #expect(body["voice_settings"]?["stability"]?.doubleValue == 0.3)
    #expect(body["voice_settings"]?["similarity_boost"]?.doubleValue == 0.8)
    #expect(body["voice_settings"]?["style"]?.doubleValue == 0.1)
    #expect(body["voice_settings"]?["use_speaker_boost"]?.boolValue == true)
    #expect(body["pronunciation_dictionary_locators"]?[0]?["pronunciation_dictionary_id"]?.stringValue == "dict-provider")
    #expect(body["pronunciation_dictionary_locators"]?[0]?["version_id"]?.stringValue == "v3")
    #expect(body["seed"]?.intValue == 123)
    #expect(body["previous_text"]?.stringValue == "Provider before")
    #expect(body["next_text"]?.stringValue == "Provider after")
    #expect(body["previous_request_ids"]?[0]?.stringValue == "prev-provider")
    #expect(body["next_request_ids"]?[0]?.stringValue == "next-provider")
    #expect(body["apply_text_normalization"]?.stringValue == "on")
    #expect(body["apply_language_text_normalization"]?.boolValue == false)
    #expect(body["elevenlabs"] == nil)
    #expect(body["openai"] == nil)
    #expect(body["voice_settings"]?["speed"] == nil)
    #expect(body["voice_settings"]?["ignoredSetting"] == nil)
    #expect(body["unsupportedProperty"] == nil)
    #expect(body["pronunciation_dictionary_locators"]?[0]?["ignored"] == nil)
}

@Test func elevenLabsSpeechTreatsNullProviderOptionsNamespaceAsNoop() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(statusCode: 200, headers: ["content-type": "audio/mpeg"], body: Data("eleven-audio".utf8)))
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: transport))
    let model = try provider.speechModel("eleven_multilingual_v2")

    _ = try await model.speak(SpeechRequest(
        text: "Hello",
        voice: "voice-123",
        providerOptions: ["elevenlabs": .null],
        extraBody: ["elevenlabs": .object(["languageCode": "ja", "enableLogging": false])]
    ))

    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/voice-123?enable_logging=false&output_format=mp3_44100_128")
    let body = try decodeJSONBody(try #require(request.body))
    #expect(body["language_code"]?.stringValue == "ja")
}

@Test func elevenLabsSpeechProviderOptionsRejectInvalidSchemaFields() async throws {
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: RecordingTransport(response: AIHTTPResponse(statusCode: 200, body: Data()))))
    let model = try provider.speechModel("eleven_multilingual_v2")

    await #expect(throws: AIError.invalidArgument(argument: "providerOptions.elevenlabs", message: "ElevenLabs provider options must be an object.")) {
        _ = try await model.speak(SpeechRequest(
            text: "Hello",
            providerOptions: ["elevenlabs": .string("invalid")]
        ))
    }

    await #expect(throws: AIError.self) {
        _ = try await model.speak(SpeechRequest(
            text: "Hello",
            providerOptions: ["elevenlabs": .object(["languageCode": .null])]
        ))
    }

    await #expect(throws: AIError.self) {
        _ = try await model.speak(SpeechRequest(
            text: "Hello",
            providerOptions: ["elevenlabs": .object(["voiceSettings": .object(["stability": .number(1.5)])])]
        ))
    }

    await #expect(throws: AIError.self) {
        _ = try await model.speak(SpeechRequest(
            text: "Hello",
            providerOptions: ["elevenlabs": .object(["pronunciationDictionaryLocators": .array([
                .object(["pronunciationDictionaryId": .string("one")]),
                .object(["pronunciationDictionaryId": .string("two")]),
                .object(["pronunciationDictionaryId": .string("three")]),
                .object(["pronunciationDictionaryId": .string("four")])
            ])])]
        ))
    }

    await #expect(throws: AIError.self) {
        _ = try await model.speak(SpeechRequest(
            text: "Hello",
            providerOptions: ["elevenlabs": .object(["seed": .number(-1)])]
        ))
    }

    await #expect(throws: AIError.self) {
        _ = try await model.speak(SpeechRequest(
            text: "Hello",
            providerOptions: ["elevenlabs": .object(["previousRequestIds": .array([.string("a"), .string("b"), .string("c"), .string("d")])])]
        ))
    }

    await #expect(throws: AIError.self) {
        _ = try await model.speak(SpeechRequest(
            text: "Hello",
            providerOptions: ["elevenlabs": .object(["applyTextNormalization": .string("sometimes")])]
        ))
    }

    await #expect(throws: AIError.self) {
        _ = try await model.speak(SpeechRequest(
            text: "Hello",
            providerOptions: ["elevenlabs": .object(["enableLogging": .string("false")])]
        ))
    }
}

@Test func elevenLabsTranscriptionPassesProviderAndRequestHeadersLikeUpstream() async throws {
    let transport = RecordingTransport(response: jsonResponse(#"{"language_code":"en","language_probability":0.99,"text":"headers","words":[]}"#))
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(
        apiKey: "eleven-key",
        headers: ["Custom-Provider-Header": "provider-header-value"],
        transport: transport
    ))

    _ = try await provider.transcriptionModel("scribe_v2").transcribe(AudioTranscriptionRequest(
        audio: Data("wav".utf8),
        mimeType: "audio/wav",
        headers: ["Custom-Request-Header": "request-header-value"]
    ))

    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text")
    #expect(request.headers["xi-api-key"] == "eleven-key")
    #expect(request.headers["content-type"]?.hasPrefix("multipart/form-data; boundary=SwiftAISDK-") == true)
    #expect(request.headers["custom-provider-header"] == "provider-header-value")
    #expect(request.headers["Custom-Request-Header"] == "request-header-value")
    #expect(request.headers["user-agent"] == "ai-sdk-elevenlabs/3.0.71")
}

@Test func elevenLabsTranscriptionRejectsInvalidResponseShapeLikeUpstreamSchema() async throws {
    let missingLanguageTransport = RecordingTransport(response: jsonResponse(#"{"text":"missing language","language_probability":0.99}"#))
    let missingLanguageProvider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: missingLanguageTransport))
    let missingLanguageModel = try missingLanguageProvider.transcriptionModel("scribe_v1")

    await #expect(throws: AIError.invalidResponse(provider: "elevenlabs.transcription", message: "ElevenLabs transcription response did not contain a valid language_code.")) {
        _ = try await missingLanguageModel.transcribe(AudioTranscriptionRequest(audio: Data("mp3".utf8)))
    }

    let invalidWordsTransport = RecordingTransport(response: jsonResponse(#"{"language_code":"en","language_probability":0.99,"text":"bad words","words":[{"text":"hello","type":"not_a_word"}]}"#))
    let invalidWordsProvider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: invalidWordsTransport))
    let invalidWordsModel = try invalidWordsProvider.transcriptionModel("scribe_v1")

    await #expect(throws: AIError.invalidResponse(provider: "elevenlabs.transcription", message: "ElevenLabs transcription response words[0].type is invalid.")) {
        _ = try await invalidWordsModel.transcribe(AudioTranscriptionRequest(audio: Data("mp3".utf8)))
    }
}

@Test func elevenLabsModelsUseUpstreamErrorMessageSchema() async throws {
    let speechProvider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(
        apiKey: "eleven-key",
        transport: RecordingTransport(response: AIHTTPResponse(
            statusCode: 401,
            headers: ["content-type": "application/json", "x-eleven": "speech"],
            body: Data(#"{"error":{"message":"speech unauthorized","code":401}}"#.utf8)
        ))
    ))
    let speechModel = try speechProvider.speechModel("eleven_multilingual_v2")

    await #expect(throws: AIError.apiCall(
        provider: "elevenlabs.speech",
        statusCode: 401,
        body: "speech unauthorized",
        headers: ["content-type": "application/json", "x-eleven": "speech"]
    )) {
        _ = try await speechModel.speak(SpeechRequest(text: "Hello"))
    }

    let transcriptionProvider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(
        apiKey: "eleven-key",
        transport: RecordingTransport(response: AIHTTPResponse(
            statusCode: 422,
            headers: ["content-type": "application/json", "x-eleven": "stt"],
            body: Data(#"{"error":{"message":"bad audio","code":422}}"#.utf8)
        ))
    ))
    let transcriptionModel = try transcriptionProvider.transcriptionModel("scribe_v1")

    await #expect(throws: AIError.apiCall(
        provider: "elevenlabs.transcription",
        statusCode: 422,
        body: "bad audio",
        headers: ["content-type": "application/json", "x-eleven": "stt"]
    )) {
        _ = try await transcriptionModel.transcribe(AudioTranscriptionRequest(audio: Data("mp3".utf8)))
    }
}

@Test func elevenLabsMusicUsesMusicEndpoint() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(statusCode: 200, headers: ["content-type": "audio/mpeg", "song-id": "song-1"], body: Data("music".utf8)))
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: transport))
    let model = try provider.musicModel()

    let result = try await AI.generateAudio(
        model: model,
        request: AudioGenerationRequest(
            prompt: "Tiny upbeat instrumental loop",
            durationSeconds: 3,
            format: "mp3_64",
            providerOptions: ["elevenlabs": .object(["forceInstrumental": true])]
        )
    )

    #expect(result.audio == Data("music".utf8))
    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString == "https://api.elevenlabs.io/v1/music?output_format=mp3_44100_64")
    #expect(request.headers["xi-api-key"] == "eleven-key")
    let body = try decodeJSONBody(try #require(request.body))
    #expect(body["prompt"]?.stringValue == "Tiny upbeat instrumental loop")
    #expect(body["music_length_ms"]?.intValue == 3000)
    #expect(body["model_id"]?.stringValue == "music_v1")
    #expect(body["force_instrumental"]?.boolValue == true)
}

@Test func elevenLabsSoundEffectsUsesSoundGenerationEndpoint() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(statusCode: 200, headers: ["content-type": "audio/mpeg"], body: Data("sfx".utf8)))
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: transport))
    let model = try provider.soundEffectsModel()

    _ = try await model.generateAudio("Soft UI click", durationSeconds: 0.5, format: "mp3_32", providerOptions: [
        "elevenlabs": .object(["promptInfluence": 0.4, "loop": false])
    ])

    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString == "https://api.elevenlabs.io/v1/sound-generation?output_format=mp3_44100_32")
    let body = try decodeJSONBody(try #require(request.body))
    #expect(body["text"]?.stringValue == "Soft UI click")
    #expect(body["duration_seconds"]?.doubleValue == 0.5)
    #expect(body["prompt_influence"]?.doubleValue == 0.4)
    #expect(body["loop"]?.boolValue == false)
    #expect(body["model_id"]?.stringValue == "eleven_text_to_sound_v2")
}

@Test func elevenLabsVoiceChangerUsesSpeechToSpeechEndpoint() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(statusCode: 200, headers: ["content-type": "audio/mpeg"], body: Data("changed".utf8)))
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: transport))
    let model = try provider.voiceChangerModel()

    _ = try await model.transformAudio(
        audio: Data("input".utf8),
        fileName: "input.mp3",
        mimeType: "audio/mpeg",
        voice: "voice-123",
        format: "mp3_64",
        providerOptions: [
            "elevenlabs": .object([
                "removeBackgroundNoise": true,
                "fileFormat": "other",
                "voiceSettings": ["stability": 0.4],
                "enableLogging": false
            ])
        ]
    )

    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString == "https://api.elevenlabs.io/v1/speech-to-speech/voice-123?enable_logging=false&output_format=mp3_44100_64")
    let body = String(data: try #require(request.body), encoding: .utf8) ?? ""
    #expect(body.contains("name=\"audio\"; filename=\"input.mp3\""))
    #expect(body.contains("name=\"model_id\""))
    #expect(body.contains("eleven_multilingual_sts_v2"))
    #expect(body.contains("name=\"remove_background_noise\""))
    #expect(body.contains("true"))
    #expect(body.contains("name=\"file_format\""))
    #expect(body.contains("other"))
    #expect(body.contains("name=\"voice_settings\""))
    #expect(body.contains(#""stability":0.4"#))
}

@Test func elevenLabsVoiceIsolatorUsesAudioIsolationEndpoint() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(statusCode: 200, headers: ["content-type": "audio/mpeg"], body: Data("clean".utf8)))
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: transport))
    let model = try provider.voiceIsolatorModel()

    _ = try await AI.transformAudio(
        model: model,
        request: AudioTransformationRequest(
            audio: Data("noisy".utf8),
            fileName: "noisy.wav",
            mimeType: "audio/wav",
            providerOptions: ["elevenlabs": .object(["fileFormat": "other"])]
        )
    )

    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString == "https://api.elevenlabs.io/v1/audio-isolation")
    let body = String(data: try #require(request.body), encoding: .utf8) ?? ""
    #expect(body.contains("name=\"audio\"; filename=\"noisy.wav\""))
    #expect(body.contains("name=\"file_format\""))
    #expect(body.contains("other"))
}

@Test func elevenLabsDubbingClientCreatesGetsAndDownloadsDub() async throws {
    let transport = RecordingTransport(responses: [
        jsonResponse(#"{"dubbing_id":"dub-123","expected_duration_sec":2.5}"#),
        jsonResponse(#"{"dubbing_id":"dub-123","name":"Smoke","status":"dubbed","source_language":"en","target_languages":["es"],"error":null}"#),
        AIHTTPResponse(statusCode: 200, headers: ["content-type": "audio/mpeg"], body: Data("dub-audio".utf8))
    ])
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: transport))
    let client = try provider.dubbing()

    let created = try await client.create(DubbingCreateRequest(file: Data("audio".utf8), fileName: "clip.mp3", name: "Smoke", sourceLanguage: "en", targetLanguage: "es", extraBody: ["disableVoiceCloning": true]))
    let status = try await client.get(created.dubbingID)
    let audio = try await client.audio(dubbingID: created.dubbingID, languageCode: "es")

    #expect(created.dubbingID == "dub-123")
    #expect(created.expectedDurationSeconds == 2.5)
    #expect(status.status == "dubbed")
    #expect(status.targetLanguages == ["es"])
    #expect(audio.audio == Data("dub-audio".utf8))

    let requests = await transport.requests()
    #expect(requests[0].url.absoluteString == "https://api.elevenlabs.io/v1/dubbing")
    #expect(requests[0].method == "POST")
    #expect(requests[1].url.absoluteString == "https://api.elevenlabs.io/v1/dubbing/dub-123")
    #expect(requests[1].method == "GET")
    #expect(requests[2].url.absoluteString == "https://api.elevenlabs.io/v1/dubbing/dub-123/audio/es")
    #expect(requests[2].method == "GET")
    let body = String(data: try #require(requests[0].body), encoding: .utf8) ?? ""
    #expect(body.contains("name=\"file\"; filename=\"clip.mp3\""))
    #expect(body.contains("name=\"target_lang\""))
    #expect(body.contains("es"))
    #expect(body.contains("name=\"disable_voice_cloning\""))
}

@Test func elevenLabsTranscriptionUsesSpeechToTextMultipartEndpoint() async throws {
    let transport = RecordingTransport(response: jsonResponse(#"{"transcription_id":"stt-123","language_code":"en","language_probability":0.99,"text":"eleven transcript","words":[{"text":"eleven","type":"word","start":0,"end":0.4}]}"#))
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: transport))
    let model = try provider.transcriptionModel("scribe_v1")

    let result = try await model.transcribe(AudioTranscriptionRequest(
        audio: Data("mp3".utf8),
        fileName: "clip.mp3",
        mimeType: "audio/mpeg",
        language: "en",
        extraBody: ["tagAudioEvents": false, "timestampsGranularity": "word", "fileFormat": "other", "diarize": false]
    ))

    #expect(result.text == "eleven transcript")
    #expect(result.responseMetadata.id == "stt-123")
    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text")
    #expect(request.headers["xi-api-key"] == "eleven-key")
    #expect(request.headers["content-type"]?.hasPrefix("multipart/form-data; boundary=SwiftAISDK-") == true)
    let body = String(data: try #require(request.body), encoding: .utf8) ?? ""
    #expect(body.contains("name=\"model_id\""))
    #expect(body.contains("scribe_v1"))
    #expect(body.contains("name=\"file\"; filename=\"audio.mp3\""))
    #expect(body.contains("name=\"diarize\""))
    #expect(body.contains("false"))
    #expect(!body.contains("name=\"language_code\""))
    #expect(body.contains("name=\"tag_audio_events\""))
    #expect(body.contains("name=\"timestamps_granularity\""))
    #expect(body.contains("word"))
}

@Test func elevenLabsTranscriptionMapsNestedExtraBodyOptions() async throws {
    let transport = RecordingTransport(response: jsonResponse(#"{"language_code":"ja","language_probability":0.99,"text":"nested transcript"}"#))
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: transport))
    let model = try provider.transcriptionModel("scribe_v1")

    _ = try await model.transcribe(AudioTranscriptionRequest(
        audio: Data("mp3".utf8),
        fileName: "clip.mp3",
        mimeType: "audio/mpeg",
        extraBody: [
            "elevenlabs": .object([
                "languageCode": "ja",
                "tagAudioEvents": true,
                "numSpeakers": 2,
                "timestampsGranularity": "character",
                "fileFormat": "mp3",
                "diarize": false
            ])
        ]
    ))

    let request = try #require(await transport.requests().first)
    let body = String(data: try #require(request.body), encoding: .utf8) ?? ""
    #expect(body.contains("name=\"language_code\""))
    #expect(body.contains("ja"))
    #expect(body.contains("name=\"tag_audio_events\""))
    #expect(body.contains("true"))
    #expect(body.contains("name=\"num_speakers\""))
    #expect(body.contains("2"))
    #expect(body.contains("name=\"timestamps_granularity\""))
    #expect(body.contains("character"))
    #expect(body.contains("name=\"file_format\""))
    #expect(body.contains("mp3"))
    #expect(body.contains("name=\"diarize\""))
    #expect(body.contains("false"))
    #expect(!body.contains("elevenlabs"))
}

@Test func elevenLabsTranscriptionTreatsNullProviderOptionsNamespaceAsNoop() async throws {
    let transport = RecordingTransport(response: jsonResponse(#"{"language_code":"ja","language_probability":0.99,"text":"null namespace"}"#))
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: transport))
    let model = try provider.transcriptionModel("scribe_v1")

    _ = try await model.transcribe(AudioTranscriptionRequest(
        audio: Data("mp3".utf8),
        fileName: "clip.mp3",
        mimeType: "audio/mpeg",
        providerOptions: ["elevenlabs": .null],
        extraBody: ["elevenlabs": .object(["languageCode": "ja", "diarize": false])]
    ))

    let request = try #require(await transport.requests().first)
    let body = String(data: try #require(request.body), encoding: .utf8) ?? ""
    #expect(body.contains("name=\"language_code\""))
    #expect(body.contains("ja"))
    #expect(body.contains("name=\"diarize\""))
    #expect(body.contains("false"))
    #expect(!body.contains("tag_audio_events"))
    #expect(!body.contains("timestamps_granularity"))
    #expect(!body.contains("file_format"))
}

@Test func elevenLabsTranscriptionMapsProviderOptionsNamespaceAndOverridesExtraBody() async throws {
    let transport = RecordingTransport(response: jsonResponse(#"{"language_code":"ja","language_probability":0.99,"text":"provider transcript"}"#))
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: transport))
    let model = try provider.transcriptionModel("scribe_v1")

    _ = try await model.transcribe(AudioTranscriptionRequest(
        audio: Data("mp3".utf8),
        fileName: "clip.mp3",
        mimeType: "audio/mpeg",
        providerOptions: [
            "elevenlabs": .object([
                "languageCode": "ja",
                "tagAudioEvents": false,
                "numSpeakers": 2,
                "timestampsGranularity": "character",
                "fileFormat": "pcm_s16le_16",
                "diarize": true,
                "unsupportedProperty": "drop-me"
            ]),
            "openai": .object(["timestampGranularities": ["word"]])
        ],
        extraBody: [
            "elevenlabs": .object([
                "languageCode": "en",
                "tagAudioEvents": true,
                "numSpeakers": 4,
                "timestampsGranularity": "word",
                "fileFormat": "mp3",
                "diarize": false
            ])
        ]
    ))

    let request = try #require(await transport.requests().first)
    let body = String(data: try #require(request.body), encoding: .utf8) ?? ""
    #expect(body.contains("name=\"language_code\""))
    #expect(body.contains("ja"))
    #expect(body.contains("name=\"tag_audio_events\""))
    #expect(body.contains("false"))
    #expect(body.contains("name=\"num_speakers\""))
    #expect(body.contains("2"))
    #expect(body.contains("name=\"timestamps_granularity\""))
    #expect(body.contains("character"))
    #expect(body.contains("name=\"file_format\""))
    #expect(body.contains("pcm_s16le_16"))
    #expect(body.contains("name=\"diarize\""))
    #expect(body.contains("true"))
    #expect(!body.contains("elevenlabs"))
    #expect(!body.contains("unsupportedProperty"))
    #expect(!body.contains("drop-me"))
    #expect(!body.contains("openai"))
}

@Test func elevenLabsTranscriptionAppliesUpstreamProviderOptionDefaults() async throws {
    let transport = RecordingTransport(response: jsonResponse(#"{"language_code":"en","language_probability":0.99,"text":"provider defaults"}"#))
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: transport))
    let model = try provider.transcriptionModel("scribe_v1")

    _ = try await model.transcribe(AudioTranscriptionRequest(
        audio: Data("wav".utf8),
        fileName: "ignored.wav",
        mimeType: "audio/wav",
        language: "fr",
        providerOptions: [
            "elevenlabs": .object([
                "languageCode": .string("en")
            ])
        ],
        extraBody: [
            "elevenlabs": .object([
                "diarize": .bool(true),
                "tagAudioEvents": .bool(false),
                "timestampsGranularity": .string("none"),
                "fileFormat": .string("pcm_s16le_16")
            ])
        ]
    ))

    let request = try #require(await transport.requests().first)
    let body = String(data: try #require(request.body), encoding: .utf8) ?? ""
    #expect(body.contains("name=\"file\"; filename=\"audio.wav\""))
    #expect(body.contains("name=\"language_code\""))
    #expect(body.contains("en"))
    #expect(body.contains("name=\"tag_audio_events\""))
    #expect(body.contains("true"))
    #expect(body.contains("name=\"timestamps_granularity\""))
    #expect(body.contains("word"))
    #expect(body.contains("name=\"file_format\""))
    #expect(body.contains("other"))
    #expect(body.contains("name=\"diarize\""))
    #expect(body.contains("false"))
    #expect(!body.contains("fr"))
}

@Test func elevenLabsTranscriptionProviderOptionsRejectInvalidSchemaFields() async throws {
    let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings(apiKey: "eleven-key", transport: RecordingTransport(response: jsonResponse(#"{}"#))))
    let model = try provider.transcriptionModel("scribe_v1")

    await #expect(throws: AIError.invalidArgument(argument: "providerOptions.elevenlabs", message: "ElevenLabs provider options must be an object.")) {
        _ = try await model.transcribe(AudioTranscriptionRequest(
            audio: Data("mp3".utf8),
            providerOptions: ["elevenlabs": .number(1)]
        ))
    }

    await #expect(throws: AIError.self) {
        _ = try await model.transcribe(AudioTranscriptionRequest(
            audio: Data("mp3".utf8),
            providerOptions: ["elevenlabs": .object(["languageCode": .number(123)])]
        ))
    }

    await #expect(throws: AIError.self) {
        _ = try await model.transcribe(AudioTranscriptionRequest(
            audio: Data("mp3".utf8),
            providerOptions: ["elevenlabs": .object(["tagAudioEvents": .string("true")])]
        ))
    }

    await #expect(throws: AIError.self) {
        _ = try await model.transcribe(AudioTranscriptionRequest(
            audio: Data("mp3".utf8),
            providerOptions: ["elevenlabs": .object(["numSpeakers": .number(0)])]
        ))
    }

    await #expect(throws: AIError.self) {
        _ = try await model.transcribe(AudioTranscriptionRequest(
            audio: Data("mp3".utf8),
            providerOptions: ["elevenlabs": .object(["numSpeakers": .number(2.5)])]
        ))
    }

    await #expect(throws: AIError.self) {
        _ = try await model.transcribe(AudioTranscriptionRequest(
            audio: Data("mp3".utf8),
            providerOptions: ["elevenlabs": .object(["timestampsGranularity": .string("segment")])]
        ))
    }

    await #expect(throws: AIError.self) {
        _ = try await model.transcribe(AudioTranscriptionRequest(
            audio: Data("mp3".utf8),
            providerOptions: ["elevenlabs": .object(["fileFormat": .string("mp3")])]
        ))
    }
}
