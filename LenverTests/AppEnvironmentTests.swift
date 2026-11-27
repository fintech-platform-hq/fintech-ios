import Foundation
import Testing
@testable import Lenver

struct AppEnvironmentTests {
    @Test
    func debugRequiresAnExplicitEnvironment() {
        #expect(throws: AppEnvironmentError.invalidEnvironmentSelection) {
            try AppEnvironment.resolve(arguments: [], environment: [:], isDebug: true)
        }
        #expect(throws: AppEnvironmentError.invalidEnvironmentSelection) {
            try AppEnvironment.resolve(arguments: ["-staging", "-production"], environment: [:], isDebug: true)
        }
    }

    @Test
    func debugProductionMustBeExplicit() throws {
        let environment = try AppEnvironment.resolve(
            arguments: ["-production"], environment: [:], isDebug: true
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
            environment: ["LENVER_STAGING_API_BASE_URL": url],
            isDebug: true,
            isSimulator: true
        )

        #expect(environment == .staging(URL(string: url)!))
        #expect(environment.keychainService?.hasPrefix("\(AppEnvironment.stagingKeychainService).") == true)
        #expect(
            AppEnvironment.productionKeychainService !=
                AppEnvironment.stagingKeychainService
        )

        let changedEndpoint = try AppEnvironment.resolve(
            arguments: ["-staging"],
            environment: ["LENVER_STAGING_API_BASE_URL": "https://staging.example.test/v2"],
            isDebug: true,
            isSimulator: true
        )
        #expect(changedEndpoint.keychainService != environment.keychainService)
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
        let environment = value.map { ["LENVER_STAGING_API_BASE_URL": $0] } ?? [:]

        #expect(throws: AppEnvironmentError.invalidStagingBaseURL) {
            try AppEnvironment.resolve(
                arguments: ["-staging"],
                environment: environment,
                isDebug: true,
                isSimulator: true
            )
        }
    }

    @Test
    func uiTestsRemainIsolatedFromStagingConfiguration() throws {
        let environment = try AppEnvironment.resolve(
            arguments: ["-ui-testing-authenticated"],
            environment: ["LENVER_STAGING_API_BASE_URL": "https://staging.example.test"],
            isDebug: true
        )

        #expect(environment == .uiTesting)
        #expect(environment.baseURL == URL(string: "http://127.0.0.1:1")!)
        #expect(environment.keychainService == nil)
    }

    @Test
    func uiTestingCannotBeCombinedWithAServiceEnvironment() {
        #expect(throws: AppEnvironmentError.invalidEnvironmentSelection) {
            try AppEnvironment.resolve(
                arguments: ["-ui-testing-authenticated", "-staging"], environment: [:], isDebug: true
            )
        }
    }

    @Test
    func releaseIgnoresStagingConfiguration() throws {
        let environment = try AppEnvironment.resolve(
            arguments: ["-staging"],
            environment: ["LENVER_STAGING_API_BASE_URL": "https://staging.example.test"],
            isDebug: false,
            isStagingRelease: false
        )

        #expect(environment == .production)
    }

    @Test
    func debugOnDeviceRejectsStagingOverride() {
        #expect(throws: AppEnvironmentError.invalidStagingConfiguration) {
            try AppEnvironment.resolve(
                arguments: ["-staging"],
                environment: ["LENVER_STAGING_API_BASE_URL": "https://staging.example.test"],
                isDebug: true,
                isSimulator: false
            )
        }
    }

    @Test
    func productionReleaseRejectsStagingMetadata() {
        #expect(throws: AppEnvironmentError.invalidStagingConfiguration) {
            try AppEnvironment.resolve(
                arguments: [], environment: [:],
                releaseConfiguration: [
                    "CFBundleIdentifier": "com.ferrari.lenver",
                    "LENVER_API_ENVIRONMENT": "staging",
                    "LENVER_API_BASE_URL": "https://staging.example.test"
                ],
                isDebug: false, isStagingRelease: false
            )
        }
    }

    @Test(arguments: ["com.ferrari.lenver", "com.ferrari.lenver.staging", "com.ferrari.Fintech"])
    func appleAuthorizationRequiresMatchingBundle(_ bundleIdentifier: String) {
        let staging = AppEnvironment.staging(URL(string: "https://staging.example.test")!)
        #expect(staging.allowsAppleAuthorization(bundleIdentifier: bundleIdentifier) ==
            (bundleIdentifier == "com.ferrari.lenver.staging"))
        #expect(AppEnvironment.production.allowsAppleAuthorization(bundleIdentifier: bundleIdentifier) ==
            (bundleIdentifier == "com.ferrari.lenver"))
        #expect(!AppEnvironment.uiTesting.allowsAppleAuthorization(bundleIdentifier: bundleIdentifier))
    }

    @Test
    func releaseStagingUsesSeparateEnvironmentAndKeychain() throws {
        let url = "https://staging.example.test/api"
        let environment = try AppEnvironment.resolve(
            arguments: [],
            environment: [:],
            releaseConfiguration: [
                "CFBundleIdentifier": "com.ferrari.lenver.staging",
                "LENVER_API_ENVIRONMENT": "staging",
                "LENVER_API_BASE_URL": url
            ],
            isDebug: false,
            isStagingRelease: true
        )

        #expect(environment == .staging(URL(string: url)!))
        #expect(environment.keychainService?.hasPrefix("\(AppEnvironment.stagingKeychainService).") == true)
        #expect(environment.keychainService != AppEnvironment.productionKeychainService)

        let changedEndpoint = try AppEnvironment.resolve(
            arguments: [],
            environment: [:],
            releaseConfiguration: [
                "CFBundleIdentifier": "com.ferrari.lenver.staging",
                "LENVER_API_ENVIRONMENT": "staging",
                "LENVER_API_BASE_URL": "https://staging.example.test/v2"
            ],
            isDebug: false,
            isStagingRelease: true
        )
        #expect(changedEndpoint.keychainService != environment.keychainService)
    }

    @Test(arguments: [nil, "production", "unknown"] as [String?])
    func stagingReleaseRejectsMissingOrInconsistentEnvironment(_ value: String?) {
        var configuration: [String: Any] = [
            "CFBundleIdentifier": "com.ferrari.lenver.staging"
        ]
        configuration["LENVER_API_ENVIRONMENT"] = value
        configuration["LENVER_API_BASE_URL"] = "https://staging.example.test"

        #expect(throws: AppEnvironmentError.invalidStagingConfiguration) {
            try AppEnvironment.resolve(
                arguments: [],
                environment: [:],
                releaseConfiguration: configuration,
                isDebug: false,
                isStagingRelease: false
            )
        }
    }

    @Test
    func stagingBuildMarkerRejectsMissingEnvironmentEvenWithoutBundleIdentifier() {
        #expect(throws: AppEnvironmentError.invalidStagingConfiguration) {
            try AppEnvironment.resolve(
                arguments: [],
                environment: [:],
                releaseConfiguration: [:],
                isDebug: false,
                isStagingRelease: true
            )
        }
    }

    @Test(arguments: [
        nil,
        "http://staging.example.test",
        "https://fintech-api-87yw.onrender.com",
        "https://user:password@staging.example.test",
        "https://staging.example.test?token=value"
    ] as [String?])
    func releaseStagingFailsClosedForUnapprovedConfiguration(_ value: String?) {
        var configuration: [String: Any] = [
            "CFBundleIdentifier": "com.ferrari.lenver.staging",
            "LENVER_API_ENVIRONMENT": "staging"
        ]
        configuration["LENVER_API_BASE_URL"] = value

        #expect(throws: AppEnvironmentError.invalidStagingBaseURL) {
            try AppEnvironment.resolve(
                arguments: [],
                environment: [:],
                releaseConfiguration: configuration,
                isDebug: false,
                isStagingRelease: true
            )
        }
    }
}
