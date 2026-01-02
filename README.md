🎓 SmartUlSU — iOS Client (v1.1)
Нативный iOS-клиент для студентов УлГУ. Разработан как альтернатива веб-версии портала с упором на скорость, безопасность и работу без интернета.

Статус: Private / Active Development

Версия: 1.1 (Security Update)

🔥 Основные возможности
🛡 Безопасность и Приватность
Face ID / Touch ID: Вход в приложение защищен биометрией.

Privacy Blur: При сворачивании приложения экран автоматически "размывается", скрывая оценки и личные данные в меню многозадачности (защита от подглядывания).

Secure Storage: Безопасная обработка сессии пользователя.

⚡️ Производительность и Оффлайн
Smart Caching: Расписание и оценки сохраняются локально (UserDefaults / Persistence). Приложение работает даже в бункере без интернета.

Rate Limiting: Интеллектуальная система обновлений снижает нагрузку на серверы университета (защита от DDOS).

Native UI: Написано на SwiftUI. Никаких веб-вью и тормозов. Поддержка 120Hz.

🎨 UI/UX
Haptic Feedback: Приятная тактильная отдача при действиях (использование UIImpactFeedbackGenerator).

Adaptive Theme: Полная поддержка тёмной и светлой темы.

Custom Design: Уникальный дизайн карточек с градиентами.

🛠 Технический стек
Language: Swift 5

Framework: SwiftUI

Architecture: MVVM (Model-View-ViewModel)

Networking: Custom Parsing Engine (Simulation Mode integrated for UI testing)

Concurrency: GCD (DispatchQueue), Swift Concurrency

📦 История версий
v1.1 — Security & Architecture
Добавлена защита контента при уходе приложения в фон (Blur effect).

Интеграция Face ID через LocalAuthentication.

Рефакторинг кода: внедрение менеджеров (FinalNetworkManager, FinalDataManager).

Исправлены конфликты компилятора.

v1.0 — MVP
Базовый интерфейс.

Просмотр расписания.

Парсинг оценок.