import SwiftUI
import PhotosUI
import LocalAuthentication
import Combine
import UserNotifications

// ==========================================
// 1. МЕНЕДЖЕРЫ (ПЕРЕИМЕНОВАНЫ ДЛЯ ИСПРАВЛЕНИЯ ОШИБОК)
// ==========================================

// Бывший DataManager -> AppDataManager
class AppDataManager: ObservableObject {
    static let shared = AppDataManager()
    
    @Published var notes: String { didSet { UserDefaults.standard.set(notes, forKey: "user_notes") } }
    @Published var creditStatuses: [Int] { didSet { UserDefaults.standard.set(creditStatuses, forKey: "credit_statuses_array") } }
    @Published var cardColorIndex: Int { didSet { UserDefaults.standard.set(cardColorIndex, forKey: "card_color_index") } }
    
    init() {
        self.notes = UserDefaults.standard.string(forKey: "user_notes") ?? ""
        self.creditStatuses = UserDefaults.standard.array(forKey: "credit_statuses_array") as? [Int] ?? Array(repeating: 0, count: 20)
        self.cardColorIndex = UserDefaults.standard.integer(forKey: "card_color_index")
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
    
    func updateStatus(index: Int, value: Int) {
        if creditStatuses.indices.contains(index) {
            creditStatuses[index] = value
        }
    }
}

// Бывший HapticManager -> AppHapticManager
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

// Бывший NotificationManager -> AppNotificationManager
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
            scheduleAlert(timeString: item.timeStart, title: "Пара через 5 минут! 🏃‍♂️", body: "\(item.subject) (\(item.place))", offset: -5, center: center, calendar: calendar, today: today)
            scheduleAlert(timeString: item.timeEnd, title: "Конец через 5 минут! 🏁", body: "Скоро свобода!", offset: -5, center: center, calendar: calendar, today: today)
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
                    let triggerComps = calendar.dateComponents([.hour, .minute, .second], from: triggerDate)
                    let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComps, repeats: false)
                    let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
                    center.add(req)
                }
            }
        }
    }
    
    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "SmartUlSU"
        content.body = "Уведомления работают! 🔥"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
}

// Бывший AuthManager -> AppAuthManager
class AppAuthManager: ObservableObject {
    @Published var isLocked = false
    @AppStorage("isFaceIDEnabled") var isFaceIDEnabled = false
    func authenticate() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Вход") { success, _ in
                DispatchQueue.main.async { if success { self.isLocked = false } }
            }
        } else { self.isLocked = false }
    }
}

// ==========================================
// 2. МОДЕЛИ И ЦВЕТА
// ==========================================
struct Student { let name: String; let id: String; let faculty: String; let group: String; let isAdmin: Bool }
struct ScheduleItem: Identifiable { let id = UUID(); let timeStart: String; let timeEnd: String; let type: String; let subject: String; let teacher: String; let place: String }
struct SubjectItem: Identifiable { let id = UUID(); let name: String; let teacher: String; let type: String }
struct Course: Identifiable { let id = UUID(); let title: String; let teacher: String }

extension Color {
    static func cardBackground(for colorScheme: ColorScheme) -> Color {
        return colorScheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color.white
    }
    
    // Исправлено: теперь это переменная, а не функция
    static let smartGreenVar = Color(red: 0.0, green: 0.7, blue: 0.35)
    
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
        case 0: return [Color.black, Color(red: 0.0, green: 0.6, blue: 0.2)] // Green
        case 1: return [Color.black, Color(white: 0.25)] // Graphite
        case 2: return [Color.black, Color(red: 0.0, green: 0.3, blue: 0.8)] // Blue
        case 3: return [Color.black, Color(red: 0.7, green: 0.0, blue: 0.1)] // Red
        default: return [Color.black, Color.gray]
        }
    }
}

// ==========================================
// 3. UI
// ==========================================
struct SnowView: View {
    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<40, id: \.self) { _ in SnowFlake(proxy: proxy) }
        }.allowsHitTesting(false).ignoresSafeArea()
    }
}
struct SnowFlake: View {
    let proxy: GeometryProxy
    @State private var y: CGFloat = -50
    @State private var x: CGFloat = 0
    var body: some View {
        Circle().fill(Color.white.opacity(0.6)).frame(width: CGFloat.random(in: 2...5)).position(x: x, y: y)
            .onAppear {
                x = CGFloat.random(in: 0...proxy.size.width)
                withAnimation(Animation.linear(duration: Double.random(in: 5...12)).repeatForever(autoreverses: false)) { y = proxy.size.height + 50 }
            }
    }
}

