import XCTest
@testable import SmartTable

final class RefreshPolicyTests: XCTestCase {
    func testTimeoutAndConnectionLossAreTransientButLoginAndCancellationAreNot() {
        XCTAssertTrue(RefreshPolicy.isTransient(URLError(.timedOut)))
        XCTAssertTrue(RefreshPolicy.isTransient(URLError(.networkConnectionLost)))
        XCTAssertFalse(RefreshPolicy.isTransient(URLError(.cancelled)))
        XCTAssertFalse(RefreshPolicy.isTransient(PortalFailure.loginRequired))
        XCTAssertFalse(RefreshPolicy.isTransient(PortalFailure.unrecognized("курсы")))
    }
    func testRateLimitAndServerFailureUseBackoffButForbiddenDoesNotRetryImmediately() {
        XCTAssertTrue(RefreshPolicy.isTransient(PortalFailure.httpStatus(429)))
        XCTAssertTrue(RefreshPolicy.isTransient(PortalFailure.httpStatus(503)))
        XCTAssertFalse(RefreshPolicy.isTransient(PortalFailure.httpStatus(403)))
    }
    func testRetryDelayGrowsAndRemainsBounded() {
        XCTAssertEqual((1...6).map { RefreshPolicy.retryDelay(failures: $0) }, [60, 120, 240, 480, 900, 900])
        XCTAssertEqual(RefreshPolicy.retryDelay(failures: 1000), 900)
    }
    func testOfflineMessageOnlyClaimsSavedDataWhenAvailable() {
        XCTAssertEqual(PortalErrorMessage.message(for: URLError(.notConnectedToInternet), hasSavedData: true),
                       "Нет подключения к интернету. Показаны последние сохранённые данные.")
        XCTAssertEqual(PortalErrorMessage.message(for: URLError(.notConnectedToInternet)),
                       "Нет подключения к интернету. Попробуйте ещё раз.")
    }
    func testTLSAndTimeoutAreNotMisreportedAsNoInternet() {
        for code: URLError.Code in [.secureConnectionFailed, .serverCertificateUntrusted, .timedOut, .cannotFindHost] {
            XCTAssertEqual(PortalErrorMessage.message(for: URLError(code), hasSavedData: true),
                           "Не удаётся подключиться к ЭИОС. Показаны последние сохранённые данные.")
        }
        XCTAssertFalse(RefreshPolicy.isTransient(URLError(.secureConnectionFailed)))
        XCTAssertFalse(RefreshPolicy.isTransient(URLError(.serverCertificateUntrusted)))
    }
    func testConnectionCopyDoesNotReplaceParserOrLoginFailures() {
        for failure in [PortalFailure.loginRequired, .incompleteSchedule, .unrecognized("курсы")] {
            XCTAssertNil(PortalErrorMessage.connectionMessage(for: failure, hasSavedData: true))
            XCTAssertEqual(PortalErrorMessage.message(for: failure), failure.localizedDescription)
        }
        XCTAssertNil(PortalErrorMessage.connectionMessage(for: URLError(.cancelled), hasSavedData: true))
    }
    func testUnavailableServerHasFriendlyCopyWithoutErasingItsClassification() {
        let error = PortalFailure.httpStatus(503)
        XCTAssertEqual(PortalErrorMessage.message(for: error, hasSavedData: true),
                       "ЭИОС временно недоступна. Показаны последние сохранённые данные.")
        XCTAssertTrue(RefreshPolicy.isTransient(error))
    }
}
