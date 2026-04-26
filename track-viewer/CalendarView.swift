import SwiftUI

// MARK: - Calendar Day Cell

struct CalendarDayCell: View {
    let dateStr: String?          // nil = empty slot
    let summary: DailySummary?    // nil = no data
    let isSelected: Bool
    let onTap: () -> Void

    private var weekdayLabel: String {
        guard let d = dateStr, let date = DateFormatter.utcDate.date(from: d) else { return "" }
        let idx = Calendar.utc.component(.weekday, from: date) - 1  // 1=Sun
        return ["日","一","二","三","四","五","六"][idx]
    }

    private var dayNumber: String {
        guard let d = dateStr else { return "" }
        return String(d.suffix(2).drop(while: { $0 == "0" }))   // remove leading zero
    }

    private var monthLabel: String {
        guard let d = dateStr else { return "" }
        let parts = d.split(separator: "-")
        guard parts.count >= 2 else { return "" }
        let m = Int(parts[1]) ?? 0
        return m > 0 ? "\(m)月" : ""
    }

    private var bgColor: Color {
        guard let s = summary else {
            return Color(nsColor: NSColor.separatorColor).opacity(0.15)
        }
        return ColorUtils.heatmapColor(intensity: s.colorIntensity)
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(bgColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                    )

                if dateStr != nil {
                    VStack(spacing: 2) {
                        Text(weekdayLabel)
                            .font(.system(size: 8, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text(dayNumber)
                            .font(.system(size: 14, weight: summary != nil ? .semibold : .light))
                            .foregroundStyle(summary != nil ? .primary : .tertiary)
                    }
                }
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(dateStr == nil)
    }
}

// MARK: - Mini Calendar (13-day strip)

struct MiniCalendarView: View {
    @Bindable var appState: AppState

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< 13, id: \.self) { idx in
                let dateStr = appState.miniCalendarDates[idx]
                CalendarDayCell(
                    dateStr: dateStr,
                    summary: dateStr.flatMap { appState.summaryByDate[$0] },
                    isSelected: dateStr == appState.selectedDate,
                    onTap: {
                        if let d = dateStr {
                            Task { await appState.selectDate(d) }
                        }
                    }
                )
            }

            // Expand button
            Button {
                appState.showFullCalendar.toggle()
            } label: {
                Image(systemName: appState.showFullCalendar ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 30)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $appState.showFullCalendar, arrowEdge: .bottom) {
                FullCalendarView(appState: appState)
                    .frame(width: 320, height: 500)
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Full Calendar (scrollable months)

struct FullCalendarView: View {
    @Bindable var appState: AppState
    @State private var scrollTarget: String?

    private var monthRanges: [MonthInfo] {
        guard let earliest = appState.sortedDates.first,
              let latest   = appState.sortedDates.last,
              let startDate = DateFormatter.utcDate.date(from: earliest),
              let endDate   = DateFormatter.utcDate.date(from: latest) else { return [] }

        var months: [MonthInfo] = []
        var cursor = Calendar.utc.date(from: Calendar.utc.dateComponents([.year, .month], from: startDate))!
        let endMonth = Calendar.utc.date(from: Calendar.utc.dateComponents([.year, .month], from: endDate))!

        while cursor <= endMonth {
            months.append(MonthInfo(date: cursor))
            cursor = Calendar.utc.date(byAdding: .month, value: 1, to: cursor)!
        }
        return months.reversed()   // newest first
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 24, pinnedViews: []) {
                    ForEach(monthRanges) { month in
                        MonthGridView(
                            month: month,
                            appState: appState,
                            onSelectDate: { date in
                                Task {
                                    await appState.selectDate(date)
                                    appState.showFullCalendar = false
                                }
                            }
                        )
                        .id(month.id)
                    }
                }
                .padding()
            }
            .onAppear {
                // Scroll to selected date's month
                if let sel = appState.selectedDate {
                    let month = String(sel.prefix(7))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(month, anchor: .top)
                    }
                }
            }
        }
    }
}

// MARK: - Month Info

struct MonthInfo: Identifiable {
    let date: Date  // First day of the month (UTC midnight)
    var id: String { DateFormatter.utcDate.string(from: date).prefix(7).description }

    var title: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }

    /// All days to display (including leading/trailing blanks = nil)
    var calendarDays: [String?] {
        let cal = Calendar.utc
        let comps = cal.dateComponents([.year, .month], from: date)
        let firstDay = cal.date(from: comps)!
        let weekday = cal.component(.weekday, from: firstDay) - 1  // 0=Sun
        let range = cal.range(of: .day, in: .month, for: firstDay)!

        var days: [String?] = Array(repeating: nil, count: weekday)
        for d in range {
            let dayDate = cal.date(byAdding: .day, value: d - 1, to: firstDay)!
            days.append(DateFormatter.utcDate.string(from: dayDate))
        }
        // Pad to full weeks
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }
}

// MARK: - Month Grid View

struct MonthGridView: View {
    let month:        MonthInfo
    let appState:     AppState
    let onSelectDate: (String) -> Void

    private let weekdays = ["日","一","二","三","四","五","六"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(month.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            // Weekday header
            HStack(spacing: 3) {
                ForEach(weekdays, id: \.self) { wd in
                    Text(wd)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .center)
                }
            }

            // Day grid
            let days = month.calendarDays
            let rows = days.count / 7
            ForEach(0 ..< rows, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0 ..< 7, id: \.self) { col in
                        let dateStr = days[row * 7 + col]
                        let summary = dateStr.flatMap { appState.summaryByDate[$0] }
                        let hasData = summary != nil
                        let isSelected = dateStr == appState.selectedDate

                        Button {
                            if let d = dateStr, hasData { onSelectDate(d) }
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(hasData
                                          ? ColorUtils.heatmapColor(intensity: summary!.colorIntensity)
                                          : Color.clear)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                                    )

                                if let d = dateStr {
                                    let dayNum = Int(d.suffix(2)) ?? 0
                                    Text("\(dayNum)")
                                        .font(.system(size: 12, weight: isSelected ? .bold : .regular))
                                        .foregroundStyle(hasData ? .primary : .tertiary)
                                }
                            }
                            .frame(width: 38, height: 34)
                        }
                        .buttonStyle(.plain)
                        .disabled(dateStr == nil || !hasData)
                    }
                }
            }
        }
    }
}