struct ContentView: View {
    @AppStorage("savedUserName") private var savedUserName = ""
    @AppStorage("isDarkMode") private var isDarkMode = true
    @AppStorage("isChristmasMode") private var isChristmasMode = true
    @StateObject private var authManager = AppAuthManager() // Используем новое имя
    @State private var currentStudent: Student? = nil
    
    var body: some View {
        ZStack {
            if authManager.isLocked && authManager.isFaceIDEnabled {
                VStack {
                    Image(systemName: "faceid").font(.system(size: 60)).foregroundColor(Color.themeAccent(isChristmas: isChristmasMode))
                    Button("Войти") {
                        AppHapticManager.shared.impact(style: .medium)
                        authManager.authenticate()
                    }.padding()
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(UIColor.systemBackground)).onAppear { authManager.authenticate() }
            } else {
                if currentStudent == nil {
                    LoginView(isChristmas: isChristmasMode, onLogin: { name in
                        AppHapticManager.shared.notification(type: .success)
                        savedUserName = name
                        currentStudent = Student(name: name, id: "260305250006", faculty: "ФМИАТ", group: "ИС-О-25/1", isAdmin: true)
                    })
                } else {
                    MainAppView(student: currentStudent!, logoutAction: {
                        AppHapticManager.shared.impact(style: .light)
                        savedUserName = ""
                        currentStudent = nil
                    })
                }
            }
            if isChristmasMode { SnowView() }
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .onAppear {
            if !savedUserName.isEmpty { currentStudent = Student(name: savedUserName, id: "260305250006", faculty: "ФМИАТ", group: "ИС-О-25/1", isAdmin: true) }
            if authManager.isFaceIDEnabled { authManager.isLocked = true }
            AppNotificationManager.shared.requestPermission()
        }
    }
}

struct LoginView: View {
    var isChristmas: Bool; @State private var name = ""; var onLogin: (String) -> Void
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            VStack(spacing: 20) {
                Spacer()
                if isChristmas { Text("🎄").font(.system(size: 60)) }
                Text("SmartUlSU").font(.system(size: 40, weight: .black)).foregroundColor(Color.themeAccent(isChristmas: isChristmas))
                TextField("ФИО", text: $name).padding().background(Color.white.opacity(0.1)).cornerRadius(12).foregroundColor(.white).padding(.horizontal)
                Button("Войти") { if !name.isEmpty { onLogin(name) } }.padding().background(Color.themeAccent(isChristmas: isChristmas)).foregroundColor(.white).cornerRadius(12)
                Spacer()
            }
        }
    }
}

struct MainAppView: View {
    let student: Student; var logoutAction: () -> Void
    @AppStorage("isChristmasMode") private var isChristmasMode = true
    @AppStorage("isDarkMode") private var isDarkMode = true
    @State private var selection = 0
    @State private var resetTrigger = false
    
    var body: some View {
        TabView(selection: $selection) {
            ProfileContainerView(student: student, isChristmasMode: isChristmasMode, resetTrigger: $resetTrigger)
                .tabItem { Image(systemName: "person.crop.circle"); Text("Профиль") }.tag(0)
            
            Text("Новости (Скоро)").tabItem { Image(systemName: "newspaper"); Text("Новости") }.tag(1)
            AskQuestionView().tabItem { Image(systemName: "questionmark.bubble"); Text("Вопрос") }.tag(2)
            SettingsView(isDarkMode: $isDarkMode, isChristmasMode: $isChristmasMode, logoutAction: logoutAction).tabItem { Image(systemName: "gearshape"); Text("Настройки") }.tag(3)
        }
        .accentColor(Color.themeAccent(isChristmas: isChristmasMode))
        .onChange(of: selection) { val in
            AppHapticManager.shared.impact(style: .light)
            if val == 0 { resetTrigger.toggle() }
        }
    }
}

