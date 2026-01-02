import Foundation
import SwiftSoup
import Combine
import SwiftUI

// Модель оценки (Codable нужно для сохранения в память)
struct GradeItem: Identifiable, Codable {
    var id = UUID()
    let subject: String
    let type: String
    let grade: String
    let date: String
    let teacher: String
}

class NetworkManager: ObservableObject {
    static let shared = NetworkManager()
    
    // 🔒 ЗАЩИТА (KILL SWITCH)
    private let LICENSE_OWNER = "Борисов Антон Александрович"
    
    @Published var grades: [GradeItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var userNameFromSite: String = ""
    
    private var session: URLSession!
    private var lastRequestTime: Date?
    private let minRequestInterval: TimeInterval = 2.0
    
    init() {
        // Проверка лицензии
        if LICENSE_OWNER != "Борисов Антон Александрович" {
            fatalError("CRITICAL ERROR: License violation.")
        }
        
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 15 // Тайм-аут 15 секунд
        self.session = URLSession(configuration: config)
        
        // 🔥 ЗАГРУЗКА ИЗ ПАМЯТИ (ОФФЛАЙН РЕЖИМ)
        loadFromCache()
    }
    
    // --- КЭШИРОВАНИЕ ---
    private func saveToCache(items: [GradeItem], name: String) {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: "cached_grades")
        }
        UserDefaults.standard.set(name, forKey: "cached_username")
    }
    
    private func loadFromCache() {
        if let data = UserDefaults.standard.data(forKey: "cached_grades"),
           let decoded = try? JSONDecoder().decode([GradeItem].self, from: data) {
            self.grades = decoded
        }
        self.userNameFromSite = UserDefaults.standard.string(forKey: "cached_username") ?? ""
    }
    
    // --- ВХОД ---
    func login(login: String, pass: String, isAuto: Bool = false, completion: @escaping (Bool) -> Void) {
        if isLoading { return }
        
        // Анти-спам (только для ручного входа)
        if !isAuto, let last = lastRequestTime, Date().timeIntervalSince(last) < minRequestInterval { return }
        lastRequestTime = Date()
        
        isLoading = true
        errorMessage = nil
        
        guard let url = URL(string: "https://portal.ulsu.ru/login/index.php") else { return }
        
        // 1. Получаем токен
        let request1 = URLRequest(url: url)
        session.dataTask(with: request1) { data, _, error in
            // Если нет интернета, но есть кэш и это авто-вход -> пускаем
            if error != nil {
                DispatchQueue.main.async {
                    self.isLoading = false
                    if isAuto && !self.grades.isEmpty {
                        completion(true) // Пускаем в оффлайн
                    } else {
                        self.errorMessage = "Нет интернета"
                        completion(false)
                    }
                }
                return
            }
            
            guard let data = data, let html = String(data: data, encoding: .utf8),
                  let token = try? SwiftSoup.parse(html).select("input[name=logintoken]").val() else {
                DispatchQueue.main.async { self.isLoading = false; self.errorMessage = "Ошибка сервера"; completion(false) }
                return
            }
            
            // 2. Отправляем пароль
            var request2 = URLRequest(url: url)
            request2.httpMethod = "POST"
            let body = "logintoken=\(token)&username=\(login)&password=\(pass)"
            request2.httpBody = body.data(using: .utf8)
            
            self.session.dataTask(with: request2) { data, _, _ in
                DispatchQueue.main.async {
                    if let data = data, let resHtml = String(data: data, encoding: .utf8), !resHtml.contains("loginerrors") {
                        // Успех
                        if !isAuto {
                            UserDefaults.standard.set(login, forKey: "saved_login")
                            UserDefaults.standard.set(pass, forKey: "saved_password")
                        }
                        self.fetchGradesSafely()
                        completion(true)
                    } else {
                        self.isLoading = false
                        self.errorMessage = "Неверный логин/пароль"
                        completion(false)
                    }
                }
            }.resume()
        }.resume()
    }
    
    // --- ЗАГРУЗКА ОЦЕНОК ---
    func fetchGradesSafely() {
        guard let url = URL(string: "https://portal.ulsu.ru/blocks/buttons/academic_progress.php") else { return }
        
        // Если вызов ручной (тянем вниз), ставим загрузку
        if !isLoading { isLoading = true }
        
        session.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async {
                self.isLoading = false
                if let data = data, let html = String(data: data, encoding: .utf8) {
                    self.parseHTML(html)
                }
            }
        }.resume()
    }
    
    // --- ПАРСЕР ---
    private func parseHTML(_ html: String) {
        do {
            let doc = try SwiftSoup.parse(html)
            
            // Имя
            if let user = try? doc.select("span.usertext").first() {
                self.userNameFromSite = try user.text()
            }
            
            // Таблица
            let rows = try doc.select("table#att0 tbody tr")
            var items: [GradeItem] = []
            
            for row in rows {
                let cols = try row.select("td")
                if cols.size() >= 7 {
                    items.append(GradeItem(
                        subject: try cols.get(1).text(),
                        type: try cols.get(3).text(),
                        grade: try cols.get(4).text().trimmingCharacters(in: .whitespacesAndNewlines),
                        date: try cols.get(2).text(),
                        teacher: try cols.get(6).text()
                    ))
                }
            }
            
            self.grades = items
            saveToCache(items: items, name: self.userNameFromSite) // Сохраняем в память
            
        } catch { print("Parse error") }
    }
    
    func tryAutoLogin(completion: @escaping (Bool) -> Void) {
        guard let l = UserDefaults.standard.string(forKey: "saved_login"),
              let p = UserDefaults.standard.string(forKey: "saved_password") else {
            completion(false)
            return
        }
        login(login: l, pass: p, isAuto: true, completion: completion)
    }
    
    func clearCredentials() {
        UserDefaults.standard.removeObject(forKey: "saved_login")
        UserDefaults.standard.removeObject(forKey: "saved_password")
        UserDefaults.standard.removeObject(forKey: "cached_grades")
        self.grades = []
        self.userNameFromSite = ""
    }
}
