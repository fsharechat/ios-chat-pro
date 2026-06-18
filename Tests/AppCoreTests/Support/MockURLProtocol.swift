import Foundation

/// Intercepts every request made through a `URLSession` configured with
/// this protocol class, so tests never touch the real network.
///
/// **Verified empirically**: `URLSession` converts an outgoing request's
/// `httpBody` into an `httpBodyStream` before handing it to a custom
/// `URLProtocol` — `request.httpBody` is `nil` here even though the caller
/// set it. `capturedBody(of:)` below reads the stream instead.
final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func capturedBody(of request: URLRequest) -> String? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix(count), as: UTF8.self)
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
