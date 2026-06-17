import Foundation

struct SendCodeRequestBody: Encodable {
    let mobile: String
}

struct LoginRequestBody: Encodable {
    let mobile: String
    let code: String
    let clientId: String
}

private struct RestEnvelope<T: Decodable>: Decodable {
    let code: Int
    let message: String?
    let result: T?
}

public struct LoginResult: Decodable, Equatable {
    public let userId: String
    public let token: String
    public let register: Bool
}

public enum LoginClientError: Error, Equatable {
    case server(code: Int, message: String?)
    case invalidResponse
}

/// Performs one HTTP request and returns its raw response — the seam tests
/// substitute to avoid real network calls. Production code uses `URLSession`.
public protocol HTTPRequesting {
    func perform(_ request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionHTTPRequester: HTTPRequesting {
    private let session: URLSession
    public init(session: URLSession = .shared) {
        self.session = session
    }
    public func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// HTTP client for the two login-flow endpoints exposed by
/// `chat-server-pro`'s `push-api` (`LoginController`): `/send_code` and `/login`.
public final class LoginClient {
    private let baseURL: URL
    private let requester: HTTPRequesting
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(baseURL: URL, requester: HTTPRequesting = URLSessionHTTPRequester()) {
        self.baseURL = baseURL
        self.requester = requester
    }

    public func sendCode(mobile: String) async throws {
        _ = try await post(path: "send_code", body: SendCodeRequestBody(mobile: mobile), resultType: Bool.self)
    }

    public func login(mobile: String, code: String, clientId: String) async throws -> LoginResult {
        guard let result = try await post(
            path: "login",
            body: LoginRequestBody(mobile: mobile, code: code, clientId: clientId),
            resultType: LoginResult.self
        ) else {
            throw LoginClientError.invalidResponse
        }
        return result
    }

    private func post<Body: Encodable, ResultValue: Decodable>(
        path: String,
        body: Body,
        resultType: ResultValue.Type
    ) async throws -> ResultValue? {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let (data, _) = try await requester.perform(request)
        let envelope = try decoder.decode(RestEnvelope<ResultValue>.self, from: data)
        guard envelope.code == 0 else {
            throw LoginClientError.server(code: envelope.code, message: envelope.message)
        }
        return envelope.result
    }
}
