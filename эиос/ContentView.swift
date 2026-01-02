import SwiftUI
import PhotosUI
import LocalAuthentication
import Combine
import UserNotifications

// ==========================================
// 0. МОДЕЛИ ДАННЫХ (ОБЯЗАТЕЛЬНО В НАЧАЛЕ)
// ==========================================

struct Student {
    let name: String
    let id: String
    let faculty: String
    let group: String
    let isAdmin: Bool
}

struct ScheduleItem: Identifiable {
    let id = UUID()
    let timeStart: String
    let timeEnd: String
    let type: String
    let subject: String
    let teacher: String
    let place: String
}

struct SubjectItem: Identifiable {
    let id = UUID()
    let name: String
    let teacher: String
    let type: String
}

struct Course: Identifiable {
    let id = UUID()
    let title: String
    let teacher: String
}

// ==========================================
// 1. МЕНЕДЖЕРЫ ДАННЫХ
// ==========================================

class AppDataManager: ObservableObject {
    static let shared = AppDataManager()
    
    @Published var notes: String { didSet { UserDefaults.standard.set(notes, forKey: "user_notes") } }
    @Published var creditStatuses: [Int] { didSet { UserDefaults.standard.set(creditStatuses, forKey: "credit_statuses_array") } }
    @Published var cardColorIndex: Int { didSet { UserDefaults.standard.set(cardColorIndex, forKey: "card_color_index") } }
    @Published var attestationStatuses: [Int] { didSet { UserDefaults.standard.set(attestationStatuses, forKey: "attestation_statuses_array") } }
    
    init() {
        self.notes = UserDefaults.standard.string(forKey: "user_notes") ?? ""
        self.creditStatuses = UserDefaults.standard.array(forKey: "credit_statuses_array") as? [Int] ?? Array(repeating: 0, count: 20)
        self.cardColorIndex = UserDefaults.standard.integer(forKey: "card_color_index")
        self.attestationStatuses = UserDefaults.standard.array(forKey: "attestation_statuses_array") as? [Int] ?? Array(repeating: 0, count: 20)
    }
    
    func saveImage(image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.7) else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("avatar.jpg")
        try? data.write(to: url)
    }
    
    func loadImage() -> UIImage? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("avatar.jpg")
        if let data = try? Data(contentsOf: url) { return UIImage(data: data) }
        return nil
    }
    
    func toggleAttestation(index: Int) {
        if attestationStatuses.indices.contains(index) {
            var current = attestationStatuses[index]
            current += 1
            if current > 2 { current = 0 }
            attestationStatuses[index] = current
            AppHapticManager.shared.impact(style: .medium)
        }
    }
}

class AppHapticManager {
    static let shared = AppHapticManager()
    func impact(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
    func notification(type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type)
    }
}

class AppNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotificationManager()
    
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        UNUserNotificationCenter.current().delegate = self
    }
    
    func scheduleSmartNotifications(schedule: [ScheduleItem], enabled: Bool) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        if !enabled { return }
        
        let calendar = Calendar.current
        let today = Date()
        
        for item in schedule {
            scheduleAlert(timeString: item.timeStart, title: "Пара через 5 минут!", body: "\(item.subject) (\(item.place))", offset: -5, center: center, calendar: calendar, today: today)
        }
    }
    
    private func scheduleAlert(timeString: String, title: String, body: String, offset: Double, center: UNUserNotificationCenter, calendar: Calendar, today: Date) {
        let parts = timeString.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2 {
            var components = calendar.dateComponents([.year, .month, .day], from: today)
            components.hour = parts[0]
            components.minute = parts[1]
            if let date = calendar.date(from: components) {
                let triggerDate = date.addingTimeInterval(offset * 60)
                if triggerDate > Date() {
                    let content = UNMutableNotificationContent()
                    content.title = title
                    content.body = body
                    content.sound = .default
                    let trigger = UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.hour, .minute, .second], from: triggerDate), repeats: false)
                    center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
                }
            }
        }
    }
    
    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "SmartUlSU"
        content.body = "Уведомления работают! ✅"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
}

class AppAuthManager: ObservableObject {
    @Published var isLocked = false
    @AppStorage("isFaceIDEnabled") var isFaceIDEnabled = false
    
    func authenticate() {
        if !isFaceIDEnabled {
            self.isLocked = false
            return
        }
        self.isLocked = true
        let context = LAContext()
        var error: NSError?
        
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Вход в приложение") { success, _ in
                DispatchQueue.main.async {
                    if success { self.isLocked = false }
                }
            }
        } else {
            self.isLocked = false
        }
    }
}

