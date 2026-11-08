import Foundation
import QuillNoteCore

/// The note detail meta line's tags, shared with the iPhone (#697).
@main
struct NoteMetaTagsTests {
    static func main() {
        let local = NoteMetaTags(
            isAudioOnly: false, usedLocalTranscription: true, usedContextCapture: false,
            usedPostProcessing: true, languageCode: "ko"
        )
        precondition(local.tags.map(\.label) == [.verbatim("LOCAL"), .verbatim("NO CTX"), .verbatim("LLM"), .verbatim("KO")])
        precondition(local.tags.map(\.isActive) == [true, false, true, true])
        precondition(local.tags.map(\.helpKey) == [
            "Local transcription", "Context capture disabled", "LLM post-processing enabled", "Transcription language"
        ])
        precondition(local.tags.last?.spoken == .transcriptionLanguage("KO"))
        precondition(local.tags.first?.spoken == .key("Local transcription"))

        let cloud = NoteMetaTags(
            isAudioOnly: false, usedLocalTranscription: false, usedContextCapture: true,
            usedPostProcessing: false, languageCode: "auto"
        )
        precondition(cloud.tags.map(\.label) == [.verbatim("CLOUD"), .verbatim("CTX"), .verbatim("NO LLM")])
        precondition(cloud.tags.map(\.isActive) == [false, true, false])

        let audioOnly = NoteMetaTags(
            isAudioOnly: true, usedLocalTranscription: false, usedContextCapture: false,
            usedPostProcessing: false, languageCode: nil
        )
        precondition(audioOnly.tags.first?.label == .key("Audio only"))
        precondition(audioOnly.tags.first?.spoken == .key("Audio-only recording"))
        precondition(audioOnly.tags.count == 3)

        precondition(NoteMetaTags.languageTag(" en ") == "EN")
        precondition(NoteMetaTags.languageTag("") == nil)
        precondition(NoteMetaTags.languageTag("  ") == nil)
        precondition(NoteMetaTags.languageTag("auto") == nil)
        precondition(NoteMetaTags.languageTag(nil) == nil)
        // Every key any tag can use is in `allCopyKeys`, which the catalog
        // test checks.
        var produced = Set<String>()
        for flags in 0..<16 {
            let tags = NoteMetaTags(
                isAudioOnly: flags & 1 != 0, usedLocalTranscription: flags & 2 != 0,
                usedContextCapture: flags & 4 != 0, usedPostProcessing: flags & 8 != 0, languageCode: "ko"
            ).tags
            for tag in tags {
                produced.insert(tag.helpKey)
                if case .key(let key) = tag.label { produced.insert(key) }
                switch tag.spoken {
                case .key(let key): produced.insert(key)
                case .transcriptionLanguage: produced.insert(NoteMetaTags.Spoken.transcriptionLanguageFormatKey)
                }
            }
        }
        precondition(produced == Set(NoteMetaTags.allCopyKeys), "allCopyKeys matches the keys the tags use")
        print("NoteMetaTagsTests passed")
    }
}
