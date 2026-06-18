import Foundation
import Combine
import IMClient
// Disambiguates `Scheduler` from `Combine.Scheduler` (also in scope, for
// `@Published`/`AnyCancellable`): plain `IMClient.Scheduler` doesn't work
// here because the `IMClient` module also contains a same-named `IMClient`
// class, which shadows the module name in qualified lookups. This selective
// import takes precedence over the ambiguous unqualified `Scheduler` lookup.
import protocol IMClient.Scheduler

/// **Threading contract:** like the rest of this codebase (see `IMClient`'s
/// own threading-contract doc comment), this has no internal locking and
/// must be called from a single consistent queue — by convention the main
/// queue, since `requestCode()`/`login()` are driven by UIKit button taps.
public final class LoginViewModel {
    @Published public var phoneNumber: String = ""
    @Published public var code: String = ""
    @Published public private(set) var isRequestCodeEnabled = false
    @Published public private(set) var isLoginEnabled = false
    @Published public private(set) var requestCodeCountdown = 0
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?

    /// Fires after a successful login, after credentials are already
    /// persisted to `credentialsStore` — whoever owns this view model
    /// reacts to this to construct `IMClient`/`MessagingService` and switch
    /// the root view controller. `LoginViewModel` itself never touches
    /// `IMClient`.
    public var onLoginSucceeded: ((Credentials) -> Void)?

    private let apiClient: LoginAPIClientProtocol
    private let credentialsStore: CredentialsStore
    private let deviceIdentifierProvider: DeviceIdentifierProvider
    private let scheduler: Scheduler
    private var countdownToken: SchedulerToken?
    private var cancellables = Set<AnyCancellable>()

    public init(
        apiClient: LoginAPIClientProtocol,
        credentialsStore: CredentialsStore,
        deviceIdentifierProvider: DeviceIdentifierProvider,
        scheduler: Scheduler = DispatchQueueScheduler()
    ) {
        self.apiClient = apiClient
        self.credentialsStore = credentialsStore
        self.deviceIdentifierProvider = deviceIdentifierProvider
        self.scheduler = scheduler

        $phoneNumber.combineLatest($code)
            .sink { [weak self] phone, code in self?.updateButtonStates(phone: phone, code: code) }
            .store(in: &cancellables)
    }

    private func updateButtonStates(phone: String, code: String) {
        let validIdentifier = phone.count == 11 || phone.contains("@")
        isRequestCodeEnabled = validIdentifier && requestCodeCountdown == 0
        isLoginEnabled = code.count > 2
    }

    public func requestCode() async {
        guard isRequestCodeEnabled else { return }
        errorMessage = nil
        do {
            try await apiClient.requestCode(mobile: phoneNumber)
            startCountdown()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    private func startCountdown() {
        requestCodeCountdown = 60
        isRequestCodeEnabled = false
        tickCountdown()
    }

    private func tickCountdown() {
        countdownToken = scheduler.scheduleOnce(after: 1) { [weak self] in
            guard let self else { return }
            self.requestCodeCountdown -= 1
            if self.requestCodeCountdown > 0 {
                self.tickCountdown()
            } else {
                self.updateButtonStates(phone: self.phoneNumber, code: self.code)
            }
        }
    }

    public func login() async {
        guard isLoginEnabled, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let clientId = deviceIdentifierProvider.currentIdentifier()
            let result = try await apiClient.login(mobile: phoneNumber, code: code, clientId: clientId)
            let credentials = Credentials(userId: result.userId, token: result.token)
            credentialsStore.save(credentials)
            onLoginSucceeded?(credentials)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let apiError = error as? LoginAPIError, case .server(_, let message) = apiError {
            return message
        }
        return "网络出来问题了。。。"
    }
}