struct ProfileContainerView: View {
    let student: Student; var isChristmasMode: Bool; @Binding var resetTrigger: Bool
    @State private var selectedTab = 0
    let tabs = ["ИНФОРМАЦИЯ", "РАСПИСАНИЕ", "ЗАДОЛЖЕННОСТИ", "СПРАВКИ", "КУРСЫ"]
    @Environment(\.colorScheme) var colorScheme
    @State private var avatarItem: PhotosPickerItem? = nil; @State private var avatarImage: Image? = nil
    @State private var showNotification = false
    @StateObject private var dataManager = AppDataManager.shared // Используем новое имя
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Хедер
                HStack {
                    HStack(spacing: 5) {
                        Text("SmartUlSU").font(.title2).fontWeight(.black)
                            .foregroundColor(Color.themeAccent(isChristmas: isChristmasMode))
                        if isChristmasMode { Text("🎅").font(.title2) }
                    }
                    Spacer()
                    Button(action: {
                        AppHapticManager.shared.impact(style: .medium)
                        showNotification = true
                    }) {
                        Image(systemName: "bell.fill").foregroundColor(.gray)
                            .padding(8).background(Color.white.opacity(0.1)).clipShape(Circle())
                    }
                }.padding().background(Color.cardBackground(for: colorScheme))
                
                // Меню
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            ForEach(0..<tabs.count, id: \.self) { index in
                                VStack {
                                    Text(tabs[index])
                                        .fontWeight(.bold)
                                        .foregroundColor(selectedTab == index ? Color.themeAccent(isChristmas: isChristmasMode) : .gray)
                                        .onTapGesture {
                                            AppHapticManager.shared.impact(style: .light)
                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                                selectedTab = index
                                            }
                                        }
                                    
                                    Rectangle()
                                        .fill(selectedTab == index ? Color.themeAccent(isChristmas: isChristmasMode) : Color.clear)
                                        .frame(height: 3)
                                }
                                .id(index)
                            }
                        }.padding(.horizontal)
                    }
                    .background(Color.cardBackground(for: colorScheme))
                    .onChange(of: selectedTab) { newTab in withAnimation { proxy.scrollTo(newTab, anchor: .center) } }
                }
                
                // Контент
                TabView(selection: $selectedTab) {
                    InfoTab(student: student, avatarItem: $avatarItem, avatarImage: $avatarImage, isChristmasMode: isChristmasMode).tag(0)
                    ScheduleTab(isChristmasMode: isChristmasMode).tag(1)
                    PlaceholderView(text: "Долгов нет").tag(2)
                    PlaceholderView(text: "Заказ справок").tag(3)
                    CoursesTab(isChristmasMode: isChristmasMode).tag(4)
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .animation(.easeInOut, value: selectedTab)
            }
            .navigationBarHidden(true).background(Color(UIColor.systemGroupedBackground))
            .alert(isPresented: $showNotification) { Alert(title: Text("Уведомления"), message: Text("Нет новых уведомлений"), dismissButton: .default(Text("OK"))) }
            .onChange(of: resetTrigger) { _ in withAnimation { selectedTab = 0 } }
            .onAppear {
                if let saved = dataManager.loadImage() { avatarImage = Image(uiImage: saved) }
            }
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
}

// ==========================================
// 6. ИНФОРМАЦИЯ
// ==========================================
struct InfoTab: View {
    let student: Student; @Binding var avatarItem: PhotosPickerItem?; @Binding var avatarImage: Image?
    var isChristmasMode: Bool; @Environment(\.colorScheme) var colorScheme
    @StateObject private var dataManager = AppDataManager.shared // Новое имя
    @State private var isAttestationExpanded = false
    @State private var isCreditWeekExpanded = false
    
