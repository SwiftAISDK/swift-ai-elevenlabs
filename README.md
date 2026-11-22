<!-- Generated distribution; edit the canonical repository. -->
# swift-ai-elevenlabs 1.3.1

Independent Swift-native port of Vercel AI SDK. Source and upstream dispositions are in PROVENANCE.json and Porting/.

## Distribution manifest

Add this package to your SwiftPM dependencies:

```swift
.package(url: "https://github.com/SwiftAISDK/swift-ai-elevenlabs.git", from: "1.3.1")
```

Products: `SwiftAIElevenLabs`.
Contribute and report issues in the canonical SwiftAISDK repository.

## Authored usage guide

# ElevenLabs for Swift

`SwiftAIElevenLabs` adds ElevenLabs to [SwiftAISDK](https://github.com/SwiftAISDK/SwiftAISDK), an independent Swift port of the Vercel AI SDK. It ports `@ai-sdk/elevenlabs` and supports transcription, speech, audio generation, audio transformation and dubbing.

Provider guide with models, options, streaming and errors:

- [ElevenLabs](https://swiftaisdk.github.io/SwiftAISDK/providers/elevenlabs/)

## Usage

Add the `SwiftAI` product from `swift-ai-core` and the `SwiftAIElevenLabs` product from this package to your target, then create the provider:

```swift
import SwiftAI
import SwiftAIElevenLabs

let provider = try AIProviders.elevenLabs(configuration: ElevenLabsProviderSettings())
```

By default the provider reads `ELEVENLABS_API_KEY` from the environment; values set in `ElevenLabsProviderSettings` take precedence.

To use every provider through one dependency, add the complete [SwiftAISDK](https://github.com/SwiftAISDK/SwiftAISDK) package instead; see [Install](https://swiftaisdk.github.io/SwiftAISDK/getting-started/install/).

## Contributing

This package is exported from `Packages/swift-ai-elevenlabs` in the canonical [SwiftAISDK](https://github.com/SwiftAISDK/SwiftAISDK) repository. Open issues and pull requests there.
