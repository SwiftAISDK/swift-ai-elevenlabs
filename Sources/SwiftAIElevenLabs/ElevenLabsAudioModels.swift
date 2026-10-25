import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


public final class ElevenLabsSpeechModel: StreamingSpeechModel, @unchecked Sendable {
    public let providerID = "elevenlabs.speech"
    public let modelID: String
    let config: ElevenLabsModelConfiguration

    let webSocketTransport: any AIDuplexWebSocketTransport

    public init(modelID: String, config: ElevenLabsModelConfiguration, webSocketTransport: any AIDuplexWebSocketTransport = URLSessionDuplexWebSocketTransport.shared) {
        self.modelID = modelID
        self.config = config
        self.webSocketTransport = webSocketTransport
    }

    public func speak(_ request: SpeechRequest) async throws -> SpeechResult {
        let options = try elevenLabsProviderOptions(from: request)
        var warnings = elevenLabsSpeechWarnings(for: request)
        if modelID.hasPrefix("music_") || modelID.hasPrefix("eleven_text_to_sound") || options["inputs"] != nil {
            return try await elevenLabsSpecialSpeech(model: self, request: request, options: options)
        }
        for key in ["streaming", "dialogue", "musicLengthMs", "forceInstrumental", "compositionPlan", "durationSeconds", "promptInfluence", "loop"] where options[key] != nil {
            warnings.append(elevenLabsIgnoredWarning(key))
        }
        let voice = request.voice ?? "21m00Tcm4TlvDq8ikWAM"
        var query: [String: String] = [
            "output_format": elevenLabsOutputFormat(request.format)
        ]
        if let enableLogging = options["enableLogging"]?.boolValue ?? options["enable_logging"]?.boolValue {
            query["enable_logging"] = String(enableLogging)
        }

        var body: [String: JSONValue] = [
            "text": .string(request.text),
            "model_id": .string(modelID)
        ]
        if let language = request.language ?? options["languageCode"]?.stringValue ?? options["language_code"]?.stringValue {
            body["language_code"] = .string(language)
        }
        var voiceSettings: [String: JSONValue] = [:]
        if let speed = request.speed {
            voiceSettings["speed"] = .number(speed)
        }
        if let speed = options["speed"] {
            voiceSettings["speed"] = speed
        }
        if let voiceSettingsValue = options["voiceSettings"] ?? options["voice_settings"],
           let mapped = elevenLabsVoiceSettings(voiceSettingsValue).objectValue {
            voiceSettings.merge(mapped) { _, new in new }
        }
        if !voiceSettings.isEmpty {
            body["voice_settings"] = .object(voiceSettings)
        }
        for (key, value) in options {
            switch key {
            case "languageCode", "language_code", "voiceSettings", "voice_settings", "enableLogging", "enable_logging", "speed", "streaming", "dialogue", "musicLengthMs", "forceInstrumental", "compositionPlan", "durationSeconds", "promptInfluence", "loop":
                continue
            case "pronunciationDictionaryLocators":
                body["pronunciation_dictionary_locators"] = elevenLabsPronunciationLocators(value)
            case "previousText":
                body["previous_text"] = value
            case "nextText":
                body["next_text"] = value
            case "previousRequestIds":
                body["previous_request_ids"] = value
            case "nextRequestIds":
                body["next_request_ids"] = value
            case "applyTextNormalization":
                body["apply_text_normalization"] = value
            case "applyLanguageTextNormalization":
                body["apply_language_text_normalization"] = value
            default:
                body[key] = value
            }
        }

        let response = try await config.transport.send(config.request(
            path: "/v1/text-to-speech/\(voice)?\(queryString(query))",
            modelID: modelID,
            body: .object(body),
            headers: request.headers,
            abortSignal: request.abortSignal
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw audioProviderHTTPStatusError(provider: providerID, response: response)
        }
        return SpeechResult(
            audio: response.body,
            contentType: response.headers.contentType,
            warnings: warnings,
            providerMetadata: ["elevenlabs": .object(["outputFormat": .string(query["output_format"] ?? "mp3_44100_128")])],
            requestMetadata: AIRequestMetadata(body: .object(body), headers: request.headers),
            responseMetadata: aiResponseMetadata(response: response, modelID: modelID)
        )
    }
}

public final class ElevenLabsTranscriptionModel: TranscriptionModel, @unchecked Sendable {
    public let providerID = "elevenlabs.transcription"
    public let modelID: String
    private let config: ElevenLabsModelConfiguration

