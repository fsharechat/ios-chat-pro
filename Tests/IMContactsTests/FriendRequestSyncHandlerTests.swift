// Tests/IMContactsTests/FriendRequestSyncHandlerTests.swift
import XCTest
import IMClient
import IMTransport
import IMProto
import IMStorage
@testable import IMContacts

final class FriendRequestSyncHandlerTests: XCTestCase {
    private var storage: IMStorage!
    private var handler: FriendRequestSyncHandler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        handler = FriendRequestSyncHandler(storage: storage)
    }

    private func makeEntry(fromUid: String, toUid: String, updateDt: Int64) -> Im_FriendRequest {
        var entry = Im_FriendRequest()
        entry.fromUid = fromUid
        entry.toUid = toUid
        entry.reason = "hi"
        entry.status = 0
        entry.updateDt = updateDt
        entry.fromReadStatus = false
        entry.toReadStatus = false
        return entry
    }

    private func makeFrpFrame(errorCode: UInt8, entries: [Im_FriendRequest] = []) throws -> Frame {
        var result = Im_GetFriendRequestResult()
        result.entry = entries
        var body = Data([errorCode])
        body += try result.serializedData()
        return Frame(header: Header(signal: .pubAck, subSignal: .frp, bodyLength: UInt32(body.count), messageId: 1), body: body)
    }

    private func makeFrnFrame(headValue: Int64) -> Frame {
        var bytes = [UInt8](repeating: 0, count: 8)
        var value = headValue
        for index in stride(from: 7, through: 0, by: -1) {
            bytes[index] = UInt8(value & 0xff)
            value >>= 8
        }
        let body = Data(bytes)
        return Frame(header: Header(signal: .publish, subSignal: .frn, bodyLength: UInt32(body.count), messageId: 0), body: body)
    }

    func test_canHandle_matchesFRPPullResponseAndFRNNotify_butNothingElse() {
        XCTAssertTrue(handler.canHandle(signal: .pubAck, subSignal: .frp))
        XCTAssertTrue(handler.canHandle(signal: .publish, subSignal: .frn))
        XCTAssertFalse(handler.canHandle(signal: .pubAck, subSignal: .frn))
        XCTAssertFalse(handler.canHandle(signal: .publish, subSignal: .frp))
    }

    func test_handle_frpSuccessBody_upsertsEntriesAndAdvancesHeadToMaxUpdateDt() throws {
        let frame = try makeFrpFrame(errorCode: 0, entries: [
            makeEntry(fromUid: "u1", toUid: "me", updateDt: 100),
            makeEntry(fromUid: "u2", toUid: "me", updateDt: 300),
        ])

        handler.handle(frame: frame)

        let rows = try storage.dbQueueForTesting.read { db in try StoredFriendRequest.fetchAll(db) }
        XCTAssertEqual(Set(rows.map(\.fromUid)), ["u1", "u2"])
        XCTAssertEqual(try storage.syncState.get().friendRequestHead, 300)
    }

    func test_handle_frpEmptyResult_doesNotAdvanceHead() throws {
        var initial = try storage.syncState.get()
        initial.friendRequestHead = 50
        try storage.syncState.set(initial)

        let frame = try makeFrpFrame(errorCode: 0, entries: [])
        handler.handle(frame: frame)

        XCTAssertEqual(try storage.syncState.get().friendRequestHead, 50)
    }

    func test_handle_frpNonZeroErrorCode_doesNothingNoCrash() throws {
        let frame = try makeFrpFrame(errorCode: 1, entries: [makeEntry(fromUid: "u1", toUid: "me", updateDt: 100)])
        handler.handle(frame: frame)

        let rows = try storage.dbQueueForTesting.read { db in try StoredFriendRequest.fetchAll(db) }
        XCTAssertEqual(rows.count, 0)
    }

    func test_handle_frnNotify_writesDecodedValueMinusOneToHeadAndFiresCallback() {
        var callbackFired = false
        handler.onRemoteUpdateNotified = { callbackFired = true }

        handler.handle(frame: makeFrnFrame(headValue: 501))

        XCTAssertEqual(try? storage.syncState.get().friendRequestHead, 500)
        XCTAssertTrue(callbackFired)
    }

    func test_handle_frnNotify_shortBody_doesNothingNoCrash() {
        var callbackFired = false
        handler.onRemoteUpdateNotified = { callbackFired = true }

        let frame = Frame(header: Header(signal: .publish, subSignal: .frn, bodyLength: 3, messageId: 0), body: Data([0, 1, 2]))
        handler.handle(frame: frame) // must not crash

        XCTAssertFalse(callbackFired)
    }
}
