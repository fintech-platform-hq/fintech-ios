import Foundation

nonisolated enum AppEnvironment: Equatable, Sendable {
    case production
    case staging(URL)
    case uiTesting

    private static let productionBundleIdentifier = "com.ferrari.lenver"
    private static let stagingBundleIdentifier = "com.ferrari.lenver.staging"
    static let productionKeychainService = "\(productionBundleIdentifier).authentication"
    static let stagingKeychainService = "\(stagingBundleIdentifier).authentication"

    var baseURL: URL {
        switch self {
        case .production:
            APIClient.productionBaseURL
        case let .staging(url):
            url
        case .uiTesting:
            URL(string: "http://127.0.0.1:1")!
        }
    }

    var keychainService: String? {
        switch self {
        case .production: Self.productionKeychainService
        case let .staging(url): "\(Self.stagingKeychainService).\(url.absoluteString)"
        case .uiTesting: nil
        }
    }

    func allowsAppleAuthorization(bundleIdentifier: String?) -> Bool {
        switch self {
        case .production: bundleIdentifier == Self.productionBundleIdentifier
        case .staging: bundleIdentifier == Self.stagingBundleIdentifier
        case .uiTesting: false
        }
    }

    static func resolve(
        arguments: [String],
        environment: [String: String],
        releaseConfiguration: [String: Any] = [:],
        isDebug: Bool = isDebugBuild,
        isStagingRelease: Bool = isStagingReleaseBuild,
        isSimulator: Bool = isSimulatorBuild
    ) throws -> AppEnvironment {
        if isDebug {
            let selectors = ["-ui-testing-authenticated", "-local-identity", "-staging", "-production"]
                .filter { arguments.contains($0) }
            guard selectors.count == 1 else {
                throw AppEnvironmentError.invalidEnvironmentSelection
            }
            switch selectors[0] {
            case "-ui-testing-authenticated":
                guard isSimulator else { throw AppEnvironmentError.invalidStagingConfiguration }
                return .uiTesting
            case "-production":
                return .production
            case "-local-identity":
                guard isSimulator,
                      let value = environment["LENVER_LOCAL_IDENTITY_PORT"],
                      let port = UInt16(value), port > 0,
                      let url = URL(string: "http://127.0.0.1:\(port)") else {
                    throw AppEnvironmentError.invalidStagingBaseURL
                }
                return .staging(url)
            case "-staging":
                guard isSimulator else {
                    throw AppEnvironmentError.invalidStagingConfiguration
                }
                return .staging(try stagingURL(environment["LENVER_STAGING_API_BASE_URL"]))
            default:
                throw AppEnvironmentError.invalidEnvironmentSelection
            }
        }

        let configuredEnvironment = releaseConfiguration["LENVER_API_ENVIRONMENT"] as? String
        let bundleIdentifier = releaseConfiguration["CFBundleIdentifier"] as? String
        let isStagingArtifact = isStagingRelease ||
            bundleIdentifier == Self.stagingBundleIdentifier
        if isStagingArtifact {
            guard configuredEnvironment == "staging",
                  bundleIdentifier == Self.stagingBundleIdentifier else {
                throw AppEnvironmentError.invalidStagingConfiguration
            }
            return .staging(try stagingURL(releaseConfiguration["LENVER_API_BASE_URL"] as? String))
        }
        guard configuredEnvironment == nil || configuredEnvironment == "production" else {
            throw AppEnvironmentError.invalidStagingConfiguration
        }
        return .production
    }

    private static func stagingURL(_ value: String?) throws -> URL {
        guard let value,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              host.lowercased() != APIClient.productionBaseURL.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url else {
            throw AppEnvironmentError.invalidStagingBaseURL
        }
        return url
    }

    private static let isDebugBuild: Bool = {
#if DEBUG
        true
#else
        false
#endif
    }()

    private static let isStagingReleaseBuild: Bool = {
#if LENVER_STAGING_RELEASE
        true
#else
        false
#endif
    }()

    private static let isSimulatorBuild: Bool = {
#if targetEnvironment(simulator)
        true
#else
        false
#endif
    }()
}

nonisolated enum AppEnvironmentError: Error, Equatable, Sendable {
    case invalidEnvironmentSelection
    case invalidStagingConfiguration
    case invalidStagingBaseURL
}
