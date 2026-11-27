import Foundation

nonisolated struct APIClient: Sendable {
    static let productionBaseURL = URL(string: "https://fintech-api-87yw.onrender.com")!

    private let baseURL: URL
    private let session: URLSession
    private let authenticationSession: AuthenticationSession?
    var environmentID: String { baseURL.absoluteString }

    init(
        baseURL: URL,
        session: URLSession,
        authenticationSession: AuthenticationSession? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.authenticationSession = authenticationSession
    }

    func get<Response>(
        path: String,
        expectedGeneration: Int,
        queryItems: [URLQueryItem] = []
    ) async throws -> Response where Response: Decodable & Sendable {
        let data = try await execute(
            path: path, method: "GET", body: nil, headers: [:],
            expectedStatusCode: 200, expectedGeneration: expectedGeneration,
            queryItems: queryItems
        )
        return try decode(data)
    }

    func post<Request, Response>(
        path: String,
        body: Request,
        headers: [String: String],
        expectedStatusCode: Int,
        expectedGeneration: Int? = nil
    ) async throws -> Response
    where Request: Encodable & Sendable, Response: Decodable & Sendable {
        try await post(
            path: path, frozenBody: Self.freeze(body), headers: headers,
            expectedStatusCode: expectedStatusCode, expectedGeneration: expectedGeneration
        )
    }

    static func freeze(_ body: some Encodable) throws -> Data {
        do { return try APICoding.makeEncoder().encode(body) }
        catch { throw APIError.encoding }
    }

    func post<Response: Decodable & Sendable>(
        path: String,
        frozenBody: Data,
        headers: [String: String],
        expectedStatusCode: Int,
        expectedGeneration: Int?,
        canSend: (@MainActor @Sendable () -> Bool)? = nil
    ) async throws -> Response {
        let responseData = try await execute(
            path: path,
            method: "POST",
            body: frozenBody,
            headers: headers,
            expectedStatusCode: expectedStatusCode,
            expectedGeneration: expectedGeneration,
            canSend: canSend
        )
        return try decode(responseData)
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try APICoding.makeDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    func postWithoutResponse<Request>(
        path: String,
        body: Request,
        headers: [String: String],
        expectedStatusCode: Int,
        expectedGeneration: Int? = nil
    ) async throws
    where Request: Encodable & Sendable {
        let data: Data

        do {
            data = try APICoding.makeEncoder().encode(body)
        } catch {
            throw APIError.encoding
        }

        _ = try await execute(
            path: path,
            method: "POST",
            body: data,
            headers: headers,
            expectedStatusCode: expectedStatusCode,
            expectedGeneration: expectedGeneration
        )
    }

    private func execute(
        path: String,
        method: String,
        body: Data?,
        headers: [String: String],
        expectedStatusCode: Int,
        expectedGeneration: Int? = nil,
        queryItems: [URLQueryItem] = [],
        canSend: (@MainActor @Sendable () -> Bool)? = nil
    ) async throws -> Data {
        let url = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .reduce(baseURL) { $0.appendingPathComponent(String($1)) }

        var request = URLRequest(url: queryItems.isEmpty ? url : url.appending(queryItems: queryItems))
        if authenticationSession != nil || path.hasPrefix("/v1/auth/") {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let implicitSession = headers.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
            ? nil : authenticationSession
        let requestGeneration: Int?
        if let expectedGeneration { requestGeneration = expectedGeneration }
        else { requestGeneration = await implicitSession?.currentGeneration() }
        let firstToken: String?
        if let implicitSession {
            let token = try await implicitSession.accessToken(expectedGeneration: requestGeneration)
            firstToken = token
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
        } else {
            firstToken = nil
        }

        try await checkGeneration(requestGeneration)
        if let canSend, !(await canSend()) { throw CancellationError() }
        let firstResponse = try await send(request)
        try await checkGeneration(requestGeneration)
        guard firstResponse.response.statusCode == 401,
              let authenticationSession,
              let firstToken else {
            return try validatedData(
                firstResponse.data,
                response: firstResponse.response,
                expectedStatusCode: expectedStatusCode,
                path: path
            )
        }

        if let canSend, !(await canSend()) { throw CancellationError() }
        let refreshedToken: String
        do {
            refreshedToken = try await authenticationSession
                .accessToken(afterUnauthorizedFor: firstToken, expectedGeneration: requestGeneration)
        } catch is CancellationError {
            throw CancellationError()
        } catch AuthenticationError.refreshUnavailable {
            throw APIError.refreshUnavailable
        } catch AuthenticationError.reauthenticationRequired {
            throw APIError.reauthenticationRequired
        } catch {
            throw APIError.unauthorized(messages: [])
        }

        var retry = request
        retry.setValue(
            "Bearer \(refreshedToken)",
            forHTTPHeaderField: "Authorization"
        )
        try await checkGeneration(requestGeneration)
        if let canSend, !(await canSend()) { throw CancellationError() }
        let retryResponse = try await send(retry)
        try await checkGeneration(requestGeneration)

        if retryResponse.response.statusCode == 401 {
            await authenticationSession.invalidate(expectedGeneration: requestGeneration)
        }

        return try validatedData(
            retryResponse.data,
            response: retryResponse.response,
            expectedStatusCode: expectedStatusCode, path: path
        )
    }

    private func checkGeneration(_ expectedGeneration: Int?) async throws {
        guard let expectedGeneration else { return }
        guard let authenticationSession,
              await authenticationSession.hasActiveSession(generation: expectedGeneration) else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let responseData: Data
        let response: URLResponse

        do {
            (responseData, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled {
                throw CancellationError()
            }

            throw APIError.transport(code: error.code)
        } catch {
            throw APIError.transport(code: .unknown)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        return (responseData, httpResponse)
    }

    private func validatedData(
        _ data: Data,
        response: HTTPURLResponse,
        expectedStatusCode: Int,
        path: String
    ) throws -> Data {
        guard response.statusCode == expectedStatusCode else {
            throw mapHTTPError(response: response, data: data, path: path)
        }

        return data
    }

    private func mapHTTPError(response: HTTPURLResponse, data: Data, path: String) -> APIError {
        let payload = try? JSONDecoder().decode(APIErrorPayload.self, from: data)
        let messages = payload?.messages ?? []

        switch response.statusCode {
        case 401:
            return .unauthorized(messages: messages)
        case 400:
            return .badRequest(messages: messages)
        case 409:
            if (path == "/auth/apple" || path == "/v1/auth/apple"), payload?.code == "ACCOUNT_LINK_REQUIRED" { return .accountLinkRequired }
            if path.hasPrefix("/mvp/"), let code = payload?.code { return .mvpConflict(code: code) }
            return .idempotencyConflict(message: messages.first)
        case 429:
            return .rateLimited(retryAfter: Self.retryAfterSeconds(response.value(forHTTPHeaderField: "Retry-After")))
        case 500...599:
            return .server(statusCode: response.statusCode, message: messages.first)
        default:
            return .http(statusCode: response.statusCode, message: messages.first)
        }
    }

    static func retryAfterSeconds(_ value: String?, now: Date = .now) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = Int(value), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, Int(ceil(date.timeIntervalSince(now))))
    }
}

private nonisolated struct APIErrorPayload: Decodable, Sendable {
    let statusCode: Int?
    let message: APIErrorMessage?
    let error: String?
    let code: String?

    var messages: [String] {
        message?.values ?? []
    }
}

private nonisolated enum APIErrorMessage: Decodable, Sendable {
    case single(String)
    case multiple([String])

    var values: [String] {
        switch self {
        case let .single(message):
            [message]
        case let .multiple(messages):
            messages
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let message = try? container.decode(String.self) {
            self = .single(message)
        } else {
            self = .multiple(try container.decode([String].self))
        }
    }
}

private nonisolated enum APICoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(format(date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = parse(value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an RFC 3339 timestamp."
            )
        }
        return decoder
    }

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func parse(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let wholeSecondsFormatter = ISO8601DateFormatter()
        wholeSecondsFormatter.formatOptions = [.withInternetDateTime]
        return wholeSecondsFormatter.date(from: value)
    }
}
