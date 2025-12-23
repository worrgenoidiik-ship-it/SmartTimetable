import WidgetKit
import SwiftUI

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), nextClass: "Алгебра и геометрия", room: "3/316", time: "08:00")
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> ()) {
        let entry = SimpleEntry(date: Date(), nextClass: "Алгебра и геометрия", room: "3/316", time: "08:00")
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        let entry = SimpleEntry(date: Date(), nextClass: "Прог. на Python", room: "503", time: "11:00")
        let timeline = Timeline(entries: [entry], policy: .atEnd)
        completion(timeline)
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let nextClass: String
    let room: String
    let time: String
}

struct SmartUlSUWidgetEntryView : View {
    var entry: Provider.Entry
    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.11, blue: 0.12)
            VStack(alignment: .leading) {
                HStack {
                    Text("SmartUlSU").font(.caption2).bold().foregroundColor(.green)
                    Spacer()
                    Text("Сегодня").font(.caption2).foregroundColor(.gray)
                }
                Spacer()
                Text(entry.time).font(.title).fontWeight(.black).foregroundColor(.white)
                Text(entry.nextClass).font(.headline).bold().foregroundColor(.white).lineLimit(2)
                Text(entry.room).font(.caption).padding(4).background(Color.white.opacity(0.1)).cornerRadius(5).foregroundColor(.white)
            }.padding()
        }
        .containerBackground(for: .widget) {
             Color(red: 0.11, green: 0.11, blue: 0.12)
        }
    }
}

@main
struct SmartUlSUWidget: Widget {
    let kind: String = "SmartUlSUWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            SmartUlSUWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Расписание")
        .description("Ближайшая пара.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