// ==========================================
// 2. РАСШИРЕНИЯ (COLORS & UTILS)
// ==========================================

extension Color {
    static func cardBackground(for colorScheme: ColorScheme) -> Color {
        return colorScheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color.white
    }
    static func themeAccent(isChristmas: Bool) -> Color {
        return isChristmas ? Color(red: 0.85, green: 0.1, blue: 0.1) : Color(red: 0.0, green: 0.48, blue: 1.0)
    }
    static func neonColor(_ type: String) -> Color {
        if type.contains("Лек") { return .orange }
        if type.contains("Лаб") { return Color(red: 0.0, green: 0.5, blue: 1.0) }
        return Color(red: 0.0, green: 0.8, blue: 0.4)
    }
    static func gradientColors(index: Int) -> [Color] {
        switch index {
        case 0: return [Color.black, Color(red: 0.0, green: 0.6, blue: 0.2)]
        case 1: return [Color.black, Color(white: 0.25)]
        case 2: return [Color.black, Color(red: 0.0, green: 0.3, blue: 0.8)]
        case 3: return [Color.black, Color(red: 0.7, green: 0.0, blue: 0.1)]
        default: return [Color.black, Color.gray]
        }
    }
}

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// ==========================================
// 3. UI КОМПОНЕНТЫ
// ==========================================
struct SnowView: View {
    var body: some View { GeometryReader { proxy in ForEach(0..<40, id: \.self) { _ in SnowFlake(proxy: proxy) } }.allowsHitTesting(false).ignoresSafeArea() }
}
struct SnowFlake: View {
    let proxy: GeometryProxy
    @State private var y: CGFloat = -50; @State private var x: CGFloat = 0
    var body: some View { Circle().fill(Color.white.opacity(0.6)).frame(width: CGFloat.random(in: 2...5)).position(x: x, y: y).onAppear { x = CGFloat.random(in: 0...proxy.size.width); withAnimation(Animation.linear(duration: Double.random(in: 5...12)).repeatForever(autoreverses: false)) { y = proxy.size.height + 50 } } }
}

// ==========================================
// 4. ГЛАВНЫЙ ЭКРАН (ContentView)
// ==========================================
struct ContentView: View {
    @AppStorage("isLoggedIn") private var isLoggedIn = false
    @AppStorage("isDarkMode") private var isDarkMode = true
    @AppStorage("isChristmasMode") private var isChristmasMode = true
    @StateObject private var authManager = AppAuthManager()
    @StateObject private var networkManager = NetworkManager.shared
    
    var body: some View {
        ZStack {
            if authManager.isLocked && authManager.isFaceIDEnabled {
                VStack {
                    Image(systemName: "faceid").font(.system(size: 60)).foregroundColor(Color.themeAccent(isChristmas: isChristmasMode))
                    Button("Войти") { AppHapticManager.shared.impact(style: .medium); authManager.authenticate() }
                        .padding().foregroundColor(Color.themeAccent(isChristmas: isChristmasMode))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(UIColor.systemBackground))
                .onAppear { authManager.authenticate() }
            } else {
                if !isLoggedIn {
                    LoginView(isChristmas: isChristmasMode, onLoginSuccess: { isLoggedIn = true })
                } else {
                    MainAppView(logoutAction: {
                        isLoggedIn = false
                        networkManager.clearCredentials()
                    })
                }
            }
            if isChristmasMode { SnowView() }
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .onAppear {
            authManager.authenticate()
            AppNotificationManager.shared.requestPermission()
            
            if isLoggedIn {
                networkManager.tryAutoLogin { success in
                    if !success { print("Auto-login failed") }
                }
            }
        }
    }
}

// ==========================================
// 5. ЭКРАН ВХОДА (LoginView)
// ==========================================
struct LoginView: View {
    var isChristmas: Bool
    var onLoginSuccess: () -> Void
    
