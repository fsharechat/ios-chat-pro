import XCTest
import Combine
@testable import IMStorage

final class ConversationStoreTests: XCTestCase {
    private var database: IMDatabase!
    private var store: ConversationStore!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try IMDatabase.openInMemory()
        store = ConversationStore(dbQueue: database.dbQueue)
        cancellables = []
    }

    func test_recordIncomingMessage_createsConversationIfMissing() throws {
        try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 10, timestamp: 1_000, incrementUnread: true)

        let conversation = try store.conversation(conversationType: .single, target: "u2")
        XCTAssertEqual(conversation?.lastMessageUid, 10)
        XCTAssertEqual(conversation?.timestamp, 1_000)
        XCTAssertEqual(conversation?.unreadCount, 1)
    }

    func test_recordIncomingMessage_updatesExistingConversationAndAccumulatesUnread() throws {
        try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 10, timestamp: 1_000, incrementUnread: true)
        try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 11, timestamp: 2_000, incrementUnread: true)

        let conversation = try store.conversation(conversationType: .single, target: "u2")
        XCTAssertEqual(conversation?.lastMessageUid, 11)
        XCTAssertEqual(conversation?.timestamp, 2_000)
        XCTAssertEqual(conversation?.unreadCount, 2)
    }

    func test_recordIncomingMessage_withIncrementUnreadFalse_doesNotChangeUnreadCount() throws {
        // e.g. recording my own sent message — shouldn't mark my own conversation unread
        try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 10, timestamp: 1_000, incrementUnread: false)

        XCTAssertEqual(try store.conversation(conversationType: .single, target: "u2")?.unreadCount, 0)
    }

    func test_clearUnread_resetsCountToZero() throws {
        try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 10, timestamp: 1_000, incrementUnread: true)

        try store.clearUnread(conversationType: .single, target: "u2", line: 0)

        XCTAssertEqual(try store.conversation(conversationType: .single, target: "u2")?.unreadCount, 0)
    }

    func test_setDraft_storesDraftText() throws {
        try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 10, timestamp: 1_000, incrementUnread: false)

        try store.setDraft("unsent text", conversationType: .single, target: "u2", line: 0)

        XCTAssertEqual(try store.conversation(conversationType: .single, target: "u2")?.draft, "unsent text")
    }

    func test_conversations_ordersByTimestampDescending() throws {
        try store.recordIncomingMessage(conversationType: .single, target: "older", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: false)
        try store.recordIncomingMessage(conversationType: .single, target: "newer", line: 0, messageUid: 2, timestamp: 2_000, incrementUnread: false)

        let conversations = try store.conversations()

        XCTAssertEqual(conversations.map { $0.target }, ["newer", "older"])
    }

    func test_conversationsPublisher_emitsOnInsertAndOnUpdate() throws {
        var receivedCounts: [Int] = []
        let expectation = expectation(description: "received at least 2 updates")
        expectation.expectedFulfillmentCount = 2

        store.conversationsPublisher()
            .sink(receiveCompletion: { _ in }, receiveValue: { conversations in
                receivedCounts.append(conversations.count)
                expectation.fulfill()
            })
            .store(in: &cancellables)

        try store.recordIncomingMessage(conversationType: .single, target: "u2", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: true)

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(receivedCounts, [0, 1]) // initial empty list, then one conversation
    }

    func test_conversations_sortsPinnedConversationsFirstRegardlessOfTimestamp() throws {
        try store.recordIncomingMessage(conversationType: .single, target: "newer", line: 0, messageUid: 1, timestamp: 2_000, incrementUnread: false)
        try store.recordIncomingMessage(conversationType: .single, target: "olderButPinned", line: 0, messageUid: 2, timestamp: 1_000, incrementUnread: false)
        try store.setTop(true, conversationType: .single, target: "olderButPinned", line: 0)

        let conversations = try store.conversations()

        XCTAssertEqual(conversations.map { $0.target }, ["olderButPinned", "newer"])
    }

    func test_recordIncomingMessage_withIncrementMentionTrue_incrementsUnreadMentionCount() throws {
        try store.recordIncomingMessage(conversationType: .group, target: "g1", line: 0, messageUid: 10, timestamp: 1_000, incrementUnread: true, incrementMention: true)

        let conversation = try store.conversation(conversationType: .group, target: "g1")
        XCTAssertEqual(conversation?.unreadMentionCount, 1)
    }

    func test_recordIncomingMessage_withIncrementMentionFalse_doesNotChangeUnreadMentionCount() throws {
        try store.recordIncomingMessage(conversationType: .group, target: "g1", line: 0, messageUid: 10, timestamp: 1_000, incrementUnread: true, incrementMention: false)

        XCTAssertEqual(try store.conversation(conversationType: .group, target: "g1")?.unreadMentionCount, 0)
    }

    func test_clearUnread_alsoResetsUnreadMentionCount() throws {
        try store.recordIncomingMessage(conversationType: .group, target: "g1", line: 0, messageUid: 10, timestamp: 1_000, incrementUnread: true, incrementMention: true)

        try store.clearUnread(conversationType: .group, target: "g1", line: 0)

        XCTAssertEqual(try store.conversation(conversationType: .group, target: "g1")?.unreadMentionCount, 0)
    }

    func test_setMuted_true_storesMutedFlag() throws {
        try store.recordIncomingMessage(conversationType: .group, target: "g1", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: false)

        try store.setMuted(true, conversationType: .group, target: "g1", line: 0)

        XCTAssertEqual(try store.conversation(conversationType: .group, target: "g1")?.isMuted, true)
    }

    func test_setMuted_false_clearsMutedFlag() throws {
        try store.recordIncomingMessage(conversationType: .group, target: "g1", line: 0, messageUid: 1, timestamp: 1_000, incrementUnread: false)
        try store.setMuted(true, conversationType: .group, target: "g1", line: 0)

        try store.setMuted(false, conversationType: .group, target: "g1", line: 0)

        XCTAssertEqual(try store.conversation(conversationType: .group, target: "g1")?.isMuted, false)
    }
}
