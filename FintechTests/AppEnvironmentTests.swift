import Foundation
import Testing
@testable import Fintech

struct AppEnvironmentTests {
    @Test
    func debugDefaultsToProduction() throws {
        let environment = try AppEnvironment.resolve(
            arguments: [], environment: [:], isDebug: true
        )

        #expect(environment == .production)
        #expect(environment.baseURL == APIClient.productionBaseURL)
        #expect(environment.keychainService == AppEnvironment.productionKeychainService)
    }

    @Test
    func debugStagingRequiresExplicitHTTPSURL() throws {
        let url = "https://staging.example.test/api"
        let environment = try AppEnvironment.resolve(
            arguments: ["-staging"],
            environment: ["FINTECH_STAGING_BASE_URL": url],
            isDebug: true
        )

        #expect(environment == .staging(URL(string: url)!))
        #expect(environment.keychainService == AppEnvironment.stagingKeychainService)
        #expect(
            AppEnvironment.productionKeychainService !=
                AppEnvironment.stagingKeychainService
        )
    }

    @Test(arguments: [
        nil,
        "http://staging.example.test",
        "staging.example.test",
        "https://user:password@staging.example.test",
        "https://staging.example.test?token=value",
        "https://staging.example.test#fragment"
    ] as [String?])
    func invalidStagingConfigurationFailsClosed(_ value: String?) {
        let environment = value.map { ["FINTECH_STAGING_BASE_URL": $0] } ?? [:]

        #expect(throws: AppEnvironmentError.invalidStagingBaseURL) {
            try AppEnvironment.resolve(
                arguments: ["-staging"],
                environment: environment,
                isDebug: true
            )
        }
    }

    @Test
    func uiTestsRemainIsolatedFromStagingConfiguration() throws {
        let environment = try AppEnvironment.resolve(
            arguments: ["-staging", "-ui-testing-authenticated"],
            environment: ["FINTECH_STAGING_BASE_URL": "https://staging.example.test"],
            isDebug: true
        )

        #expect(environment == .uiTesting)
        #expect(environment.baseURL == URL(string: "http://127.0.0.1:1")!)
        #expect(environment.keychainService == nil)
    }

    @Test
    func releaseIgnoresStagingConfiguration() throws {
        let environment = try AppEnvironment.resolve(
            arguments: ["-staging"],
            environment: ["FINTECH_STAGING_BASE_URL": "https://staging.example.test"],
            isDebug: false
        )

        #expect(environment == .production)
    }
}
