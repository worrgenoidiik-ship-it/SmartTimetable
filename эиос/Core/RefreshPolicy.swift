import Foundation

enum RefreshPolicy {
    static func isTransient(_ error: Error) -> Bool {
        if let value = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(value.code)
        }
        if let value = error as? PortalFailure, case .httpStatus(let status) = value {
            return [408, 429, 500, 502, 503, 504].contains(status)
        }
        return false
    }

    static func retryDelay(failures: Int) -> TimeInterval {
        min(900, 60 * pow(2, Double(max(0, min(failures - 1, 4)))))
    }
}

/// User-facing copy only. This never alters TLS trust, retry policy or cookies.
enum PortalErrorMessage {
    static func message(for error: Error, hasSavedData: Bool = false) -> String {
        connectionMessage(for: error, hasSavedData: hasSavedData) ?? error.localizedDescription
    }

    static func connectionMessage(for error: Error, hasSavedData: Bool) -> String? {
        let failure = error as NSError
        let prefix: String
        if failure.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: failure.code)
            switch code {
            case .notConnectedToInternet:
                prefix = "Нет подключения к интернету."
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
                // A TLS or server failure is not proof that the phone is offline.
                prefix = "Не удаётся подключиться к ЭИОС."
            default: return nil
            }
        } else if let failure = error as? PortalFailure, case .httpStatus(let status) = failure,
                  [408, 429, 500, 502, 503, 504].contains(status) {
            prefix = "ЭИОС временно недоступна."
        } else { return nil }
        return prefix + (hasSavedData ? " Показаны последние сохранённые данные." : " Попробуйте ещё раз.")
    }
}