    @State private var login = ""
    @State private var password = ""
    @StateObject private var networkManager = NetworkManager.shared
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            VStack(spacing: 20) {
                Spacer()
                Text("SmartUlSU").font(.system(size: 40, weight: .black)).foregroundColor(Color.themeAccent(isChristmas: isChristmas))
                
                VStack(spacing: 12) {
                    TextField("Логин", text: $login)
                        .padding()
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(12)
                        .foregroundColor(.white)
                        .textInputAutocapitalization(.never)
                    
                    SecureField("Пароль", text: $password)
                        .padding()
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(12)
                        .foregroundColor(.white)
                }.padding(.horizontal)
                
                Button(action: {
                    hideKeyboard()
                    if !login.isEmpty && !password.isEmpty {
                        networkManager.login(login: login, pass: password) { success in
                            if success { onLoginSuccess() }
                        }
                    }
                }) {
                    HStack {
                        if networkManager.isLoading { ProgressView().tint(.white).padding(.trailing, 5) }
                        Text(networkManager.isLoading ? "Входим..." : "Войти").bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.themeAccent(isChristmas: isChristmas))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .padding(.horizontal)
                .disabled(networkManager.isLoading)
                
                if let error = networkManager.errorMessage {
                    Text(error).foregroundColor(.red).font(.caption)
                }
                
                Spacer()
            }
        }.onTapGesture { hideKeyboard() }
    }
}

// ==========================================
// 6. ОСНОВНОЕ ПРИЛОЖЕНИЕ (MainAppView)
// ==========================================
struct MainAppView: View {
    var logoutAction: () -> Void
    @AppStorage("isChristmasMode") private var isChristmasMode = true
    @AppStorage("isDarkMode") private var isDarkMode = true
    @State private var selection = 0
    @State private var resetTrigger = false
    
    var body: some View {
        TabView(selection: $selection) {
            ProfileContainerView(isChristmasMode: isChristmasMode, resetTrigger: $resetTrigger)
                .tabItem { Image(systemName: "person.crop.circle"); Text("Профиль") }.tag(0)
            
            Text("Новости (Скоро)").tabItem { Image(systemName: "newspaper"); Text("Новости") }.tag(1)
            AskQuestionView().tabItem { Image(systemName: "questionmark.bubble"); Text("Вопрос") }.tag(2)
            
            SettingsView(logoutAction: logoutAction, isDarkMode: $isDarkMode, isChristmasMode: $isChristmasMode)
                .tabItem { Image(systemName: "gearshape"); Text("Настройки") }.tag(3)
        }
        .accentColor(Color.themeAccent(isChristmas: isChristmasMode))
        .onChange(of: selection) { val in if val == 0 { resetTrigger.toggle() } }
    }
}

// ==========================================
// 7. КОНТЕЙНЕР ПРОФИЛЯ (ProfileContainerView)
// ==========================================
struct ProfileContainerView: View {
    var isChristmasMode: Bool
    @Binding var resetTrigger: Bool
    
    @State private var selectedTab = 0
    let tabs = ["ИНФОРМАЦИЯ", "РАСПИСАНИЕ", "ДОЛГИ", "СПРАВКИ", "КУРСЫ"]
    @Environment(\.colorScheme) var colorScheme
    
    // Состояние для фото
    @State private var avatarItem: PhotosPickerItem? = nil
    @State private var avatarImage: Image? = nil
    
    @StateObject private var dataManager = AppDataManager.shared
    @State private var showNotification = false
    @Namespace private var animation
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 1. Верхняя панель (Header)
                headerView
                
                // 2. Меню вкладок
                tabMenuView
                
                // 3. Содержимое вкладок
                contentView
            }
            .navigationBarHidden(true)
            .background(Color(UIColor.systemGroupedBackground))
            .alert(isPresented: $showNotification) {
                Alert(title: Text("Уведомления"), message: Text("Нет новых уведомлений"), dismissButton: .default(Text("OK")))
            }
            .onChange(of: resetTrigger) { _ in withAnimation { selectedTab = 0 } }
            
            // Загрузка фото при старте
            .onAppear {
                if let saved = dataManager.loadImage() { avatarImage = Image(uiImage: saved) }
            }
            // Обработка выбора нового фото
            .onChange(of: avatarItem) { item in
                Task {
                    if let d = try? await item?.loadTransferable(type: Data.self), let ui = UIImage(data: d) {
                        avatarImage = Image(uiImage: ui)
                        dataManager.saveImage(image: ui)
                    }
                }
            }
        }
    }
    
    // --- Вынесенные части интерфейса (чтобы компилятор не ругался) ---
    
    private var headerView: some View {
        HStack {
            HStack(spacing: 5) {
                Text("SmartUlSU").font(.title2).fontWeight(.black).foregroundColor(Color.themeAccent(isChristmas: isChristmasMode))
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
            }
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
            .onChange(of: selectedTab) { newTab in
                withAnimation { proxy.scrollTo(newTab, anchor: .center) }
            }
        }
    }
    
    private var contentView: some View {
        TabView(selection: $selectedTab) {
            // Передаем привязки к фото в InfoTab
            InfoTab(isChristmasMode: isChristmasMode, avatarItem: $avatarItem, avatarImage: $avatarImage).tag(0)
            
            ScheduleTab(isChristmasMode: isChristmasMode).tag(1)
            DebtsView(isChristmasMode: isChristmasMode).tag(2)
            PlaceholderView(text: "Заказ справок").tag(3)
            CoursesTab(isChristmasMode: isChristmasMode).tag(4)
        }
        .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
        .animation(.easeInOut, value: selectedTab)
    }
}

