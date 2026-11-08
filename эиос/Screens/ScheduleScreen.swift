import SwiftUI

// ==========================================
// РАСПИСАНИЕ: как в Android-версии — неделя ПН–ВС, «Сегодня»,
// выбор источника (ручной план или ЭИОС) и обновление из ЭИОС.
// ==========================================
@MainActor
struct ScheduleTab: View {
    let isChristmasMode: Bool
    @ObservedObject private var network = NetworkManager.shared
    // Тот же ключ, что читает NetworkManager.displayedSchedule, напоминания и виджет.
    @AppStorage(PortalConfiguration.scheduleSourceKey) private var sourceRaw = PortalConfiguration.scheduleMode.rawValue
    @State private var selectedDate = Date()
    @State private var calendarExpanded = false
    @Environment(\.colorScheme) private var colorScheme

    private static let weekdayLabels = ["ПН", "ВТ", "СР", "ЧТ", "ПТ", "СБ", "ВС"]
    private var calendar: Calendar { CampusDate.calendar }
    private var accent: Color { Color.themeAccent(isChristmas: isChristmasMode) }
    private var day: String { CampusDate.key(selectedDate) }
    private var mode: ScheduleMode { ScheduleMode(rawValue: sourceRaw) ?? .auto }
    // One cached merge for the whole screen (see NetworkManager.scheduleDisplay).
    private var display: NetworkManager.ScheduleDisplay { network.scheduleDisplay(mode) }
    private var section: CachedSection<ScheduleWindow>? { display.section }
    /// Whether the selected day comes from the group's plan (labels, «уточняется» texts).
    private var manual: Bool { display.plannedDays.contains(day) }
    private var items: [ScheduleItem] { display.itemsByDay[day] ?? [] }
    private var covered: Bool { display.days.contains(day) }
    private var isToday: Bool { calendar.isDate(selectedDate, inSameDayAs: Date()) }

