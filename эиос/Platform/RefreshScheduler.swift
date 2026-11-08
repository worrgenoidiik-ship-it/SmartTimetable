import Foundation
import BackgroundTasks
import UIKit

@MainActor
final class RefreshScheduler {
    static let shared = RefreshScheduler()
    private var foregroundTask: Task<Void, Never>?

    func startForeground() {
        guard foregroundTask == nil else { return }
        foregroundTask = Task {
            let network = NetworkManager.shared
            await network.bootstrap()
            var firstPass = true
            while !Task.isCancelled {
                let recoverOnOpen = firstPass && network.autoRefreshEnabled
                    && (network.sessionState == .offline || network.sessionState == .needsLogin)
                firstPass = false
                _ = await network.refresh(force: recoverOnOpen)
                if Task.isCancelled { break }
                // Between full refreshes a light touch keeps the portal session from idling out.
                await network.keepAliveIfNeeded()
                if Task.isCancelled { break }
                let seconds = max(30, min(60, network.nextRefreshAt?.timeIntervalSinceNow ?? 30))
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                catch { break }
            }
        }
    }
    func stopForeground() { foregroundTask?.cancel(); foregroundTask = nil }

    /// The server's idle timer restarts at the last request, so one touch at the moment the
    /// user leaves gives the session its full lifetime before background work is needed.
    func touchOnLeaving() {
        let network = NetworkManager.shared
        guard network.canOpenApp else { return }
        let task = BackgroundTaskBox()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "smarttable.keepalive") {
            MainActor.assumeIsolated { task.end() }
        }
        Task {
            await network.keepAliveIfNeeded(within: 60)
            task.end()
        }
    }

    func scheduleBackground() {
        let network = NetworkManager.shared
        guard network.autoRefreshEnabled, network.canOpenApp,
              let identifiers = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String],
              identifiers.contains(PortalConfiguration.refreshIdentifier) else { return }
        let request = BGAppRefreshTaskRequest(identifier: PortalConfiguration.refreshIdentifier)
        let due = network.nextRefreshAt ?? Date().addingTimeInterval(PortalConfiguration.randomRefreshDelay())
        // Ask for the earlier of the data refresh and the next keep-alive; iOS still decides.
        let keepAlive = (network.lastServerContact ?? Date()).addingTimeInterval(network.keepAliveInterval)
        request.earliestBeginDate = max(Date().addingTimeInterval(60), min(due, keepAlive))
        do { try BGTaskScheduler.shared.submit(request) }
        catch { /* Foreground/manual refresh remains available; iOS may refuse background work. */ }
        // A processing task gets extra chances to run, typically overnight while charging.
        if identifiers.contains(PortalConfiguration.keepAliveIdentifier) {
            let processing = BGProcessingTaskRequest(identifier: PortalConfiguration.keepAliveIdentifier)
            processing.requiresNetworkConnectivity = true
            processing.requiresExternalPower = false
            processing.earliestBeginDate = Date().addingTimeInterval(network.keepAliveInterval)
            try? BGTaskScheduler.shared.submit(processing)
        }
    }
    func cancelBackground() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: PortalConfiguration.refreshIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: PortalConfiguration.keepAliveIdentifier)
    }
}

@MainActor
final class SmartTableAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        guard let identifiers = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String],
              identifiers.contains(PortalConfiguration.refreshIdentifier) else { return true }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: PortalConfiguration.refreshIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            let operation = Task { @MainActor in
                let success = await NetworkManager.shared.refresh()
                // refresh() skips the network until its 30–60 min slot; the touch does not.
                let alive = await NetworkManager.shared.keepAliveIfNeeded()
                SessionJournal.add("iOS разбудила приложение (обновление): " + (alive ? "сессия жива" : "сессия не подтверждена"))
                RefreshScheduler.shared.scheduleBackground()
                refresh.setTaskCompleted(success: (success || alive) && !Task.isCancelled)
            }
            refresh.expirationHandler = { operation.cancel() }
        }
        if identifiers.contains(PortalConfiguration.keepAliveIdentifier) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: PortalConfiguration.keepAliveIdentifier, using: nil) { task in
                let operation = Task { @MainActor in
                    let alive = await NetworkManager.shared.keepAliveIfNeeded()
                    SessionJournal.add("iOS разбудила приложение (обслуживание): " + (alive ? "сессия жива" : "сессия не подтверждена"))
                    RefreshScheduler.shared.scheduleBackground()
                    task.setTaskCompleted(success: alive && !Task.isCancelled)
                }
                task.expirationHandler = { operation.cancel() }
            }
        }
        return true
    }
}

/// Ends a UIKit background task exactly once, whichever finishes first: the work or iOS's expiry.
@MainActor
private final class BackgroundTaskBox {
    var id = UIBackgroundTaskIdentifier.invalid
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
