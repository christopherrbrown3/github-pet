import Foundation
import ServiceManagement
import Testing
@testable import GitHubPetCore

private struct FakeError: LocalizedError { var errorDescription: String? { "denied" } }

private final class FakeBackend: LoginItemBackend, @unchecked Sendable {
    var status: LoginItemStatus
    /// Status after a successful register (a fresh registration may still need approval).
    var statusAfterRegister: LoginItemStatus = .enabled
    var registerError: Error?
    var unregisterError: Error?
    private(set) var calls: [String] = []

    init(_ status: LoginItemStatus) { self.status = status }

    func register() throws {
        calls.append("register")
        if let registerError { throw registerError }
        status = statusAfterRegister
    }

    func unregister() throws {
        calls.append("unregister")
        if let unregisterError { throw unregisterError }
        status = .disabled
    }
}

@Suite struct LoginItemTests {
    @Test func systemStatusesMapToOurStatuses() {
        #expect(LoginItemStatus(.enabled) == .enabled)
        #expect(LoginItemStatus(.notRegistered) == .disabled)
        #expect(LoginItemStatus(.requiresApproval) == .requiresApproval)
        #expect(LoginItemStatus(.notFound) == .notFound)
    }

    @Test func enablingRegistersAndReportsTheNewStatus() {
        let backend = FakeBackend(.disabled)
        let result = LoginItem(backend: backend).setEnabled(true)
        #expect(result == LoginItemResult(status: .enabled, failure: nil))
        #expect(backend.calls == ["register"])
    }

    @Test func approvalIsReportedNotAssumedAway() {
        let backend = FakeBackend(.disabled)
        backend.statusAfterRegister = .requiresApproval
        let result = LoginItem(backend: backend).setEnabled(true)
        #expect(result.status == .requiresApproval && result.failure == nil)
        #expect(result.status.isRegistered)
        #expect(result.status.explanation?.contains("Login Items") == true)
    }

    @Test func alreadyEnabledIsNotRegisteredAgain() {
        let backend = FakeBackend(.enabled)
        #expect(LoginItem(backend: backend).setEnabled(true).status == .enabled)
        #expect(backend.calls.isEmpty)
    }

    /// Already registered and waiting for the user's approval: enabling again must not call
    /// register() (which can throw for a pending item) and is pending approval, not a failure.
    @Test func requiresApprovalIsPendingNotRegisteredAgainAndCanBeUnregistered() {
        for registerError in [nil, FakeError()] as [Error?] {
            let again = FakeBackend(.requiresApproval)
            again.registerError = registerError
            let result = LoginItem(backend: again).setEnabled(true)
            #expect(result == LoginItemResult(status: .requiresApproval, failure: nil))
            #expect(again.calls.isEmpty, "a pending registration is not registered again")
            #expect(result.status.explanation?.contains("Login Items") == true)
        }
        let off = FakeBackend(.requiresApproval)
        #expect(LoginItem(backend: off).setEnabled(false).status == .disabled)
        #expect(off.calls == ["unregister"])
    }

    @Test func disablingUnregistersOnlyWhenRegistered() {
        let on = FakeBackend(.enabled)
        #expect(LoginItem(backend: on).setEnabled(false) == LoginItemResult(status: .disabled, failure: nil))
        #expect(on.calls == ["unregister"])
        for status in [LoginItemStatus.disabled, .notFound] {
            let backend = FakeBackend(status)
            #expect(LoginItem(backend: backend).setEnabled(false).status == status)
            #expect(backend.calls.isEmpty, "\(status)")
        }
    }

    @Test func notFoundSurfacesTheSystemErrorAndStaysNotFound() {
        let backend = FakeBackend(.notFound)
        backend.registerError = FakeError()
        let result = LoginItem(backend: backend).setEnabled(true)
        #expect(result == LoginItemResult(status: .notFound, failure: "denied"))
        #expect(result.status.explanation?.contains("Applications") == true)
    }

    @Test func aFailedUnregisterKeepsTheRealStatus() {
        let backend = FakeBackend(.enabled)
        backend.unregisterError = FakeError()
        #expect(LoginItem(backend: backend).setEnabled(false) == LoginItemResult(status: .enabled, failure: "denied"))
    }

    @Test func plainStatusesNeedNoExplanation() {
        #expect(LoginItemStatus.enabled.explanation == nil)
        #expect(LoginItemStatus.disabled.explanation == nil)
        #expect(!LoginItemStatus.disabled.isRegistered && !LoginItemStatus.notFound.isRegistered)
    }
}