// ==========================================
// 8. ИНФОРМАЦИЯ (InfoTab)
// ==========================================
struct InfoTab: View {
    var isChristmasMode: Bool
    
    // Принимаем фото из родителя
    @Binding var avatarItem: PhotosPickerItem?
    @Binding var avatarImage: Image?
    
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var networkManager = NetworkManager.shared
    @StateObject private var dataManager = AppDataManager.shared
    @State private var isCreditWeekExpanded = true
    @State private var isAttestationExpanded = true
    @FocusState private var isNotesFocused: Bool
    
    @State private var notesHeight: CGFloat = 150
    @State private var initialNotesHeight: CGFloat = 150
    
    let manualSubjects = ["Программирование на Python", "Информатика", "История России", "Аппаратные средства ЭВМ", "Мат. логика", "Мировые инф. ресурсы", "Проектное управление", "Технология программирования", "Основы рос. гос-ва", "Физкультура"]
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                // КАРТОЧКА СТУДЕНТА
                ZStack(alignment: .bottomTrailing) {
                    LinearGradient(gradient: Gradient(colors: Color.gradientColors(index: dataManager.cardColorIndex)), startPoint: .top, endPoint: .bottom)
                        .cornerRadius(24).animation(.easeInOut, value: dataManager.cardColorIndex)
                    
                    VStack(spacing: 15) {
                        HStack {
                            Text("Студенческий").font(.caption).bold().padding(6).background(.white.opacity(0.2)).cornerRadius(8).foregroundColor(.white)
                            Spacer()
                            Text("17-я неделя").font(.caption).fontWeight(.black).padding(6).background(Color.orange).cornerRadius(8).foregroundColor(.white)
                        }
                        
                        HStack(alignment: .center, spacing: 15) {
                            // Аватарка с возможностью выбора (PhotosPicker)
                            PhotosPicker(selection: $avatarItem, matching: .images) {
                                if let img = avatarImage {
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
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(networkManager.userNameFromSite.isEmpty ? "Загрузка..." : networkManager.userNameFromSite)
                                    .font(.system(size: 20, weight: .heavy)).foregroundColor(.white).lineLimit(2)
                                Text("ИС-О-25/1").font(.title3).fontWeight(.black).foregroundColor(.white.opacity(0.95))
                            }
                            Spacer()
                        }.padding(.bottom, 10)
                    }.padding(20)
                    
                    Button(action: { AppHapticManager.shared.impact(style: .medium); dataManager.cardColorIndex = (dataManager.cardColorIndex + 1) % 4 }) {
                        Image(systemName: "paintpalette.fill").font(.title2).foregroundColor(.white).frame(width: 44, height: 44).background(.black.opacity(0.4)).clipShape(Circle())
                    }.padding(15)
                }.shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
                
                // ЗАМЕТКИ
                VStack(alignment: .leading, spacing: 10) {
                    Label("Личные заметки", systemImage: "pencil.and.scribble").font(.headline).foregroundColor(.primary)
                    VStack(spacing: 0) {
                        ZStack(alignment: .topLeading) {
                            if dataManager.notes.isEmpty {
                                Text("Напиши сюда что-нибудь важное...").foregroundColor(.gray).padding(.top, 12).padding(.leading, 8)
                            }
                            TextEditor(text: $dataManager.notes)
                                .focused($isNotesFocused)
                                .frame(height: notesHeight)
                                .padding(4).background(Color.clear).scrollContentBackground(.hidden)
                        }
                        
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 20)
                            .overlay(Image(systemName: "chevron.compact.down").foregroundColor(.gray))
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        let newHeight = initialNotesHeight + value.translation.height
                                        notesHeight = min(max(newHeight, 100), 400)
                                    }
                                    .onEnded { _ in initialNotesHeight = notesHeight }
                            )
                    }
                    .padding(8).background(Color.cardBackground(for: colorScheme)).cornerRadius(16).shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer(); Button("Готово") { isNotesFocused = false }.bold().foregroundColor(.blue)
                        }
                    }
                }
                
                // ЭИОС ЗАЧЕТКА
                DisclosureGroup("Зачетная книжка (ЭИОС)", isExpanded: $isCreditWeekExpanded) {
                    if networkManager.isLoading { ProgressView().padding() }
                    else if networkManager.grades.isEmpty { Text("Потяните вниз для обновления ⬇️").foregroundColor(.gray).padding() }
                    else {
                        LazyVStack(spacing: 12) {
                            ForEach(networkManager.grades) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.subject).font(.system(size: 16, weight: .bold)).lineLimit(2)
                                        Text(item.teacher).font(.caption).foregroundColor(.gray)
                                    }
                                    Spacer()
                                    // Используем StatusChip
                                    StatusChip(text: item.grade.uppercased(), color: getNetworkColor(item.grade), icon: getIconForGrade(item.grade))
                                }
                                .padding().background(Color.cardBackground(for: colorScheme)).cornerRadius(18).shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
                            }
                        }.padding(.top, 10)
                    }
                }.accentColor(.gray)
                
                // РУЧНАЯ АТТЕСТАЦИЯ
                DisclosureGroup("Внутренняя аттестация", isExpanded: $isAttestationExpanded) {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(manualSubjects.enumerated()), id: \.offset) { index, subject in
                            HStack {
                                Text(subject).font(.system(size: 15, weight: .medium)).lineLimit(2)
                                Spacer()
                                Button(action: { withAnimation { dataManager.toggleAttestation(index: index) } }) {
                                    let status = index < dataManager.attestationStatuses.count ? dataManager.attestationStatuses[index] : 0
                                    // Используем StatusChip
                                    StatusChip(text: getManualText(status), color: getManualColor(status), icon: status == 1 ? "checkmark" : (status == 2 ? "xmark" : nil))
                                }
                            }
                            .padding().background(Color.cardBackground(for: colorScheme)).cornerRadius(18).shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
                        }
                    }.padding(.top, 10)
                }.accentColor(.gray)
            }.padding()
        }
        .refreshable { networkManager.fetchGradesSafely() }
    }
    
    func getNetworkColor(_ g: String) -> Color {
        let l = g.lowercased(); if l.contains("зачет") && !l.contains("не") { return .green }
        if l.contains("не") { return .red }
        return .blue
    }
    func getIconForGrade(_ g: String) -> String {
        let l = g.lowercased(); if l.contains("зачет") && !l.contains("не") { return "checkmark.circle.fill" }
        if l.contains("незачет") { return "xmark.circle.fill" }
        return "circle.fill"
    }
    func getManualText(_ s: Int) -> String { s == 1 ? "СДАНО" : (s == 2 ? "ДОЛГ" : "ВЫБРАТЬ") }
    func getManualColor(_ s: Int) -> Color { s == 1 ? .green : (s == 2 ? .red : .gray) }
}

