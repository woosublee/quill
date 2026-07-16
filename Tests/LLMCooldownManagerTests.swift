import Foundation

@main
struct LLMCooldownManagerTests {
    static func main() async {
        testIdentityNormalizesProviderAndModel()
        testRateLimitHeaderParsing()
        await testProviderIsolationAndExpiration()
        await testDailyCooldownPersists()
        await testEffectivePrimaryUsesAvailableFallback()
        await testEffectivePrimaryRejectsCoolingRetryCandidate()
        print("LLMCooldownManagerTests passed")
    }

    private static func testIdentityNormalizesProviderAndModel() {
        let first = LLMCooldownIdentity(baseURL: " HTTPS://API.EXAMPLE.COM/openai/v1/ ", model: " Model-A ")
        let second = LLMCooldownIdentity(baseURL: "https://api.example.com/openai/v1", model: "model-a")
        let otherProvider = LLMCooldownIdentity(baseURL: "https://other.example.com/openai/v1", model: "model-a")

        assert(first == second)
        assert(first != otherProvider)
    }

    private static func testRateLimitHeaderParsing() {
        let url = URL(string: "https://api.example.com")!
        let retryAfter = HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "7.5"]
        )!
        let daily = HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: [
                "x-ratelimit-remaining-requests": "0",
                "x-ratelimit-reset-requests": "1h2m3.5s",
                "Retry-After": "2"
            ]
        )!
        let malformed = HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "not-a-duration"]
        )!

        assert(LLMCooldownManager.rateLimitCooldown(from: retryAfter).seconds == 7.5)
        let dailyCooldown = LLMCooldownManager.rateLimitCooldown(from: daily)
        assert(dailyCooldown.seconds == 3723.5)
        assert(dailyCooldown.isDaily)
        assert(LLMCooldownManager.rateLimitCooldown(from: malformed).seconds == 60)
    }

    private static func testProviderIsolationAndExpiration() async {
        let defaults = isolatedDefaults()
        let manager = LLMCooldownManager(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_000)
        let first = LLMCooldownIdentity(baseURL: "https://first.example.com/v1", model: "shared-model")
        let second = LLMCooldownIdentity(baseURL: "https://second.example.com/v1", model: "shared-model")

        await manager.setCooldown(first, retryAfterSeconds: 30, now: now)

        let firstIsCooling = await manager.isInCooldown(first, now: now.addingTimeInterval(10))
        let secondIsCooling = await manager.isInCooldown(second, now: now.addingTimeInterval(10))
        let firstExpired = await manager.isInCooldown(first, now: now.addingTimeInterval(31))
        assert(firstIsCooling)
        assert(!secondIsCooling)
        assert(!firstExpired)
    }

    private static func testDailyCooldownPersists() async {
        let defaults = isolatedDefaults()
        let now = Date(timeIntervalSince1970: 2_000)
        let identity = LLMCooldownIdentity(baseURL: "https://api.example.com/v1", model: "daily-model")
        let firstManager = LLMCooldownManager(defaults: defaults)

        await firstManager.setCooldown(identity, retryAfterSeconds: 7_200, persist: true, now: now)

        let secondManager = LLMCooldownManager(defaults: defaults)
        let persisted = await secondManager.isInCooldown(identity, now: now.addingTimeInterval(60))
        let expired = await secondManager.isInCooldown(identity, now: now.addingTimeInterval(7_201))
        assert(persisted)
        assert(!expired)
    }

    private static func testEffectivePrimaryUsesAvailableFallback() async {
        let defaults = isolatedDefaults()
        let manager = LLMCooldownManager(defaults: defaults)
        let now = Date(timeIntervalSince1970: 3_000)
        let baseURL = "https://api.example.com/v1"

        await manager.setCooldown(
            LLMCooldownIdentity(baseURL: baseURL, model: "primary"),
            retryAfterSeconds: 60,
            now: now
        )

        let fallback = await manager.effectivePrimary(baseURL: baseURL, primary: "primary", fallback: "fallback", now: now)
        assert(fallback == "fallback")

        await manager.setCooldown(
            LLMCooldownIdentity(baseURL: baseURL, model: "fallback"),
            retryAfterSeconds: 60,
            now: now
        )

        let unavailable = await manager.effectivePrimary(baseURL: baseURL, primary: "primary", fallback: "fallback", now: now)
        assert(unavailable == nil)
    }

    private static func testEffectivePrimaryRejectsCoolingRetryCandidate() async {
        let defaults = isolatedDefaults()
        let manager = LLMCooldownManager(defaults: defaults)
        let now = Date(timeIntervalSince1970: 4_000)
        let baseURL = "https://api.example.com/v1"
        let retryIdentity = LLMCooldownIdentity(baseURL: baseURL, model: "fallback")

        await manager.setCooldown(retryIdentity, retryAfterSeconds: 60, now: now)

        let unavailable = await manager.effectivePrimary(
            baseURL: baseURL,
            primary: "fallback",
            fallback: nil,
            now: now
        )
        assert(unavailable == nil)
    }

    private static func isolatedDefaults() -> UserDefaults {
        let suiteName = "LLMCooldownManagerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
