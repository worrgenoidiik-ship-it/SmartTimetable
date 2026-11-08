import SwiftUI
import UIKit
import Combine
import Security

// Экраны вынесены в папку Screens/: Profile, Schedule, Courses, Messages (+ЭИОС), Settings, SharedViews.

@MainActor
class AppDataManager: ObservableObject {
    static let shared = AppDataManager()

    @Published var notes: String { didSet { UserDefaults.standard.set(notes, forKey: "user_notes") } }
    @Published var creditStatuses: [Int] { didSet { UserDefaults.standard.set(creditStatuses, forKey: "credit_statuses_array") } }
    @Published var cardColorIndex: Int { didSet { UserDefaults.standard.set(cardColorIndex, forKey: "card_color_index") } }
    @Published var attestationStatuses: [Int] { didSet { UserDefaults.standard.set(attestationStatuses, forKey: "attestation_statuses_array") } }
    /// The profile photo and its round 30 pt copy for the tab bar.
    @Published private(set) var avatar: UIImage?
    @Published private(set) var tabAvatar: UIImage?

    init() {
        self.notes = UserDefaults.standard.string(forKey: "user_notes") ?? ""
        self.creditStatuses = (UserDefaults.standard.array(forKey: "credit_statuses_array") as? [Int]) ?? Array(repeating: 0, count: 20)
        self.cardColorIndex = UserDefaults.standard.integer(forKey: "card_color_index")
        self.attestationStatuses = (UserDefaults.standard.array(forKey: "attestation_statuses_array") as? [Int]) ?? Array(repeating: 0, count: 20)
        // Documents are wiped by a reinstall, the Keychain is not: restore the photo from its copy.
        let stored = (try? Data(contentsOf: avatarURL)).flatMap(UIImage.init(data:))
            ?? AvatarBackup.load().flatMap(UIImage.init(data:))
        setAvatar(stored)
    }

    private func setAvatar(_ image: UIImage?) {
        avatar = image
        tabAvatar = image.map(Self.roundTabImage)
    }

    /// Tab bars tint template images; an original-rendered circle keeps the photo's colours.
    static func roundTabImage(_ image: UIImage) -> UIImage {
        let size = CGSize(width: 30, height: 30)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).addClip()
            let scale = max(size.width / image.size.width, size.height / image.size.height)
            let width = image.size.width * scale, height = image.size.height * scale
            image.draw(in: CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height))
        }.withRenderingMode(.alwaysOriginal)
    }

    private var avatarURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("avatar.jpg")
    }

    func saveImage(image: UIImage) {
        let resized = Self.resized(image, maxSide: 600)
        guard let data = resized.jpegData(compressionQuality: 0.75) else { return }
        try? data.write(to: avatarURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        AvatarBackup.save(data)
        setAvatar(resized)
    }

    private static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let largest = max(image.size.width, image.size.height)
        guard largest > maxSide else { return image }
        let scale = maxSide / largest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    func loadImage() -> UIImage? {
        if let data = try? Data(contentsOf: avatarURL) { return UIImage(data: data) }
        return nil
    }

    func clearPersonalData() {
        notes = ""
        creditStatuses = Array(repeating: 0, count: 20)
        attestationStatuses = Array(repeating: 0, count: 20)
        try? FileManager.default.removeItem(at: avatarURL)
        AvatarBackup.delete()
        setAvatar(nil)
    }
}

@MainActor
class AppHapticManager {
    static let shared = AppHapticManager()
    func impact(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
    func notification(type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type)
    }
}

/// Keychain copy of the profile photo (≈600 px JPEG): survives a reinstall like the session.
enum AvatarBackup {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "SmartTable") + ".avatar",
         kSecAttrAccount as String: "photo"]
    }
    static func load() -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        return SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess ? value as? Data : nil
    }
    static func save(_ data: Data) {
        SecItemDelete(query as CFDictionary)
        var record = query
        record[kSecValueData as String] = data
        record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(record as CFDictionary, nil)
    }
    static func delete() { SecItemDelete(query as CFDictionary) }
}

// ==========================================
// РАСШИРЕНИЯ (COLORS & UTILS)
// ==========================================

extension Color {
    static func cardBackground(for colorScheme: ColorScheme) -> Color {
        AppTheme.color(AppTheme.cardKey) ?? (colorScheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color.white)
    }
    /// The user's accent always wins; the festive red is only the default in winter.
    static func themeAccent(isChristmas: Bool) -> Color {
        AppTheme.color(AppTheme.accentKey)
            ?? (isChristmas ? Color(red: 0.85, green: 0.1, blue: 0.1) : Color(red: 0.0, green: 0.48, blue: 1.0))
    }
    static func neonColor(_ type: String) -> Color {
        if type.contains("Лек") { return .orange }
        if type.contains("Лаб") { return Color(red: 0.0, green: 0.5, blue: 1.0) }
        return Color(red: 0.0, green: 0.8, blue: 0.4)
    }
    static func gradientColors(index: Int) -> [Color] {
        if let top = AppTheme.color(AppTheme.studentTopKey), let bottom = AppTheme.color(AppTheme.studentBottomKey) {
            return [top, bottom]
        }
        if UserDefaults.standard.bool(forKey: ChristmasMode.effectiveKey) {
            return [Color(red: 0.05, green: 0.35, blue: 0.15), Color(red: 0.75, green: 0.08, blue: 0.1)]
        }
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
    @MainActor
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// ==========================================
// СНЕГ (новогодний режим)
// ==========================================
/// One Canvas redrawn ~30 times a second instead of 40 separately animated views:
/// a single cheap draw pass, no per-flake layout or animation bookkeeping.
@MainActor
struct SnowView: View {
    private struct Flake { let x: Double; let size: Double; let speed: Double; let phase: Double; let drift: Double }
    private let flakes: [Flake] = (0..<40).map { _ in
        Flake(x: .random(in: 0...1), size: .random(in: 2...5), speed: .random(in: 0.08...0.2),
              phase: .random(in: 0...1), drift: .random(in: 4...14))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                for flake in flakes {
                    let progress = (flake.phase + t * flake.speed).truncatingRemainder(dividingBy: 1)
                    let y = progress * (size.height + 60) - 30
                    let x = flake.x * size.width + sin(t * 0.8 + flake.phase * 6) * flake.drift
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: flake.size, height: flake.size)),
                                 with: .color(.white.opacity(0.6)))
                }
            }
        }
        .allowsHitTesting(false).ignoresSafeArea().accessibilityHidden(true)
    }
}