    let subjects = [
        SubjectItem(name: "Программирование на Python", teacher: "Титов Юлиан Германович", type: "Credit"),
        SubjectItem(name: "Информатика и программирование", teacher: "Никитина Вера Германовна", type: "Exam"),
        SubjectItem(name: "История России", teacher: "Сорокин Андрей Максимович", type: "Exam"),
        SubjectItem(name: "Аппаратные средства ЭВМ", teacher: "Рябов Марк Алексеевич", type: "Credit"),
        SubjectItem(name: "Математическая логика", teacher: "Ершова Нина Остаповна", type: "Credit"),
        SubjectItem(name: "Мировые информационные ресурсы", teacher: "Беляева Олеся Львовна", type: "Credit"),
        SubjectItem(name: "Основы проектного управления", teacher: "Ларионова Ольга Александровна", type: "Credit"),
        SubjectItem(name: "Технология программирования", teacher: "Горбунов Илья Андреевич", type: "Credit"),
        SubjectItem(name: "Основы российской государственности", teacher: "Гусева Ольга Викторовна", type: "Credit"),
        SubjectItem(name: "Физическая культура", teacher: "Терещенко Евгения Никитична", type: "Credit")
    ]
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                // КАРТОЧКА
                ZStack(alignment: .bottomTrailing) {
                    LinearGradient(gradient: Gradient(colors: Color.gradientColors(index: dataManager.cardColorIndex)), startPoint: .top, endPoint: .bottom)
                        .cornerRadius(20)
                        .animation(.easeInOut, value: dataManager.cardColorIndex)
                    
                    VStack(spacing: 15) {
                        HStack {
                            Text("Студенческий билет").font(.caption).bold().padding(6).background(Color.white.opacity(0.2)).cornerRadius(8).foregroundColor(.white)
                            Spacer()
                            Text("17-я неделя").font(.caption).fontWeight(.black).padding(6).background(Color.orange).cornerRadius(8).foregroundColor(.white)
                        }
                        
                        HStack(alignment: .center, spacing: 15) {
                            PhotosPicker(selection: $avatarItem, matching: .images) {
                                if let avatarImage {
                                    avatarImage.resizable().scaledToFill().frame(width: 85, height: 85).clipShape(Circle()).overlay(Circle().stroke(.white, lineWidth: 3))
                                } else {
                                    Circle().fill(.white.opacity(0.3)).frame(width: 85, height: 85).overlay(Image(systemName: "camera.fill").foregroundColor(.white))
                                }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(student.name).font(.system(size: 22, weight: .heavy)).foregroundColor(.white).lineLimit(2)
                                Text(student.group).font(.title3).fontWeight(.black).foregroundColor(.white.opacity(0.95))
                                Text(student.faculty).font(.headline).bold().foregroundColor(.white.opacity(0.8))
                            }
                            Spacer()
                        }.padding(.bottom, 10)
                    }.padding(20)
                    
                    Button(action: {
                        AppHapticManager.shared.impact(style: .medium)
                        dataManager.cardColorIndex = (dataManager.cardColorIndex + 1) % 4
                    }) {
                        Image(systemName: "paintpalette.fill").font(.title2).foregroundColor(.white.opacity(0.9)).frame(width: 50, height: 50).background(Color.black.opacity(0.4)).clipShape(Circle())
                    }.padding(15)
                }.shadow(radius: 8)
                
                VStack(alignment: .leading) {
                    Label("Заметки", systemImage: "note.text").font(.headline)
                    TextEditor(text: $dataManager.notes).frame(height: 100).padding(5).background(Color.cardBackground(for: colorScheme)).cornerRadius(12)
                }
                
