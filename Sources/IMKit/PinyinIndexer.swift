// Sources/IMKit/PinyinIndexer.swift
import Foundation

/// Converts a display name into an A-Z (or "#") section letter for the
/// contacts list's pinyin grouping/index sidebar, and a sort key for
/// ordering names within a section. Uses iOS's built-in Latin
/// transliteration (`applyingTransform(.toLatin:)`, backed by
/// `CFStringTransform`/`kCFStringTransformToLatin`) plus diacritic
/// stripping — no third-party pinyin library needed, unlike Android's
/// `pinyin4j`.
///
/// Accepted Phase-1 limitation: polyphonic Chinese characters (e.g. "重" can
/// be "chóng" or "zhòng") aren't guaranteed to match whichever reading
/// Android's `pinyin4j` would pick — this can make the same name sort under
/// a different letter than on Android. Sorting is still deterministic on
/// this platform: the same name always produces the same letter/key here.
public enum PinyinIndexer {
    public static func sectionLetter(for name: String) -> String {
        transliteratedFirstLetter(of: name) ?? "#"
    }

    public static func sortKey(for name: String) -> String {
        transliterate(name)?.lowercased() ?? name.lowercased()
    }

    private static func transliterate(_ name: String) -> String? {
        guard !name.isEmpty, let latin = name.applyingTransform(.toLatin, reverse: false) else { return nil }
        return latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
    }

    private static func transliteratedFirstLetter(of name: String) -> String? {
        guard let latin = transliterate(name)?.uppercased(),
              let firstLetter = latin.first(where: { $0.isASCII && $0.isLetter }) else { return nil }
        return String(firstLetter)
    }
}
