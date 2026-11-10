import Foundation
import MetricKit

/// iOS itself hands the app the crash reports of its previous runs (MetricKit, about once a
/// day, real devices only). Only a short summary of the latest one is kept on the phone, for
/// «Сообщить о проблеме»; nothing is sent anywhere automatically.
final class CrashReports: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReports()
    static let key = "smarttable.lastCrash"

    static var last: String? { UserDefaults.standard.string(forKey: key) }

    func start() { MXMetricManager.shared.add(self) }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard let payload = payloads.last(where: { !($0.crashDiagnostics ?? []).isEmpty }),
              let crash = payload.crashDiagnostics?.last else { return }
        let summary = ProblemReport.crashSummary(
            date: payload.timeStampEnd, version: crash.applicationVersion, system: crash.metaData.osVersion,
            exception: crash.exceptionType?.intValue, signal: crash.signal?.intValue, reason: crash.terminationReason,
            frames: ProblemReport.crashFrames(callStackJSON: crash.callStackTree.jsonRepresentation()))
        UserDefaults.standard.set(summary, forKey: Self.key)
    }
}
