import Foundation

/// A fully-decoded wire frame: header plus its complete body bytes.
public struct Frame: Equatable {
    public let header: Header
    public let body: Data

    public init(header: Header, body: Data) {
        self.header = header
        self.body = body
    }
}
