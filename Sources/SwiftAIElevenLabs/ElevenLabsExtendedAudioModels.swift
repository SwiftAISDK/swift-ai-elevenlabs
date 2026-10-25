import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public final class ElevenLabsMusicModel: AudioGenerationModel, @unchecked Sendable {
    public let providerID = "elevenlabs.music"
    public let modelID: String
    private let config: ElevenLabsModelConfiguration

    public init(modelID: String = "music_v1", config: ElevenLabsModelConfiguration) {
        self.modelID = modelID
        self.config = config
    }

    public func generateAudio(_ request: AudioGenerationRequest) async throws -> AudioGenerationResult {
        let options = try elevenLabsExtendedProviderOptions(from: request, supportedProviderOptionKeys: elevenLabsMusicProviderOptionKeys, validateProviderOptions: elevenLabsValidateMusicOptions)
        var query: [String: String] = [:]
        if let format = request.format {
            query["output_format"] = elevenLabsExtendedOutputFormat(format)
        }
        var body: [String: JSONValue] = [
            "prompt": .string(request.prompt),
            "model_id": .string(modelID)
        ]
        if let durationSeconds = request.durationSeconds {
            body["music_length_ms"] = .number((durationSeconds * 1000).rounded())
        }
        if let seed = request.seed {
            body["seed"] = .number(Double(seed))
        }
        for (key, value) in options {
            switch key {
            case "musicLengthMs":
                body["music_length_ms"] = value
            case "compositionPlan":
                body["composition_plan"] = value
                body["prompt"] = nil
            case "forceInstrumental":
                body["force_instrumental"] = value
            case "respectSectionsDurations":
                body["respect_sections_durations"] = value
            case "storeForInpainting":
                body["store_for_inpainting"] = value
            case "signWithC2PA":
                body["sign_with_c2pa"] = value
            case "outputFormat":
                if let format = value.stringValue { query["output_format"] = elevenLabsExtendedOutputFormat(format) }
            default:
                body[key] = value
            }
        }

        let path = "/v1/music" + (query.isEmpty ? "" : "?\(queryString(query))")
        let response = try await config.transport.send(config.request(path: path, modelID: modelID, body: .object(body), headers: request.headers, abortSignal: request.abortSignal))
        guard (200..<300).contains(response.statusCode) else {
            throw audioProviderHTTPStatusError(provider: providerID, response: response)
        }
        return AudioGenerationResult(
            audio: response.body,
            contentType: response.headers.contentType,
            requestMetadata: aiRequestMetadata(body: .object(body), headers: request.headers),
            responseMetadata: aiResponseMetadata(response: response, modelID: modelID)
        )
    }
}

public final class ElevenLabsSoundEffectsModel: AudioGenerationModel, @unchecked Sendable {
    public let providerID = "elevenlabs.sound-effects"
    public let modelID: String
    private let config: ElevenLabsModelConfiguration

    public init(modelID: String = "eleven_text_to_sound_v2", config: ElevenLabsModelConfiguration) {
        self.modelID = modelID
        self.config = config
    }

    public func generateAudio(_ request: AudioGenerationRequest) async throws -> AudioGenerationResult {
        let options = try elevenLabsExtendedProviderOptions(from: request, supportedProviderOptionKeys: elevenLabsSoundEffectsProviderOptionKeys, validateProviderOptions: elevenLabsValidateSoundEffectOptions)
        var query: [String: String] = [:]
        if let format = request.format {
            query["output_format"] = elevenLabsExtendedOutputFormat(format)
        }
        var body: [String: JSONValue] = [
            "text": .string(request.prompt),
            "model_id": .string(modelID)
        ]
        if let durationSeconds = request.durationSeconds {
            body["duration_seconds"] = .number(durationSeconds)
        }
        if let seed = request.seed {
            body["seed"] = .number(Double(seed))
        }
        for (key, value) in options {
            switch key {
            case "promptInfluence":
                body["prompt_influence"] = value
            case "outputFormat":
                if let format = value.stringValue { query["output_format"] = elevenLabsExtendedOutputFormat(format) }
            default:
                body[key] = value
            }
        }

        let path = "/v1/sound-generation" + (query.isEmpty ? "" : "?\(queryString(query))")
        let response = try await config.transport.send(config.request(path: path, modelID: modelID, body: .object(body), headers: request.headers, abortSignal: request.abortSignal))
        guard (200..<300).contains(response.statusCode) else {
            throw audioProviderHTTPStatusError(provider: providerID, response: response)
        }
        return AudioGenerationResult(
            audio: response.body,
            contentType: response.headers.contentType,
            requestMetadata: aiRequestMetadata(body: .object(body), headers: request.headers),
            responseMetadata: aiResponseMetadata(response: response, modelID: modelID)
        )
    }
}

