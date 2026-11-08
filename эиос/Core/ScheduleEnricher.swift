import Foundation

/// Fills gaps of the group's plan from portal data instead of guessing:
/// - a missing or abbreviated teacher («Ж. Н. Донилова») gets the full name from the course of
///   the same subject («Психология и педагогика ИС-О-25/1 (3 семестр, Данилова Жанна Никитична)»)
///   when the initials agree;
/// - a missing room comes from the portal schedule: same subject, weekday and start time.
/// Existing full names and rooms are never replaced.
enum ScheduleEnricher {
    struct Teacher: Equatable {
        let subjectKey: Set<String>
        let fullName: String
    }

    static func enrich(_ window: ScheduleWindow, courses: [Course], portal: ScheduleWindow?) -> ScheduleWindow {
        let teachers = courseTeachers(courses) + portalTeachers(portal)
        let rooms = portalRooms(portal)
        guard !teachers.isEmpty || !rooms.isEmpty else { return window }
        let items = window.items.map { item -> ScheduleItem in
            var teacher = item.teacher
            if needsTeacher(teacher), let full = fullName(for: item.subject, current: teacher, in: teachers) { teacher = full }
            var place = item.place
            if place.isEmpty, let slot = slotKey(item), let room = bestRoom(rooms[slot] ?? [], subject: item.subject) { place = room }
            guard teacher != item.teacher || place != item.place else { return item }
            return ScheduleItem(id: item.id, day: item.day, timeStart: item.timeStart, timeEnd: item.timeEnd, type: item.type,
                                subject: item.subject, teacher: teacher, place: place, subgroup: item.subgroup,
                                lessonNumber: item.lessonNumber, requiresConfirmation: item.requiresConfirmation)
        }
        return ScheduleWindow(days: window.days, items: items, origin: window.origin,
                              dayNotes: window.dayNotes, cancelledDays: window.cancelledDays)
    }

    /// Word stems of a subject: «Элективные курсы по физической культуре» ≈ «Элективные дисциплины по физической культуре».
    static func subjectKey(_ subject: String) -> Set<String> {
        let aliases = ["английский": "иностранный"]
        let words = PortalParser.normalized(subject).split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 }
        return Set(words.map { word in String((aliases[word] ?? word).prefix(5)) })
    }

    static func sameSubject(_ a: Set<String>, _ b: Set<String>) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return Double(a.intersection(b).count) / Double(a.union(b).count) >= 0.5
    }

    private static func needsTeacher(_ teacher: String) -> Bool {
        let value = teacher.trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value.contains(".")
    }

    /// Initials of «Фамилия Имя Отчество» / «И. О. Фамилия» / «Фамилия И. О.» as two letters.
    static func initials(_ name: String) -> String? {
        let parts = name.split(separator: " ").map(String.init)
        if parts.count == 3, !name.contains(".") { return String(parts[1].prefix(1) + parts[2].prefix(1)).uppercased() }
        let letters = parts.filter { $0.hasSuffix(".") }.compactMap(\.first).map(String.init)
        return letters.count >= 2 ? letters.prefix(2).joined().uppercased() : nil
    }

    private static func fullName(for subject: String, current: String, in teachers: [Teacher]) -> String? {
        let key = subjectKey(subject)
        let candidates = Array(Set(teachers.filter { sameSubject($0.subjectKey, key) }.map(\.fullName)))
        if current.trimmingCharacters(in: .whitespaces).isEmpty {
            return candidates.count == 1 ? candidates[0] : nil
        }
        guard let wanted = initials(current) else { return nil }
        let matching = candidates.filter { initials($0) == wanted }
        return matching.count == 1 ? matching[0] : nil
    }

    private static func courseTeachers(_ courses: [Course]) -> [Teacher] {
        courses.compactMap { course in
            let title = CourseTitle(course.title)
            guard let teacher = title.teacher, !teacher.contains(".") else { return nil }
            return Teacher(subjectKey: subjectKey(title.subject), fullName: teacher)
        }
    }

    private static func portalTeachers(_ portal: ScheduleWindow?) -> [Teacher] {
        (portal?.items ?? []).flatMap { item in
            item.teacher.split(separator: "\n").map(String.init)
                .filter { $0.split(separator: " ").count == 3 && !$0.contains(".") }
                .map { Teacher(subjectKey: subjectKey(item.subject), fullName: $0) }
        }
    }

    /// Weekday + start time; the subject is compared separately because names differ slightly.
    private static func slotKey(_ item: ScheduleItem) -> String? {
        guard let date = CampusDate.formatter("yyyy-MM-dd").date(from: item.day), !item.timeStart.isEmpty else { return nil }
        return "\(CampusDate.calendar.component(.weekday, from: date))|" + item.timeStart
    }

    private static func portalRooms(_ portal: ScheduleWindow?) -> [String: [(subject: Set<String>, place: String)]] {
        var slots: [String: [(subject: Set<String>, place: String)]] = [:]
        for item in portal?.items ?? [] where !item.place.isEmpty {
            guard let slot = slotKey(item) else { continue }
            slots[slot, default: []].append((subjectKey(item.subject), item.place))
        }
        return slots
    }

    /// The most frequent room of the same subject in that slot.
    private static func bestRoom(_ entries: [(subject: Set<String>, place: String)], subject: String) -> String? {
        let key = subjectKey(subject)
        var counts: [String: Int] = [:]
        for entry in entries where sameSubject(entry.subject, key) { counts[entry.place, default: 0] += 1 }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }
}
