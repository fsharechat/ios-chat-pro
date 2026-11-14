import Foundation

/// Mention identity follows attributed ranges rather than display-name substring matching.
public enum ComposerMentions {
    public static let attributeKey = NSAttributedString.Key("FshareComposerMention")

    public final class Reference: NSObject {
        public let uid: String?
        public init(uid: String?) { self.uid = uid }
    }

    public static func expandedRange(for edit: NSRange, in text: NSAttributedString) -> NSRange {
        var expanded = edit
        text.enumerateAttribute(attributeKey, in: NSRange(location: 0, length: text.length)) { value, token, _ in
            guard value is Reference else { return }
            let intersects = NSIntersectionRange(token, edit).length > 0
            let insertsInside = edit.length == 0 && edit.location > token.location && edit.location < NSMaxRange(token)
            if intersects || insertsInside { expanded = NSUnionRange(expanded, token) }
        }
        return expanded
    }

    public static func recipients(in text: NSAttributedString) -> (type: Int32, targets: [String]) {
        var targets: [String] = []
        var all = false
        text.enumerateAttribute(attributeKey, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let reference = value as? Reference else { return }
            if let uid = reference.uid {
                if !targets.contains(uid) { targets.append(uid) }
            } else { all = true }
        }
        return (all ? 2 : (targets.isEmpty ? 0 : 1), all ? [] : targets)
    }
}