// ==========================================
// ГЛАВНЫЙ ЭКРАН (ContentView)
// ==========================================
@MainActor
struct ContentView: View {
    @AppStorage("isDarkMode") private var isDarkMode = true
    @AppStorage("isChristmasMode") private var isChristmasMode = false
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var authManager = AppAuthManager.shared
    @ObservedObject private var networkManager = NetworkManager.shared
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        ZStack {
            if networkManager.isSigningOut {
                ProgressView("Выходим…")
            } else if !networkManager.canOpenApp && (networkManager.isRestoringSession || !networkManager.startupResolved) {
                ProgressView("Восстанавливаем сессию ЭИОС…")
            } else if networkManager.canOpenApp {
                MainAppView(logoutAction: { Task { await networkManager.clearCredentials() } })
                    // A new theme redraws every screen once; the open tab survives (SceneStorage).
                    .id("\(networkManager.snapshot.profile?.accountKey ?? "")#\(theme.revision)")
            } else {
                LoginView(isChristmas: isChristmasMode)
            }
            if isChristmasMode && !authManager.isLocked { SnowView() }
            if authManager.isLocked { AppLockScreen() }
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .sheet(isPresented: $networkManager.showLogin) {
            NativeLoginScreen(isChristmas: isChristmasMode, allowsClose: true)
        }
        .task {
            ChristmasMode.refresh()
            authManager.authenticate()
            await networkManager.bootstrap()
            await networkManager.restoreSavedSession() // also marks startup as resolved
            RefreshScheduler.shared.startForeground()
            AppNotificationManager.shared.updateFromSnapshot()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                ChristmasMode.refresh()
                if authManager.isLocked { authManager.authenticate() }
                RefreshScheduler.shared.startForeground()
                // Refill the nearest reminder dates even when the portal is offline.
                AppNotificationManager.shared.updateFromSnapshot()
            } else if phase == .background {
                RefreshScheduler.shared.touchOnLeaving()
                authManager.lock()
                RefreshScheduler.shared.stopForeground()
                RefreshScheduler.shared.scheduleBackground()
            }
        }
    }
}

@MainActor
struct LoginView: View {
    let isChristmas: Bool
    var body: some View {
        NativeLoginScreen(isChristmas: isChristmas)
    }
}

// ==========================================
// ВКЛАДКИ: Профиль · Сообщения · ЭИОС · Настройки
// ==========================================
@MainActor
struct MainAppView: View {
    var logoutAction: () -> Void
    @AppStorage("isChristmasMode") private var isChristmasMode = false
    @AppStorage("isDarkMode") private var isDarkMode = true
    @ObservedObject private var network = NetworkManager.shared
    @ObservedObject private var messenger = Messenger.shared
    @ObservedObject private var dataManager = AppDataManager.shared
    @SceneStorage("main.tab") private var selection = 0
    @State private var resetTrigger = false

    var body: some View {
        TabView(selection: $selection) {
            ProfileContainerView(isChristmasMode: isChristmasMode, resetTrigger: $resetTrigger)
                .tabItem {
                    // Your photo instead of the generic person icon, like on Android.
                    if let photo = dataManager.tabAvatar { Image(uiImage: photo) } else { Image(systemName: "person.crop.circle") }
                    Text("Профиль")
                }.tag(0)
            MessagesScreen(isChristmasMode: isChristmasMode)
                .tabItem { Image(systemName: "bubble.left.and.bubble.right"); Text("Сообщения") }.tag(1)
                .badge(network.unreadNotificationCount + messenger.unreadTotal)
            ServicesScreen(isChristmasMode: isChristmasMode)
                .tabItem { Image(systemName: "square.grid.2x2"); Text("ЭИОС") }.tag(2)
            SettingsView(logoutAction: logoutAction, isDarkMode: $isDarkMode, isChristmasMode: $isChristmasMode)
                .tabItem { Image(systemName: "gearshape"); Text("Настройки") }.tag(3)
        }
        .tint(Color.themeAccent(isChristmas: isChristmasMode))
        .onChange(of: selection) { _, val in if val == 0 { resetTrigger.toggle() } }
        .task { await messenger.loadConversations() } // unread chats on the tab badge
    }
}

@MainActor
struct AppLockScreen: View {
    @ObservedObject private var auth = AppAuthManager.shared
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "faceid").font(.system(size: 60))
            Text(auth.message ?? "Приложение заблокировано").multilineTextAlignment(.center)
            Button("Разблокировать") { auth.authenticate() }.buttonStyle(.borderedProminent)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(UIColor.systemBackground)).ignoresSafeArea()
    }
}
