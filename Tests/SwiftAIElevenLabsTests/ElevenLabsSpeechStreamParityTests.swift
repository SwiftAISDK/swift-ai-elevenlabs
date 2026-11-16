@testable import SwiftAIElevenLabs
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

// Translated from packages/elevenlabs/src/elevenlabs-speech-stream.test.ts.
// Fake-timer keepalive cases are not translated: the shared Swift session
// uses a wall-clock 15 s idle check that tests cannot advance.

private func streamModel(_ socket: WeeklySpeechSocketTransport) throws -> any StreamingSpeechModel {
    try streamModel("eleven_flash_v2_5", socket)
}

private func streamModel(_ id: String, _ socket: WeeklySpeechSocketTransport) throws -> any StreamingSpeechModel {
    try AIProviders.elevenLabs(configuration: .init(apiKey: "test-api-key")).streamingSpeechModel(id, webSocketTransport: socket)
}

private func collect(_ result: StreamingSpeechModelResult) async throws -> [StreamingSpeechPart] {
    var parts: [StreamingSpeechPart] = []
    for try await part in result.stream { parts.append(part) }
    return parts
}

private func startWarnings(_ result: StreamingSpeechModelResult) async throws -> [AIWarning] {
    var iterator = result.stream.makeAsyncIterator()
    guard case let .streamStart(warnings)? = try await iterator.next() else { Issue.record("Expected stream-start"); return [] }
    return warnings
}

private func failure(_ result: StreamingSpeechModelResult) async -> String? {
    do { _ = try await collect(result); return nil } catch let error as AIStreamingSpeechError { return error.message } catch let AIError.invalidArgument(_, message) { return message } catch { return String(describing: error) }
}