                DisclosureGroup("Внутренняя аттестация", isExpanded: $isAttestationExpanded) {
                    LazyVStack(spacing: 12) {
                        ForEach(subjects) { item in
                            HStack(spacing: 0) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name).font(.headline).bold().foregroundColor(.primary)
                                    Text(item.teacher).font(.caption).foregroundColor(.red)
                                    Text("05.11.25").font(.caption2).foregroundColor(.gray)
                                }.padding()
                                Spacer()
                                if item.type == "Credit" {
                                    ZStack {
                                        Circle().fill(Color.smartGreenVar).frame(width: 100, height: 100).offset(x: 35)
                                        Text("Аттесто").font(.caption).bold().foregroundColor(.white).offset(x: 15)
                                    }.frame(width: 70).clipped()
                                }
                            }.background(Color.cardBackground(for: colorScheme)).cornerRadius(15)
                        }
                    }.padding(.top)
                }.accentColor(.gray)
                
                DisclosureGroup("Зачетная неделя", isExpanded: $isCreditWeekExpanded) {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(subjects.enumerated()), id: \.offset) { index, item in
                            HStack {
                                Text(item.name).font(.subheadline).fontWeight(.medium).lineLimit(1)
                                Spacer()
                                Menu {
                                    Button("Пусто") { dataManager.updateStatus(index: index, value: 0) }
                                    Button("Зачет") { dataManager.updateStatus(index: index, value: 1) }
                                    Button("Автомат") { dataManager.updateStatus(index: index, value: 2) }
                                } label: {
                                    if index < dataManager.creditStatuses.count {
                                        if dataManager.creditStatuses[index] == 1 { Text("Зачет").font(.caption).bold().padding(5).background(Color.green.opacity(0.2)).foregroundColor(.green).cornerRadius(5) }
                                        else if dataManager.creditStatuses[index] == 2 { Text("Автомат").font(.caption).bold().padding(5).background(Color.orange.opacity(0.2)).foregroundColor(.orange).cornerRadius(5) }
                                        else { Text("Выбрать").font(.caption).foregroundColor(.gray) }
                                    }
                                }
                            }.padding().background(Color.cardBackground(for: colorScheme)).cornerRadius(12)
                        }
                    }.padding(.top)
                }.accentColor(.gray)
            }.padding()
        }
    }
}

// ==========================================
// 7. РАСПИСАНИЕ
// ==========================================
struct ScheduleTab: View {
    var isChristmasMode: Bool; @Environment(\.colorScheme) var colorScheme
    @State private var selectedDate = Date()
    @State private var isCalendarExpanded = false
    @AppStorage("notificationsEnabled") var notificationsEnabled = false
    
