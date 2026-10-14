import XCTest
import GRDB
@testable import IMStorage

final class MessagePlayedStatusTests: XCTestCase {

    private func voice(_ localId: Int64, direction: MessageDirection, status: MessageStatus) -> StoredMessage {
        StoredMessage(
            localMessageId: localId, messageUid: 1000 + localId,
            conversationType: .single, target: "them", from: direction == .receive ? "them" : "me",
            content: .voice(remoteURL: "http://x/\(localId).amr", localPath: nil, duration: 3),
            timestamp: 1_000, status: status, direction: direction
        )
    }

    private func status(_ queue: DatabaseQueue, id: Int64) throws -> Int? {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT status FROM message WHERE id = ?", arguments: [id])
        }
    }

    func test_playedRawValueMatchesAndroid() {
        XCTAssertEqual(MessageStatus.played.rawValue, 7)
    }

    func test_markPlayed_updatesIncomingOnly() throws {
        let database = try IMDatabase.openInMemory()
        let store = MessageStore(dbQueue: database.dbQueue)
        let incoming = try store.insert(voice(1, direction: .receive, status: .unread))
        let outgoing = try store.insert(voice(2, direction: .send, status: .sent))

        try store.markPlayed(id: incoming.id!)
        try store.markPlayed(id: outgoing.id!)

        XCTAssertEqual(try status(database.dbQueue, id: incoming.id!), 7)
        XCTAssertEqual(try status(database.dbQueue, id: outgoing.id!), MessageStatus.sent.rawValue)
    }

    func test_v10_marksExistingIncomingVoiceAsPlayed() throws {
        let queue = try DatabaseQueue()
        try IMDatabase.migrator.migrate(queue, upTo: "v9_addUserSettingTable")
        try queue.write { db in
            for (localId, contentType, direction) in [(1, 2, 1), (2, 1, 1), (3, 2, 0)] {
                try db.execute(sql: """
                    INSERT INTO message (localMessageId, messageUid, conversationType, target, line, "from", contentType, timestamp, status, direction)
                    VALUES (?, ?, 0, 'them', 0, 'them', ?, 1000, ?, ?)
                    """, arguments: [localId, 100 + localId, contentType, direction == 1 ? 5 : 1, direction])
            }
        }

        try IMDatabase.migrator.migrate(queue)

        let statuses = try queue.read { db in
            try Int.fetchAll(db, sql: "SELECT status FROM message ORDER BY localMessageId")
        }
        XCTAssertEqual(statuses, [7, 5, 1])
    }
}
