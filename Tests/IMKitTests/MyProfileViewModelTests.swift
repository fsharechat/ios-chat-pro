import XCTest
import Combine
import IMStorage
@testable import IMKit

private final class FakeContactInfoFetcher: ContactInfoFetching {
    private(set) var fetchedUids: [String] = []
    private(set) var lastForceRefresh: Bool?

    func fetchUserInfo(uids: [String], forceRefresh: Bool) {
        fetchedUids.append(contentsOf: uids)
        lastForceRefresh = forceRefresh
    }
}

private final class FakeProfileUpdating: ProfileUpdating {
    private(set) var updatedDisplayNames: [String] = []
    private(set) var updatedPortraits: [String] = []
    var nextResult: Result<Void, Error> = .success(())

    func updateDisplayName(_ name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        updatedDisplayNames.append(name)
        completion(nextResult)
    }

    func updatePortrait(_ url: String, completion: @escaping (Result<Void, Error>) -> Void) {
        updatedPortraits.append(url)
        completion(nextResult)
    }
}

final class MyProfileViewModelTests: XCTestCase {
    private var storage: IMStorage!
    private var fetcher: FakeContactInfoFetcher!
    private var updating: FakeProfileUpdating!
    private var viewModel: MyProfileViewModel!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try IMStorage.openInMemory()
        fetcher = FakeContactInfoFetcher()
        updating = FakeProfileUpdating()
    }

    func test_init_publishesDisplayNameAndAvatarFromUserStore() throws {
        viewModel = MyProfileViewModel(myUid: "me", storage: storage, profileUpdating: updating, contactSync: fetcher)

        let expectation = expectation(description: "displayName published")
        viewModel.$displayName
            .dropFirst() // initial "" emitted synchronously at subscribe time, before the seeded profile below resolves
            .sink { name in
                if name == "Alice" { expectation.fulfill() }
            }
            .store(in: &cancellables)

        try storage.users.upsertProfile(uid: "me", name: "real", displayName: "Alice", portrait: "https://example.com/a.png", mobile: nil, gender: 0, updateDt: 0)

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(viewModel.avatarURL, "https://example.com/a.png")
    }

    func test_init_fallsBackToNameThenUidWhenNoDisplayName() throws {
        viewModel = MyProfileViewModel(myUid: "me", storage: storage, profileUpdating: updating, contactSync: fetcher)

        let expectation = expectation(description: "displayName falls back to name")
        viewModel.$displayName
            .dropFirst()
            .sink { name in if name == "real-name" { expectation.fulfill() } }
            .store(in: &cancellables)

        try storage.users.upsertProfile(uid: "me", name: "real-name", displayName: nil, portrait: nil, mobile: nil, gender: 0, updateDt: 0)

        wait(for: [expectation], timeout: 2)
    }

    func test_init_alwaysCallsFetchUserInfoForMyUid() {
        viewModel = MyProfileViewModel(myUid: "me", storage: storage, profileUpdating: updating, contactSync: fetcher)

        XCTAssertEqual(fetcher.fetchedUids, ["me"])
        XCTAssertEqual(fetcher.lastForceRefresh, false)
    }

    func test_updateDisplayName_forwardsToProfileUpdating() {
        viewModel = MyProfileViewModel(myUid: "me", storage: storage, profileUpdating: updating, contactSync: fetcher)

        var capturedResult: Result<Void, Error>?
        viewModel.updateDisplayName("New") { result in capturedResult = result }

        XCTAssertEqual(updating.updatedDisplayNames, ["New"])
        switch capturedResult {
        case .success: break
        default: XCTFail("expected .success, got \(String(describing: capturedResult))")
        }
    }

    func test_updatePortrait_forwardsToProfileUpdating() {
        viewModel = MyProfileViewModel(myUid: "me", storage: storage, profileUpdating: updating, contactSync: fetcher)

        viewModel.updatePortrait("https://example.com/new.png") { _ in }

        XCTAssertEqual(updating.updatedPortraits, ["https://example.com/new.png"])
    }
}