    var dateFormatter: DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.dateFormat = "d MMMM yyyy"; return formatter
    }
    init(isChristmasMode: Bool) {
        self.isChristmasMode = isChristmasMode
        var comp = DateComponents(); comp.year = 2025; comp.month = 12; comp.day = 22
        if let d = Calendar.current.date(from: comp) { _selectedDate = State(initialValue: d) }
    }
    func getWeekTypeString(date: Date) -> String {
        let week = Calendar.current.component(.weekOfYear, from: date)
        return week % 2 == 0 ? "(Нечетная)" : "(Четная)"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            VStack {
                Button(action: {
                    AppHapticManager.shared.impact(style: .light)
                    withAnimation { isCalendarExpanded.toggle() }
                }) {
                    HStack {
                        Image(systemName: "calendar").foregroundColor(Color.themeAccent(isChristmas: isChristmasMode))
                        Text(dateFormatter.string(from: selectedDate)).bold().foregroundColor(.primary)
                        Text(getWeekTypeString(date: selectedDate)).font(.caption).foregroundColor(.gray)
                        Spacer()
                        Image(systemName: "chevron.right").rotationEffect(.degrees(isCalendarExpanded ? 90 : 0))
                    }.padding().background(Color.cardBackground(for: colorScheme)).cornerRadius(12)
                }.padding()
                if isCalendarExpanded {
                    DatePicker("", selection: $selectedDate, displayedComponents: .date).datePickerStyle(.graphical).environment(\.locale, Locale(identifier: "ru_RU")).padding().background(Color.cardBackground(for: colorScheme)).cornerRadius(12).padding(.horizontal)
                }
            }.background(Color(UIColor.systemGroupedBackground)).zIndex(1)
            
            ScrollView {
                LazyVStack(spacing: 15) {
                    let items = getScheduleForDate(selectedDate)
                    if items.isEmpty { Text("Пар нет").foregroundColor(.gray).padding(.top, 50) }
                    else {
                        ForEach(items) { item in
                            HStack(spacing: 10) {
                                VStack {
                                    Text(item.timeStart).font(.headline).bold().foregroundColor(.white)
                                    Text(item.timeEnd).font(.caption).foregroundColor(.gray)
                                }.frame(width: 55)
                                Rectangle().fill(Color.neonColor(item.type)).frame(width: 4).cornerRadius(2).padding(.vertical, 10)
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(item.type.uppercased()).font(.caption2).bold().foregroundColor(Color.neonColor(item.type))
                                        Spacer()
                                        if !item.place.isEmpty { Text(item.place).font(.caption).bold().padding(4).background(Color.white.opacity(0.1)).cornerRadius(5).foregroundColor(.white) }
                                    }
                                    Text(item.subject).font(.subheadline).bold().foregroundColor(.white)
                                    Text(item.teacher).font(.caption).foregroundColor(.gray)
                                }.padding(10)
                            }.background(Color(red: 0.12, green: 0.12, blue: 0.12)).cornerRadius(16)
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
    
    func getScheduleForDate(_ date: Date) -> [ScheduleItem] {
        let cal = Calendar.current
        let day = cal.component(.weekday, from: date)
        let week = cal.component(.weekOfYear, from: date)
        let isOdd = (week % 2 == 0)
        
        if isOdd {
            switch day {
            case 2: return [
                ScheduleItem(timeStart: "08:00", timeEnd: "09:20", type: "Сем", subject: "Алгебра и геометрия", teacher: "Ковалёва Юлиана Юлиановна", place: "3/316"),
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лек", subject: "Алгебра и геометрия", teacher: "Титов Юлиан Германович", place: "332"),
                ScheduleItem(timeStart: "11:00", timeEnd: "12:20", type: "Лаб", subject: "1п Python / 2п Информатика", teacher: "Титов / Никитина", place: "503 / 3/127"),
                ScheduleItem(timeStart: "12:45", timeEnd: "14:05", type: "Лаб", subject: "2п Python / 1п Информатика", teacher: "Титов / Никитина", place: "503 / 3/127")
            ]
            case 3: return [
                ScheduleItem(timeStart: "08:00", timeEnd: "09:20", type: "Лаб", subject: "1п Мировые инф. ресурсы", teacher: "Беляева Олеся Львовна", place: "303"),
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лаб", subject: "1п Мировые инф. ресурсы", teacher: "Беляева Олеся Львовна", place: "303"),
                ScheduleItem(timeStart: "11:00", timeEnd: "12:20", type: "Сем", subject: "Дискретная математика", teacher: "Миронов Андрей Юрьевич", place: "3/316"),
                ScheduleItem(timeStart: "12:45", timeEnd: "14:05", type: "Лек", subject: "Физика", teacher: "Миронова Диана Андреевна", place: "332"),
                ScheduleItem(timeStart: "15:45", timeEnd: "17:05", type: "Лек", subject: "История России (ВКС)", teacher: "Сорокин Андрей Максимович", place: "332")
            ]
            case 4: return [
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лек", subject: "Дискретная математика", teacher: "Зайцева Олеся Денисовна", place: "332"),
                ScheduleItem(timeStart: "11:00", timeEnd: "12:20", type: "Прак", subject: "Английский язык", teacher: "Морозова Инна Руслановна", place: "337"),
                ScheduleItem(timeStart: "12:45", timeEnd: "14:05", type: "Сем", subject: "История России", teacher: "Сорокин Андрей Максимович", place: "2/26")
            ]
            case 5: return [
                ScheduleItem(timeStart: "08:00", timeEnd: "09:20", type: "Прак", subject: "Физическая культура", teacher: "Соколова Олеся Алексеевна", place: "Спортзал"),
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лек", subject: "Аппаратные средства ЭВМ", teacher: "Рябов Марк Алексеевич", place: "337"),
                ScheduleItem(timeStart: "11:00", timeEnd: "12:20", type: "Лаб", subject: "1п Физика / 2п Аппаратные", teacher: "Миронова / Рябов", place: "218 / 3/213"),
                ScheduleItem(timeStart: "12:45", timeEnd: "14:05", type: "Сем", subject: "Математический анализ", teacher: "Белов Артём Богданович", place: "3/418")
            ]
            case 6: return [
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лаб", subject: "1п Аппаратные средства", teacher: "Рябов Марк Алексеевич", place: "3/111"),
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
                ScheduleItem(timeStart: "11:00", timeEnd: "12:20", type: "Лаб", subject: "1п Python", teacher: "Титов Юлиан Германович", place: "503"),
                ScheduleItem(timeStart: "12:45", timeEnd: "14:05", type: "Лаб", subject: "2п Python", teacher: "Титов Юлиан Германович", place: "503")
            ]
            case 3: return [
                ScheduleItem(timeStart: "08:00", timeEnd: "09:20", type: "Лаб", subject: "2п Мировые инф. ресурсы", teacher: "Беляева Олеся Львовна", place: "303"),
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лаб", subject: "2п Мировые инф. ресурсы", teacher: "Беляева Олеся Львовна", place: "303"),
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
                ScheduleItem(timeStart: "11:00", timeEnd: "12:20", type: "Лаб", subject: "2п Физика / 1п Аппаратные", teacher: "Миронова / Рябов", place: "218 / 3/213"),
                ScheduleItem(timeStart: "12:45", timeEnd: "14:05", type: "Лаб", subject: "2п Аппаратные средства", teacher: "Захаров Вадим Алексеевич", place: "3/213")
            ]
            case 6: return [
                ScheduleItem(timeStart: "08:00", timeEnd: "09:20", type: "Лаб", subject: "2п Информатика", teacher: "Никитина Вера Германовна", place: "3/118"),
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лаб", subject: "1п Информатика", teacher: "Никитина Вера Германовна", place: "3/118"),
                ScheduleItem(timeStart: "11:00", timeEnd: "12:20", type: "Сем", subject: "Математический анализ", teacher: "Белов Артём Богданович", place: "3/316"),
                ScheduleItem(timeStart: "12:45", timeEnd: "14:05", type: "Лек", subject: "Математический анализ", teacher: "Белов Артём Богданович", place: "332"),
                ScheduleItem(timeStart: "14:15", timeEnd: "15:35", type: "Прак", subject: "Английский язык", teacher: "Морозова Инна Руслановна", place: "332")
            ]
            case 7: return [
                ScheduleItem(timeStart: "09:30", timeEnd: "10:50", type: "Лек", subject: "Физическая культура (онлайн)", teacher: "Терещенко Евгения Никитична", place: "Онлайн")
            ]
            default: return []
            }
        }
    }
}

// ==========================================
// 8. ДРУГИЕ ВКЛАДКИ
// ==========================================
struct CoursesTab: View {
    var isChristmasMode: Bool; @Environment(\.colorScheme) var colorScheme
    let courses = [
        Course(title: "Аппаратные средства ЭВМ", teacher: "Рябов Марк Алексеевич"),
        Course(title: "Дискретная математика", teacher: "Миронов Андрей Юрьевич"),
        Course(title: "Информатика (Python)", teacher: "Ефимов Илья Арсеньевич")
    ]
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(courses) { course in
                    HStack {
                        Image(systemName: "book.fill").foregroundColor(Color.themeAccent(isChristmas: isChristmasMode)).padding().background(Color.themeAccent(isChristmas: isChristmasMode).opacity(0.1)).cornerRadius(10)
                        VStack(alignment: .leading) {
                            Text(course.title).font(.subheadline).bold()
                            Text(course.teacher).font(.caption).foregroundColor(.gray)
                        }
                        Spacer(); Image(systemName: "chevron.right").foregroundColor(.gray)
                    }.padding().background(Color.cardBackground(for: colorScheme)).cornerRadius(12)
                }
            }.padding()
        }
    }
}

