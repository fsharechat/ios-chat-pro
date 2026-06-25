// Sources/IMKit/ProfileUpdating.swift
import Foundation
import IMContacts

/// Narrow interface `MyProfileViewModel` depends on instead of the
/// concrete `ContactSyncService` — same decoupling-for-testability pattern
/// as `ImageUploading`/`ContactInfoFetching`.
public protocol ProfileUpdating: AnyObject {
    func updateDisplayName(_ name: String, completion: @escaping (Result<Void, Error>) -> Void)
    func updatePortrait(_ url: String, completion: @escaping (Result<Void, Error>) -> Void)
}

extension ContactSyncService: ProfileUpdating {}
