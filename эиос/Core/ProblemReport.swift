import Foundation

/// «Сообщить о проблеме»: a text the student sends to the author themselves (share sheet).
/// The app sends nothing on its own. No name, login, cookies, grades or page text in it:
/// only the version, the system, the group, which sections failed and the session journal.
enum ProblemReport {
    static let projectURL = URL(string: "https://github.com/worrgenoidiik-ship-it/SmartTimetable/issues")!
    static let journalLines = 40

    static func text(version: String, system: String, device: String, group: String?,
                     errors: [String: String], journal: String, crash: String?) -> String {
        var lines = ["SmartTimetable \(version) · \(system) · \(device)",
                     "Группа: \(group ?? "не определена")"]
        if errors.isEmpty {
            lines.append("Ошибок загрузки нет")
        } else {
            lines.append("Ошибки загрузки:")
            lines += errors.keys.sorted().map { "  \($0): \(errors[$0] ?? "")" }
        }
        if let crash, !crash.isEmpty { lines += ["Последнее падение:", crash] }
        let recent = journal.split(separator: "\n", omittingEmptySubsequences: true).prefix(journalLines)
        if !recent.isEmpty { lines += ["Журнал сессии (последние \(recent.count)):"] + recent.map(String.init) }
        lines += ["", "Что случилось (допишите своими словами): "]
        return lines.joined(separator: "\n")
    }

    /// The crashed thread from MetricKit's call-stack JSON as «binary+offset» lines, top first.
    /// With the build's dSYM these offsets turn back into function names (atos).
    static func crashFrames(callStackJSON data: Data, limit: Int = 12) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]] else { return [] }
        let crashed = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var result: [String] = []
        var frame = (crashed?["callStackRootFrames"] as? [[String: Any]])?.first
        while let current = frame, result.count < limit {
            let name = current["binaryName"] as? String ?? "?"
            let offset = (current["offsetIntoBinaryTextSegment"] as? NSNumber)?.intValue ?? 0
            result.append("\(name)+\(offset)")
            frame = (current["subFrames"] as? [[String: Any]])?.first
        }
        return result
    }

    static func crashSummary(date: Date, version: String, system: String, exception: Int?, signal: Int?,
                             reason: String?, frames: [String]) -> String {
        var head = CampusDate.formatter("dd.MM.yyyy HH:mm").string(from: date) + " · версия \(version) · \(system)"
        if let exception { head += " · исключение \(exception)" }
        if let signal { head += " · сигнал \(signal)" }
        var lines = [head]
        if let reason, !reason.isEmpty { lines.append(String(reason.prefix(300))) }
        if !frames.isEmpty { lines.append(frames.joined(separator: " < ")) }
        return lines.joined(separator: "\n")
    }
}
