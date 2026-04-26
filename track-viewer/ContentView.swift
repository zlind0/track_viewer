import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @State private var appState  = AppState()
    @State private var showOpen  = false

    var body: some View {
        ZStack {
            MapContainer(appState: appState)

            // Loading overlay
            if appState.isLoading {
                LoadingOverlayView(
                    progress: appState.loadingProgress,
                    message:  appState.loadingMessage
                )
            }

            // Error banner
            if let err = appState.loadError {
                VStack {
                    ErrorBannerView(message: err) {
                        appState.loadError = nil
                    }
                    Spacer()
                }
                .padding(12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(minWidth: 1100, minHeight: 680)
        .toolbar {
            // ── 左：打开 ──────────────────────────────────────────
            ToolbarItem(placement: .navigation) {
                Button {
                    showOpen = true
                } label: {
                    Label("打开", systemImage: "folder")
                }
            }

            // ── 左：返回多日（条件显示）────────────────────────────
            if appState.viewMode == .singleDayFromMulti {
                ToolbarItem(placement: .navigation) {
                    Button {
                        Task { await appState.returnToMultiDay() }
                    } label: {
                        Label("返回多日", systemImage: "arrow.backward")
                    }
                }
            }

            // ── 中：日历 / 日期范围 ───────────────────────────────
            if appState.currentFileMD5 != nil {
                ToolbarItem(placement: .principal) {
                    if appState.viewMode == .multiDay {
                        MultiDayRangeSelector(appState: appState)
                    } else {
                        MiniCalendarView(appState: appState)
                    }
                }
            }

            // ── 右：一日 / 多日 切换 ──────────────────────────────
            if appState.currentFileMD5 != nil {
                ToolbarItem(placement: .primaryAction) {
                    Picker("", selection: Binding(
                        get: {
                            appState.viewMode == .multiDay ? 1 : 0
                        },
                        set: { val in
                            if val == 1 {
                                let dates = appState.sortedDates
                                if let last  = dates.last.flatMap({ DateFormatter.utcDate.date(from: $0) }),
                                   let first = dates.first.flatMap({ DateFormatter.utcDate.date(from: $0) }) {
                                    let start = Calendar.utc.date(byAdding: .day, value: -6, to: last) ?? first
                                    Task { await appState.loadMultiDay(start: start, end: last) }
                                }
                            } else {
                                Task {
                                    if let sel = appState.selectedDate {
                                        await appState.selectDate(sel)
                                    }
                                }
                            }
                        }
                    )) {
                        Text("一日").tag(0)
                        Text("多日").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 100)
                }
            }
        }
        .fileImporter(
            isPresented: $showOpen,
            allowedContentTypes: [.commaSeparatedText,
                                  .init(filenameExtension: "gpx") ?? .data],
            onCompletion: { result in
                if case .success(let url) = result {
                    Task { await appState.importFile(url) }
                }
            }
        )
    }
}

// MARK: - MultiDayRangeSelector

struct MultiDayRangeSelector: View {
    @Bindable var appState: AppState

    private var label: String {
        let fmt = DateFormatter.utcDate
        if let s = appState.multiDayStart, let e = appState.multiDayEnd {
            return "\(fmt.string(from: s))  →  \(fmt.string(from: e))"
        } else if let s = appState.multiDayStart {
            return "从 \(fmt.string(from: s)) 开始…"
        }
        return "选择日期范围"
    }

    var body: some View {
        Button {
            appState.showDateRangePicker.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text(label)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $appState.showDateRangePicker, arrowEdge: .bottom) {
            DateRangePickerView(appState: appState)
                .frame(width: 340, height: 520)
        }
    }
}

// MARK: - Loading Overlay

struct LoadingOverlayView: View {
    let progress: Double
    let message:  String

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 16) {
                ProgressView(value: progress > 0 ? progress : nil)
                    .progressViewStyle(.circular)
                    .scaleEffect(1.4)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white)
                if progress > 0 {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 260)
                        .tint(.white)
                    Text(String(format: "%.0f%%", progress * 100))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .ignoresSafeArea()
    }
}

// MARK: - Error Banner

struct ErrorBannerView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
