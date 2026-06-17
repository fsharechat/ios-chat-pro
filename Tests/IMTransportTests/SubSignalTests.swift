import XCTest
@testable import IMTransport

final class SubSignalTests: XCTestCase {
    func test_rawValuesMatchAndroidOrdinals() {
        XCTAssertEqual(SubSignal.none.rawValue, 0)
        XCTAssertEqual(SubSignal.connectionAccepted.rawValue, 1)
        XCTAssertEqual(SubSignal.connectionRefusedUnacceptableProtocolVersion.rawValue, 2)
        XCTAssertEqual(SubSignal.connectionRefusedIdentifierRejected.rawValue, 3)
        XCTAssertEqual(SubSignal.connectionRefusedServerUnavailable.rawValue, 4)
        XCTAssertEqual(SubSignal.connectionRefusedBadUserNameOrPassword.rawValue, 5)
        XCTAssertEqual(SubSignal.connectionRefusedNotAuthorized.rawValue, 6)
        XCTAssertEqual(SubSignal.connectionRefusedUnexpectNode.rawValue, 7)
        XCTAssertEqual(SubSignal.connectionRefusedSessionNotExist.rawValue, 8)
        XCTAssertEqual(SubSignal.us.rawValue, 9)
        XCTAssertEqual(SubSignal.far.rawValue, 10)
        XCTAssertEqual(SubSignal.upui.rawValue, 11)
        XCTAssertEqual(SubSignal.frn.rawValue, 12)
        XCTAssertEqual(SubSignal.frus.rawValue, 13)
        XCTAssertEqual(SubSignal.frp.rawValue, 14)
        XCTAssertEqual(SubSignal.fhr.rawValue, 15)
        XCTAssertEqual(SubSignal.fp.rawValue, 16)
        XCTAssertEqual(SubSignal.mn.rawValue, 17)
        XCTAssertEqual(SubSignal.ms.rawValue, 18)
        XCTAssertEqual(SubSignal.mp.rawValue, 19)
        XCTAssertEqual(SubSignal.fn.rawValue, 20)
        XCTAssertEqual(SubSignal.gc.rawValue, 21)
        XCTAssertEqual(SubSignal.gpgi.rawValue, 22)
        XCTAssertEqual(SubSignal.gpgm.rawValue, 23)
        XCTAssertEqual(SubSignal.gam.rawValue, 24)
        XCTAssertEqual(SubSignal.gkm.rawValue, 25)
        XCTAssertEqual(SubSignal.gq.rawValue, 26)
        XCTAssertEqual(SubSignal.gmi.rawValue, 27)
        XCTAssertEqual(SubSignal.mmi.rawValue, 28)
        XCTAssertEqual(SubSignal.gqnut.rawValue, 29)
        XCTAssertEqual(SubSignal.mr.rawValue, 30)
        XCTAssertEqual(SubSignal.rmn.rawValue, 31)
        XCTAssertEqual(SubSignal.lrm.rawValue, 32)
        XCTAssertEqual(SubSignal.gd.rawValue, 33)
        XCTAssertEqual(SubSignal.gmurl.rawValue, 34)
        XCTAssertEqual(SubSignal.fals.rawValue, 35)
        XCTAssertEqual(SubSignal.mrn.rawValue, 36)
        XCTAssertEqual(SubSignal.mrp.rawValue, 37)
        XCTAssertEqual(SubSignal.mrr.rawValue, 38)
        XCTAssertEqual(SubSignal.mdr.rawValue, 39)
        XCTAssertEqual(SubSignal.sai.rawValue, 40)
    }

    func test_outOfRangeRawValueIsNil() {
        XCTAssertNil(SubSignal(rawValue: 41))
    }
}
