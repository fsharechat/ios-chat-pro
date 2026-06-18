import Foundation

public struct LoginResult: Equatable {
    public let userId: String
    public let token: String
    public let isNewRegistration: Bool
}

public enum LoginAPIError: Error, Equatable {
    case server(code: Int, message: String)
    case invalidResponse
}

/// Lets `LoginViewModel` depend on an abstraction instead of the concrete
/// `URLSession`-backed client, so its tests use a plain stub instead of
/// `MockURLProtocol` HTTP mocking.
public protocol LoginAPIClientProtocol {
    func requestCode(mobile: String) async throws
    func login(mobile: String, code: String, clientId: String) async throws -> LoginResult
}

/// The `RestResult` envelope's common fields (`code`/`message`), decoded
/// before attempting to decode `result` — see `LoginAPIClient.post` below.
private struct RestEnvelope: Decodable {
    let code: Int
    let message: String
}

private struct ResultWrapper<Value: Decodable>: Decodable {
    let result: Value
}

/// `POST /send_code` and `POST /login` against `chat-server-pro`'s
/// `LoginController`. Both endpoints always return HTTP 200; failure is a
/// non-zero `code` field in the `RestResult` envelope, never a 4xx/5xx
/// status.
public final class LoginAPIClient: LoginAPIClientProtocol {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func requestCode(mobile: String) async throws {
        let _: Bool = try await post("/send_code", params: ["mobile": mobile])
    }

    public func login(mobile: String, code: String, clientId: String) async throws -> LoginResult {
        struct LoginResponseResult: Decodable {
            let userId: String
            let token: String
            let register: Bool
        }
        let result: LoginResponseResult = try await post(
            "/login",
            params: ["mobile": mobile, "code": code, "clientId": clientId]
        )
        return LoginResult(userId: result.userId, token: result.token, isNewRegistration: result.register)
    }

    /// Decodes the `RestResult` envelope (`code`/`message` only) first,
    /// before attempting to decode `result` as `T` — error responses may
    /// shape `result` differently (or omit it) from success responses, so
    /// decoding it eagerly as `T` would crash on a perfectly normal error
    /// reply instead of surfacing `.server(code:message:)`.
    private func post<T: Decodable>(_ path: String, params: [String: String]) async throws -> T {
        // Strip any trailing slash from `baseURL` defensively before appending
        // `path` (which always starts with "/"): `appendingPathComponent`
        // would otherwise double the slash if `baseURL` ever has a trailing
        // one. `AppConfig.production`'s value happens not to have one today,
        // but `AppConfig` is a public, freely-constructible struct, so this
        // guards against a future custom-server value that does.
        let baseURLString = baseURL.absoluteString
        let trimmedBase = baseURLString.hasSuffix("/") ? String(baseURLString.dropLast()) : baseURLString
        var request = URLRequest(url: URL(string: trimmedBase + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&").utf8)

        let (data, _) = try await session.data(for: request)

        // Decode failures (malformed/unexpected JSON shape) collapse to
        // `.invalidResponse` without preserving the underlying
        // `DecodingError` — accepted for Phase 1 since there's no logging
        // facility yet, the same accepted gap documented in
        // `ReceiveMessageHandler` and `CredentialsStore`.
        guard let envelope = try? JSONDecoder().decode(RestEnvelope.self, from: data) else {
            throw LoginAPIError.invalidResponse
        }
        guard envelope.code == 0 else {
            throw LoginAPIError.server(code: envelope.code, message: envelope.message)
        }

        guard let wrapper = try? JSONDecoder().decode(ResultWrapper<T>.self, from: data) else {
            throw LoginAPIError.invalidResponse
        }
        return wrapper.result
    }
}
