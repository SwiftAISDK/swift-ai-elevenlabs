import Foundation
import Testing
import SwiftAIProvider
import SwiftAITransport
@testable import SwiftAIElevenLabs

private actor WeeklyCredentialSequence {
    private(set) var count = 0
    func next() -> String { count += 1; return "rotating-\(count)" }
}
private actor WeeklyCredentialProbe: AITransport {
    private(set) var requests: [AIHTTPRequest] = []
    struct Sent: Error {}
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        requests.append(request)
        throw Sent()
    }
}

@Suite("Weekly20261101 elevenlabs credentials")
struct Weekly20261101CredentialsTests {
    @Test func resolvesFreshCredentialOnlyWhenRequestIsSent() async throws {
        let sequence = WeeklyCredentialSequence()
        let transport = WeeklyCredentialProbe()
        let provider = try ElevenLabsProvider(configuration: ElevenLabsProviderSettings(apiKeyProvider: { await sequence.next() }, transport: transport))
        let model = try provider.transcriptionModel("scribe_v2")
        #expect(await sequence.count == 0)
        for _ in 0..<2 { _ = try? await model.transcribe(AudioTranscriptionRequest(audio: Data([1, 2, 3]), mimeType: "audio/wav")) }
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(await sequence.count == 2)
        for (index, request) in requests.enumerated() {
            #expect(request.headers.values.contains(where: { $0.contains("rotating-\(index + 1)") }))
            #expect(!request.headers.values.contains(where: { $0.contains("__swift_ai_credential_") }))
        }
    }

    @Test func webSocketCredentialsRefreshAtConnectAndDoNotEnterReportedMetadata() async throws {
        let sequence = WeeklyCredentialSequence()
        let provider = try ElevenLabsProvider(configuration: .init(apiKeyProvider: { await sequence.next() }))
        #expect(await sequence.count == 0)
        for override in [false, true, false] {
            let socket = WeeklySpeechSocketTransport()
            let model = try provider.streamingSpeechModel("eleven_flash_v2_5", webSocketTransport: socket)
            let result = try await model.stream(.init(text: .text("Hello"), headers: override ? ["Xi-Api-Key": "override-key"] : [:]))
            socket.socket.open()
            #expect(await weeklySpeechWait { !socket.socket.sent.isEmpty })
            let count = await sequence.count
            #expect(socket.socket.sent.first?["xi-api-key"] == .string(override ? "override-key" : "rotating-\(count)"))
            #expect(socket.requests.first?.headers.keys.contains { $0.caseInsensitiveCompare("xi-api-key") == .orderedSame } == false)
            #expect(result.requestMetadata.body?["initMessage"]?["xi-api-key"] == nil)
            result.cancel()
        }
        #expect(await sequence.count == 2)
    }
}
