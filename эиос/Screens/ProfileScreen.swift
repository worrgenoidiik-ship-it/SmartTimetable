import SwiftUI
import PhotosUI

// ==========================================
// ПРОФИЛЬ: шапка, меню вкладок и их содержимое
// ==========================================
@MainActor
struct ProfileContainerView: View {
    var isChristmasMode: Bool
    @Binding var resetTrigger: Bool

    @State private var selectedTab = 0
    // «Справки» убраны: в ЭИОС нет страницы заказа справок, вкладка была пустой заглушкой.
    let tabs = ["ИНФОРМАЦИЯ", "РАСПИСАНИЕ", "ДОЛГИ", "КУРСЫ"]
    @Environment(\.colorScheme) var colorScheme

    // Состояние для фото
    @State private var avatarItem: PhotosPickerItem? = nil

    @ObservedObject private var dataManager = AppDataManager.shared
    @State private var showNotification = false
    @ObservedObject private var inboxNetwork = NetworkManager.shared
    @Namespace private var animation

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerView
                if isChristmasMode { ChristmasGarland().background(Color.cardBackground(for: colorScheme)) }
                tabMenuView
                contentView
            }
            .toolbar(.hidden, for: .navigationBar)
            .background(Color.appBackground)
            .sheet(isPresented: $showNotification) { PortalInboxScreen() }
            .onChange(of: resetTrigger) { _, _ in withAnimation { selectedTab = 0 } }
            .onChange(of: avatarItem) { _, item in
                Task {
                    if let d = try? await item?.loadTransferable(type: Data.self), let ui = UIImage(data: d) {
                        dataManager.saveImage(image: ui)
                    }
                }
            }
        }
    }

    private var headerView: some View {
        HStack {
            HStack(spacing: 5) {
                Text("SmartTimetable").font(.title2).fontWeight(.black).foregroundColor(Color.themeAccent(isChristmas: isChristmasMode))
                if isChristmasMode { Text("🎅").font(.title2) }
            }
            Spacer()
            Button(action: {
                AppHapticManager.shared.impact(style: .medium)
                showNotification = true
            }) {
                Image(systemName: "bell.fill")
                    .foregroundColor(.gray)
                    .padding(8)
                    .background(Color.gray.opacity(0.15))
                    .clipShape(Circle())
                    .overlay(alignment: .topTrailing) {
                        if inboxNetwork.unreadNotificationCount > 0 {
                            Text(String(inboxNetwork.unreadNotificationCount)).font(.caption2.bold())
                                .foregroundColor(.white).padding(4).background(Color.red, in: Circle())
                        }
                    }
            }
            .accessibilityLabel("Уведомления ЭИОС")
        }
        .padding()
        .background(Color.cardBackground(for: colorScheme))
    }

    private var tabMenuView: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<tabs.count, id: \.self) { index in
                        Text(tabs[index])
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(selectedTab == index ? .white : .gray)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                ZStack {
                                    if selectedTab == index {
                                        Capsule()
                                            .fill(Color.themeAccent(isChristmas: isChristmasMode))
                                            .matchedGeometryEffect(id: "TabBackground", in: animation)
                                    }
                                }
                            )
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    selectedTab = index
                                }
                            }
                            .id(index)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .background(Color.cardBackground(for: colorScheme))
            .onChange(of: selectedTab) { _, newTab in
                withAnimation { proxy.scrollTo(newTab, anchor: .center) }
            }
        }
    }

    /// Only the open section exists. A paging TabView kept all four alive, so every data
    /// change redrew the schedule, debts and courses too. Horizontal swipes still switch.
    private var contentView: some View {
        ZStack {
            switch selectedTab {
            case 0: InfoTab(isChristmasMode: isChristmasMode, avatarItem: $avatarItem)
            case 1: ScheduleTab(isChristmasMode: isChristmasMode)
            case 2: DebtsView(isChristmasMode: isChristmasMode)
            default: CoursesTab(isChristmasMode: isChristmasMode, isActive: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                guard abs(value.translation.width) > 80, abs(value.translation.width) > abs(value.translation.height) * 2 else { return }
                let next = selectedTab + (value.translation.width < 0 ? 1 : -1)
                guard tabs.indices.contains(next) else { return }
                AppHapticManager.shared.impact(style: .light)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selectedTab = next }
            }
        )
    }
}

// ==========================================
// ИНФОРМАЦИЯ: карточка студента, заметки, зачётка
// ==========================================
@MainActor
struct InfoTab: View {
    var isChristmasMode: Bool

    @Binding var avatarItem: PhotosPickerItem?

    @Environment(\.colorScheme) var colorScheme
    @ObservedObject private var networkManager = NetworkManager.shared
    @ObservedObject private var dataManager = AppDataManager.shared
    @State private var isCreditWeekExpanded = true
    @State private var isAttestationExpanded = true
    @State private var selectedSemester = ""
    @State private var semesterChosen = false

    private func chooseCurrentSemester() {
        guard !semesterChosen, let last = semesters.last else { return }
        selectedSemester = last
        semesterChosen = true
    }
    @FocusState private var isNotesFocused: Bool

    @State private var notesHeight: CGFloat = 150
    @State private var initialNotesHeight: CGFloat = 150

