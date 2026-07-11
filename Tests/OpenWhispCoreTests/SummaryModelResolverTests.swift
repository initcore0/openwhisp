import XCTest
@testable import OpenWhispCore

/// Tests for `SummaryModelResolver` (MAK-53): the separate summarization
/// provider/model, decoupled from dictation cleanup. Covers the sentinel
/// passthrough, explicit overrides, empty-model defaulting, endpoint handling,
/// and locality classification of the RESOLVED provider (which must reuse
/// `ScreenContextGate.localRefineProviders`).
final class SummaryModelResolverTests: XCTestCase {

    // MARK: - Sentinel passthrough

    func testSentinelPassesCleanupGlobalsVerbatim() {
        let r = SummaryModelResolver.resolve(
            override: .init(),  // default = sameAsCleanup
            globalProvider: "openai",
            globalModel: "gpt-4o-mini",
            globalEndpoint: ""
        )
        XCTAssertEqual(r.provider, "openai")
        XCTAssertEqual(r.model, "gpt-4o-mini")
        XCTAssertEqual(r.endpoint, "")
    }

    func testSentinelCarriesLocalEndpointThrough() {
        let r = SummaryModelResolver.resolve(
            override: .init(provider: SummaryModelResolver.sameAsCleanupID),
            globalProvider: "local",
            globalModel: "qwen2.5",
            globalEndpoint: "http://localhost:8080/v1"
        )
        XCTAssertEqual(r.provider, "local")
        XCTAssertEqual(r.model, "qwen2.5")
        XCTAssertEqual(r.endpoint, "http://localhost:8080/v1")
        XCTAssertTrue(r.isLocal)
    }

    // MARK: - Explicit override

    func testExplicitProviderWithModel() {
        // Cleanup is the tiny bundled model; summaries go to a big local model.
        let r = SummaryModelResolver.resolve(
            override: .init(provider: "local", model: "llama-3.3-70b", endpoint: "http://box:1234/v1"),
            globalProvider: "bundled",
            globalModel: "qwen2.5-0.5b",
            globalEndpoint: ""
        )
        XCTAssertEqual(r.provider, "local")
        XCTAssertEqual(r.model, "llama-3.3-70b")
        XCTAssertEqual(r.endpoint, "http://box:1234/v1")
        XCTAssertTrue(r.isLocal)
    }

    func testExplicitOpenAIOverrideIgnoresLocalEndpointField() {
        let r = SummaryModelResolver.resolve(
            override: .init(provider: "openai", model: "gpt-4o", endpoint: "http://ignored"),
            globalProvider: "bundled",
            globalModel: "qwen2.5-0.5b",
            globalEndpoint: ""
        )
        XCTAssertEqual(r.provider, "openai")
        XCTAssertEqual(r.model, "gpt-4o")
        // Endpoint only applies to `local`; OpenAI derives its own.
        XCTAssertEqual(r.endpoint, "")
    }

    // MARK: - Empty-model defaulting

    func testEmptyModelSameProviderAsCleanupInheritsCleanupModel() {
        let r = SummaryModelResolver.resolve(
            override: .init(provider: "openai", model: ""),
            globalProvider: "openai",
            globalModel: "gpt-4o-mini",
            globalEndpoint: ""
        )
        // Same provider as cleanup + blank model ⇒ the cleanup model.
        XCTAssertEqual(r.model, "gpt-4o-mini")
    }

    func testEmptyModelDifferentProviderYieldsProviderDefault() {
        let r = SummaryModelResolver.resolve(
            override: .init(provider: "local", model: "", endpoint: "http://box/v1"),
            globalProvider: "bundled",
            globalModel: "qwen2.5-0.5b",
            globalEndpoint: ""
        )
        // Different provider + blank model ⇒ empty (server/provider default).
        XCTAssertEqual(r.model, "")
    }

    func testLocalEndpointFallsBackToCleanupWhenCleanupIsAlsoLocal() {
        let r = SummaryModelResolver.resolve(
            override: .init(provider: "local", model: "big", endpoint: ""),
            globalProvider: "local",
            globalModel: "small",
            globalEndpoint: "http://localhost:8080/v1"
        )
        XCTAssertEqual(r.endpoint, "http://localhost:8080/v1")
    }

    // MARK: - Locality of the resolved provider

    func testLocalityBundledIsLocal() {
        let r = SummaryModelResolver.resolve(
            override: .init(provider: "bundled"),
            globalProvider: "openai", globalModel: "x", globalEndpoint: "")
        XCTAssertTrue(r.isLocal)
    }

    func testLocalityLocalIsLocal() {
        let r = SummaryModelResolver.resolve(
            override: .init(provider: "local", endpoint: "http://box/v1"),
            globalProvider: "openai", globalModel: "x", globalEndpoint: "")
        XCTAssertTrue(r.isLocal)
    }

    func testLocalityOpenAIIsNonLocal() {
        let r = SummaryModelResolver.resolve(
            override: .init(provider: "openai"),
            globalProvider: "bundled", globalModel: "x", globalEndpoint: "")
        XCTAssertFalse(r.isLocal)
    }

    func testLocalityAgentCLIIsNonLocal() {
        let r = SummaryModelResolver.resolve(
            override: .init(provider: "agentCLI"),
            globalProvider: "bundled", globalModel: "x", globalEndpoint: "")
        XCTAssertFalse(r.isLocal)
    }

    /// The resolver must reuse `ScreenContextGate.localRefineProviders` verbatim,
    /// never fork the set — this pins that contract.
    func testLocalityReusesScreenContextGateSet() {
        for provider in ScreenContextGate.localRefineProviders {
            let r = SummaryModelResolver.Resolved(provider: provider, model: "", endpoint: "")
            XCTAssertTrue(r.isLocal, "\(provider) is in localRefineProviders so must resolve local")
        }
    }
}
