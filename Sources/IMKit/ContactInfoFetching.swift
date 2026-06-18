import IMContacts

public protocol ContactInfoFetching {
    func fetchUserInfo(uids: [String], forceRefresh: Bool)
}

extension ContactSyncService: ContactInfoFetching {}
