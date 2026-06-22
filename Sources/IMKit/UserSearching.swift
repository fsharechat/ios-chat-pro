// Sources/IMKit/UserSearching.swift
import IMContacts

/// Narrow interface `SearchUserViewModel` depends on instead of the
/// concrete `ContactSyncService` — same decoupling-for-testability pattern
/// as `ImageUploading`/`ContactInfoFetching`.
public protocol UserSearching: AnyObject {
    func searchUser(keyword: String, completion: @escaping (Result<[String], Error>) -> Void)
}

extension ContactSyncService: UserSearching {}
