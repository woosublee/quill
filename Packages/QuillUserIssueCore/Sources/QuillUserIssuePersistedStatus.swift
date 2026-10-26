import Foundation

/// The issue record as one status string (`user-issue:v1:` and base64url
/// JSON with sorted keys), stored in a note's post-processing status and
/// synced with it.
public enum QuillUserIssuePersistenceError: Error, Equatable, Sendable {
    case invalidPrefix
    case unsupportedSchemaVersion(Int)
    case invalidEncoding
    case invalidPayload
}

public extension QuillUserIssueRecord {
    static let persistedStatusPrefix = "user-issue:v1:"

    /// A record from a schema this build doesn't write is stored as `unknown`.
    var persistedStatus: String {
        guard schemaVersion == Self.currentSchemaVersion else {
            return Self.encodeUnchecked(QuillUserIssueRecord(code: .unknown))
        }
        return Self.encodeUnchecked(self)
    }

    func encodedStatus() throws -> String {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw QuillUserIssuePersistenceError
                .unsupportedSchemaVersion(schemaVersion)
        }
        return Self.encodeUnchecked(self)
    }

    private static func encodeUnchecked(_ record: Self) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(record)
        return Self.persistedStatusPrefix + data.base64URLEncodedString()
    }

    static func decodePersistedStatus(_ status: String) throws -> Self {
        guard status.hasPrefix("user-issue:") else {
            throw QuillUserIssuePersistenceError.invalidPrefix
        }
        let components = status.split(
            separator: ":",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard components.count == 3,
              components[0] == "user-issue",
              components[1].hasPrefix("v"),
              let version = Int(components[1].dropFirst()) else {
            throw QuillUserIssuePersistenceError.invalidPrefix
        }
        guard version == Self.currentSchemaVersion else {
            throw QuillUserIssuePersistenceError
                .unsupportedSchemaVersion(version)
        }
        guard let data = Data(base64URLString: String(components[2])) else {
            throw QuillUserIssuePersistenceError.invalidEncoding
        }
        let record: Self
        do {
            record = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw QuillUserIssuePersistenceError.invalidPayload
        }
        guard record.schemaVersion == Self.currentSchemaVersion else {
            throw QuillUserIssuePersistenceError
                .unsupportedSchemaVersion(record.schemaVersion)
        }
        return record
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLString: String) {
        guard !base64URLString.isEmpty,
              base64URLString.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || scalar == "-"
                      || scalar == "_"
              }) else {
            return nil
        }
        var base64 = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