public final class ElevenLabsVoiceChangerModel: AudioTransformationModel, @unchecked Sendable {
    public let providerID = "elevenlabs.voice-changer"
    public let modelID: String
    private let config: ElevenLabsModelConfiguration

    public init(modelID: String = "eleven_multilingual_sts_v2", config: ElevenLabsModelConfiguration) {
        self.modelID = modelID
        self.config = config
    }

    public func transformAudio(_ request: AudioTransformationRequest) async throws -> AudioTransformationResult {
        let options = try elevenLabsExtendedProviderOptions(from: request, supportedProviderOptionKeys: elevenLabsVoiceChangerProviderOptionKeys, validateProviderOptions: elevenLabsValidateVoiceChangerOptions)
        let voice = request.voice ?? options["voiceID"]?.stringValue ?? options["voice_id"]?.stringValue ?? "21m00Tcm4TlvDq8ikWAM"
        var query = ["output_format": elevenLabsExtendedOutputFormat(request.format)]
        if let enableLogging = options["enableLogging"]?.boolValue ?? options["enable_logging"]?.boolValue {
            query["enable_logging"] = String(enableLogging)
        }
        if let optimize = options["optimizeStreamingLatency"] ?? options["optimize_streaming_latency"],
           let scalar = jsonScalarString(optimize) {
            query["optimize_streaming_latency"] = scalar
        }

        var form = MultipartFormData()
        form.appendFile(name: "audio", fileName: request.fileName, mimeType: request.mimeType, data: request.audio)
        form.appendField(name: "model_id", value: modelID)
        var metadata: [String: JSONValue] = [
            "fileName": .string(request.fileName),
            "mimeType": .string(request.mimeType),
            "byteLength": .number(Double(request.audio.count)),
            "voice": .string(voice),
            "model_id": .string(modelID)
        ]
        for (key, value) in options {
            guard let scalar = jsonScalarString(value) else {
                if key == "voiceSettings" || key == "voice_settings" {
                    form.appendField(name: "voice_settings", value: jsonString(value))
                    metadata["voice_settings"] = value
                }
                continue
            }
            switch key {
            case "voiceID", "voice_id", "enableLogging", "enable_logging", "optimizeStreamingLatency", "optimize_streaming_latency":
                continue
            case "fileFormat":
                form.appendField(name: "file_format", value: scalar)
                metadata["file_format"] = value
            case "removeBackgroundNoise":
                form.appendField(name: "remove_background_noise", value: scalar)
                metadata["remove_background_noise"] = value
            case "voiceSettings", "voice_settings":
                form.appendField(name: "voice_settings", value: scalar)
                metadata["voice_settings"] = value
            default:
                form.appendField(name: key, value: scalar)
                metadata[key] = value
            }
        }

        let response = try await config.transport.send(config.rawRequest(
            path: "/v1/speech-to-speech/\(urlPathEncode(voice))?\(queryString(query))",
            modelID: modelID,
            body: form.finalize(),
            contentType: "multipart/form-data; boundary=\(form.boundary)",
            headers: request.headers,
            abortSignal: request.abortSignal
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw audioProviderHTTPStatusError(provider: providerID, response: response)
        }
        return AudioTransformationResult(
            audio: response.body,
            contentType: response.headers.contentType,
            requestMetadata: aiRequestMetadata(body: .object(metadata), headers: request.headers),
            responseMetadata: aiResponseMetadata(response: response, modelID: modelID)
        )
    }
}

public final class ElevenLabsVoiceIsolatorModel: AudioTransformationModel, @unchecked Sendable {
    public let providerID = "elevenlabs.voice-isolator"
    public let modelID: String
    private let config: ElevenLabsModelConfiguration

