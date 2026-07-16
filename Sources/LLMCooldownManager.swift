import Foundation

struct LLMCooldownIdentity: Hashable {
    let baseURL: String
    let model: String

    init(baseURL: String, model: String) {
        self.baseURL = Self.normalizedBaseURL(baseURL)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var storageKey: String {
        let raw = "\(baseURL)|\(model)"
        let encoded = Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "llm_cooldown_expiry_\(encoded)"
    }

    private static func normalizedBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            return trimmed.lowercased().replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path == "/" {
            components.path = ""
        } else {
            components.path = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        }
        return components.string ?? trimmed.lowercased()
    }
}

actor LLMCooldownManager {
    static let shared = LLMCooldownManager()

    private static let defaultReprobeCooldownSeconds: TimeInterval = 60
    private let dailyLimitThreshold: TimeInterval = 3_600
    private let defaults: UserDefaults
    private var cooldowns: [LLMCooldownIdentity: Date] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isInCooldown(_ identity: LLMCooldownIdentity, now: Date = Date()) -> Bool {
        if let expiry = cooldowns[identity] {
            if now < expiry { return true }
            cooldowns.removeValue(forKey: identity)
        }

        let timestamp = defaults.double(forKey: identity.storageKey)
        guard timestamp > 0 else { return false }
        let expiry = Date(timeIntervalSince1970: timestamp)
        if now < expiry { return true }
        defaults.removeObject(forKey: identity.storageKey)
        return false
    }

    func setCooldown(
        _ identity: LLMCooldownIdentity,
        retryAfterSeconds: TimeInterval,
        persist: Bool = false,
        now: Date = Date()
    ) {
        guard retryAfterSeconds.isFinite, retryAfterSeconds >= 0 else { return }
        let expiry = now.addingTimeInterval(retryAfterSeconds)
        if persist || retryAfterSeconds >= dailyLimitThreshold {
            defaults.set(expiry.timeIntervalSince1970, forKey: identity.storageKey)
        } else {
            cooldowns[identity] = expiry
        }
    }

    func effectivePrimary(
        baseURL: String,
        primary: String,
        fallback: String?,
        now: Date = Date()
    ) -> String? {
        let primaryIdentity = LLMCooldownIdentity(baseURL: baseURL, model: primary)
        if !isInCooldown(primaryIdentity, now: now) {
            return primary
        }
        guard let fallback else { return nil }
        let fallbackIdentity = LLMCooldownIdentity(baseURL: baseURL, model: fallback)
        return isInCooldown(fallbackIdentity, now: now) ? nil : fallback
    }

    nonisolated static func rateLimitCooldown(
        from httpResponse: HTTPURLResponse
    ) -> (seconds: TimeInterval, isDaily: Bool) {
        let remainingRequests = httpResponse.value(forHTTPHeaderField: "x-ratelimit-remaining-requests")
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let remainingRequests, remainingRequests <= 0,
           let reset = httpResponse.value(forHTTPHeaderField: "x-ratelimit-reset-requests").flatMap(parseDuration) {
            return (reset, true)
        }
        if let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(parseRetryAfter) {
            return (retryAfter, false)
        }
        if let reset = httpResponse.value(forHTTPHeaderField: "x-ratelimit-reset-tokens").flatMap(parseDuration) {
            return (reset, false)
        }
        return (defaultReprobeCooldownSeconds, false)
    }

    private nonisolated static func parseRetryAfter(_ value: String) -> TimeInterval? {
        if let duration = parseDuration(value) {
            return duration
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return max(0, date.timeIntervalSinceNow)
    }

    private nonisolated static func parseDuration(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if let seconds = Double(trimmed) {
            return seconds.isFinite && seconds >= 0 ? seconds : nil
        }

        var total: TimeInterval = 0
        var numberBuffer = ""
        var matchedUnit = false
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if character.isNumber || character == "." {
                numberBuffer.append(character)
                index = trimmed.index(after: index)
                continue
            }

            guard let number = Double(numberBuffer), number.isFinite, number >= 0 else { return nil }
            numberBuffer = ""
            if trimmed[index...].hasPrefix("ms") {
                total += number / 1_000
                index = trimmed.index(index, offsetBy: 2)
            } else if character == "h" {
                total += number * 3_600
                index = trimmed.index(after: index)
            } else if character == "m" {
                total += number * 60
                index = trimmed.index(after: index)
            } else if character == "s" {
                total += number
                index = trimmed.index(after: index)
            } else {
                return nil
            }
            matchedUnit = true
        }

        guard numberBuffer.isEmpty, matchedUnit, total.isFinite else { return nil }
        return total
    }
}