struct AskQuestionView: View {
    var body: some View { Text("Вопрос").foregroundColor(.gray) }
}
struct SettingsView: View {
    @Binding var isDarkMode: Bool; @Binding var isChristmasMode: Bool; var logoutAction: () -> Void
    @AppStorage("isFaceIDEnabled") var isFaceIDEnabled = false
    @AppStorage("notificationsEnabled") var notificationsEnabled = false
    
    var body: some View {
        Form {
            Section(header: Text("Безопасность")) { Toggle("Вход по Face ID", isOn: $isFaceIDEnabled) }
            Section(header: Text("Уведомления")) {
                Toggle("Уведомления о парах (за 5 мин)", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { enabled in
                        if !enabled { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
                    }
                Button("Тест") { AppNotificationManager.shared.sendTestNotification() }
            }
            Section(header: Text("Вид")) { Toggle("Темная тема", isOn: $isDarkMode); Toggle("Новогодний режим (Красный)", isOn: $isChristmasMode).tint(Color.themeAccent(isChristmas: isChristmasMode)) }
            Button("Выйти из аккаунта") { logoutAction() }.foregroundColor(.red)
        }
    }
}
struct PlaceholderView: View { let text: String; var body: some View { VStack { Spacer(); Text(text).foregroundColor(.gray); Spacer() } } }