@Suite("ElevenLabs streaming speech parity")
struct ElevenLabsSpeechStreamParityTests {
    @Test func streamsTextDeltasAndAudioOverTheStreamInputWebSocket() async throws {
        let socket = WeeklySpeechSocketTransport()
        let result = try await streamModel(socket).stream(.init(
            text: .chunks(["Hello ", "", "wörld 👋 "]), voice: "voice-1", outputFormat: .init(mediaType: "audio/pcm", sampleRate: 24000), speed: 1.1, language: "en",
            providerOptions: ["elevenlabs": [
                "voiceSettings": ["stability": 0.4, "similarityBoost": 0.8], "seed": 7, "applyTextNormalization": "off",
                "streaming": ["autoMode": true, "chunkLengthSchedule": [50, 120], "inactivityTimeout": 60, "syncAlignment": true]
            ]]))
        let request = try #require(socket.requests.first)
        #expect(request.url.absoluteString == "wss://api.elevenlabs.io/v1/text-to-speech/voice-1/stream-input?model_id=eleven_flash_v2_5&output_format=pcm_24000&language_code=en&inactivity_timeout=60&sync_alignment=true&auto_mode=true&apply_text_normalization=off&seed=7")
        #expect(normalizeHeaders(request.headers)["xi-api-key"] == nil)
        #expect(!String(describing: result.requestMetadata.body).contains("test-api-key"))
        socket.socket.open()
        #expect(await weeklySpeechWait { socket.socket.sent.count == 4 })
        #expect(socket.socket.sent == [
            ["text": " ", "voice_settings": ["stability": 0.4, "similarity_boost": 0.8, "speed": 1.1], "generation_config": ["chunk_length_schedule": [50, 120]], "xi-api-key": "test-api-key"],
            ["text": "Hello "], ["text": "wörld 👋 "], ["text": ""]
        ])
        try socket.socket.receive(["audio": "AQI=", "alignment": ["chars": ["H"], "charStartTimesMs": [0], "charDurationsMs": [5]]])
        try socket.socket.receive(["audio": "AwQ="])
        try socket.socket.receive(["audio": .null, "isFinal": true])
        let parts = try await collect(result)
        #expect(parts.count == 4)
        if case let .streamStart(warnings) = parts[0] { #expect(warnings.isEmpty) } else { Issue.record("Expected stream-start") }
        if case let .audio(_, audio, format, metadata) = parts[1] {
            #expect(audio == Data([1, 2])); #expect(format == .init(mediaType: "audio/pcm", sampleRate: 24000))
            #expect(metadata == ["elevenlabs": ["alignment": ["chars": ["H"], "charStartTimesMs": [0], "charDurationsMs": [5]]]])
        } else { Issue.record("Expected audio") }
        if case let .audio(_, audio, _, metadata) = parts[2] { #expect(audio == Data([3, 4])); #expect(metadata.isEmpty) } else { Issue.record("Expected audio") }
        if case let .finish(usage, _) = parts[3] { #expect(usage == ["inputCharacters": 14]) } else { Issue.record("Expected finish") }
    }

    @Test func holdsPartialWordsAndDoesNotHoldUnspacedTextIndefinitely() async throws {
        let socket = WeeklySpeechSocketTransport()
        let result = try await streamModel(socket).stream(.init(text: .chunks(["Hel", "lo wor", "ld, how a", "re", " you"])))
        socket.socket.open()
        #expect(await weeklySpeechWait { socket.socket.sent.count == 6 })
        #expect(Array(socket.socket.sent.dropFirst()) == [["text": "Hello "], ["text": "world, how "], ["text": "are "], ["text": "you"], ["text": ""]])
        try socket.socket.receive(["audio": "AQI="]); try socket.socket.receive(["isFinal": true])
        if case let .finish(usage, _)? = try await collect(result).last { #expect(usage == ["inputCharacters": 24]) } else { Issue.record("Expected finish") }

        let cjk = WeeklySpeechSocketTransport()
        let kept1 = try await streamModel(cjk).stream(.init(text: .chunks(["こんにちは", "世界。次", String(repeating: "x", count: 100)])))
        cjk.socket.open()
        #expect(await weeklySpeechWait { cjk.socket.sent.count == 4 })
        #expect(Array(cjk.socket.sent.dropFirst()) == [["text": "こんにちは世界。"], ["text": .string("次" + String(repeating: "x", count: 100))], ["text": ""]])
        withExtendedLifetime(kept1) {}
    }

    @Test func errorsWhenATextPartRequestsADifferentVoice() async throws {
        let socket = WeeklySpeechSocketTransport()
        let result = try await streamModel(socket).stream(.init(text: .parts([.init(text: "Hello ", voice: "voice-1"), .init(text: "there ", voice: "voice-2")]), voice: "voice-1"))
        socket.socket.open()
        #expect(await failure(result) == "The ElevenLabs text-to-speech WebSocket speaks a single voice per stream (\"voice-1\"); a text part requested \"voice-2\". Use an eleven_v3 or eleven_v4 model with dialogue options for several voices.")
    }

    @Test func defaultsTheVoiceAndOutputFormat() async throws {
        let socket = WeeklySpeechSocketTransport()
        let kept2 = try await streamModel(socket).stream(.init(text: .chunks(["Hi"])))
        #expect(socket.requests.first?.url.absoluteString == "wss://api.elevenlabs.io/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM/stream-input?model_id=eleven_flash_v2_5&output_format=mp3_44100_128")
        withExtendedLifetime(kept2) {}
    }

    @Test func includesRawChunksWhenRequested() async throws {
        let socket = WeeklySpeechSocketTransport()
        let result = try await streamModel(socket).stream(.init(text: .chunks(["Hi"]), includeRawChunks: true))
        socket.socket.open()
        try socket.socket.receive(["audio": "AQI="]); try socket.socket.receive(["isFinal": true])
        let raw = try await collect(result).compactMap { part -> JSONValue? in if case let .raw(value) = part { return value }; return nil }
        #expect(raw == [["audio": "AQI="], ["isFinal": true]])
    }

    @Test func warnsAboutUnsupportedOptions() async throws {
        let socket = WeeklySpeechSocketTransport()
        let result = try await streamModel(socket).stream(.init(text: .chunks(["Hi"]), instructions: "whisper", providerOptions: ["elevenlabs": ["previousText": "Before."]]))
        socket.socket.open()
        #expect(try await startWarnings(result) == [
            AIWarning(type: "unsupported", feature: "instructions", message: "ElevenLabs speech models do not support instructions. Instructions parameter was ignored."),
            AIWarning(type: "unsupported", feature: "providerOptions.elevenlabs.previousText", message: "ElevenLabs streaming speech does not support previousText.")
        ])
    }

    @Test(arguments: [("eleven_flash_v2_5", false), ("eleven_v4", true)])
    func warnsAboutHTTPOnlyGenerationOptions(_ modelID: String, _ dialogue: Bool) async throws {
        let socket = WeeklySpeechSocketTransport()
        var options: [String: JSONValue] = ["withTimestamps": true, "inputs": [["text": "Knock knock", "voiceId": "voice-a"]], "musicLengthMs": 5000, "durationSeconds": 2, "loop": true]
        if dialogue { options["dialogue"] = ["voices": ["voice-a"]] }
        let result = try await streamModel(modelID, socket).stream(.init(text: .chunks(["Hi"]), providerOptions: ["elevenlabs": .object(options)]))
        socket.socket.open()
        #expect(try await startWarnings(result).map { $0.feature } == [
            "providerOptions.elevenlabs.withTimestamps", "providerOptions.elevenlabs.inputs", "providerOptions.elevenlabs.musicLengthMs",
            "providerOptions.elevenlabs.durationSeconds", "providerOptions.elevenlabs.loop"
        ])
        #expect(!String(describing: socket.socket.sent).contains("Knock"))
    }

    @Test func errorsOnAServerErrorMessageAndOnEarlyClose() async throws {
        let socket = WeeklySpeechSocketTransport()
        let result = try await streamModel(socket).stream(.init(text: .chunks(["Hi"])))
        socket.socket.open()
        try socket.socket.receive(["message": "Invalid API key", "error": "auth_error"])
        #expect(await failure(result) == "ElevenLabs speech stream error: Invalid API key")

        let closing = WeeklySpeechSocketTransport()
        let closed = try await streamModel(closing).stream(.init(text: .chunks(["Hi"])))
        closing.socket.open()
        closing.socket.continuation.yield(.closed(.init(code: 1008, reason: "Have not received new text")))
        #expect(await failure(closed) == "ElevenLabs speech stream closed before completion (code 1008: Have not received new text).")
    }

    @Test func sendsVersionedLocatorsAndRejectsUnversionedOnesBeforeConnecting() async throws {
        let socket = WeeklySpeechSocketTransport()
        let kept3 = try await streamModel(socket).stream(.init(text: .chunks(["Hi"]), providerOptions: ["elevenlabs": ["pronunciationDictionaryLocators": [["pronunciationDictionaryId": "dict", "versionId": "v1"]]]]))
        socket.socket.open()
        #expect(await weeklySpeechWait { !socket.socket.sent.isEmpty })
        #expect(socket.socket.sent[0]["pronunciation_dictionary_locators"] == [["pronunciation_dictionary_id": "dict", "version_id": "v1"]])

        let rejected = WeeklySpeechSocketTransport()
        await #expect(throws: AIError.invalidArgument(argument: "providerOptions.elevenlabs.pronunciationDictionaryLocators", message: "Streaming speech requires a versionId for pronunciation dictionary \"dict\".")) {
            _ = try await streamModel(rejected).stream(.init(text: .chunks(["Hi"]), providerOptions: ["elevenlabs": ["pronunciationDictionaryLocators": [["pronunciationDictionaryId": "dict"]]]]))
        }
        #expect(rejected.requests.isEmpty)
        withExtendedLifetime(kept3) {}
    }

    @Test(arguments: ["eleven_v3", "eleven_v3_conversational", "eleven_v4"])
    func rejectsDialogueModelsWithoutDialogueOptions(_ modelID: String) async throws {
        await #expect(throws: AIError.invalidArgument(argument: "providerOptions.elevenlabs.dialogue", message: "The ElevenLabs text-to-speech WebSocket does not serve \(modelID). Set providerOptions.elevenlabs.dialogue to stream it as dialogue.")) {
            _ = try await streamModel(modelID, WeeklySpeechSocketTransport()).stream(.init(text: .chunks(["Hi"])))
        }
    }

    @Test(arguments: ["music_v2_5", "eleven_text_to_sound_v2"])
    func rejectsStreamingForMusicAndSoundEffects(_ modelID: String) async throws {
        await #expect(throws: AIError.invalidArgument(argument: "model", message: "ElevenLabs \(modelID) does not support streaming; use generateSpeech instead.")) {
            _ = try await streamModel(modelID, WeeklySpeechSocketTransport()).stream(.init(text: .chunks(["Hi"])))
        }
    }

    @Test func mapsAudioFormatsAndRejectsUnsupportedOnes() throws {
        for (output, type, rate) in [("mp3_44100_128", "audio/mpeg", 44100), ("pcm_16000", "audio/pcm", 16000), ("ulaw_8000", "audio/pcmu", 8000), ("alaw_8000", "audio/pcma", 8000), ("opus_48000_64", "audio/ogg", 48000)] {
            #expect(elevenLabsAudioFormat(output) == .init(mediaType: type, sampleRate: rate))
        }
        #expect(elevenLabsAudioFormat("unknown") == .init(mediaType: "application/octet-stream"))
        let mapped: [(AIStreamingAudioFormat?, String)] = [
            (nil, "mp3_44100_128"), (.init(mediaType: "audio/mpeg"), "mp3_44100_128"), (.init(mediaType: "audio/mpeg", sampleRate: 22050), "mp3_22050_32"),
            (.init(mediaType: "audio/pcm"), "pcm_24000"), (.init(mediaType: "audio/pcm", sampleRate: 16000), "pcm_16000"), (.init(mediaType: "audio/pcmu"), "ulaw_8000"),
            (.init(mediaType: "audio/pcma", sampleRate: 8000), "alaw_8000"), (.init(mediaType: "audio/opus"), "opus_48000_64"), (.init(mediaType: "Audio/L16; rate=16000", sampleRate: 16000), "pcm_16000")
        ]
        for (format, expected) in mapped { #expect(try elevenLabsStreamOutputFormat(format) == expected) }
        for format in [AIStreamingAudioFormat(mediaType: "audio/pcm", sampleRate: 11025), .init(mediaType: "audio/wav"), .init(mediaType: "audio/mpeg", sampleRate: 48000)] {
            #expect(throws: AIError.self) { try elevenLabsStreamOutputFormat(format) }
        }
        #expect(throws: AIError.invalidArgument(argument: "outputFormat", message: #"ElevenLabs streaming speech does not support the output format {"type":"audio/wav"}. Use providerOptions.elevenlabs.streaming.outputFormat for a native ElevenLabs format."#)) {
            try elevenLabsStreamOutputFormat(.init(mediaType: "audio/wav"))
        }
    }
}
