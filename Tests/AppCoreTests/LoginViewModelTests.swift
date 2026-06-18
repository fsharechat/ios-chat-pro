import XCTest
import IMClient
@testable import AppCore

private final class StubLoginAPIClient: LoginAPIClientProtocol {
    var requestCodeError: Error?
    var loginResult: Result<AppCore.LoginResult, Error> = .success(AppCore.LoginResult(userId: "u1", token: "t1", isNewRegistration: false))
    private(set) var requestCodeCallCount = 0
    private(set) var lastLoginArgs: (mobile: String, code: String, clientId: String)?

    func requestCode(mobile: String) async throws {
        requestCodeCallCount += 1
        if let requestCodeError { throw requestCodeError }
    }

    func login(mobile: String, code: String, clientId: String) async throws -> AppCore.LoginResult {
        lastLoginArgs = (mobile, code, clientId)
        return try loginResult.get()
    }
}

final class LoginViewModelTests: XCTestCase {
    private var apiClient: StubLoginAPIClient!
    private var credentialsStore: CredentialsStore!
    private var deviceIdentifierProvider: DeviceIdentifierProvider!
    private var scheduler: ManualScheduler!
    private var viewModel: LoginViewModel!

    override func setUp() {
        super.setUp()
        apiClient = StubLoginAPIClient()
        credentialsStore = CredentialsStore(service: "LoginViewModelTests.\(UUID().uuidString)")
        deviceIdentifierProvider = DeviceIdentifierProvider(defaults: UserDefaults(suiteName: "LoginViewModelTests.\(UUID().uuidString)")!)
        scheduler = ManualScheduler()
        viewModel = LoginViewModel(apiClient: apiClient, credentialsStore: credentialsStore, deviceIdentifierProvider: deviceIdentifierProvider, scheduler: scheduler)
    }

    override func tearDown() {
        credentialsStore.clear()
        super.tearDown()
    }

    func test_initialState_bothButtonsDisabled() {
        XCTAssertFalse(viewModel.isRequestCodeEnabled)
        XCTAssertFalse(viewModel.isLoginEnabled)
    }

    func test_elevenDigitPhoneNumber_enablesRequestCodeButton() {
        viewModel.phoneNumber = "13800000000"
        XCTAssertTrue(viewModel.isRequestCodeEnabled)
    }

    func test_emailAddressContainingAtSign_alsoEnablesRequestCodeButton() {
        viewModel.phoneNumber = "user@example.com"
        XCTAssertTrue(viewModel.isRequestCodeEnabled)
    }

    func test_tenDigitPhoneNumber_keepsRequestCodeButtonDisabled() {
        viewModel.phoneNumber = "1380000000"
        XCTAssertFalse(viewModel.isRequestCodeEnabled)
    }

    func test_codeLongerThanTwoCharacters_enablesLoginButton() {
        viewModel.code = "123"
        XCTAssertTrue(viewModel.isLoginEnabled)
        viewModel.code = "12"
        XCTAssertFalse(viewModel.isLoginEnabled)
    }

    func test_requestCode_onSuccess_startsSixtySecondCountdownAndDisablesButton() async {
        viewModel.phoneNumber = "13800000000"
        await viewModel.requestCode()

        XCTAssertEqual(apiClient.requestCodeCallCount, 1)
        XCTAssertEqual(viewModel.requestCodeCountdown, 60)
        XCTAssertFalse(viewModel.isRequestCodeEnabled)
        XCTAssertEqual(scheduler.scheduledDelays, [1])
    }

    func test_requestCode_countdownTicksDownToZeroThenReenablesButton() async {
        viewModel.phoneNumber = "13800000000"
        await viewModel.requestCode()

        for expectedRemaining in stride(from: 59, through: 0, by: -1) {
            scheduler.fireNext()
            XCTAssertEqual(viewModel.requestCodeCountdown, expectedRemaining)
        }
        XCTAssertTrue(viewModel.isRequestCodeEnabled)
        XCTAssertFalse(scheduler.fireNext()) // nothing left scheduled
    }

    func test_requestCode_failure_setsErrorMessageAndDoesNotStartCountdown() async {
        apiClient.requestCodeError = LoginAPIError.server(code: 1, message: "invalid mobile")
        viewModel.phoneNumber = "13800000000"

        await viewModel.requestCode()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.requestCodeCountdown, 0)
        XCTAssertTrue(viewModel.isRequestCodeEnabled)
    }

    func test_login_onSuccess_savesCredentialsAndInvokesCallbackWithDeviceClientId() async {
        viewModel.phoneNumber = "13800000000"
        viewModel.code = "1234"
        var captured: Credentials?
        viewModel.onLoginSucceeded = { captured = $0 }

        await viewModel.login()

        XCTAssertEqual(captured?.userId, "u1")
        XCTAssertEqual(credentialsStore.load()?.userId, "u1")
        XCTAssertEqual(apiClient.lastLoginArgs?.mobile, "13800000000")
        XCTAssertEqual(apiClient.lastLoginArgs?.code, "1234")
        XCTAssertEqual(apiClient.lastLoginArgs?.clientId, deviceIdentifierProvider.currentIdentifier())
    }

    // NOTE: `startCountdown()` defensively cancels any existing
    // `countdownToken` before starting a new chain (see LoginViewModel.swift),
    // guarding against double-decrementing `requestCodeCountdown` if
    // `startCountdown()` were ever re-entered while a previous chain is still
    // in flight. Today, `requestCode()`'s `isRequestCodeEnabled` guard keeps
    // `isRequestCodeEnabled` and `requestCodeCountdown` in lockstep — both are
    // `private(set)`/private to this type, so there is no reachable path,
    // even via `@testable import`, to force a second `startCountdown()` call
    // while the first chain is still pending. This test instead locks in
    // that reachable invariant: calling `requestCode()` again while a
    // countdown is already running is a no-op, so the scheduler never has
    // more than one pending tick at a time.
    func test_requestCode_calledAgainWhileCountdownAlreadyRunning_isNoOpAndLeavesOnlyOneTickPending() async {
        viewModel.phoneNumber = "13800000000"
        await viewModel.requestCode() // starts the only countdown chain

        XCTAssertEqual(scheduler.pendingCount, 1)

        await viewModel.requestCode() // guarded no-op: isRequestCodeEnabled is false

        XCTAssertEqual(apiClient.requestCodeCallCount, 1) // API not called again
        XCTAssertEqual(scheduler.pendingCount, 1) // still only the original tick pending
        XCTAssertEqual(viewModel.requestCodeCountdown, 60) // untouched by the no-op call
    }

    func test_login_onFailure_setsErrorMessageAndDoesNotInvokeCallback() async {
        apiClient.loginResult = .failure(LoginAPIError.server(code: 6, message: "incorrect code"))
        viewModel.phoneNumber = "13800000000"
        viewModel.code = "0000"
        var invoked = false
        viewModel.onLoginSucceeded = { _ in invoked = true }

        await viewModel.login()

        XCTAssertFalse(invoked)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertNil(credentialsStore.load())
    }
}
