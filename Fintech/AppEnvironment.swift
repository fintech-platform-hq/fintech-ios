import Foundation

nonisolated enum AppEnvironment: Equatable, Sendable {
    case production
    case staging(URL)
    case uiTesting

    static let productionKeychainService = "com.ferrari.Fintech.authentication"
    static let stagingKeychainService = "com.ferrari.Fintech.staging.authentication"

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
        case .staging: Self.stagingKeychainService
        case .uiTesting: nil
        }
    }

    static func resolve(
        arguments: [String],
        environment: [String: String],
        isDebug: Bool = isDebugBuild
    ) throws -> AppEnvironment {
        if isDebug, arguments.contains("-ui-testing-authenticated") { return .uiTesting }
        guard isDebug, arguments.contains("-staging") else { return .production }
        guard let value = environment["FINTECH_STAGING_BASE_URL"],
              let components = URLComponents(string: value),
              components.scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url else {
            throw AppEnvironmentError.invalidStagingBaseURL
        }
        return .staging(url)
    }

    private static let isDebugBuild: Bool = {
#if DEBUG
        true
#else
        false
#endif
    }()
}

nonisolated enum AppEnvironmentError: Error, Equatable, Sendable {
    case invalidStagingBaseURL
}
