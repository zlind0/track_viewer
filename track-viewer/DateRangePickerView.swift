import SwiftUI

// MARK: - DateRangePickerView
// Agoda/Booking.com-style scrollable month calendar for selecting a date range.

struct DateRangePickerView: View {
    @Bindable var appState: AppState
    @State private var hoverDate: String?

    private var rangeStart: String? {
        appState.multiDayStart.map { DateFormatter.utcDate.string(from: $0) }
    }
    private var rangeEnd: String? {
        appState.multiDayEnd.map { DateFormatter.utcDate.string(from: $0) }
    }

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
        return months.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("选择日期范围")
                        .font(.headline)
                    if let s = rangeStart, let e = rangeEnd {
                        Text("\(s)  →  \(e)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let s = rangeStart {
                        Text("从 \(s) 开始…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("点击选择开始日期")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if rangeStart != nil || rangeEnd != nil {
                    Button("清除") {
                        appState.multiDayStart = nil
                        appState.multiDayEnd   = nil
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                Button("确定") {
                    appState.showDateRangePicker = false
                    if let s = appState.multiDayStart, let e = appState.multiDayEnd {
                        Task { await appState.loadMultiDay(start: s, end: e) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(rangeStart == nil || rangeEnd == nil)
            }
            .padding()

            Divider()

            // Weekday header (sticky)
            HStack(spacing: 0) {
                ForEach(["日","一","二","三","四","五","六"], id: \.self) { wd in
                    Text(wd)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial)

            Divider()

            ScrollView(.vertical) {
                LazyVStack(spacing: 20) {
                    ForEach(monthRanges) { month in
                        RangeMonthGridView(
                            month: month,
                            appState: appState,
                            hoverDate: $hoverDate,
                            rangeStart: rangeStart,
                            rangeEnd: rangeEnd,
                            onTap: { handleTap($0) }
                        )
                        .id(month.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
    }

    private func handleTap(_ dateStr: String) {
        guard DateFormatter.utcDate.date(from: dateStr) != nil else { return }

        if rangeStart == nil {
            // Set start
            appState.multiDayStart = DateFormatter.utcDate.date(from: dateStr)
            appState.multiDayEnd   = nil
        } else if rangeEnd == nil {
            // Set end — ensure start <= end
            let clickedDate = DateFormatter.utcDate.date(from: dateStr)!
            if clickedDate < appState.multiDayStart! {
                appState.multiDayEnd   = appState.multiDayStart
                appState.multiDayStart = clickedDate
            } else {
                appState.multiDayEnd = clickedDate
            }
        } else {
            // Reset
            appState.multiDayStart = DateFormatter.utcDate.date(from: dateStr)
            appState.multiDayEnd   = nil
        }
    }
}

// MARK: - RangeMonthGridView

private struct RangeMonthGridView: View {
    let month:      MonthInfo
    let appState:   AppState
    @Binding var hoverDate: String?
    let rangeStart: String?
    let rangeEnd:   String?
    let onTap:      (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(month.title)
                .font(.system(size: 13, weight: .semibold))

            let days = month.calendarDays
            let rows = days.count / 7
            ForEach(0 ..< rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0 ..< 7, id: \.self) { col in
                        let dateStr = days[row * 7 + col]
                        RangeDayCell(
                            dateStr:    dateStr,
                            summary:    dateStr.flatMap { appState.summaryByDate[$0] },
                            rangeStart: rangeStart,
                            rangeEnd:   rangeEnd,
                            hoverDate:  hoverDate,
                            onTap:      { if let d = dateStr { onTap(d) } },
                            onHover:    { hoverDate = $0 }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - RangeDayCell

private struct RangeDayCell: View {
    let dateStr:    String?
    let summary:    DailySummary?
    let rangeStart: String?
    let rangeEnd:   String?
    let hoverDate:  String?
    let onTap:      () -> Void
    let onHover:    (String?) -> Void

    private var effectiveEnd: String? { rangeEnd ?? (rangeStart != nil ? hoverDate : nil) }

    private var position: CellPosition {
        guard let d = dateStr else { return .none }
        let s = rangeStart, e = effectiveEnd

        if s == nil && e == nil    { return .none }
        if d == s && d == e        { return .single }
        if d == s                  { return .start }
        if d == e                  { return .end }

        // In range?
        if let s = s, let e = e {
            let lo = min(s, e), hi = max(s, e)
            if d > lo && d < hi { return .middle }
        }
        return .none
    }

    private var hasData: Bool { summary != nil }

    var body: some View {
        ZStack {
            // Range highlight background
            switch position {
            case .start:
                HStack(spacing: 0) {
                    Color.clear
                    Color.accentColor.opacity(0.15)
                }
            case .end:
                HStack(spacing: 0) {
                    Color.accentColor.opacity(0.15)
                    Color.clear
                }
            case .middle:
                Color.accentColor.opacity(0.15)
            case .single, .none:
                Color.clear
            }

            // Dot (data indicator)
            VStack(spacing: 0) {
                Spacer()
                if hasData, let d = dateStr {
                    Circle()
                        .fill(ColorUtils.heatmapColor(intensity: summary!.colorIntensity))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle().strokeBorder(
                                (d == rangeStart || d == effectiveEnd) ? Color.accentColor : .clear,
                                lineWidth: 2
                            )
                        )
                }
                Spacer()
            }

            if let d = dateStr {
                let dayNum = Int(d.suffix(2)) ?? 0
                Text("\(dayNum)")
                    .font(.system(size: 12, weight: (d == rangeStart || d == effectiveEnd) ? .bold : .regular))
                    .foregroundStyle(hasData ? .primary : .tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .contentShape(Rectangle())
        .onTapGesture { if dateStr != nil { onTap() } }
        .onHover { hovering in
            onHover(hovering ? dateStr : nil)
        }
    }

    enum CellPosition { case none, start, end, middle, single }
}
