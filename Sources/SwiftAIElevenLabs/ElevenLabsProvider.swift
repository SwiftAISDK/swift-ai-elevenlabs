import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities

public struct ElevenLabsProviderSettings: Sendable {
    public var apiKey: String?
    public var baseURL: String?
    public var headers: [String: String]
    public var queryParams: [String: String]
    public var transport: any AITransport

    public init(apiKey: String? = nil, baseURL: String? = nil, headers: [String: String] = [:],
                queryParams: [String: String] = [:], transport: any AITransport = URLSessionTransport.shared) {
        self.apiKey = apiKey; self.baseURL = baseURL; self.headers = headers
        self.queryParams = queryParams; self.transport = transport
    }
}

public final class ElevenLabsProvider: AIProvider, Sendable {
    public let providerID = "elevenlabs"
    public let supportedCapabilities: Set<ModelCapability> = [.transcription, .speech, .audioGeneration, .audioTransformation, .dubbing]
    private let config: ElevenLabsModelConfiguration

    public init(configuration: ElevenLabsProviderSettings = .init()) throws {
        let names = ["ELEVENLABS_API_KEY"]
        guard let key = configuration.apiKey ?? environmentValue(names) else {
            throw AIError.missingAPIKey(provider: "elevenlabs", environmentVariables: names)
        }
        var headers = configuration.headers
        headers["xi-api-key"] = headers["xi-api-key"] ?? "\(key)"
        headers = withUserAgentSuffix(headers, "ai-sdk-elevenlabs/3.0.71")
        let baseURL = withoutTrailingSlash(configuration.baseURL ?? "https://api.elevenlabs.io")
        let http = AIProviderHTTPClient(providerID: "elevenlabs", headers: headers, transport: configuration.transport,
            url: { _, path in try providerURL("\(baseURL)\(path)", queryParams: configuration.queryParams) })
        config = ElevenLabsModelConfiguration(http: http, baseURL: baseURL)
    }

    public func languageModel(_ modelID: String) throws -> any LanguageModel {
        throw AIError.unsupportedModel(provider: providerID, capability: .language, modelID: modelID)
    }

    public func embeddingModel(_ modelID: String) throws -> any EmbeddingModel {
        throw AIError.unsupportedModel(provider: providerID, capability: .embedding, modelID: modelID)
    }

    public func imageModel(_ modelID: String) throws -> any ImageModel {
        throw AIError.unsupportedModel(provider: providerID, capability: .image, modelID: modelID)
    }

    public func transcriptionModel(_ modelID: String) throws -> any TranscriptionModel {
        ElevenLabsTranscriptionModel(modelID: modelID, config: config)
    }

    public func speechModel(_ modelID: String) throws -> any SpeechModel {
        ElevenLabsSpeechModel(modelID: modelID, config: config)
    }

    public func videoModel(_ modelID: String) throws -> any VideoModel {
        throw AIError.unsupportedModel(provider: providerID, capability: .video, modelID: modelID)
    }

    public func rerankingModel(_ modelID: String) throws -> any RerankingModel {
        throw AIError.unsupportedModel(provider: providerID, capability: .reranking, modelID: modelID)
    }

    public func musicModel(_ modelID: String = "music_v1") throws -> any AudioGenerationModel {
        guard providerID == "elevenlabs" else {
            throw AIError.unsupportedModel(provider: providerID, capability: .audioGeneration, modelID: modelID)
        }
        return ElevenLabsMusicModel(modelID: modelID, config: config)
    }

    public func music(_ modelID: String = "music_v1") throws -> any AudioGenerationModel {
        try musicModel(modelID)
    }

    public func soundEffectsModel(_ modelID: String = "eleven_text_to_sound_v2") throws -> any AudioGenerationModel {
        guard providerID == "elevenlabs" else {
            throw AIError.unsupportedModel(provider: providerID, capability: .audioGeneration, modelID: modelID)
        }
        return ElevenLabsSoundEffectsModel(modelID: modelID, config: config)
    }

    public func soundEffects(_ modelID: String = "eleven_text_to_sound_v2") throws -> any AudioGenerationModel {
        try soundEffectsModel(modelID)
    }

    public func voiceChangerModel(_ modelID: String = "eleven_multilingual_sts_v2") throws -> any AudioTransformationModel {
        guard providerID == "elevenlabs" else {
            throw AIError.unsupportedModel(provider: providerID, capability: .audioTransformation, modelID: modelID)
        }
        return ElevenLabsVoiceChangerModel(modelID: modelID, config: config)
    }

    public func voiceChanger(_ modelID: String = "eleven_multilingual_sts_v2") throws -> any AudioTransformationModel {
        try voiceChangerModel(modelID)
    }

    public func voiceIsolatorModel(_ modelID: String = "audio-isolation") throws -> any AudioTransformationModel {
        guard providerID == "elevenlabs" else {
            throw AIError.unsupportedModel(provider: providerID, capability: .audioTransformation, modelID: modelID)
        }
        return ElevenLabsVoiceIsolatorModel(modelID: modelID, config: config)
    }

    public func voiceIsolator(_ modelID: String = "audio-isolation") throws -> any AudioTransformationModel {
        try voiceIsolatorModel(modelID)
    }

    public func dubbing() throws -> ElevenLabsDubbingClient {
        guard providerID == "elevenlabs" else {
            throw AIError.unsupportedModel(provider: providerID, capability: .dubbing, modelID: "dubbing")
        }
        return ElevenLabsDubbingClient(config: config)
    }

    public func streamingSpeechModel(_ modelID: String, webSocketTransport: any AIDuplexWebSocketTransport = URLSessionDuplexWebSocketTransport.shared) throws -> any StreamingSpeechModel {
        guard providerID == "elevenlabs" else {
            throw AIError.unsupportedModel(provider: providerID, capability: .speech, modelID: modelID)
        }
        return ElevenLabsSpeechModel(modelID: modelID, config: config, webSocketTransport: webSocketTransport)
    }


    public func chatModel(_ modelID: String) throws -> any LanguageModel { try languageModel(modelID) }
}

public extension AIProviders {
    static func elevenLabs(configuration: ElevenLabsProviderSettings) throws -> ElevenLabsProvider {
        try ElevenLabsProvider(configuration: configuration)
    }
}

public struct ElevenLabsModelConfiguration: AIProviderHTTPConfiguration {
    public var http: AIProviderHTTPClient
    public var baseURL: String
    public init(http: AIProviderHTTPClient, baseURL: String) {
        self.http = http; self.baseURL = withoutTrailingSlash(baseURL)
    }
}
