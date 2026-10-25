import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities


extension ElevenLabsSpeechModel {
    public func stream(_ request: StreamingSpeechRequest) async throws -> StreamingSpeechModelResult {
        do {
            try request.abortSignal?.throwIfAborted()
            guard !modelID.hasPrefix("music_"), !modelID.hasPrefix("eleven_text_to_sound") else {
                throw AIError.invalidArgument(argument: "model", message: "ElevenLabs music and sound effects models do not support streaming speech.")
            }
            let options = try elevenLabsValidateSpeechProviderOptions(request.providerOptions["elevenlabs"]?.objectValue ?? [:])
            if let raw = request.providerOptions["elevenlabs"], raw != .null, raw.objectValue == nil {
                throw AIError.invalidArgument(argument: "providerOptions.elevenlabs", message: "ElevenLabs options must be an object.")
            }
            let streaming = options["streaming"]?.objectValue ?? [:]
            let dialogue = options["dialogue"]?.objectValue
            let dialogueModel = modelID.hasPrefix("eleven_v3") || modelID.hasPrefix("eleven_v4")
            if dialogue != nil && !dialogueModel { throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.dialogue", message: "ElevenLabs dialogue requires an eleven_v3 or eleven_v4 model.") }
            if dialogueModel && dialogue == nil { throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.dialogue", message: "ElevenLabs v3/v4 streaming speech requires dialogue options.") }
            let voices = dialogue?["voices"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if modelID == "eleven_v3_conversational", voices.count != 1 { throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.dialogue.voices", message: "eleven_v3_conversational requires exactly one voice.") }
            let voice = request.voice ?? voices.first ?? "21m00Tcm4TlvDq8ikWAM"
            if dialogue != nil, !voices.contains(voice) { throw AIError.invalidArgument(argument: "voice", message: "The streaming voice must be listed in dialogue.voices.") }
            let locators = options["pronunciationDictionaryLocators"]?.arrayValue
            if locators?.contains(where: { $0["versionId"]?.stringValue?.isEmpty != false }) == true {
                throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.pronunciationDictionaryLocators", message: "Streaming speech requires a versionId for every pronunciation dictionary.")
            }
            let output = try streaming["outputFormat"]?.stringValue ?? elevenLabsStreamOutputFormat(request.outputFormat)
            let path = dialogue != nil ? "/v1/text-to-dialogue/stream-input" : "/v1/text-to-speech/\(encodePathSegment(voice))/stream-input"
            guard var url = URLComponents(string: config.baseURL + path) else { throw AIError.invalidURL(config.baseURL) }
            if url.scheme == "https" { url.scheme = "wss" } else if url.scheme == "http" { url.scheme = "ws" }
            var query: [String: String] = ["model_id": modelID, "output_format": output]
            query["language_code"] = request.language ?? options["languageCode"]?.stringValue
            for (key, value) in [("enable_logging", options["enableLogging"]), ("sync_alignment", streaming["syncAlignment"]),
                                  ("apply_text_normalization", options["applyTextNormalization"]), ("seed", options["seed"])] { if let value { query[key] = jsonScalarString(value) } }
            if dialogue == nil {
                for (key, value) in [("inactivity_timeout", streaming["inactivityTimeout"]), ("auto_mode", streaming["autoMode"]), ("enable_ssml_parsing", streaming["enableSsmlParsing"])] { if let value { query[key] = jsonScalarString(value) } }
            }
            url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let socketURL = url.url else { throw AIError.invalidURL(config.baseURL) }
            let voiceSettings = options["voiceSettings"]?.objectValue ?? [:]
            var initial: [String: JSONValue] = [:]
            if let locators { initial["pronunciation_dictionary_locators"] = elevenLabsPronunciationLocators(.array(locators)) }
            if let dialogue {
                initial["voices"] = dialogue["voices"]
                initial["voice_settings"] = dialogue["voiceSettings"]
            } else {
                initial["text"] = " "
                var settings = elevenLabsVoiceSettings(.object(voiceSettings)).objectValue ?? [:]
                if let speed = request.speed { settings["speed"] = .number(speed) }
                if !settings.isEmpty { initial["voice_settings"] = .object(settings) }
                if let schedule = streaming["chunkLengthSchedule"] { initial["generation_config"] = .object(["chunk_length_schedule": schedule]) }
            }
            var headers = normalizeHeaders(config.headers.mergingHeaders(request.headers))
            let key = headers.removeValue(forKey: "xi-api-key")
            let reportedInitial = JSONValue.object(initial)
            if let key { initial[dialogue == nil ? "xi-api-key" : "xi_api_key"] = .string(key) }
            let connection = try await webSocketTransport.connect(.init(url: socketURL, headers: headers, abortSignal: request.abortSignal))
            let state = ElevenSpeechState(dialogue: dialogue != nil, incremental: modelID.hasPrefix("eleven_v4"), voice: voice, voices: voices)
            var warnings: [AIWarning] = []
            if request.instructions != nil { warnings.append(AIWarning(type: "unsupported", feature: "instructions", message: "ElevenLabs streaming speech ignores instructions.")) }
            let ignored = ["applyLanguageTextNormalization", "inputs", "nextRequestIds", "nextText", "previousRequestIds", "previousText", "musicLengthMs", "forceInstrumental", "compositionPlan", "durationSeconds", "promptInfluence", "loop"]
            for key in ignored where options[key] != nil { warnings.append(elevenLabsIgnoredWarning(key)) }
            if dialogue != nil {
                if request.speed != nil { warnings.append(AIWarning(type: "unsupported", feature: "speed", message: "Streaming dialogue ignores speed.")) }
                if options["voiceSettings"] != nil { warnings.append(elevenLabsIgnoredWarning("voiceSettings")) }
                for key in ["autoMode", "chunkLengthSchedule", "enableSsmlParsing", "inactivityTimeout"] where streaming[key] != nil { warnings.append(elevenLabsIgnoredWarning("streaming." + key)) }
            }
            let format = elevenLabsAudioFormat(output)
            let includeRaw = request.includeRawChunks
            let keepalive = dialogue != nil || streaming["inactivityTimeout"] == nil
            let session = SpeechSocketSession(connection: connection, input: request.text, abortSignal: request.abortSignal,
                                              startFrame: .object(initial), initialParts: [.streamStart(warnings: warnings)],
                                              keepaliveFrame: keepalive ? (dialogue != nil ? .object(["keep_alive": true]) : .object(["text": " "])) : nil,
                                              decode: { text in try state.decode(text, format: format, raw: includeRaw) }, inputPump: { session in
                try await state.sendText(request.text, session: session)
            })
            return .init(stream: session.makeStream(), requestMetadata: .init(body: .object(["url": .string(socketURL.absoluteString), "initMessage": reportedInitial])),
                         responseMetadata: .init(timestamp: Date(), modelID: modelID), cancel: { session.cancel() })
        } catch { request.text.cancelFromConsumer(); throw error }
    }
}


private final class ElevenSpeechState: @unchecked Sendable {
    let dialogue: Bool; let incremental: Bool; let voice: String; let voices: [String]
    private let lock = NSLock(); private var characters = 0
    init(dialogue: Bool, incremental: Bool, voice: String, voices: [String]) { self.dialogue = dialogue; self.incremental = incremental; self.voice = voice; self.voices = voices }

    func sendText(_ input: AIStreamingTextInput, session: SpeechSocketSession) async throws {
        var held = ""; var heldVoice = voice; var heldTurn = false
        var previousVoice: String?; var buffered: [JSONValue] = []
        func emit(_ text: String, voice: String, newTurn: Bool) async throws {
            guard !text.isEmpty else { return }
            lock.withLock { characters += text.unicodeScalars.count }
            if !dialogue { try await session.send(.object(["text": .string(text)])); return }
            let turn = previousVoice != nil && (previousVoice != voice || newTurn)
            previousVoice = voice
            let part: JSONValue = .object(["text": .string(text), "voice_id": .string(voice), "new_turn": turn ? .bool(true) : nil])
            if incremental { try await session.send(.object(["inputs": .array([part])])) } else { buffered.append(part) }
        }
        for try await part in input {
            let selected = part.voice ?? voice
            guard dialogue ? voices.contains(selected) : selected == voice else { throw AIError.invalidArgument(argument: "text", message: "The requested text-part voice is unavailable on this speech stream.") }
            let rawTurn = part.providerOptions["elevenlabs"]?["newTurn"]
            if let rawTurn, rawTurn != .null, rawTurn.boolValue == nil { throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.newTurn", message: "newTurn must be a boolean.") }
            let newTurn = rawTurn?.boolValue == true
            if selected != heldVoice || newTurn { try await emit(held, voice: heldVoice, newTurn: heldTurn); held = ""; heldTurn = newTurn }
            heldVoice = selected
            if held.isEmpty && newTurn { heldTurn = true }
            let split = elevenLabsCompleteWords(held + part.text)
            if !split.send.isEmpty { try await emit(split.send, voice: selected, newTurn: heldTurn); heldTurn = false }
            held = split.hold
        }
        try await emit(held, voice: heldVoice, newTurn: heldTurn)
        if dialogue { try await session.send(incremental ? .object(["close_socket": true]) : .object(["inputs": .array(buffered), "close_socket": true])) }
        else { try await session.send(.object(["text": ""])) }
    }

    func decode(_ text: String, format: AIStreamingAudioFormat, raw: Bool) throws -> [StreamingSpeechPart] {
        guard let value = try? secureJSONParse(text), value.objectValue != nil else { return [] }
        var parts: [StreamingSpeechPart] = raw ? [.raw(value)] : []
        if let error = value["error"], error != .null {
            throw AIStreamingSpeechError(provider: "elevenlabs", message: "ElevenLabs speech stream error: " + (value["message"]?.stringValue ?? error.stringValue ?? String(describing: error)), rawValue: value)
        }
        if let message = value["message"]?.stringValue, value["isFinal"]?.boolValue != true, value["audio"]?.stringValue == nil {
            throw AIStreamingSpeechError(provider: "elevenlabs", message: "ElevenLabs speech stream error: " + message, rawValue: value)
        }
        var metadata: [String: JSONValue] = [:]
        if let alignment = value["alignment"], alignment != .null {
            if dialogue {
                metadata["alignment"] = .object(["chars": alignment["chars"], "charStartTimesMs": alignment["char_start_times_ms"], "charDurationsMs": alignment["char_durations_ms"]])
            } else { metadata["alignment"] = alignment }
        }
        if let alignment = value["normalizedAlignment"], alignment != .null { metadata["normalizedAlignment"] = alignment }
        let finalTurn = value["is_final_audio_for_turn"]?.boolValue == true
        if finalTurn { metadata["isFinalAudioForTurn"] = .bool(true) }
        if let encoded = value["audio"]?.stringValue, !encoded.isEmpty {
            guard let bytes = Data(base64Encoded: encoded) else { throw AIStreamingSpeechError(provider: "elevenlabs", message: "Invalid base64 speech audio.") }
            parts.append(.audio(audio: bytes, audioFormat: format, providerMetadata: metadata.isEmpty ? [:] : ["elevenlabs": .object(metadata)]))
        } else if finalTurn { parts.append(.audio(audio: Data(), audioFormat: format, providerMetadata: ["elevenlabs": .object(metadata)])) }
        if value["isFinal"]?.boolValue == true || value["is_final"]?.boolValue == true { parts.append(.finish(usage: ["inputCharacters": .number(Double(lock.withLock { characters }))])) }
        return parts
    }
}

func elevenLabsCompleteWords(_ value: String) -> (send: String, hold: String) {
    let scalars = Array(value.unicodeScalars)
    if let boundary = scalars.lastIndex(where: { CharacterSet.whitespacesAndNewlines.contains($0) || "。、！？，；：".unicodeScalars.contains($0) }) {
        return (String(String.UnicodeScalarView(scalars[...boundary])), String(String.UnicodeScalarView(scalars.dropFirst(boundary + 1))))
    }
    return scalars.count >= 100 ? (value, "") : ("", value)
}

func elevenLabsStreamOutputFormat(_ format: AIStreamingAudioFormat?) throws -> String {
    guard let format else { return "mp3_44100_128" }
    let type = format.mediaType.split(separator: ";")[0].trimmingCharacters(in: .whitespaces).lowercased(); let rate = format.sampleRate
    switch type {
    case "audio/mpeg", "audio/mp3": if rate == nil || rate == 44100 { return "mp3_44100_128" }; if rate == 22050 { return "mp3_22050_32" }
    case "audio/pcm", "audio/l16": if [8000, 16000, 22050, 24000, 44100, 48000].contains(rate ?? 24000) { return "pcm_\(rate ?? 24000)" }
    case "audio/pcmu", "audio/basic": if rate == nil || rate == 8000 { return "ulaw_8000" }
    case "audio/pcma": if rate == nil || rate == 8000 { return "alaw_8000" }
    case "audio/opus", "audio/ogg": if rate == nil || rate == 48000 { return "opus_48000_64" }
    default: break
    }
    throw AIError.invalidArgument(argument: "outputFormat", message: "Unsupported ElevenLabs streaming audio format; use streaming.outputFormat for a native format.")
}

func elevenLabsAudioFormat(_ output: String) -> AIStreamingAudioFormat {
    let pieces = output.split(separator: "_"); let rate = pieces.count > 1 ? Int(pieces[1]) : nil
    let types = ["mp3": "audio/mpeg", "pcm": "audio/pcm", "ulaw": "audio/pcmu", "alaw": "audio/pcma", "opus": "audio/ogg", "wav": "audio/wav"]
    guard let type = pieces.first.flatMap({ types[String($0)] }) else { return .init(mediaType: "application/octet-stream") }
    return .init(mediaType: type, sampleRate: rate)
}

func elevenLabsIgnoredWarning(_ key: String) -> AIWarning {
    .init(type: "unsupported", feature: "providerOptions.elevenlabs." + key, message: "ElevenLabs ignores \(key) for this speech operation.")
}

func elevenLabsValidateNewSpeechOption(_ key: String, _ value: JSONValue) throws -> JSONValue {
    func invalid() -> AIError { .invalidArgument(argument: "providerOptions.elevenlabs." + key, message: "Invalid ElevenLabs \(key) option.") }
    func number(_ value: JSONValue?, _ min: Double, _ max: Double, integer: Bool = false) -> Bool {
        guard let number = value?.doubleValue else { return false }
        return number.isFinite && number >= min && number <= max && (!integer || number.rounded() == number)
    }
    switch key {
    case "forceInstrumental", "loop": guard value.boolValue != nil else { throw invalid() }; return value
    case "musicLengthMs": guard number(value, 3000, 600000, integer: true) else { throw invalid() }; return value
    case "durationSeconds": guard number(value, 0.5, 30) else { throw invalid() }; return value
    case "promptInfluence": guard number(value, 0, 1) else { throw invalid() }; return value
    case "streaming":
        guard let object = value.objectValue else { throw invalid() }; var result: [String: JSONValue] = [:]
        for key in ["autoMode", "enableSsmlParsing", "syncAlignment"] { if let item = object[key] { guard item.boolValue != nil else { throw invalid() }; result[key] = item } }
        if let item = object["inactivityTimeout"] { guard number(item, 1, 180, integer: true) else { throw invalid() }; result["inactivityTimeout"] = item }
        if let item = object["outputFormat"] { guard let string = item.stringValue, !string.isEmpty else { throw invalid() }; result["outputFormat"] = item }
        if let item = object["chunkLengthSchedule"] { guard let array = item.arrayValue, !array.isEmpty, array.allSatisfy({ number($0, 50, 500) }) else { throw invalid() }; result["chunkLengthSchedule"] = item }
        return .object(result)
    case "dialogue":
        guard let object = value.objectValue, let voices = object["voices"]?.arrayValue, !voices.isEmpty, voices.count <= 10,
              voices.allSatisfy({ $0.stringValue?.isEmpty == false }) else { throw invalid() }
        var result: [String: JSONValue] = ["voices": .array(voices)]
        if let item = object["voiceSettings"] {
            guard let settings = item.objectValue else { throw invalid() }
            if let stability = settings["stability"] { guard number(stability, 0, 1) else { throw invalid() }; result["voiceSettings"] = .object(["stability": stability]) }
            else { result["voiceSettings"] = .object([:]) }
        }
        return .object(result)
    case "inputs":
        guard let inputs = value.arrayValue, !inputs.isEmpty else { throw invalid() }
        return .array(try inputs.map { input in
            guard let text = input["text"]?.stringValue, !text.isEmpty, let voice = input["voiceId"]?.stringValue, !voice.isEmpty else { throw invalid() }
            return .object(["text": .string(text), "voiceId": .string(voice)])
        })
    case "compositionPlan": return try elevenLabsCompositionPlan(value)
    default: return value
    }
}

private func elevenLabsCompositionPlan(_ value: JSONValue) throws -> JSONValue {
    func invalid() -> AIError { .invalidArgument(argument: "providerOptions.elevenlabs.compositionPlan", message: "Invalid ElevenLabs music composition plan.") }
    func strings(_ value: JSONValue?) -> Bool { value?.arrayValue?.allSatisfy { $0.stringValue != nil } == true }
    func duration(_ value: JSONValue?) -> Bool { guard let x = value?.doubleValue else { return false }; return x.isFinite && x.rounded() == x && x >= 3000 && x <= 120000 }
    func range(_ value: JSONValue?) -> JSONValue? {
        guard let value, let start = value["start_ms"]?.doubleValue, let end = value["end_ms"]?.doubleValue,
              start.isFinite, end.isFinite, start >= 0, end >= 0, start.rounded() == start, end.rounded() == end else { return nil }
        return .object(["start_ms": .number(start), "end_ms": .number(end)])
    }
    func reference(_ value: JSONValue) -> JSONValue? {
        guard let song = value["song_id"]?.stringValue, let range = range(value["range"]) else { return nil }
        return .object(["song_id": .string(song), "range": range])
    }
    guard let object = value.objectValue else { throw invalid() }
    if let sections = object["sections"]?.arrayValue, strings(object["positive_global_styles"]), strings(object["negative_global_styles"]) {
        let normalized = try sections.map { section -> JSONValue in
            guard let name = section["section_name"]?.stringValue, (1...100).contains(name.utf16.count),
                  strings(section["positive_local_styles"]), strings(section["negative_local_styles"]), duration(section["duration_ms"]),
                  let lines = section["lines"]?.arrayValue, lines.count <= 30, lines.allSatisfy({ $0.stringValue.map { $0.utf16.count <= 200 } == true }) else { throw invalid() }
            var output: [String: JSONValue] = ["section_name": .string(name), "positive_local_styles": section["positive_local_styles"]!,
                                               "negative_local_styles": section["negative_local_styles"]!, "duration_ms": section["duration_ms"]!, "lines": .array(lines)]
            if let source = section["source_from"] {
                if source == .null { output["source_from"] = .null }
                else {
                    guard var ref = reference(source)?.objectValue else { throw invalid() }
                    if let negatives = source["negative_ranges"] {
                        guard let values = negatives.arrayValue else { throw invalid() }
                        ref["negative_ranges"] = .array(try values.map { guard let normalized = range($0) else { throw invalid() }; return normalized })
                    }
                    output["source_from"] = .object(ref)
                }
            }
            return .object(output)
        }
        return .object(["positive_global_styles": object["positive_global_styles"]!, "negative_global_styles": object["negative_global_styles"]!, "sections": .array(normalized)])
    }
    guard let chunks = object["chunks"]?.arrayValue else { throw invalid() }
    return .object(["chunks": .array(try chunks.map { chunk -> JSONValue in
        if let text = chunk["text"]?.stringValue, duration(chunk["duration_ms"]), strings(chunk["positive_styles"]) {
            var normalized: [String: JSONValue] = ["text": .string(text), "duration_ms": chunk["duration_ms"]!, "positive_styles": chunk["positive_styles"]!]
            if let styles = chunk["negative_styles"] { guard strings(styles) else { throw invalid() }; normalized["negative_styles"] = styles }
            if let adherence = chunk["context_adherence"] { guard ["low", "medium", "high"].contains(adherence.stringValue ?? "") else { throw invalid() }; normalized["context_adherence"] = adherence }
            if let strength = chunk["condition_strength"] { guard strength == .null || ["low", "medium", "high", "xhigh"].contains(strength.stringValue ?? "") else { throw invalid() }; normalized["condition_strength"] = strength }
            if let ref = chunk["conditioning_ref"] { guard ref == .null || reference(ref) != nil else { throw invalid() }; normalized["conditioning_ref"] = ref == .null ? .null : reference(ref) }
            return .object(normalized)
        }
        guard let ref = reference(chunk) else { throw invalid() }; return ref
    })])
}

func elevenLabsSpecialSpeech(model: ElevenLabsSpeechModel, request: SpeechRequest, options: [String: JSONValue]) async throws -> SpeechResult {
    let music = model.modelID.hasPrefix("music_")
    let effects = model.modelID.hasPrefix("eleven_text_to_sound")
    let output = elevenLabsOutputFormat(request.format)
    var query = ["output_format": output]
    if let logging = options["enableLogging"]?.boolValue { query["enable_logging"] = String(logging) }
    var warnings: [AIWarning] = []; var duration: Double?
    var body: [String: JSONValue] = ["model_id": .string(model.modelID)]
    let path: String
    let ttsOnly = ["applyLanguageTextNormalization", "applyTextNormalization", "dialogue", "inputs", "languageCode", "nextRequestIds", "nextText", "previousRequestIds", "previousText", "pronunciationDictionaryLocators", "streaming", "voiceSettings"]
    let musicOnly = ["compositionPlan", "forceInstrumental", "musicLengthMs"]
    let soundOnly = ["durationSeconds", "loop", "promptInfluence"]
    if music || effects {
        for (key, hasValue) in [("instructions", request.instructions != nil), ("language", request.language != nil), ("speed", request.speed != nil), ("voice", request.voice != nil)] where hasValue {
            warnings.append(AIWarning(type: "unsupported", feature: key, message: "ElevenLabs audio generation ignores \(key)."))
        }
        for key in ttsOnly + (music ? soundOnly : musicOnly + ["seed"]) where options[key] != nil { warnings.append(elevenLabsIgnoredWarning(key)) }
        if music {
            path = "/v1/music"
            if let plan = options["compositionPlan"] {
                guard options["musicLengthMs"] == nil, options["forceInstrumental"] == nil else { throw AIError.invalidArgument(argument: "providerOptions.elevenlabs", message: "Music compositionPlan cannot be combined with musicLengthMs or forceInstrumental.") }
                body["composition_plan"] = plan
                if !request.text.isEmpty { warnings.append(.init(type: "other", message: "ElevenLabs compositionPlan replaces the text prompt.")) }
                let parts = plan["sections"]?.arrayValue ?? plan["chunks"]?.arrayValue ?? []
                let durations = parts.map { $0["duration_ms"]?.doubleValue ?? (($0["range"]?["end_ms"]?.doubleValue ?? 0) - ($0["range"]?["start_ms"]?.doubleValue ?? 0)) }
                if !durations.isEmpty && durations.allSatisfy({ $0 > 0 }) { duration = durations.reduce(0, +) }
            } else { body["prompt"] = .string(request.text); duration = options["musicLengthMs"]?.doubleValue }
            for (key, wire) in [("musicLengthMs", "music_length_ms"), ("forceInstrumental", "force_instrumental"), ("seed", "seed")] { body[wire] = options[key] }
        } else {
            path = "/v1/sound-generation"; body["text"] = .string(request.text)
            for (key, wire) in [("durationSeconds", "duration_seconds"), ("promptInfluence", "prompt_influence"), ("loop", "loop")] { body[wire] = options[key] }
            duration = options["durationSeconds"]?.doubleValue.map { $0 * 1000 }
        }
    } else {
        guard model.modelID.hasPrefix("eleven_v3") || model.modelID.hasPrefix("eleven_v4") else { throw AIError.invalidArgument(argument: "providerOptions.elevenlabs.inputs", message: "ElevenLabs dialogue requires an eleven_v3 or eleven_v4 model.") }
        path = "/v1/text-to-dialogue"
        body["inputs"] = options["inputs"]?.arrayValue.map { .array($0.map { .object(["text": $0["text"], "voice_id": $0["voiceId"]]) }) }
        if !request.text.isEmpty { warnings.append(.init(type: "other", message: "ElevenLabs dialogue inputs replace the text prompt.")) }
        for (key, hasValue) in [("instructions", request.instructions != nil), ("speed", request.speed != nil), ("voice", request.voice != nil)] where hasValue { warnings.append(.init(type: "unsupported", feature: key, message: "ElevenLabs dialogue ignores \(key).")) }
        for key in ["streaming", "dialogue", "applyLanguageTextNormalization"] + musicOnly + soundOnly where options[key] != nil { warnings.append(elevenLabsIgnoredWarning(key)) }
        let settings = options["voiceSettings"]?.objectValue ?? [:]
        for key in ["style", "useSpeakerBoost"] where settings[key] != nil { warnings.append(elevenLabsIgnoredWarning("voiceSettings." + key)) }
        let wireSettings: [String: JSONValue] = .init(uniqueKeysWithValues: [("stability", settings["stability"]), ("similarity", settings["similarityBoost"])].compactMap { key, value in value.map { (key, $0) } })
        if !wireSettings.isEmpty { body["settings"] = .object(wireSettings) }
        body["language_code"] = (request.language ?? options["languageCode"]?.stringValue).map(JSONValue.string)
        for (key, wire) in [("previousText", "previous_text"), ("nextText", "future_text"), ("seed", "seed"), ("applyTextNormalization", "apply_text_normalization"), ("previousRequestIds", "previous_request_ids"), ("nextRequestIds", "next_request_ids")] { body[wire] = options[key] }
        if let locators = options["pronunciationDictionaryLocators"] { body["pronunciation_dictionary_locators"] = elevenLabsPronunciationLocators(locators) }
    }
    let response = try await model.config.transport.send(model.config.request(path: path + "?" + queryString(query), modelID: model.modelID,
                                                                             body: .object(body), headers: request.headers, abortSignal: request.abortSignal))
    guard (200..<300).contains(response.statusCode) else { throw audioProviderHTTPStatusError(provider: model.providerID, response: response) }
    return SpeechResult(audio: response.body, contentType: response.headers.contentType, warnings: warnings,
                        providerMetadata: ["elevenlabs": .object(["outputFormat": .string(output), "requestedDurationMs": duration.map(JSONValue.number)])],
                        requestMetadata: .init(body: .object(body), headers: request.headers), responseMetadata: aiResponseMetadata(response: response, modelID: model.modelID))
}