import XCTest
@testable import AppCore

final class DeviceIdentifierProviderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var provider: DeviceIdentifierProvider!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "DeviceIdentifierProviderTests-\(UUID().uuidString)")
        provider = DeviceIdentifierProvider(defaults: defaults)
    }

    /// No hyphens: the server's `PushUtil.pushMessageByBsId` misroutes any
    /// `bsId` containing `"-"` to its WebSocket delivery path, silently
    /// dropping `PUB_ACK`s meant for this TCP client. A standard
    /// `UUID().uuidString` would trip that check, so this id must be
    /// hyphen-free while still being derived from a UUID for uniqueness.
    func test_currentIdentifier_generatesAHyphenFreeUUIDDerivedStringOnFirstCall() {
        let identifier = provider.currentIdentifier()
        XCTAssertFalse(identifier.contains("-"))
        XCTAssertNotNil(UUID(uuidString: identifier.insertingHyphensAsUUID()))
    }

    func test_currentIdentifier_returnsTheSameValueOnSubsequentCalls() {
        let first = provider.currentIdentifier()
        let second = provider.currentIdentifier()
        XCTAssertEqual(first, second)
    }

    func test_currentIdentifier_persistsAcrossProviderInstances() {
        let first = provider.currentIdentifier()
        let secondProvider = DeviceIdentifierProvider(defaults: defaults)
        XCTAssertEqual(secondProvider.currentIdentifier(), first)
    }

    /// Installs that persisted a hyphenated id before this fix shipped must
    /// self-heal on their very next launch, not require a fresh install.
    func test_currentIdentifier_migratesAPreviouslyStoredHyphenatedId() {
        let staleHyphenated = UUID().uuidString
        defaults.set(staleHyphenated, forKey: "AppCore.deviceIdentifier")

        let migrated = provider.currentIdentifier()

        XCTAssertFalse(migrated.contains("-"))
        XCTAssertEqual(migrated, staleHyphenated.replacingOccurrences(of: "-", with: ""))
        // The migration is persisted, not recomputed on every call.
        XCTAssertEqual(defaults.string(forKey: "AppCore.deviceIdentifier"), migrated)
    }
}

private extension String {
    /// Reinserts standard UUID hyphen positions (8-4-4-4-12) so a
    /// hyphen-stripped id can still be round-tripped through `UUID(uuidString:)`
    /// to confirm it's still 32 valid hex characters underneath.
    func insertingHyphensAsUUID() -> String {
        guard count == 32 else { return self }
        var result = self
        // Insert highest offset first so earlier (lower) offsets stay valid.
        for offset in [20, 16, 12, 8] {
            let index = result.index(result.startIndex, offsetBy: offset)
            result.insert("-", at: index)
        }
        return result
    }
}