    /// Понедельник…воскресенье недели выбранной даты (firstWeekday = понедельник).
    private var weekDays: [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? selectedDate
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                SyncStatusView()
                header
                weekCard
                if calendarExpanded {
                    DatePicker("Дата", selection: $selectedDate, displayedComponents: .date)
                        .datePickerStyle(.graphical).environment(\.locale, Locale(identifier: "ru_RU"))
                        .environment(\.timeZone, calendar.timeZone)
                        .tint(accent)
                        .padding(8).background(Color.cardBackground(for: colorScheme)).cornerRadius(16)
                }
                dayInfo
                lessons
                if mode != .manual {
                    UpdatedText(date: network.snapshot.portalSchedule?.fetchedAt)
                    if let error = network.errors["schedule"] { Text(error).font(.caption).foregroundColor(.orange) }
                }
            }.padding()
        }
        .refreshable { _ = await network.refresh(force: true) }
        .onChange(of: sourceRaw) { _, _ in AppNotificationManager.shared.updateFromSnapshot() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Расписание").font(.title2).bold()
                Spacer()
                Button("Сегодня") { withAnimation { selectedDate = Date() } }
                    .font(.subheadline.bold()).foregroundColor(accent).disabled(isToday)
            }
            Picker("Источник", selection: $sourceRaw) {
                ForEach(ScheduleMode.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }.pickerStyle(.segmented)
            if mode == .auto {
                Text(manual ? "Авто: план группы \(ManualSchedule.group) · \(ManualSchedule.periodLabel)"
                            : "Авто: вне плана группы показывается расписание из ЭИОС")
                    .font(.caption).foregroundColor(.secondary)
            }
            if mode == .manual {
                Text("План на семестр · \(ManualSchedule.group) · \(ManualSchedule.periodLabel)")
                    .font(.caption).foregroundColor(.secondary)
            } else if !manual {
                if let first = section?.value.days.first, let last = section?.value.days.last {
                    Text("Данные ЭИОС и сохранённая история: \(shortDate(first)) — \(shortDate(last))")
                        .font(.caption).foregroundColor(.secondary)
                }
                Button {
                    Task { _ = await network.refresh(force: true) }
                } label: {
                    Label(network.isLoading ? "Обновляем…" : "Обновить расписание из ЭИОС", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(accent).disabled(network.isLoading)
            }
        }
    }

    private var weekCard: some View {
        VStack(spacing: 10) {
            HStack {
                Button { shift(weeks: -1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                    .accessibilityLabel("Предыдущая неделя")
                Spacer()
                Button { withAnimation { calendarExpanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text(CampusDate.formatter("d MMMM yyyy").string(from: selectedDate)).bold()
                        Image(systemName: calendarExpanded ? "chevron.up" : "calendar")
                    }.foregroundColor(.primary)
                }.accessibilityLabel("Выбрать дату в календаре")
                Spacer()
                Button { shift(weeks: 1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
                    .accessibilityLabel("Следующая неделя")
            }.foregroundColor(accent)

            HStack(spacing: 4) {
                ForEach(Array(weekDays.enumerated()), id: \.offset) { index, date in
                    let active = calendar.isDate(date, inSameDayAs: selectedDate)
                    let today = calendar.isDate(date, inSameDayAs: Date())
                    Button {
                        AppHapticManager.shared.impact(style: .light)
                        withAnimation(.easeInOut(duration: 0.2)) { selectedDate = date }
                    } label: {
                        VStack(spacing: 4) {
                            Text(Self.weekdayLabels[index]).font(.system(size: 10, weight: .semibold))
                                .foregroundColor(active ? .white : .secondary)
                            Text(CampusDate.formatter("d").string(from: date)).font(.body.bold())
                                .foregroundColor(active ? .white : (today ? accent : .primary))
                            Circle().fill(hasLessons(date) ? (active ? Color.white : accent) : Color.clear)
                                .frame(width: 5, height: 5)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(active ? accent : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(12).background(Color.cardBackground(for: colorScheme)).cornerRadius(18)
    }

    @ViewBuilder private var dayInfo: some View {
        if manual, let label = ManualSchedule.weekLabel(for: day) {
            Text(label).font(.subheadline).bold()
        }
        if let note = section?.value.dayNotes?[day] {
            Text(note).font(.caption).foregroundColor(.orange)
        }
    }

    @ViewBuilder private var lessons: some View {
        if !covered {
            EmptyDataView(symbol: "calendar.badge.exclamationmark", text: emptyText)
        } else if items.isEmpty {
            EmptyDataView(symbol: "moon.zzz", text: "По сохранённому расписанию занятий нет.")
        } else {
            ForEach(items) { item in LessonCard(item: item, manual: manual) }
        }
    }

    private var emptyText: String {
        if section == nil {
            return manual ? "Расписание пока не загружено. Потяните вниз для обновления."
                : "Расписание из ЭИОС ещё не загружено. Нажмите «Обновить расписание из ЭИОС»."
        }
        if manual {
            return day > ManualSchedule.lastDay ? "План группы закончился. Выберите «Авто» или «Из ЭИОС», либо загрузите план нового семестра в настройках."
                : "На эту дату ручное расписание ещё не заполнено."
        }
        return "ЭИОС не прислала данных на эту дату. Это не значит, что занятий нет: портал отдаёт только ближайшие недели."
    }

    private func hasLessons(_ date: Date) -> Bool {
        !(display.itemsByDay[CampusDate.key(date)] ?? []).isEmpty
    }

    private func shift(weeks: Int) {
        AppHapticManager.shared.impact(style: .light)
        if let date = calendar.date(byAdding: .weekOfYear, value: weeks, to: selectedDate) {
            withAnimation { selectedDate = date }
        }
    }

    private func shortDate(_ key: String) -> String {
        guard let date = CampusDate.formatter("yyyy-MM-dd").date(from: key) else { return key }
        return CampusDate.formatter("d MMM").string(from: date)
    }
}

@MainActor
private struct LessonCard: View {
    let item: ScheduleItem
    let manual: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                if let number = item.lessonNumber {
                    Text("\(number)-я пара").font(.caption2).foregroundColor(.secondary)
                }
                if item.timeStart.isEmpty || item.timeEnd.isEmpty {
                    Text("Время уточняется").font(.caption).multilineTextAlignment(.center)
                } else {
                    Text(item.timeStart).bold()
                    Text(item.timeEnd).font(.caption).foregroundColor(.secondary)
                }
            }.frame(width: 65)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(item.type.isEmpty ? "ВИД ЗАНЯТИЯ НЕ УКАЗАН" : item.type.uppercased())
                        .font(.caption).bold().foregroundColor(item.type.isEmpty ? .secondary : Color.neonColor(item.type))
                    Spacer()
                    Text(item.place.isEmpty && manual ? "Место уточняется" : item.place).font(.caption).bold()
                        .multilineTextAlignment(.trailing)
                }
                Text(item.subject).font(.headline)
                if item.requiresConfirmation == true {
                    Label("Выбор курса нужно уточнить", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundColor(.orange)
                }
                Text(item.teacher.isEmpty ? (manual ? "Преподаватель уточняется" : "Преподаватель не указан на сайте") : item.teacher)
                    .font(.caption).foregroundColor(.secondary)
                if !item.subgroup.isEmpty { Text(item.subgroup).font(.caption).foregroundColor(.secondary) }
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cardBackground(for: colorScheme)).cornerRadius(18)
        }
    }
}
