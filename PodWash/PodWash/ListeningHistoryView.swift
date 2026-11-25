import SwiftUI

enum ListeningHistoryDestination: Hashable {
    case history
}

struct ListeningHistoryView: View {
    let model: AppShellModel
    var bottomContentClearance: CGFloat = 0

    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.scenePhase) private var scenePhase
    @State private var now = Date()

    var body: some View {
        let entries = model.historyEntries
        let dated = entries.filter { $0.completedAt != nil }
        let undated = entries.filter { $0.completedAt == nil }
        let localCalendar = calendarWithTimeZone
        let groups = Dictionary(grouping: dated) { entry in
            localCalendar.startOfDay(for: entry.completedAt ?? .distantPast)
        }
        Group {
            if entries.isEmpty {
                ContentUnavailableView("No listening history", systemImage: "clock",
                                       description: Text("Episodes you finish will appear here."))
            } else {
                List {
                    ForEach(groups.keys.sorted(by: >), id: \.self) { date in
                        Section(dayLabel(date, calendar: localCalendar)) {
                            rows(groups[date, default: []])
                        }
                    }
                    if !undated.isEmpty {
                        Section("Previously marked played") { rows(undated) }
                    }
                }
                .listStyle(.plain)
                .contentMargins(.bottom, bottomContentClearance, for: .scrollContent)
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Text("History").font(.headline) }
        }
        .accessibilityIdentifier("listeningHistory")
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = Date() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in now = Date() }
        .onChange(of: scenePhase) { _, next in
            if next == .active { now = Date() }
        }
    }

    private var calendarWithTimeZone: Calendar {
        var result = calendar
        result.timeZone = timeZone
        return result
    }

    private func dayLabel(_ date: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: calendar.timeZone))
    }

    private func rows(_ entries: [ListeningHistoryEntry]) -> some View {
        ForEach(entries) { entry in
            SharedEpisodeRow(snapshot: model.historyRowSnapshot(entry), bindings: model.historyRowBindings(entry))
                .accessibilityIdentifier("historyEpisode_\(entry.id.accessibilityID)")
        }
    }
}