    public init(modelID: String = "audio-isolation", config: ElevenLabsModelConfiguration) {
        self.modelID = modelID
        self.config = config
    }

    public func transformAudio(_ request: AudioTransformationRequest) async throws -> AudioTransformationResult {
        let options = try elevenLabsExtendedProviderOptions(from: request, supportedProviderOptionKeys: elevenLabsVoiceIsolatorProviderOptionKeys, validateProviderOptions: elevenLabsValidateVoiceIsolatorOptions)
        var form = MultipartFormData()
        form.appendFile(name: "audio", fileName: request.fileName, mimeType: request.mimeType, data: request.audio)
        var metadata: [String: JSONValue] = [
            "fileName": .string(request.fileName),
            "mimeType": .string(request.mimeType),
            "byteLength": .number(Double(request.audio.count))
        ]
        for (key, value) in options {
            guard let scalar = jsonScalarString(value) else { continue }
            switch key {
            case "fileFormat":
                form.appendField(name: "file_format", value: scalar)
                metadata["file_format"] = value
            case "previewB64":
                form.appendField(name: "preview_b64", value: scalar)
                metadata["preview_b64"] = value
            default:
                form.appendField(name: key, value: scalar)
                metadata[key] = value
            }
        }

        let response = try await config.transport.send(config.rawRequest(
            path: "/v1/audio-isolation",
            modelID: modelID,
            body: form.finalize(),
            contentType: "multipart/form-data; boundary=\(form.boundary)",
            headers: request.headers,
            abortSignal: request.abortSignal
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw audioProviderHTTPStatusError(provider: providerID, response: response)
        }
        return AudioTransformationResult(
            audio: response.body,
            contentType: response.headers.contentType,
            requestMetadata: aiRequestMetadata(body: .object(metadata), headers: request.headers),
            responseMetadata: aiResponseMetadata(response: response, modelID: modelID)
        )
    }
}

public final class ElevenLabsDubbingClient: @unchecked Sendable {
    public let providerID = "elevenlabs.dubbing"
    private let config: ElevenLabsModelConfiguration

    public init(config: ElevenLabsModelConfiguration) {
        self.config = config
    }

