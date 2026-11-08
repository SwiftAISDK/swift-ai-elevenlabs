import Foundation
import Testing
@testable import SwiftAIElevenLabs
import SwiftAIProvider

@Suite("Weekly20261108 ElevenLabs source URL")
struct Weekly20261108SourceTests {
    @Test(arguments: [false, true])
    func sourceURLReplacesUploadAndWarnsOnlyForNonemptyAudio(_ withAudio: Bool) async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"text":"Hello","language_code":"eng","language_probability":1,"words":[]}"#))
        let provider = try ElevenLabsProvider(configuration: .init(apiKey: "key", transport: transport))
        let result = try await provider.transcriptionModel("scribe_v2").transcribe(.init(audio: withAudio ? Data("ignored".utf8) : Data(), providerOptions: ["elevenlabs": ["sourceUrl": "https://media.example.com/audio.wav"]]))
        let request = try #require(await transport.requests().first)
        let form = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(form.contains("name=\"source_url\""))
        #expect(form.contains("https://media.example.com/audio.wav"))
        #expect(!form.contains("name=\"file\""))
        #expect(result.warnings.count == (withAudio ? 1 : 0))
    }
}
