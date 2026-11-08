import SwiftUI

@MainActor
struct PortalInboxScreen: View {
    @ObservedObject private var network = NetworkManager.shared
    @ObservedObject private var auth = AppAuthManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showImport = false
    @State private var didRequestImport = false
    @State private var page: PortalDestination?

    var body: some View {
        NavigationStack {
            List {
                if network.notifications.isEmpty {
                    Text("Уведомления ещё не загружены.").foregroundColor(.secondary)
                }
                ForEach(network.notifications) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(item.isUnread ? Color.accentColor : Color.clear)
                                .frame(width: 8, height: 8).padding(.top, 6)
                            Text(item.message).font(.body).textSelection(.enabled)
                        }
                        Text("На \(CampusDate.formatter("d MMM, HH:mm").string(from: item.observedAt)): \(item.sourceTimeLabel)")
                            .font(.caption).foregroundColor(.secondary)
                        if item.isUnread { Text("Не прочитано в ЭИОС").font(.caption2).foregroundColor(.accentColor) }
                    }.padding(.vertical, 6)
                }
                Section {
                    if let error = network.errors["notifications"] {
                        Text(error).font(.caption).foregroundColor(.secondary)
                    }
                    UpdatedText(date: network.snapshot.notifications?.fetchedAt)
                    Text("Показан текст из списка ЭИОС. Полное сообщение можно открыть на сайте.")
                        .font(.caption).foregroundColor(.secondary)
                    Button("Открыть полные сообщения") {
                        page = PortalDestination(title: "Уведомления", url: PortalConfiguration.notificationsURL)
                    }
                }
            }
            .navigationTitle("Уведомления")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showImport = true } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Обновить уведомления")
                }
            }
            .refreshable { showImport = true }
            .sheet(isPresented: $showImport) { CourseImportScreen(kind: .notifications) }
            .sheet(item: $page) { PortalBrowserScreen(title: $0.title, url: $0.url) }
            .task {
                guard !didRequestImport else { return }
                didRequestImport = true
                // Refresh on opening the inbox; the last valid list stays in cache.
                showImport = true
            }
        }
        .overlay { if auth.isLocked { AppLockScreen() } }
    }
}