    private var semesters: [String] {
        var seen: Set<String> = []
        return networkManager.grades.map(\.semester).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var visibleGrades: [GradeItem] {
        selectedSemester.isEmpty ? networkManager.grades : networkManager.grades.filter { $0.semester == selectedSemester }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                SyncStatusView()
                studentCard
                DisclosureGroup("Зачётная книжка (ЭИОС)", isExpanded: $isCreditWeekExpanded) {
                    if !semesters.isEmpty {
                        Picker("Семестр", selection: $selectedSemester) {
                            Text("Все семестры").tag("")
                            ForEach(semesters, id: \.self) { Text($0).tag($0) }
                        }.pickerStyle(.menu)
                    }
                    GradeRowsView(items: visibleGrades)
                    UpdatedText(date: networkManager.snapshot.grades?.fetchedAt)
                    if let error = networkManager.errors["grades"] { Text(error).font(.caption).foregroundColor(.orange) }
                }.accentColor(.gray)
                DisclosureGroup("Аттестация (ЭИОС)", isExpanded: $isAttestationExpanded) {
                    // Источник — страница «Текущая успеваемость» (CDO/academic_progress_inside.php).
                    PortalDocumentContent(kind: .attestation).padding(.top, 8)
                }.accentColor(.gray)
            }.padding()
        }
        .refreshable { _ = await networkManager.refresh(force: true) }
        // The gradebook opens on the current semester (the portal's active tab is always the last).
        .onAppear { chooseCurrentSemester() }
        .onChange(of: semesters) { _, values in
            if !values.contains(selectedSemester) { selectedSemester = "" }
            chooseCurrentSemester()
        }
    }

    private var studentCard: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(gradient: Gradient(colors: Color.gradientColors(index: dataManager.cardColorIndex)), startPoint: .top, endPoint: .bottom)
                .cornerRadius(24).animation(.easeInOut, value: dataManager.cardColorIndex)

            VStack(spacing: 15) {
                HStack {
                    Text("Студенческий").font(.caption).bold().padding(6).background(.white.opacity(0.2)).cornerRadius(8).foregroundColor(.white)
                    Spacer()
                    Text("ЭИОС").font(.caption).fontWeight(.black).padding(6).background(Color.orange).cornerRadius(8).foregroundColor(.white)
                }

                HStack(alignment: .center, spacing: 15) {
                    // Аватарка с возможностью выбора (PhotosPicker).
                    // Значение копируется заранее: замыкание PhotosPicker не должно читать @State напрямую.
                    let currentAvatar = dataManager.avatar.map { Image(uiImage: $0) }
                    PhotosPicker(selection: $avatarItem, matching: .images) {
                        if let img = currentAvatar {
                            img
                                .resizable()
                                .scaledToFill()
                                .frame(width: 80, height: 80)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        } else {
                            Circle()
                                .fill(.white.opacity(0.3))
                                .frame(width: 80, height: 80)
                                .overlay(Image(systemName: "person.fill").foregroundColor(.white))
                        }
                    }
                    .accessibilityLabel("Выбрать фото профиля")

                    VStack(alignment: .leading, spacing: 4) {
                        Text(networkManager.userNameFromSite.isEmpty ? "Загрузка..." : networkManager.userNameFromSite)
                            .font(.system(size: 20, weight: .heavy)).foregroundColor(.white).lineLimit(2)
                        Text("Студент УлГУ").font(.title3).fontWeight(.black).foregroundColor(.white.opacity(0.95))
                    }
                    Spacer()
                }.padding(.bottom, 10)
            }.padding(20)

            Button(action: { AppHapticManager.shared.impact(style: .medium); dataManager.cardColorIndex = (dataManager.cardColorIndex + 1) % 4 }) {
                Image(systemName: "paintpalette.fill").font(.title2).foregroundColor(.white).frame(width: 44, height: 44).background(.black.opacity(0.4)).clipShape(Circle())
            }
            .accessibilityLabel("Сменить цвет карточки")
            .padding(15)
        }.shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
    }

}

// ==========================================
// ДОЛГИ: считаются из зачётки, а не заглушка
// ==========================================
@MainActor
struct DebtsView: View {
    let isChristmasMode: Bool
    @ObservedObject private var network = NetworkManager.shared
    @State private var page: PortalDestination?

    private var debts: [GradeItem] { network.grades.filter { GradeStatus.of($0.grade) == .failed } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Академические задолженности").font(.title2).bold()
                if network.snapshot.grades == nil {
                    EmptyDataView(symbol: "doc.text.magnifyingglass",
                                  text: "Зачётка ещё не загружена. Потяните вниз, чтобы обновить данные из ЭИОС.")
                } else if debts.isEmpty {
                    EmptyDataView(symbol: "checkmark.seal.fill", text: "В зачётке нет незачётов и неудовлетворительных оценок. Так держать!")
                        .foregroundColor(.green)
                } else {
                    Text("Найдено по зачётке: \(debts.count). Сроки пересдач уточняйте в деканате или в ЭИОС.")
                        .font(.caption).foregroundColor(.secondary)
                    GradeRowsView(items: debts)
                }
                Text("Список строится по оценкам «незачёт», «неудовлетворительно» и «неявка» из зачётной книжки ЭИОС.")
                    .font(.caption).foregroundColor(.secondary)
                UpdatedText(date: network.snapshot.grades?.fetchedAt)

                Text("Официально в ЭИОС").font(.title3).bold().padding(.top, 8)
                Text("Страница «Узнать задолженности» — она главнее расчёта по зачётке.")
                    .font(.caption).foregroundColor(.secondary)
                PortalDocumentContent(kind: .debts)
                Button("Открыть успеваемость в ЭИОС") {
                    page = PortalDestination(title: "Успеваемость", url: PortalConfiguration.gradesURL)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.themeAccent(isChristmas: isChristmasMode))
                .frame(maxWidth: .infinity)
            }.padding()
        }
        .refreshable {
            _ = await network.refresh(force: true)
            await network.loadPage(.debts)
        }
        .sheet(item: $page) { PortalBrowserScreen(title: $0.title, url: $0.url) }
    }
}