    public func create(_ request: DubbingCreateRequest) async throws -> DubbingCreateResult {
        let options = elevenLabsExtendedProviderOptions(from: request.extraBody, providerOptions: request.providerOptions)
        var form = MultipartFormData()
        if let file = request.file {
            form.appendFile(name: "file", fileName: request.fileName, mimeType: request.mimeType, data: file)
        }
        if let sourceURL = request.sourceURL {
            form.appendField(name: "source_url", value: sourceURL)
        }
        form.appendField(name: "target_lang", value: request.targetLanguage)
        if let name = request.name { form.appendField(name: "name", value: name) }
        if let sourceLanguage = request.sourceLanguage { form.appendField(name: "source_lang", value: sourceLanguage) }
        if let numSpeakers = request.numSpeakers { form.appendField(name: "num_speakers", value: String(numSpeakers)) }
        if let watermark = request.watermark { form.appendField(name: "watermark", value: String(watermark)) }
        if let startTime = request.startTime { form.appendField(name: "start_time", value: String(startTime)) }
        if let endTime = request.endTime { form.appendField(name: "end_time", value: String(endTime)) }
        for (key, value) in options {
            if let scalar = jsonScalarString(value) {
                form.appendField(name: elevenLabsDubbingFieldName(key), value: scalar)
            }
        }

        let response = try await config.transport.send(config.rawRequest(
            path: "/v1/dubbing",
            modelID: "dubbing",
            body: form.finalize(),
            contentType: "multipart/form-data; boundary=\(form.boundary)",
            headers: request.headers,
            abortSignal: request.abortSignal
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw audioProviderHTTPStatusError(provider: providerID, response: response)
        }
        let raw = try response.jsonValue()
        guard let id = raw["dubbing_id"]?.stringValue else {
            throw AIError.invalidResponse(provider: providerID, message: "ElevenLabs dubbing response did not contain dubbing_id.")
        }
        return DubbingCreateResult(
            dubbingID: id,
            expectedDurationSeconds: raw["expected_duration_sec"]?.doubleValue,
            rawValue: raw,
            requestMetadata: aiRequestMetadata(body: elevenLabsDubbingCreateMetadata(request), headers: request.headers),
            responseMetadata: aiResponseMetadata(from: raw, response: response, modelID: "dubbing")
        )
    }

    public func get(_ dubbingID: String, headers: [String: String] = [:], abortSignal: AIAbortSignal? = nil) async throws -> DubbingStatusResult {
        let response = try await config.transport.send(try request(method: "GET", path: "/v1/dubbing/\(urlPathEncode(dubbingID))", headers: headers, abortSignal: abortSignal))
        guard (200..<300).contains(response.statusCode) else {
            throw audioProviderHTTPStatusError(provider: providerID, response: response)
        }
        let raw = try response.jsonValue()
        return DubbingStatusResult(
            dubbingID: raw["dubbing_id"]?.stringValue ?? dubbingID,
            name: raw["name"]?.stringValue,
            status: raw["status"]?.stringValue ?? "unknown",
            sourceLanguage: raw["source_language"]?.stringValue,
            targetLanguages: raw["target_languages"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            error: raw["error"]?.stringValue,
            rawValue: raw,
            responseMetadata: aiResponseMetadata(from: raw, response: response, modelID: "dubbing")
        )
    }

    public func audio(dubbingID: String, languageCode: String, headers: [String: String] = [:], abortSignal: AIAbortSignal? = nil) async throws -> DubbingAudioResult {
        let response = try await config.transport.send(try request(method: "GET", path: "/v1/dubbing/\(urlPathEncode(dubbingID))/audio/\(urlPathEncode(languageCode))", headers: headers, abortSignal: abortSignal))
        guard (200..<300).contains(response.statusCode) else {
            throw audioProviderHTTPStatusError(provider: providerID, response: response)
        }
        return DubbingAudioResult(audio: response.body, contentType: response.headers.contentType, responseMetadata: aiResponseMetadata(response: response, modelID: "dubbing"))
    }

    private func request(method: String, path: String, headers requestHeaders: [String: String], abortSignal: AIAbortSignal?) throws -> AIHTTPRequest {
        var headers = config.headers.mergingHeaders(requestHeaders)
        headers["user-agent"] = headers["user-agent"] ?? userAgent(providerID)
        return AIHTTPRequest(method: method, url: try config.url("dubbing", path), headers: headers, abortSignal: abortSignal)
    }
}

private let elevenLabsMusicProviderOptionKeys: Set<String> = ["musicLengthMs", "compositionPlan", "forceInstrumental", "respectSectionsDurations", "storeForInpainting", "signWithC2PA", "outputFormat"]
private let elevenLabsSoundEffectsProviderOptionKeys: Set<String> = ["loop", "promptInfluence", "outputFormat"]
private let elevenLabsVoiceChangerProviderOptionKeys: Set<String> = ["voiceID", "voice_id", "voiceSettings", "voice_settings", "seed", "removeBackgroundNoise", "fileFormat", "enableLogging", "enable_logging", "optimizeStreamingLatency", "optimize_streaming_latency"]
private let elevenLabsVoiceIsolatorProviderOptionKeys: Set<String> = ["fileFormat", "previewB64"]

private func elevenLabsExtendedProviderOptions(from request: AudioGenerationRequest, supportedProviderOptionKeys: Set<String>, validateProviderOptions: ([String: JSONValue]) throws -> [String: JSONValue]) throws -> [String: JSONValue] {
    try elevenLabsExtendedProviderOptions(extraBody: request.extraBody, providerOptions: request.providerOptions, supportedProviderOptionKeys: supportedProviderOptionKeys, validateProviderOptions: validateProviderOptions)
}

private func elevenLabsExtendedProviderOptions(from request: AudioTransformationRequest, supportedProviderOptionKeys: Set<String>, validateProviderOptions: ([String: JSONValue]) throws -> [String: JSONValue]) throws -> [String: JSONValue] {
    try elevenLabsExtendedProviderOptions(extraBody: request.extraBody, providerOptions: request.providerOptions, supportedProviderOptionKeys: supportedProviderOptionKeys, validateProviderOptions: validateProviderOptions)
}

private func elevenLabsExtendedProviderOptions(extraBody: [String: JSONValue], providerOptions: [String: JSONValue], supportedProviderOptionKeys: Set<String>, validateProviderOptions: ([String: JSONValue]) throws -> [String: JSONValue]) throws -> [String: JSONValue] {
    var output = elevenLabsExtendedProviderOptions(from: extraBody, providerOptions: [:])
    if let value = providerOptions["elevenlabs"] {
        guard value != .null else { return output }
        guard let nested = value.objectValue else {
            throw AIError.invalidArgument(argument: "providerOptions.elevenlabs", message: "ElevenLabs provider options must be an object.")
        }
        output.merge(try validateProviderOptions(nested).filter { supportedProviderOptionKeys.contains($0.key) }) { _, providerValue in providerValue }
    }
    return output
}

private func elevenLabsExtendedProviderOptions(from extraBody: [String: JSONValue], providerOptions: [String: JSONValue]) -> [String: JSONValue] {
    var output = extraBody
    if let nested = output.removeValue(forKey: "elevenlabs")?.objectValue {
        output.merge(nested) { _, nested in nested }
    }
    if let value = providerOptions["elevenlabs"]?.objectValue {
        output.merge(value) { _, nested in nested }
    }
    return output
}

private func elevenLabsValidateMusicOptions(_ options: [String: JSONValue]) throws -> [String: JSONValue] {
    try options.mapValuesForElevenLabs { key, value in
        switch key {
        case "musicLengthMs":
            try requireNumber(value, key: key, min: 3000, max: 600_000)
        case "forceInstrumental", "respectSectionsDurations", "storeForInpainting", "signWithC2PA":
            try requireBool(value, key: key)
        case "outputFormat":
            try requireString(value, key: key)
        default:
            break
        }
        return value
    }
}

private func elevenLabsValidateSoundEffectOptions(_ options: [String: JSONValue]) throws -> [String: JSONValue] {
    try options.mapValuesForElevenLabs { key, value in
        switch key {
        case "loop":
            try requireBool(value, key: key)
        case "promptInfluence":
            try requireNumber(value, key: key, min: 0, max: 1)
        case "outputFormat":
            try requireString(value, key: key)
        default:
            break
        }
        return value
    }
}

private func elevenLabsValidateVoiceChangerOptions(_ options: [String: JSONValue]) throws -> [String: JSONValue] {
    try options.mapValuesForElevenLabs { key, value in
        switch key {
        case "voiceID", "voice_id", "fileFormat", "outputFormat":
            try requireString(value, key: key)
        case "removeBackgroundNoise", "enableLogging", "enable_logging":
            try requireBool(value, key: key)
        case "seed":
            try requireNumber(value, key: key, min: 0, max: 4_294_967_295)
        case "optimizeStreamingLatency", "optimize_streaming_latency":
            try requireNumber(value, key: key, min: 0, max: 4)
        default:
            break
        }
        return value
    }
}

private func elevenLabsValidateVoiceIsolatorOptions(_ options: [String: JSONValue]) throws -> [String: JSONValue] {
    try options.mapValuesForElevenLabs { key, value in
        if key == "fileFormat" || key == "previewB64" {
            try requireString(value, key: key)
        }
        return value
    }
}

private func requireString(_ value: JSONValue, key: String) throws {
    guard value.stringValue != nil else {
        throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.\(key)", message: "ElevenLabs \(key) must be a string.")
    }
}

private func requireBool(_ value: JSONValue, key: String) throws {
    guard value.boolValue != nil else {
        throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.\(key)", message: "ElevenLabs \(key) must be a boolean.")
    }
}

private func requireNumber(_ value: JSONValue, key: String, min: Double, max: Double) throws {
    guard let number = value.doubleValue, number >= min, number <= max else {
        throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.\(key)", message: "ElevenLabs \(key) must be a number between \(min) and \(max).")
    }
}

private func elevenLabsExtendedOutputFormat(_ outputFormat: String?) -> String {
    switch outputFormat {
    case "mp3":
        return "mp3_44100_128"
    case "mp3_32":
        return "mp3_44100_32"
    case "mp3_64":
        return "mp3_44100_64"
    case "mp3_96":
        return "mp3_44100_96"
    case "mp3_128":
        return "mp3_44100_128"
    case "mp3_192":
        return "mp3_44100_192"
    case "pcm":
        return "pcm_44100"
    case "ulaw":
        return "ulaw_8000"
    case let value?:
        return value
    case nil:
        return "mp3_44100_128"
    }
}

private func jsonString(_ value: JSONValue) -> String {
    (try? String(data: encodeJSONBody(value), encoding: .utf8)) ?? "{}"
}

private func urlPathEncode(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func elevenLabsDubbingFieldName(_ key: String) -> String {
    switch key {
    case "sourceLanguage": return "source_lang"
    case "targetLanguage": return "target_lang"
    case "targetAccent": return "target_accent"
    case "numSpeakers": return "num_speakers"
    case "startTime": return "start_time"
    case "endTime": return "end_time"
    case "highestResolution": return "highest_resolution"
    case "dropBackgroundAudio": return "drop_background_audio"
    case "useProfanityFilter": return "use_profanity_filter"
    case "dubbingStudio": return "dubbing_studio"
    case "disableVoiceCloning": return "disable_voice_cloning"
    case "csvFPS": return "csv_fps"
    default: return key
    }
}

private func elevenLabsDubbingCreateMetadata(_ request: DubbingCreateRequest) -> JSONValue {
    .object([
        "fileName": request.file.map { _ in .string(request.fileName) },
        "mimeType": request.file.map { _ in .string(request.mimeType) },
        "byteLength": request.file.map { .number(Double($0.count)) },
        "sourceURL": request.sourceURL.map(JSONValue.string),
        "name": request.name.map(JSONValue.string),
        "sourceLanguage": request.sourceLanguage.map(JSONValue.string),
        "targetLanguage": .string(request.targetLanguage),
        "numSpeakers": request.numSpeakers.map { .number(Double($0)) },
        "watermark": request.watermark.map(JSONValue.bool),
        "startTime": request.startTime.map { .number(Double($0)) },
        "endTime": request.endTime.map { .number(Double($0)) },
        "providerOptions": request.providerOptions.isEmpty ? nil : .object(request.providerOptions),
        "extraBody": request.extraBody.isEmpty ? nil : .object(request.extraBody)
    ])
}

private extension Dictionary where Key == String, Value == JSONValue {
    func mapValuesForElevenLabs(_ transform: (String, JSONValue) throws -> JSONValue) throws -> [String: JSONValue] {
        var output: [String: JSONValue] = [:]
        for (key, value) in self {
            output[key] = try transform(key, value)
        }
        return output
    }
}
