import Foundation
import Synchronization

final class URLProtocolStub: URLProtocol {
    enum Behavior {
        case response(URLResponse, Data)
        case failure(Error)
        case pending
    }

    typealias Handler = @Sendable (URLRequest) throws -> Behavior

    private static let handler = Mutex<Handler?>(nil)

    static func install(_ handler: @escaping Handler) {
        Self.handler.withLock { storedHandler in
            storedHandler = handler
        }
    }

    static func reset() {
        handler.withLock { storedHandler in
            storedHandler = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler.withLock({ $0 }) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }

        do {
            switch try handler(requestWithMaterializedBody()) {
            case let .response(response, data):
                client?.urlProtocol(
                    self,
                    didReceive: response,
                    cacheStoragePolicy: .notAllowed
                )
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case let .failure(error):
                client?.urlProtocol(self, didFailWithError: error)
            case .pending:
                break
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func requestWithMaterializedBody() throws -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)

        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)

            if count < 0 {
                throw stream.streamError ?? URLError(.cannotDecodeRawData)
            }

            if count == 0 {
                break
            }

            data.append(buffer, count: count)
        }

        var materializedRequest = request
        materializedRequest.httpBody = data
        return materializedRequest
    }
}
