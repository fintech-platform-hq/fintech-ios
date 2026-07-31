import Foundation

nonisolated struct APIClient: Sendable {
    static let productionBaseURL = URL(string: "https://fintech-api-87yw.onrender.com")!

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession) {
        self.baseURL = baseURL
        self.session = session
    }

    func post<Request, Response>(
        path: String,
        body: Request,
        headers: [String: String],
        expectedStatusCode: Int
    ) async throws -> Response
    where Request: Encodable & Sendable, Response: Decodable & Sendable {
        let data: Data

        do {
            data = try APICoding.makeEncoder().encode(body)
        } catch {
            throw APIError.encoding
        }

        let pathComponents = path.split(separator: "/", omittingEmptySubsequences: true)
        let url = pathComponents.reduce(baseURL) { partialURL, component in
            partialURL.appendingPathComponent(String(component))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

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

        guard httpResponse.statusCode == expectedStatusCode else {
            throw mapHTTPError(statusCode: httpResponse.statusCode, data: responseData)
        }

        do {
            return try APICoding.makeDecoder().decode(Response.self, from: responseData)
        } catch {
            throw APIError.decoding
        }
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> APIError {
        let payload = try? JSONDecoder().decode(APIErrorPayload.self, from: data)
        let messages = payload?.messages ?? []

        switch statusCode {
        case 400:
            return .badRequest(messages: messages)
        case 409:
            return .idempotencyConflict(message: messages.first)
        case 500...599:
            return .server(statusCode: statusCode, message: messages.first)
        default:
            return .http(statusCode: statusCode, message: messages.first)
        }
    }
}

private nonisolated struct APIErrorPayload: Decodable, Sendable {
    let statusCode: Int?
    let message: APIErrorMessage?
    let error: String?

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
