// Sources/IMKit/SingleConversationInfoViewModel.swift
import Foundation
import Combine
import IMStorage

public final class SingleConversationInfoViewModel {
    @Published public private(set) var isTop: Bool = false
    @Published public private(set) var isMuted: Bool = false

    private let storage: IMStorage
    public let userId: String

    public init(userId: String, storage: IMStorage) {
        self.userId = userId
        self.storage = storage
        if let conv = try? storage.conversations.conversation(conversationType: .single, target: userId) {
            isTop = conv.isTop
            isMuted = conv.isMuted
        }
    }

    public func userInfo() -> StoredUser? {
        try? storage.users.user(uid: userId)
    }

    public func setTop(_ value: Bool) {
        isTop = value
        try? storage.conversations.setTop(value, conversationType: .single, target: userId)
    }

    public func setMuted(_ value: Bool) {
        isMuted = value
        try? storage.conversations.setMuted(value, conversationType: .single, target: userId)
    }

    public func clearMessages(completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try storage.messages.clearMessages(conversationType: .single, target: userId)
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    public func searchMessages(keyword: String) -> [StoredMessage] {
        (try? storage.messages.searchMessages(conversationType: .single, target: userId, keyword: keyword)) ?? []
    }
}