// ==========================================
// ВСПОМОГАТЕЛЬНЫЙ КОМПОНЕНТ StatusChip
// ==========================================
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

// ==========================================
// 9. РАСПИСАНИЕ (ScheduleTab)
// ==========================================
struct ScheduleTab: View {
    var isChristmasMode: Bool; @Environment(\.colorScheme) var colorScheme
    @State private var selectedDate = Date(); @State private var isCalendarExpanded = false
    @AppStorage("notificationsEnabled") var notificationsEnabled = false
    
    var dateFormatter: DateFormatter { let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM"; return f }
    func getWeekTypeString(date: Date) -> String {
        let week = Calendar.current.component(.weekOfYear, from: date)
        return week % 2 == 0 ? "(Нечетная)" : "(Четная)"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            VStack { // Календарь
                Button(action: { withAnimation { isCalendarExpanded.toggle() } }) {
                    HStack {
                        Image(systemName: "calendar").foregroundColor(Color.themeAccent(isChristmas: isChristmasMode))
                        Text(dateFormatter.string(from: selectedDate)).font(.headline).bold().foregroundColor(.primary)
                        Text(getWeekTypeString(date: selectedDate)).font(.caption).foregroundColor(.gray)
                        Spacer(); Image(systemName: "chevron.right").rotationEffect(.degrees(isCalendarExpanded ? 90 : 0))
                    }.padding().background(Color.cardBackground(for: colorScheme)).cornerRadius(16).shadow(radius: 2)
                }.padding()
                if isCalendarExpanded { DatePicker("", selection: $selectedDate, displayedComponents: .date).datePickerStyle(.graphical).environment(\.locale, Locale(identifier: "ru_RU")).padding().background(Color.cardBackground(for: colorScheme)).cornerRadius(16).padding(.horizontal) }
            }.background(Color(UIColor.systemGroupedBackground)).zIndex(1)
            
            ScrollView {
                LazyVStack(spacing: 16) {
                    let items = getScheduleForDate(selectedDate)
                    if items.isEmpty {
                        VStack(spacing: 15) {
                            Image(systemName: "moon.zzz.fill").font(.system(size: 50)).foregroundColor(.indigo.opacity(0.5))
                            Text("Пар нет. Отдыхай!").font(.title3).bold().foregroundColor(.gray)
                        }.padding(.top, 50)
                    } else {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 0) {
                                VStack(alignment: .trailing) {
                                    Text(item.timeStart).font(.system(size: 16, weight: .bold))
                                    Text(item.timeEnd).font(.caption).foregroundColor(.gray)
                                }.frame(width: 60).padding(.top, 4)
                                Rectangle().fill(Color.neonColor(item.type)).frame(width: 4).cornerRadius(2).padding(.horizontal, 12)
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(item.type.uppercased()).font(.caption).fontWeight(.black).foregroundColor(Color.neonColor(item.type))
                                        Spacer()
                                        if !item.place.isEmpty { Text(item.place).font(.caption).bold().padding(4).background(.white.opacity(0.1)).cornerRadius(6).foregroundColor(.primary) }
                                    }
                                    Text(item.subject).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                                    HStack {
                                        Image(systemName: "person.fill").font(.caption)
                                        Text(item.teacher).font(.caption)
                                    }.foregroundColor(.gray)
                                }
                                .padding(14).background(Color.cardBackground(for: colorScheme)).cornerRadius(20).shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
                            }
                        }
                    }
                }.padding()
            }
            .onAppear {
                if notificationsEnabled {
                    let todaySchedule = getScheduleForDate(Date())
                    AppNotificationManager.shared.scheduleSmartNotifications(schedule: todaySchedule, enabled: true)
                }
            }
        }
    }
    
    // РАСПИСАНИЕ С ПОЛНЫМИ ИМЕНАМИ
    func getScheduleForDate(_ date: Date) -> [ScheduleItem] {
        let cal = Calendar.current; let day = cal.component(.weekday, from: date); let week = cal.component(.weekOfYear, from: date); let isOdd = (week % 2 == 0)
        if isOdd {
            switch day {
            case 2: return [
                ScheduleItem(timeStart: "08:00", timeEnd: "09:20", type: "Сем", subject: "Алгебра и геометрия", teacher: "Ковалёва Юлиана Юлиановна", place: "3/316"),
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лек", subject: "Алгебра и геометрия", teacher: "Титов Юлиан Германович", place: "332"),
                ScheduleItem(timeStart: "11:00", timeEnd: "12:20", type: "Лаб", subject: "Python / Информатика", teacher: "Титов Юлиан Германович / Никитина Вера Германовна", place: "503 / 3/127"),
                ScheduleItem(timeStart: "12:45", timeEnd: "14:05", type: "Лаб", subject: "Python / Информатика", teacher: "Титов Юлиан Германович / Никитина Вера Германовна", place: "503 / 3/127")
            ]
            case 3: return [
                ScheduleItem(timeStart: "08:00", timeEnd: "09:20", type: "Лаб", subject: "Мировые инф. ресурсы", teacher: "Беляева Олеся Львовна", place: "303"),
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лаб", subject: "Мировые инф. ресурсы", teacher: "Беляева Олеся Львовна", place: "303"),
                ScheduleItem(timeStart: "11:00", timeEnd: "12:20", type: "Сем", subject: "Дискретная математика", teacher: "Миронов Андрей Юрьевич", place: "3/316"),
                ScheduleItem(timeStart: "12:45", timeEnd: "14:05", type: "Лек", subject: "Физика", teacher: "Миронова Диана Андреевна", place: "332"),
                ScheduleItem(timeStart: "15:45", timeEnd: "17:05", type: "Лек", subject: "История России", teacher: "Сорокин Андрей Максимович", place: "332")
            ]
            case 4: return [
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лек", subject: "Дискретная математика", teacher: "Зайцева Олеся Денисовна", place: "332"),
                ScheduleItem(timeStart: "11:00", timeEnd: "12:20", type: "Прак", subject: "Английский язык", teacher: "Морозова Инна Руслановна", place: "337"),
                ScheduleItem(timeStart: "12:45", timeEnd: "14:05", type: "Сем", subject: "История России", teacher: "Сорокин Андрей Максимович", place: "2/26")
            ]
            case 5: return [
                ScheduleItem(timeStart: "08:00", timeEnd: "09:20", type: "Прак", subject: "Физическая культура", teacher: "Соколова Олеся Алексеевна", place: "Спортзал"),
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лек", subject: "Аппаратные средства ЭВМ", teacher: "Рябов Марк Алексеевич", place: "337"),
                ScheduleItem(timeStart: "11:00", timeEnd: "12:20", type: "Лаб", subject: "Физика / Аппаратные", teacher: "Миронова Диана Андреевна / Рябов Марк Алексеевич", place: "218 / 3/213"),
                ScheduleItem(timeStart: "12:45", timeEnd: "14:05", type: "Сем", subject: "Математический анализ", teacher: "Белов Артём Богданович", place: "3/418")
            ]
            case 6: return [
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лаб", subject: "Аппаратные средства", teacher: "Рябов Марк Алексеевич", place: "3/111"),
                ScheduleItem(timeStart: "11:00", timeEnd: "12:20", type: "Сем", subject: "Информатика и прог.", teacher: "Никитина Вера Германовна", place: "3/211"),
                ScheduleItem(timeStart: "12:45", timeEnd: "14:05", type: "Лек", subject: "Математический анализ", teacher: "Белов Артём Богданович", place: "332")
            ]
            default: return []
            }
        } else {
            switch day {
            case 2: return [
                ScheduleItem(timeStart: "08:00", timeEnd: "09:20", type: "Прак", subject: "Физическая культура", teacher: "Соколова Олеся Алексеевна", place: "Спортзал"),
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лек", subject: "Алгебра и геометрия", teacher: "Титов Юлиан Германович", place: "332"),
                ScheduleItem(timeStart: "11:00", timeEnd: "12:20", type: "Лаб", subject: "Python", teacher: "Титов Юлиан Германович", place: "503"),
                ScheduleItem(timeStart: "12:45", timeEnd: "14:05", type: "Лаб", subject: "Python", teacher: "Титов Юлиан Германович", place: "503")
            ]
            case 3: return [
                ScheduleItem(timeStart: "08:00", timeEnd: "09:20", type: "Лаб", subject: "Мировые инф. ресурсы", teacher: "Беляева Олеся Львовна", place: "303"),
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лаб", subject: "Мировые инф. ресурсы", teacher: "Беляева Олеся Львовна", place: "303"),
                ScheduleItem(timeStart: "11:00", timeEnd: "12:20", type: "Сем", subject: "Дискретная математика", teacher: "Миронов Андрей Юрьевич", place: "3/316")
            ]
            case 4: return [
                ScheduleItem(timeStart: "08:00", timeEnd: "09:20", type: "Сем", subject: "Алгебра и геометрия", teacher: "Ковалёва Юлиана Юлиановна", place: "3/418"),
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лек", subject: "Дискретная математика", teacher: "Зайцева Олеся Денисовна", place: "332"),
                ScheduleItem(timeStart: "11:00", timeEnd: "12:20", type: "Сем", subject: "История России", teacher: "Сорокин Андрей Максимович", place: "332")
            ]
            case 5: return [
                ScheduleItem(timeStart: "08:00", timeEnd: "09:20", type: "Прак", subject: "Физическая культура", teacher: "Соколова Олеся Алексеевна", place: "Спортзал"),
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лек", subject: "Информатика и прог.", teacher: "Ефимов Илья Арсеньевич", place: "332"),
                ScheduleItem(timeStart: "11:00", timeEnd: "12:20", type: "Лаб", subject: "Физика / Аппаратные", teacher: "Миронова Диана Андреевна / Рябов Марк Алексеевич", place: "218 / 3/213"),
                ScheduleItem(timeStart: "12:45", timeEnd: "14:05", type: "Лаб", subject: "Аппаратные средства", teacher: "Захаров Вадим Алексеевич", place: "3/213")
            ]
            case 6: return [
                ScheduleItem(timeStart: "08:00", timeEnd: "09:20", type: "Лаб", subject: "Информатика", teacher: "Никитина Вера Германовна", place: "3/118"),
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лаб", subject: "Информатика", teacher: "Никитина Вера Германовна", place: "3/118"),
                ScheduleItem(timeStart: "11:00", timeEnd: "12:20", type: "Сем", subject: "Математический анализ", teacher: "Белов Артём Богданович", place: "3/316"),
                ScheduleItem(timeStart: "12:45", timeEnd: "14:05", type: "Лек", subject: "Математический анализ", teacher: "Белов Артём Богданович", place: "332"),
                ScheduleItem(timeStart: "14:15", timeEnd: "15:35", type: "Прак", subject: "Английский язык", teacher: "Морозова Инна Руслановна", place: "332")
            ]
            case 7: return [ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лек", subject: "Физическая культура (онлайн)", teacher: "Терещенко Евгения Никитична", place: "Онлайн")]
            default: return []
            }
        }
    }
}

