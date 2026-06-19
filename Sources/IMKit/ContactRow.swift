public struct ContactRow: Equatable, Hashable {
    public let uid: String
    public let displayName: String
    public let avatarURL: String?
    public let sectionLetter: String

    public init(uid: String, displayName: String, avatarURL: String?, sectionLetter: String) {
        self.uid = uid
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.sectionLetter = sectionLetter
    }
}
