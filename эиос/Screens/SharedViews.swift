import SwiftUI

// ==========================================
// Общие компоненты, которые используют несколько экранов
// ==========================================

@MainActor
struct StatusChip: View {
    let text: String
    let color: Color
    let icon: String?

    var body: some View {
        HStack(spacing: 6) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .black))
            }
            Text(text)
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundColor(color == .gray ? .gray : .white)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            ZStack {
                if color == .gray {
                    Color.gray.opacity(0.15)
                } else {
                    LinearGradient(colors: [color, color.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .shadow(color: color.opacity(0.4), radius: 5, x: 0, y: 3)
                }
            }
        )
        .clipShape(Capsule())
    }
}

@MainActor
struct SyncStatusView: View {
    @ObservedObject private var network = NetworkManager.shared
    private var statusError: String? { network.errors["refresh"] ?? network.errors["cache"] ?? network.errors["session"] }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if network.isLoading { HStack { ProgressView(); Text("Обновляем данные…").font(.caption) } }
            if network.sessionState == .needsLogin {
                Text("Нужно снова войти в ЭИОС. Сохранённые данные доступны.").font(.caption).foregroundColor(.orange)
                Button("Войти в ЭИОС") { network.showLogin = true }
            } else if network.sessionState == .offline && statusError == nil {
                Text("Не удаётся подключиться к ЭИОС. Показаны последние сохранённые данные.").font(.caption).foregroundColor(.orange)
            }
            if let error = statusError {
                Text(error).font(.caption).foregroundColor(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
struct UpdatedText: View {
    let date: Date?
    var body: some View {
        if let date = date {
            Text(date == .distantPast ? "Данные старой версии. Время обновления неизвестно."
                 : "Обновлено: " + CampusDate.formatter("dd.MM.yyyy HH:mm").string(from: date))
                .font(.caption).foregroundColor(.secondary).padding(.vertical, 4)
        }
    }
}

@MainActor
struct EmptyDataView: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 38))
            Text(text).multilineTextAlignment(.center)
        }.foregroundColor(.secondary).frame(maxWidth: .infinity).padding(.vertical, 25)
    }
}

enum GradeStatus {
    case failed, passed, other

    // Одна таблица для цвета оценки и для вкладки «Долги».
    static func of(_ grade: String) -> GradeStatus {
        let value = PortalParser.normalized(grade)
        if ["незачет", "не зачет", "не зачтено", "неудовлетворительно", "неуд", "2",
            "неявка", "не явился", "не явка", "н/я"].contains(value) { return .failed }
        if ["зачет", "зачтено", "отлично", "хорошо", "удовлетворительно", "5", "4", "3"].contains(value) { return .passed }
        return .other
    }

    var color: Color {
        switch self {
        case .failed: return .red
        case .passed: return .green
        case .other: return .blue
        }
    }
}

@MainActor
struct GradeRowsView: View {
    let items: [GradeItem]
    var emptyText = "Сохранённых оценок пока нет."
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        if items.isEmpty { Text(emptyText).foregroundColor(.secondary).padding() }
        else {
            LazyVStack(spacing: 12) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.subject).font(.headline)
                            Text(item.teacher.isEmpty ? "Преподаватель не указан на сайте" : item.teacher)
                                .font(.caption).foregroundColor(.secondary)
                            Text([item.type, item.date, item.semester].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundColor(.secondary)
                            if let retake = item.retake, !retake.isEmpty {
                                Text("Пересдача: " + retake).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        StatusChip(text: item.grade.isEmpty ? "—" : item.grade, color: GradeStatus.of(item.grade).color, icon: nil)
                    }.padding().background(Color.cardBackground(for: colorScheme)).cornerRadius(18)
                }
            }.padding(.top, 10)
        }
    }
}

/// Плитка-ссылка на раздел ЭИОС: используется во вкладках «Сообщения» и «ЭИОС».
@MainActor
struct PortalLinkRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tint: Color
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: { AppHapticManager.shared.impact(style: .light); action() }) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundColor(.primary)
                    Text(subtitle).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
            .padding()
            .background(Color.cardBackground(for: colorScheme))
            .cornerRadius(18)
        }.buttonStyle(.plain)
    }
}