// ==========================================
// 10. ДОЛГИ (DebtsView)
// ==========================================
struct DebtsView: View {
    var isChristmasMode: Bool; @Environment(\.colorScheme) var colorScheme
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack { Text("Академические задолженности").font(.title2).bold(); Spacer() }.padding(.top)
                ZStack {
                    RoundedRectangle(cornerRadius: 24).fill(LinearGradient(colors: [Color.green, Color.green.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)).shadow(color: .green.opacity(0.4), radius: 10, x: 0, y: 5)
                    HStack { VStack(alignment: .leading) { Text("Все чисто!").font(.title).fontWeight(.black).foregroundColor(.white); Text("Ты молодец, долгов нет.").font(.subheadline).foregroundColor(.white.opacity(0.9)) }; Spacer(); Image(systemName: "checkmark.seal.fill").font(.system(size: 50)).foregroundColor(.white.opacity(0.8)) }.padding(25)
                }.frame(height: 120)
                VStack(alignment: .leading, spacing: 15) { Text("История погашений").font(.headline).foregroundColor(.gray); HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(.green); VStack(alignment: .leading) { Text("Математический анализ").bold(); Text("Погашено 10.10.2025").font(.caption).foregroundColor(.gray) }; Spacer() }.padding().background(Color.cardBackground(for: colorScheme)).cornerRadius(16) }
            }.padding()
        }
    }
}

