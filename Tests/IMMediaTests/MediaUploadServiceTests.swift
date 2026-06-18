import XCTest
import IMClient
import IMTransport
import IMProto
@testable import IMMedia

final class MediaUploadServiceTests: XCTestCase {
    private var fakeTransport: FakeTransportConnection!
    private var imClient: IMClient!
    private var service: MediaUploadService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fakeTransport = FakeTransportConnection()

        let plaintext = Data("\(Data("password".utf8).base64EncodedString())|mySecretKey12345|ignored".utf8)
        let token = try WireCrypto.encrypt(plaintext, key: WireCrypto.defaultKey).base64EncodedString()
        let configuration = IMClientConfiguration(hosts: "host", port: 6789, userId: "u1", token: token, clientIdentifier: "device-1")
        imClient = try IMClient(configuration: configuration, transportFactory: { [unowned self] _, _ in self.fakeTransport })
        service = MediaUploadService(imClient: imClient, session: MockURLProtocol.makeSession(), nowMillis: { 1_000 })

        imClient.connect()
        fakeTransport.simulate(.connected)
        fakeTransport.completeOldestSend()
    }

    private func decodeOnlySentFrame() throws -> Frame {
        try XCTUnwrap(FrameDecoder().feed(fakeTransport.sentFrames.last!).first)
    }

    private func simulateGMURLResponse(domain: String, url: String) throws {
        var result = Im_GetMinioUploadUrlResult()
        result.domain = domain
        result.url = url
        let body = Data([0x00]) + (try result.serializedData())
        let frame = try decodeOnlySentFrame()
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .gmurl, messageId: frame.header.messageId, body: body)
        fakeTransport.simulateReceivedData(frameBytes)
    }

    func test_uploadImage_sendsGMURLRequestWithExpectedKeyAndType() throws {
        service.uploadImage(Data([0x01])) { _ in }

        let frame = try decodeOnlySentFrame()
        XCTAssertEqual(frame.header.signal, .publish)
        XCTAssertEqual(frame.header.subSignal, .gmurl)
        let request = try Im_GetMinioUploadUrlRequest(serializedBytes: frame.body)
        XCTAssertEqual(request.type, 1)
        XCTAssertEqual(request.key, "1-u1-1000.png")
    }

    func test_uploadImage_endToEnd_returnsConstructedRemoteURL() throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        var capturedResult: Result<String, MediaUploadError>?
        let expectation = expectation(description: "upload completes")
        service.uploadImage(Data([0x01, 0x02])) { result in
            capturedResult = result
            expectation.fulfill()
        }

        try simulateGMURLResponse(domain: "https://media.example.com", url: "https://put.example.com/presigned")
        wait(for: [expectation], timeout: 2)

        switch capturedResult {
        case .success(let url): XCTAssertEqual(url, "https://media.example.com/1-u1-1000.png")
        default: XCTFail("expected .success, got \(String(describing: capturedResult))")
        }
    }

    func test_uploadImage_httpPutFailure_resolvesWithHttpFailureError() throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        var capturedResult: Result<String, MediaUploadError>?
        let expectation = expectation(description: "upload completes")
        service.uploadImage(Data([0x01])) { result in
            capturedResult = result
            expectation.fulfill()
        }

        try simulateGMURLResponse(domain: "https://media.example.com", url: "https://put.example.com/presigned")
        wait(for: [expectation], timeout: 2)

        switch capturedResult {
        case .failure(.httpFailure(let statusCode)): XCTAssertEqual(statusCode, 500)
        default: XCTFail("expected .httpFailure, got \(String(describing: capturedResult))")
        }
    }

    func test_uploadImage_wireErrorResponse_resolvesWithWireError() throws {
        var capturedResult: Result<String, MediaUploadError>?
        let expectation = expectation(description: "upload completes")
        service.uploadImage(Data([0x01])) { result in
            capturedResult = result
            expectation.fulfill()
        }

        let frame = try decodeOnlySentFrame()
        let frameBytes = FrameEncoder.encode(signal: .pubAck, subSignal: .gmurl, messageId: frame.header.messageId, body: Data([0x06]))
        fakeTransport.simulateReceivedData(frameBytes)
        wait(for: [expectation], timeout: 2)

        switch capturedResult {
        case .failure(.wireError(.serverError(let code))): XCTAssertEqual(code, 6)
        default: XCTFail("expected .wireError(.serverError), got \(String(describing: capturedResult))")
        }
    }
}
