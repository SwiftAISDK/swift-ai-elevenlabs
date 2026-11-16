@testable import SwiftAIElevenLabs
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

// Translated from the "ElevenLabsSpeechModel.doStream (dialogue)" block of
// packages/elevenlabs/src/elevenlabs-speech-stream.test.ts.

private func dialogueModel(_ socket: WeeklySpeechSocketTransport) throws -> any StreamingSpeechModel {
    try dialogueModel("eleven_v4", socket)
}

private func dialogueModel(_ id: String, _ socket: WeeklySpeechSocketTransport) throws -> any StreamingSpeechModel {
    try AIProviders.elevenLabs(configuration: .init(apiKey: "test-api-key")).streamingSpeechModel(id, webSocketTransport: socket)
}

private func parts(_ result: StreamingSpeechModelResult) async throws -> [StreamingSpeechPart] {
    var output: [StreamingSpeechPart] = []
    for try await part in result.stream { output.append(part) }
    return output
}

private func failureMessage(_ result: StreamingSpeechModelResult) async -> String? {
    do { _ = try await parts(result); return nil } catch let error as AIStreamingSpeechError { return error.message } catch let AIError.invalidArgument(_, message) { return message } catch { return String(describing: error) }
}

@Suite("ElevenLabs streaming dialogue parity")
struct ElevenLabsSpeechDialogueStreamParityTests {
    @Test func streamsSpeakerTurnsFromTextPartVoicesOverTextToDialogue() async throws {
        let socket = WeeklySpeechSocketTransport()
        let result = try await dialogueModel(socket).stream(.init(
            text: .parts([.init(text: "Hi there. ", voice: "a"), .init(text: "Hello 👋 ", voice: "b"), .init(text: "friend.", voice: "b")]),
            outputFormat: .init(mediaType: "audio/pcm", sampleRate: 24000),
            providerOptions: ["elevenlabs": ["dialogue": ["voices": ["a", "b"], "voiceSettings": ["stability": 0.5]], "streaming": ["syncAlignment": true, "inactivityTimeout": 60]]]))
        #expect(socket.requests.first?.url.absoluteString == "wss://api.elevenlabs.io/v1/text-to-dialogue/stream-input?model_id=eleven_v4&output_format=pcm_24000&sync_alignment=true")
        socket.socket.open()
        #expect(await weeklySpeechWait { socket.socket.sent.count == 5 })
        #expect(socket.socket.sent == [
            ["voice_settings": ["stability": 0.5], "voices": ["a", "b"], "xi_api_key": "test-api-key"],
            ["inputs": [["text": "Hi there. ", "voice_id": "a"]]],
            ["inputs": [["text": "Hello 👋 ", "voice_id": "b", "new_turn": true]]],
            ["inputs": [["text": "friend.", "voice_id": "b"]]],
            ["close_socket": true]
        ])
        try socket.socket.receive(["audio": "AQI=", "alignment": ["chars": ["H"], "char_start_times_ms": [0], "char_durations_ms": [5]]])
        try socket.socket.receive(["is_final_audio_for_turn": true])
        try socket.socket.receive(["is_final": true])
        let output = try await parts(result)
        #expect(output.count == 4)
        if case let .streamStart(warnings) = output[0] {
            #expect(warnings.map { $0.feature } == ["providerOptions.elevenlabs.streaming.inactivityTimeout"])
        } else { Issue.record("Expected stream-start") }
        if case let .audio(_, audio, _, metadata) = output[1] {
            #expect(audio == Data([1, 2]))
            #expect(metadata == ["elevenlabs": ["alignment": ["chars": ["H"], "charStartTimesMs": [0], "charDurationsMs": [5]]]])
        } else { Issue.record("Expected audio") }
        if case let .audio(_, audio, _, metadata) = output[2] {
            #expect(audio.isEmpty); #expect(metadata == ["elevenlabs": ["isFinalAudioForTurn": true]])
        } else { Issue.record("Expected turn boundary") }
        if case let .finish(usage, _) = output[3] { #expect(usage == ["inputCharacters": 25]) } else { Issue.record("Expected finish") }
    }

    @Test func flushesHeldTextWhenTheSpeakerChangesAndHonorsNewTurn() async throws {
        let socket = WeeklySpeechSocketTransport()
        let kept1 = try await dialogueModel(socket).stream(.init(text: .parts([
            .init(text: "Hi the", voice: "a"), .init(text: "Hello "),
            .init(text: "Again. ", providerOptions: ["elevenlabs": ["newTurn": true]]), .init(text: "More.")
        ]), voice: "b", providerOptions: ["elevenlabs": ["dialogue": ["voices": ["a", "b"]]]]))
        socket.socket.open()
        #expect(await weeklySpeechWait { socket.socket.sent.count == 7 })
        #expect(Array(socket.socket.sent.dropFirst()) == [
            ["inputs": [["text": "Hi ", "voice_id": "a"]]],
            ["inputs": [["text": "the", "voice_id": "a"]]],
            ["inputs": [["text": "Hello ", "voice_id": "b", "new_turn": true]]],
            ["inputs": [["text": "Again. ", "voice_id": "b", "new_turn": true]]],
            ["inputs": [["text": "More.", "voice_id": "b"]]],
            ["close_socket": true]
        ])
        withExtendedLifetime(kept1) {}
    }

    @Test func keepsHeldTextForTheDefaultVoiceAndCarriesHeldNewTurns() async throws {
        let socket = WeeklySpeechSocketTransport()
        let kept2 = try await dialogueModel(socket).stream(.init(text: .parts([.init(text: "Hel"), .init(text: "lo there.", voice: "a")]),
                                                         providerOptions: ["elevenlabs": ["dialogue": ["voices": ["a", "b"]]]]))
        socket.socket.open()
        #expect(await weeklySpeechWait { socket.socket.sent.count == 4 })
        #expect(Array(socket.socket.sent.dropFirst()) == [["inputs": [["text": "Hello ", "voice_id": "a"]]], ["inputs": [["text": "there.", "voice_id": "a"]]], ["close_socket": true]])

        let turns = WeeklySpeechSocketTransport()
        let kept3 = try await dialogueModel(turns).stream(.init(text: .parts([
            .init(text: "Hi. "), .init(text: "Ag", providerOptions: ["elevenlabs": ["newTurn": true]]), .init(text: "ain. ")
        ]), providerOptions: ["elevenlabs": ["dialogue": ["voices": ["a"]]]]))
        turns.socket.open()
        #expect(await weeklySpeechWait { turns.socket.sent.count == 4 })
        #expect(Array(turns.socket.sent.dropFirst()) == [["inputs": [["text": "Hi. ", "voice_id": "a"]]], ["inputs": [["text": "Again. ", "voice_id": "a", "new_turn": true]]], ["close_socket": true]])
        withExtendedLifetime(kept2) {}
        withExtendedLifetime(kept3) {}
    }

    @Test(arguments: ["Hel", "", "Hi "])
    func errorsOnAnUnlistedTextPartVoice(_ text: String) async throws {
        let socket = WeeklySpeechSocketTransport()
        let result = try await dialogueModel(socket).stream(.init(text: .parts([.init(text: text, voice: "c")]), providerOptions: ["elevenlabs": ["dialogue": ["voices": ["a", "b"]]]]))
        socket.socket.open()
        #expect(await failureMessage(result) == "Dialogue text part voice \"c\" is not listed in providerOptions.elevenlabs.dialogue.voices.")
    }

    @Test func warnsAboutOptionsTextToDialogueIgnores() async throws {
        let socket = WeeklySpeechSocketTransport()
        let result = try await dialogueModel(socket).stream(.init(text: .chunks(["Hi."]), speed: 1.2, providerOptions: ["elevenlabs": [
            "dialogue": ["voices": ["a"]], "voiceSettings": ["stability": 0.3], "streaming": ["autoMode": true, "chunkLengthSchedule": [50]]
        ]]))
        socket.socket.open()
        try socket.socket.receive(["is_final": true])
        guard case let .streamStart(warnings)? = try await parts(result).first else { Issue.record("Expected stream-start"); return }
        #expect(warnings.map { $0.feature } == ["speed", "providerOptions.elevenlabs.voiceSettings", "providerOptions.elevenlabs.streaming.autoMode", "providerOptions.elevenlabs.streaming.chunkLengthSchedule"])
        #expect(warnings[0].message == "ElevenLabs streaming dialogue does not support speed; it was ignored.")
    }

    @Test func rejectsInvalidDialogueSetupBeforeConnecting() async throws {
        let socket = WeeklySpeechSocketTransport()
        await #expect(throws: AIError.invalidArgument(argument: "voice", message: "ElevenLabs streaming dialogue voice \"c\" is not listed in providerOptions.elevenlabs.dialogue.voices.")) {
            _ = try await dialogueModel(socket).stream(.init(text: .chunks(["Hi"]), voice: "c", providerOptions: ["elevenlabs": ["dialogue": ["voices": ["a"]]]]))
        }
        await #expect(throws: AIError.invalidArgument(argument: "providerOptions.elevenlabs.dialogue.voices", message: "eleven_v3_conversational supports exactly one dialogue voice; received 2.")) {
            _ = try await dialogueModel("eleven_v3_conversational", socket).stream(.init(text: .chunks(["Hi"]), providerOptions: ["elevenlabs": ["dialogue": ["voices": ["a", "b"]]]]))
        }
        await #expect(throws: AIError.invalidArgument(argument: "providerOptions.elevenlabs.dialogue", message: "ElevenLabs streaming dialogue requires an eleven_v3 or eleven_v4 model; eleven_flash_v2_5 is not one.")) {
            _ = try await dialogueModel("eleven_flash_v2_5", socket).stream(.init(text: .chunks(["Hi"]), providerOptions: ["elevenlabs": ["dialogue": ["voices": ["a"]]]]))
        }
        #expect(socket.requests.isEmpty)
    }

    @Test func sendsTheWholeScriptInOneMessageForTheV3Family() async throws {
        let socket = WeeklySpeechSocketTransport()
        let kept7 = try await dialogueModel("eleven_v3_conversational", socket).stream(.init(text: .chunks(["Hello ", "world."]), providerOptions: ["elevenlabs": ["dialogue": ["voices": ["a"]]]]))
        socket.socket.open()
        #expect(await weeklySpeechWait { socket.socket.sent.count == 2 })
        #expect(socket.socket.sent == [
            ["voices": ["a"], "xi_api_key": "test-api-key"],
            ["inputs": [["text": "Hello ", "voice_id": "a"], ["text": "world.", "voice_id": "a"]], "close_socket": true]
        ])
        withExtendedLifetime(kept7) {}
    }

    @Test func errorsOnServerErrorFrames() async throws {
        let socket = WeeklySpeechSocketTransport()
        let result = try await dialogueModel(socket).stream(.init(text: .chunks(["Hi"]), providerOptions: ["elevenlabs": ["dialogue": ["voices": ["a", "b"]]]]))
        socket.socket.open()
        try socket.socket.receive(["message": "eleven_v3_conversational only supports a single voice.", "error": "invalid_argument", "code": 1008])
        #expect(await failureMessage(result) == "ElevenLabs speech stream error: eleven_v3_conversational only supports a single voice.")
    }
}
