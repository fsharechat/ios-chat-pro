import XCTest
@testable import IMTransport

/// SubSignal 的 rawValue 是二进制协议的一部分，与 chat-server-pro 的两份
/// Java 副本、android-chat-pro 的一份逐位对齐。只允许在末尾追加；
/// 任何插入或重排都会让线上客户端解析错位。
final class SubSignalOrdinalTest: XCTestCase {

    func testExistingRawValuesAreNotShifted() {
        XCTAssertEqual(SubSignal.none.rawValue, 0)
        XCTAssertEqual(SubSignal.us.rawValue, 9)
        XCTAssertEqual(SubSignal.gpgi.rawValue, 22)
        XCTAssertEqual(SubSignal.sai.rawValue, 40)
    }

    func testUserSettingSignalsAreAppendedAtTheEnd() {
        XCTAssertEqual(SubSignal.ug.rawValue, 41)
        XCTAssertEqual(SubSignal.up.rawValue, 42)
        XCTAssertEqual(SubSignal.un.rawValue, 43)
    }

    func testRawValueInitResolvesUserSettingSignals() {
        XCTAssertEqual(SubSignal(rawValue: 41), .ug)
        XCTAssertEqual(SubSignal(rawValue: 42), .up)
        XCTAssertEqual(SubSignal(rawValue: 43), .un)
    }

    func testSpeechToTextSignalIsAppendedAfterUserSetting() {
        XCTAssertEqual(SubSignal.asr.rawValue, 44)
        XCTAssertEqual(SubSignal(rawValue: 44), .asr)
    }
}
