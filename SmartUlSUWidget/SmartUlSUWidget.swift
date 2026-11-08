import WidgetKit
import SwiftUI

// Mirrors WidgetBridge.Payload in the app (эиос/Platform/WidgetBridge.swift).
struct WidgetPayload: Codable {
    struct Lesson: Codable, Hashable {
        let day: String
        let start: String
        let end: String
        let subject: String
        let type: String
        let place: String
    }
    struct Deadline: Codable, Hashable {
        let title: String
        let kind: String
        let due: Date
    }
    let lessons: [Lesson]
    let deadlines: [Deadline]

    static let appGroup = "group.com.antonborisov.smartulsu.app2025"

    static func load() -> WidgetPayload? {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
                .appendingPathComponent("widget-v1.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetPayload.self, from: data)
    }
}

private enum CampusClock {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Samara")!
        return value
    }
    static func formatter(_ format: String) -> DateFormatter {
        let value = DateFormatter()
        value.calendar = calendar; value.timeZone = calendar.timeZone
        value.locale = Locale(identifier: "ru_RU"); value.dateFormat = format
        return value
    }
    static func date(_ day: String, _ time: String) -> Date? { formatter("yyyy-MM-dd HH:mm").date(from: "\(day) \(time)") }
    static func key(_ date: Date) -> String { formatter("yyyy-MM-dd").string(from: date) }
}

struct SmartEntry: TimelineEntry {
    let date: Date
    let payload: WidgetPayload?

    /// Lessons of the entry's day that have not ended yet.
    var todayLessons: [WidgetPayload.Lesson] {
        let today = CampusClock.key(date)
        return (payload?.lessons ?? []).filter { lesson in
            lesson.day == today && (CampusClock.date(lesson.day, lesson.end) ?? .distantFuture) > date
        }
    }

    var nextLesson: WidgetPayload.Lesson? {
        (payload?.lessons ?? []).first { (CampusClock.date($0.day, $0.end) ?? .distantPast) > date }
    }

    var nextDeadline: WidgetPayload.Deadline? { payload?.deadlines.first { $0.due > date } }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SmartEntry { SmartEntry(date: Date(), payload: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (SmartEntry) -> Void) {
        completion(SmartEntry(date: Date(), payload: WidgetPayload.load() ?? (context.isPreview ? .sample : nil)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SmartEntry>) -> Void) {
        let now = Date()
        let payload = WidgetPayload.load()
        // A new entry at every lesson start/end over the next day keeps «следующая пара» exact.
        var moments: Set<Date> = [now]
        for lesson in payload?.lessons ?? [] {
            for time in [lesson.start, lesson.end] {
                if let date = CampusClock.date(lesson.day, time), date > now, date < now.addingTimeInterval(36 * 3_600) {
                    moments.insert(date)
                }
            }
        }
        let midnight = CampusClock.calendar.startOfDay(for: now.addingTimeInterval(86_400))
        moments.insert(midnight)
        let entries = moments.sorted().prefix(40).map { SmartEntry(date: $0, payload: payload) }
        completion(Timeline(entries: entries, policy: .after(midnight.addingTimeInterval(60))))
    }
}

struct SmartUlSUWidgetEntryView: View {
    let entry: SmartEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if entry.payload == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Label("SmartTimetable", systemImage: "calendar").font(.headline)
                    Text("Откройте приложение, чтобы загрузить расписание.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                switch family {
                case .accessoryRectangular: lockScreen
                case .systemMedium: medium
                default: small
                }
            }
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.todayLessons.isEmpty ? "СЛЕДУЮЩАЯ ПАРА" : "СЕЙЧАС И ДАЛЕЕ")
                .font(.caption2.bold()).foregroundStyle(.blue)
            if let lesson = entry.nextLesson {
                Text("\(dayLabel(lesson.day)) \(lesson.start)–\(lesson.end)").font(.caption.bold())
                Text(lesson.subject).font(.subheadline.weight(.semibold)).lineLimit(3)
                Spacer(minLength: 0)
                if !lesson.place.isEmpty { Text(lesson.place).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            } else {
                Text("Пар в ближайшие дни нет").font(.subheadline)
                Spacer(minLength: 0)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.todayLessons.isEmpty ? "БЛИЖАЙШИЕ ПАРЫ" : "СЕГОДНЯ").font(.caption2.bold()).foregroundStyle(.blue)
                let lessons = entry.todayLessons.isEmpty ? Array((entry.nextLesson.map { [$0] } ?? [])) : Array(entry.todayLessons.prefix(3))
                if lessons.isEmpty { Text("Пар нет").font(.subheadline) }
                ForEach(lessons, id: \.self) { lesson in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(lesson.start).font(.caption.monospacedDigit().bold())
                        Text(lesson.subject).font(.caption).lineLimit(1)
                    }
                    if entry.todayLessons.isEmpty { Text(dayLabel(lesson.day)).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let deadline = entry.nextDeadline {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ДЕДЛАЙН").font(.caption2.bold()).foregroundStyle(.orange)
                    Text(deadline.title).font(.caption.weight(.semibold)).lineLimit(3)
                    Text(deadline.kind).font(.caption2).foregroundStyle(.secondary)
                    Text(deadline.due, style: .relative).font(.caption2.bold()).foregroundStyle(.orange)
                    Spacer(minLength: 0)
                }.frame(maxWidth: 120, alignment: .leading)
            }
        }
    }

    private var lockScreen: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let lesson = entry.nextLesson {
                Text("\(dayLabel(lesson.day)) \(lesson.start) · \(lesson.place)").font(.caption2).lineLimit(1)
                Text(lesson.subject).font(.headline).lineLimit(2)
            } else {
                Text("Пар нет").font(.headline)
            }
        }
    }

    private func dayLabel(_ day: String) -> String {
        let today = CampusClock.key(entry.date)
        if day == today { return "Сегодня" }
        if day == CampusClock.key(entry.date.addingTimeInterval(86_400)) { return "Завтра" }
        guard let date = CampusClock.formatter("yyyy-MM-dd").date(from: day) else { return day }
        return CampusClock.formatter("EE d MMM").string(from: date)
    }
}

extension WidgetPayload {
    static let sample = WidgetPayload(
        lessons: [Lesson(day: CampusClock.key(Date()), start: "09:30", end: "10:50",
                         subject: "Программирование", type: "Лекция", place: "3/305")],
        deadlines: [Deadline(title: "Тест по модулю 2", kind: "Тест", due: Date().addingTimeInterval(86_400))])
}

@main
struct SmartUlSUWidget: Widget {
    let kind = "SmartUlSUWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { SmartUlSUWidgetEntryView(entry: $0) }
            .configurationDisplayName("SmartTimetable")
            .description("Следующая пара, расписание на сегодня и ближайший дедлайн.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}