    public init(modelID: String, config: ElevenLabsModelConfiguration) {
        self.modelID = modelID
        self.config = config
    }

    public func transcribe(_ request: AudioTranscriptionRequest) async throws -> TranscriptionResult {
        let options = try elevenLabsProviderOptions(from: request)
        var form = MultipartFormData()
        form.appendField(name: "model_id", value: modelID)
        form.appendFile(name: "file", fileName: "audio.\(mediaTypeToExtension(request.mimeType))", mimeType: request.mimeType, data: request.audio)
        form.appendField(name: "diarize", value: String(options["diarize"]?.boolValue ?? true))
        if let language = options["languageCode"]?.stringValue ?? options["language_code"]?.stringValue {
            form.appendField(name: "language_code", value: language)
        }
        for (key, value) in options {
            guard let scalar = jsonScalarString(value) else { continue }
            switch key {
            case "languageCode", "language_code", "diarize":
                continue
            case "tagAudioEvents":
                form.appendField(name: "tag_audio_events", value: scalar)
            case "numSpeakers":
                form.appendField(name: "num_speakers", value: scalar)
            case "timestampsGranularity":
                form.appendField(name: "timestamps_granularity", value: scalar)
            case "fileFormat":
                form.appendField(name: "file_format", value: scalar)
            default:
                form.appendField(name: key, value: scalar)
            }
        }

        let response = try await config.transport.send(config.rawRequest(
            path: "/v1/speech-to-text",
            modelID: modelID,
            body: form.finalize(),
            contentType: "multipart/form-data; boundary=\(form.boundary)",
            headers: request.headers,
            abortSignal: request.abortSignal
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw audioProviderHTTPStatusError(provider: providerID, response: response)
        }
        let raw = try response.jsonValue()
        try elevenLabsValidateTranscriptionResponse(raw)
        let segments = elevenLabsTranscriptionSegments(from: raw)
        return TranscriptionResult(
            text: raw["text"]?.stringValue ?? "",
            rawValue: raw,
            segments: segments,
            language: raw["language_code"]?.stringValue,
            durationInSeconds: raw["audio_duration_secs"]?.doubleValue ?? elevenLabsTranscriptionDuration(from: raw),
            providerMetadata: raw["words"]?.arrayValue.map { ["elevenlabs": .object(["words": .array($0)])] } ?? [:],
            responseMetadata: aiResponseMetadata(from: raw, response: response, modelID: modelID)
        )
    }
}

func elevenLabsOutputFormat(_ outputFormat: String?) -> String {
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

private func elevenLabsProviderOptions(from extraBody: [String: JSONValue]) -> [String: JSONValue] {
    var output = extraBody
    if let nested = output.removeValue(forKey: "elevenlabs")?.objectValue {
        output.merge(nested) { _, nested in nested }
    }
    return output
}

func elevenLabsProviderOptions(from request: SpeechRequest) throws -> [String: JSONValue] {
    try elevenLabsProviderOptions(
        extraBody: request.extraBody,
        providerOptions: request.providerOptions,
        supportedProviderOptionKeys: elevenLabsSpeechProviderOptionKeys,
        validateProviderOptions: elevenLabsValidateSpeechProviderOptions
    )
}

private func elevenLabsProviderOptions(from request: AudioTranscriptionRequest) throws -> [String: JSONValue] {
    var output = elevenLabsProviderOptions(from: request.extraBody)
    if let value = request.providerOptions["elevenlabs"] {
        guard value != .null else { return output }
        guard let nested = value.objectValue else {
            throw AIError.invalidArgument(argument: "providerOptions.elevenlabs", message: "ElevenLabs provider options must be an object.")
        }
        output.merge(elevenLabsTranscriptionProviderOptionDefaults) { _, defaultValue in defaultValue }
        output.merge(try elevenLabsValidateTranscriptionProviderOptions(nested)) { _, providerValue in providerValue }
    }
    return output
}

private func elevenLabsProviderOptions(extraBody: [String: JSONValue], providerOptions: [String: JSONValue], supportedProviderOptionKeys: Set<String>, validateProviderOptions: ([String: JSONValue]) throws -> [String: JSONValue]) throws -> [String: JSONValue] {
    var output = elevenLabsProviderOptions(from: extraBody)
    if let value = providerOptions["elevenlabs"] {
        guard value != .null else { return output }
        guard let nested = value.objectValue else {
            throw AIError.invalidArgument(argument: "providerOptions.elevenlabs", message: "ElevenLabs provider options must be an object.")
        }
        let validated = try validateProviderOptions(nested)
        output.merge(validated.filter { supportedProviderOptionKeys.contains($0.key) }) { _, providerValue in providerValue }
    }
    return output
}

func elevenLabsValidateSpeechProviderOptions(_ options: [String: JSONValue]) throws -> [String: JSONValue] {
    var output: [String: JSONValue] = [:]
    for (key, value) in options where elevenLabsSpeechProviderOptionKeys.contains(key) {
        switch key {
        case "languageCode", "previousText", "nextText":
            try elevenLabsRequireString(value, argument: "providerOptions.elevenlabs.\(key)", message: "ElevenLabs \(key) must be a string.")
            output[key] = value
        case "voiceSettings":
            output[key] = try elevenLabsValidatedVoiceSettings(value)
        case "pronunciationDictionaryLocators":
            output[key] = try elevenLabsValidatedPronunciationLocators(value)
        case "seed":
            guard let number = value.doubleValue, number >= 0, number <= 4_294_967_295 else {
                throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.seed", message: "ElevenLabs seed must be a number between 0 and 4294967295.")
            }
            output[key] = value
        case "previousRequestIds", "nextRequestIds":
            output[key] = try elevenLabsStringArray(value, argument: "providerOptions.elevenlabs.\(key)", maxCount: 3)
        case "applyTextNormalization":
            guard let mode = value.stringValue, ["auto", "on", "off"].contains(mode) else {
                throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.applyTextNormalization", message: "ElevenLabs applyTextNormalization must be one of auto, on, off.")
            }
            output[key] = value
        case "applyLanguageTextNormalization", "enableLogging":
            try elevenLabsRequireBoolean(value, argument: "providerOptions.elevenlabs.\(key)", message: "ElevenLabs \(key) must be a boolean.")
            output[key] = value
        case "streaming", "dialogue", "inputs", "musicLengthMs", "forceInstrumental", "compositionPlan", "durationSeconds", "promptInfluence", "loop":
            output[key] = try elevenLabsValidateNewSpeechOption(key, value)
        default:
            break
        }
    }
    return output
}

private func elevenLabsValidateTranscriptionProviderOptions(_ options: [String: JSONValue]) throws -> [String: JSONValue] {
    var output: [String: JSONValue] = [:]
    for (key, value) in options where elevenLabsTranscriptionProviderOptionKeys.contains(key) {
        if value == .null {
            output[key] = value
            continue
        }
        switch key {
        case "languageCode":
            try elevenLabsRequireString(value, argument: "providerOptions.elevenlabs.languageCode", message: "ElevenLabs languageCode must be a string.")
        case "tagAudioEvents", "diarize":
            try elevenLabsRequireBoolean(value, argument: "providerOptions.elevenlabs.\(key)", message: "ElevenLabs \(key) must be a boolean.")
        case "numSpeakers":
            guard let number = value.doubleValue, elevenLabsIsInteger(number), number >= 1, number <= 32 else {
                throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.numSpeakers", message: "ElevenLabs numSpeakers must be an integer between 1 and 32.")
            }
        case "timestampsGranularity":
            guard let granularity = value.stringValue, ["none", "word", "character"].contains(granularity) else {
                throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.timestampsGranularity", message: "ElevenLabs timestampsGranularity must be one of none, word, character.")
            }
        case "fileFormat":
            guard let format = value.stringValue, ["pcm_s16le_16", "other"].contains(format) else {
                throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.fileFormat", message: "ElevenLabs fileFormat must be one of pcm_s16le_16, other.")
            }
        default:
            break
        }
        output[key] = value
    }
    return output
}

private let elevenLabsSpeechProviderOptionKeys: Set<String> = [
    "languageCode",
    "voiceSettings",
    "pronunciationDictionaryLocators",
    "seed",
    "previousText",
    "nextText",
    "previousRequestIds",
    "nextRequestIds",
    "applyTextNormalization",
    "applyLanguageTextNormalization",
    "enableLogging", "streaming", "dialogue", "inputs", "musicLengthMs", "forceInstrumental", "compositionPlan", "durationSeconds", "promptInfluence", "loop"
]

private let elevenLabsTranscriptionProviderOptionKeys: Set<String> = [
    "languageCode",
    "tagAudioEvents",
    "numSpeakers",
    "timestampsGranularity",
    "diarize",
    "fileFormat"
]

private let elevenLabsTranscriptionProviderOptionDefaults: [String: JSONValue] = [
    "tagAudioEvents": .bool(true),
    "timestampsGranularity": .string("word"),
    "diarize": .bool(false),
    "fileFormat": .string("other")
]

private func elevenLabsValidateTranscriptionResponse(_ raw: JSONValue) throws {
    if let duration = raw["audio_duration_secs"], duration != .null, duration.doubleValue == nil {
        throw AIError.invalidResponse(provider: "elevenlabs.transcription", message: "ElevenLabs audio_duration_secs must be a number or null.")
    }
    guard raw["language_code"]?.stringValue != nil else {
        throw AIError.invalidResponse(provider: "elevenlabs.transcription", message: "ElevenLabs transcription response did not contain a valid language_code.")
    }
    guard raw["language_probability"]?.doubleValue != nil else {
        throw AIError.invalidResponse(provider: "elevenlabs.transcription", message: "ElevenLabs transcription response did not contain a valid language_probability.")
    }
    guard raw["text"]?.stringValue != nil else {
        throw AIError.invalidResponse(provider: "elevenlabs.transcription", message: "ElevenLabs transcription response did not contain valid text.")
    }
    guard let words = raw["words"], words != .null else { return }
    guard let wordItems = words.arrayValue else {
        throw AIError.invalidResponse(provider: "elevenlabs.transcription", message: "ElevenLabs transcription response words must be an array.")
    }
    for (index, word) in wordItems.enumerated() {
        guard word["text"]?.stringValue != nil else {
            throw AIError.invalidResponse(provider: "elevenlabs.transcription", message: "ElevenLabs transcription response words[\(index)].text must be a string.")
        }
        guard let type = word["type"]?.stringValue, ["word", "spacing", "audio_event"].contains(type) else {
            throw AIError.invalidResponse(provider: "elevenlabs.transcription", message: "ElevenLabs transcription response words[\(index)].type is invalid.")
        }
        for key in ["start", "end"] {
            if let value = word[key], value != .null, value.doubleValue == nil {
                throw AIError.invalidResponse(provider: "elevenlabs.transcription", message: "ElevenLabs transcription response words[\(index)].\(key) must be a number or null.")
            }
        }
        if let speakerID = word["speaker_id"], speakerID != .null, speakerID.stringValue == nil {
            throw AIError.invalidResponse(provider: "elevenlabs.transcription", message: "ElevenLabs transcription response words[\(index)].speaker_id must be a string or null.")
        }
        guard let characters = word["characters"], characters != .null else { continue }
        guard let characterItems = characters.arrayValue else {
            throw AIError.invalidResponse(provider: "elevenlabs.transcription", message: "ElevenLabs transcription response words[\(index)].characters must be an array.")
        }
        for (characterIndex, character) in characterItems.enumerated() {
            guard character["text"]?.stringValue != nil else {
                throw AIError.invalidResponse(provider: "elevenlabs.transcription", message: "ElevenLabs transcription response words[\(index)].characters[\(characterIndex)].text must be a string.")
            }
            for key in ["start", "end"] {
                if let value = character[key], value != .null, value.doubleValue == nil {
                    throw AIError.invalidResponse(provider: "elevenlabs.transcription", message: "ElevenLabs transcription response words[\(index)].characters[\(characterIndex)].\(key) must be a number or null.")
                }
            }
        }
    }
}

private func elevenLabsSpeechWarnings(for request: SpeechRequest) -> [AIWarning] {
    guard request.instructions != nil else { return [] }
    return [
        AIWarning(
            type: "unsupported",
            feature: "instructions",
            message: "ElevenLabs speech models do not support instructions. Instructions parameter was ignored."
        )
    ]
}

func elevenLabsVoiceSettings(_ value: JSONValue) -> JSONValue {
    guard let settings = value.objectValue else { return value }
    var mapped: [String: JSONValue] = [:]
    for (key, item) in settings {
        switch key {
        case "similarityBoost":
            mapped["similarity_boost"] = item
        case "useSpeakerBoost":
            mapped["use_speaker_boost"] = item
        default:
            mapped[key] = item
        }
    }
    return .object(mapped)
}

private func elevenLabsValidatedVoiceSettings(_ value: JSONValue) throws -> JSONValue {
    guard let settings = value.objectValue else {
        throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.voiceSettings", message: "ElevenLabs voiceSettings must be an object.")
    }
    var output: [String: JSONValue] = [:]
    for key in ["stability", "similarityBoost", "style"] {
        if let setting = settings[key] {
            guard let number = setting.doubleValue, number >= 0, number <= 1 else {
                throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.voiceSettings.\(key)", message: "ElevenLabs voiceSettings.\(key) must be a number between 0 and 1.")
            }
            output[key] = setting
        }
    }
    if let useSpeakerBoost = settings["useSpeakerBoost"] {
        guard useSpeakerBoost.boolValue != nil else {
            throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.voiceSettings.useSpeakerBoost", message: "ElevenLabs voiceSettings.useSpeakerBoost must be a boolean.")
        }
        output["useSpeakerBoost"] = useSpeakerBoost
    }
    return .object(output)
}

func elevenLabsPronunciationLocators(_ value: JSONValue) -> JSONValue {
    guard let array = value.arrayValue else { return value }
    return .array(array.map { item in
        guard let object = item.objectValue else { return item }
        var mapped: [String: JSONValue] = [:]
        for (key, value) in object {
            switch key {
            case "pronunciationDictionaryId":
                mapped["pronunciation_dictionary_id"] = value
            case "versionId":
                mapped["version_id"] = value
            default:
                mapped[key] = value
            }
        }
        return .object(mapped)
    })
}

private func elevenLabsValidatedPronunciationLocators(_ value: JSONValue) throws -> JSONValue {
    guard let array = value.arrayValue, array.count <= 3 else {
        throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.pronunciationDictionaryLocators", message: "ElevenLabs pronunciationDictionaryLocators must be an array with at most 3 items.")
    }
    return .array(try array.enumerated().map { index, item in
        guard let object = item.objectValue else {
            throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.pronunciationDictionaryLocators[\(index)]", message: "ElevenLabs pronunciationDictionaryLocators items must be objects.")
        }
        guard let pronunciationDictionaryID = object["pronunciationDictionaryId"], pronunciationDictionaryID.stringValue != nil else {
            throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.pronunciationDictionaryLocators[\(index)].pronunciationDictionaryId", message: "ElevenLabs pronunciationDictionaryId must be a string.")
        }
        var output: [String: JSONValue] = ["pronunciationDictionaryId": pronunciationDictionaryID]
        if let versionID = object["versionId"] {
            guard versionID.stringValue != nil else {
                throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.pronunciationDictionaryLocators[\(index)].versionId", message: "ElevenLabs versionId must be a string.")
            }
            output["versionId"] = versionID
        }
        return .object(output)
    })
}

private func elevenLabsStringArray(_ value: JSONValue, argument: String, maxCount: Int) throws -> JSONValue {
    guard let array = value.arrayValue, array.count <= maxCount else {
        throw AIError.invalidArgument(argument: argument, message: "ElevenLabs \(argument) must be an array of strings with at most \(maxCount) items.")
    }
    for item in array where item.stringValue == nil {
        throw AIError.invalidArgument(argument: argument, message: "ElevenLabs \(argument) values must be strings.")
    }
    return value
}

private func elevenLabsRequireString(_ value: JSONValue, argument: String, message: String) throws {
    guard value.stringValue != nil else {
        throw AIError.invalidArgument(argument: argument, message: message)
    }
}

private func elevenLabsRequireBoolean(_ value: JSONValue, argument: String, message: String) throws {
    guard value.boolValue != nil else {
        throw AIError.invalidArgument(argument: argument, message: message)
    }
}

private func elevenLabsIsInteger(_ value: Double) -> Bool {
    value.isFinite && value.rounded(.towardZero) == value
}