// ==========================================
// 11. КУРСЫ (CoursesTab)
// ==========================================
struct CoursesTab: View {
    var isChristmasMode: Bool; @Environment(\.colorScheme) var colorScheme
    let courses = [Course(title: "Аппаратные средства ЭВМ", teacher: "Рябов Марк Алексеевич"), Course(title: "Дискретная математика", teacher: "Миронов Андрей Юрьевич")]
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 15) {
                ForEach(courses) { course in
                    HStack(spacing: 15) {
                        ZStack { Circle().fill(Color.themeAccent(isChristmas: isChristmasMode).opacity(0.1)).frame(width: 50, height: 50); Image(systemName: "book.fill").foregroundColor(Color.themeAccent(isChristmas: isChristmasMode)) }
                        VStack(alignment: .leading, spacing: 2) { Text(course.title).font(.headline); Text(course.teacher).font(.caption).foregroundColor(.gray) }
                        Spacer(); Image(systemName: "chevron.right").foregroundColor(.gray.opacity(0.5))
                    }.padding().background(Color.cardBackground(for: colorScheme)).cornerRadius(20).shadow(color: Color.black.opacity(0.03), radius: 5, x: 0, y: 2)
                }
            }.padding()
        }
    }
}

// ==========================================
// 12. ДОП. ЭКРАНЫ (Settings, Placeholder)
// ==========================================
struct AskQuestionView: View { var body: some View { Text("Вопрос").foregroundColor(.gray) } }

struct SettingsView: View {
    var logoutAction: () -> Void
    @AppStorage("isFaceIDEnabled") var isFaceIDEnabled = false
    @AppStorage("notificationsEnabled") var notificationsEnabled = false
    @Binding var isDarkMode: Bool
    @Binding var isChristmasMode: Bool
    
    var body: some View {
        Form {
            Section(header: Text("Безопасность")) { Toggle("Вход по Face ID", isOn: $isFaceIDEnabled) }
            Section(header: Text("Уведомления")) { Toggle("Уведомления о парах", isOn: $notificationsEnabled); Button("Тест") { AppNotificationManager.shared.sendTestNotification() } }
            Section(header: Text("Вид")) { Toggle("Темная тема", isOn: $isDarkMode); Toggle("Новогодний режим", isOn: $isChristmasMode).tint(.red) }
            Button("Выйти") { logoutAction() }.foregroundColor(.red)
        }
    }
}

struct PlaceholderView: View { let text: String; var body: some View { VStack { Spacer(); Text(text).foregroundColor(.gray); Spacer() } } }
