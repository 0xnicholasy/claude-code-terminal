import SwiftUI

/// The ccusage reports, as one picker: `ccusage daily`, `weekly`, `monthly`, `session`, `blocks`.
enum UsageBreakdown: String, CaseIterable, Identifiable {
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
    case projects = "Projects"
    case blocks = "5h Blocks"
    var id: String { rawValue }
}

struct UsageView: View {
    @ObservedObject var usage: UsageModel
    /// Folders of known sessions, to name ccusage's project keys.
    var knownPaths: [String] = []
    @AppStorage("usage.breakdown") private var breakdown: UsageBreakdown = .daily

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                quotaSection
                costSection
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Quota

    @ViewBuilder private var quotaSection: some View {
        Card(padding: 18) { quotaBody }
    }

    @ViewBuilder private var quotaBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Plan quota").font(.headline)
            if let q = usage.quota {
                quotaRow("5-hour window", q.fiveHour)
                quotaRow("Weekly", q.weekly)
                if let o = usage.outlook, !o.summary().isEmpty {
                    Text(o.summary()).font(.callout).foregroundStyle(.secondary)
                        .help("Reserve: even pace minus used. Session quotas: weekly headroom divided by the weekly share "
                            + "one full 5-hour quota has used so far. Windows: 5-hour windows before the weekly reset.")
                }
                ForEach(q.scoped, id: \.name) { s in QuotaBar(title: "Weekly, \(s.name) only", window: s.window) }
                if let t = q.updatedAt {
                    Text("From Claude Code, updated \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            } else if usage.quotaUnavailable {
                Text("Claude Code did not report plan limits (API key or not signed in).").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder private func quotaRow(_ title: String, _ window: QuotaWindow?) -> some View {
        if let window {
            QuotaBar(title: title, window: window)
        } else {
            HStack {
                Text(title)
                Spacer()
                Text("no limit reported").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Cost

    @ViewBuilder private var costSection: some View {
        Card(padding: 18) { costBody }
    }

    @ViewBuilder private var costBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Usage cost").font(.headline)
                Text("API-equivalent, from ccusage").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if usage.costIsRefreshing { ProgressView().controlSize(.small) }
            }
            if let c = usage.costs {
                let now = Date()
                HStack(spacing: 32) {
                    figure(Formatting.dollars(c.today(now: now)), "Today")
                    figure(Formatting.dollars(c.weekTotal(now: now)), "This week")
                    figure(Formatting.dollars(c.monthTotal(now: now)), now.formatted(.dateTime.month(.wide)))
                    figure(Formatting.dollars(c.projectedMonthTotal(now: now)), "Month on pace")
                }
                Picker("Breakdown", selection: $breakdown) {
                    ForEach(UsageBreakdown.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                breakdownBody(c, now: now)
            } else if usage.costMissingTool {
                Text("Install ccusage to see cost: bun add -g ccusage").foregroundStyle(.secondary)
            } else {
                Text("Scanning transcripts with ccusage; the first run can take a few minutes.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func breakdownBody(_ c: CostHistory, now: Date) -> some View {
        switch breakdown {
        case .daily:
            DailyBars(days: c.recent(30, now: now), details: c.details, refreshing: usage.costIsRefreshing)
        case .weekly:
            CostRows(rows: c.weekly(8, now: now).reversed().enumerated().map { i, p in
                CostRow(id: p.key, title: i == 0 ? "This week" : "Week of " + Formatting.dayTitle(p.key),
                        detail: p.tokens.map { Formatting.tokens($0) + " tokens" }, cost: p.cost, highlight: i == 0)
            })
        case .monthly:
            CostRows(rows: c.monthly(3, now: now).reversed().enumerated().map { i, p in
                CostRow(id: p.key, title: Formatting.monthTitle(p.key),
                        detail: p.tokens.map { Formatting.tokens($0) + " tokens" }, cost: p.cost, highlight: i == 0)
            })
        case .projects:
            if usage.projects.isEmpty {
                pending("Per-project cost comes from ccusage session; it refreshes hourly.")
            } else {
                CostRows(rows: usage.projects.prefix(15).map { p in
                    CostRow(id: p.key, title: ProjectKey.displayName(p.key, known: knownPaths),
                            detail: [Formatting.tokens(p.tokens) + " tokens",
                                     p.lastActivity.isEmpty ? nil : "last " + Formatting.dayTitle(p.lastActivity)]
                                .compactMap { $0 }.joined(separator: " \u{00B7} "),
                            cost: p.cost, highlight: false)
                }, caption: "Last 30 days")
            }
        case .blocks:
            if usage.blocks.isEmpty {
                pending("5-hour blocks come from ccusage blocks; they refresh hourly.")
            } else {
                CostRows(rows: usage.blocks.prefix(12).map { b in
                    CostRow(id: b.start.description, title: Formatting.blockTitle(b.start, b.end),
                            detail: Formatting.blockDetail(b), cost: b.cost, highlight: b.isActive)
                }, caption: "Last 7 days")
            }
        }
    }

    private func pending(_ text: String) -> some View {
        HStack(spacing: 8) {
            if usage.costIsRefreshing { ProgressView().controlSize(.small) }
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.monospacedDigit()).fontWeight(.semibold)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

enum QuotaStyle {
    static func color(_ used: Double) -> Color {
        used >= 90 ? .red : used >= 70 ? Palette.accent : .secondary
    }

    static func fraction(_ p: Double) -> CGFloat { CGFloat(min(100, max(0, p)) / 100) }

    static func resetText(_ window: QuotaWindow, now: Date = Date()) -> String? {
        guard let r = window.resetsAt else { return nil }
        let left = r.timeIntervalSince(now)
        guard left > 0 else { return "resetting" }
        let h = Int(left) / 3600, m = Int(left) % 3600 / 60
        let rel = h >= 24 ? "\(h / 24)d \(h % 24)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
        return "resets in \(rel)"
    }
}

struct QuotaBar: View {
    let title: String
    let window: QuotaWindow

    var body: some View {
        let now = Date()
        let expected = window.expectedPercent(now: now)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))% used").monospacedDigit()
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(QuotaStyle.color(window.usedPercent))
                        .frame(width: max(4, w * QuotaStyle.fraction(window.usedPercent)))
                    if let e = expected {
                        Rectangle().fill(.primary.opacity(0.6)).frame(width: 2, height: 14)
                            .offset(x: w * QuotaStyle.fraction(e) - 1)
                            .help("Even pace: \(Int(e.rounded()))% by now")
                    }
                }
            }
            .frame(height: 10)
            HStack {
                if let r = window.resetsAt {
                    Text("Resets \(r.formatted(date: .abbreviated, time: .shortened))")
                }
                Spacer()
                if let e = expected {
                    let delta = Int((window.usedPercent - e).rounded())
                    Text(delta <= 0 ? "\(-delta)% under even pace" : "\(delta)% over even pace")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Compact quota and cost shown in the toolbar on every tab. A window Claude Code does not report
/// (the 5-hour one on plans without it) is left out rather than shown empty.
struct QuotaChip: View {
    let quota: QuotaSnapshot?
    let costs: CostHistory?
    var outlook: QuotaOutlook?

    var body: some View {
        let now = Date()
        HStack(spacing: 18) {
            if let q = quota {
                if let w = q.fiveHour { item("5h", "5-hour window", w, now: now) }
                if let w = q.weekly { item("wk", "Weekly limit", w, now: now) }
            } else {
                Text("wk --").foregroundStyle(.secondary).help("Weekly limit: loading")
            }
            if let c = costs { cost(c, now: now) }
        }
        .font(.callout.monospacedDigit())
    }

    private func item(_ label: String, _ name: String, _ w: QuotaWindow, now: Date) -> some View {
        let projected = w.projectedPercent(now: now)
        return HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            PaceBar(window: w, now: now)
            Text("\(Int(w.usedPercent.rounded()))%").fontWeight(.medium)
            if let p = projected {
                Text("\u{2192}\(Int(p.rounded()))%")
                    .foregroundStyle(p >= 100 ? Color.red : Color.secondary)
            }
        }
        .help(help(name, w, projected: projected, now: now))
    }

    private func cost(_ c: CostHistory, now: Date) -> some View {
        HStack(spacing: 4) {
            Text(Self.wholeDollars(c.today(now: now))).fontWeight(.medium)
            Text("today").foregroundStyle(.secondary)
        }
        .help([
            "Today: \(Formatting.dollars(c.today(now: now)))",
            "This week: \(Formatting.dollars(c.weekTotal(now: now)))",
            "\(now.formatted(.dateTime.month(.wide))): \(Formatting.dollars(c.monthTotal(now: now))), on pace for \(Formatting.dollars(c.projectedMonthTotal(now: now)))",
            "API-equivalent cost from ccusage",
            Shortcuts.hint("Details in Usage tab", Shortcuts.usageTab),
        ].joined(separator: "\n"))
    }

    private func help(_ name: String, _ w: QuotaWindow, projected: Double?, now: Date) -> String {
        var lines = [["\(name): \(Int(w.usedPercent.rounded()))% used", QuotaStyle.resetText(w, now: now)]
            .compactMap { $0 }.joined(separator: ", ")]
        if let e = w.expectedPercent(now: now) { lines.append("Even pace: \(Int(e.rounded()))% by now") }
        if let p = projected { lines.append("At this rate: \(Int(p.rounded()))% at reset") }
        if w.windowMinutes >= 24 * 60, let o = outlook, !o.summary().isEmpty { lines.append(o.summary()) }
        lines.append(Shortcuts.hint("Details in Usage tab", Shortcuts.usageTab))
        return lines.joined(separator: "\n")
    }

    /// "$1,234": a fixed "$" so a non-US locale does not widen it to "US$1,234".
    static func wholeDollars(_ v: Double) -> String {
        "$" + Int(v.rounded()).formatted(.number.grouping(.automatic))
    }
}

/// Fixed-size usage bar for the toolbar, with a tick at even pace. Drawn at a fixed width (no
/// GeometryReader) so the toolbar cannot stretch or squash it.
struct PaceBar: View {
    let window: QuotaWindow
    let now: Date
    static let width: CGFloat = 36

    var body: some View {
        let used = window.usedPercent
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.14)).frame(width: Self.width, height: 4)
            Capsule().fill(used >= 70 ? QuotaStyle.color(used) : Color.primary.opacity(0.6))
                .frame(width: max(3, Self.width * QuotaStyle.fraction(used)), height: 4)
            if let e = window.expectedPercent(now: now) {
                Capsule().fill(Palette.accent).frame(width: 2, height: 9)
                    .offset(x: min(Self.width - 2, max(0, Self.width * QuotaStyle.fraction(e) - 1)))
            }
        }
        .frame(width: Self.width, height: 9)
    }
}

struct DailyBars: View {
    let days: [(day: String, cost: Double)]
    let details: [String: DayUsage]
    var refreshing = false
    @State private var hovered: String?

    var body: some View {
        let top = max(days.map(\.cost).max() ?? 0, 0.01)
        let shown = hovered ?? days.last?.day
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days, id: \.day) { d in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fill(d.day, shown: shown))
                        .frame(height: max(2, 90 * d.cost / top))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { hovered = d.day } else if hovered == d.day { hovered = nil }
                        }
                }
            }
            .frame(height: 90, alignment: .bottom)
            HStack {
                Text(days.first?.day ?? "")
                Spacer()
                Text("Last 30 days")
                Spacer()
                Text("Today")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            if let shown, let cost = days.first(where: { $0.day == shown })?.cost {
                DayCard(day: shown, cost: cost, detail: details[shown], refreshing: refreshing)
                    .padding(.top, 8)
            }
        }
    }

    private func fill(_ day: String, shown: String?) -> Color {
        day == shown ? Palette.accent : Color.secondary.opacity(0.55)
    }
}

struct DayCard: View {
    let day: String
    let cost: Double
    let detail: DayUsage?
    let refreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Formatting.dayTitle(day)).fontWeight(.medium)
                Spacer()
                Text(Formatting.dollars(cost)).font(.title3.monospacedDigit()).fontWeight(.semibold)
            }
            if let d = detail {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                    GridRow {
                        stat("Input", d.inputTokens)
                        stat("Output", d.outputTokens)
                        stat("Cache write", d.cacheWriteTokens)
                        stat("Cache read", d.cacheReadTokens)
                    }
                }
                if !d.models.isEmpty {
                    Divider()
                    ForEach(d.models, id: \.name) { m in
                        HStack {
                            Text(Formatting.modelName(m.name))
                            Spacer()
                            if m.cost > 0 { Text(Formatting.dollars(m.cost)).monospacedDigit() }
                        }
                        .font(.callout)
                    }
                }
            } else {
                Text(cost == 0 ? "No usage." : refreshing ? "Loading token detail from ccusage." : "No token detail for this day.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
    }

    private func stat(_ label: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Formatting.tokens(n)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CostRow: Identifiable {
    var id: String
    var title: String
    var detail: String?
    var cost: Double
    var highlight: Bool
}

/// A ccusage-style table: one line per period, project or block, with a bar scaled to the largest.
struct CostRows: View {
    let rows: [CostRow]
    var caption: String?

    var body: some View {
        let top = max(rows.map(\.cost).max() ?? 0, 0.01)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.title).fontWeight(r.highlight ? .semibold : .regular).lineLimit(1)
                        if let d = r.detail, !d.isEmpty {
                            Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(Formatting.dollars(r.cost)).monospacedDigit().fontWeight(.medium)
                    }
                    GeometryReader { geo in
                        Capsule().fill(r.highlight ? Palette.accent : Color.secondary.opacity(0.45))
                            .frame(width: max(3, geo.size.width * r.cost / top), height: 4)
                    }
                    .frame(height: 4)
                }
            }
            if let caption { Text(caption).font(.caption2).foregroundStyle(.tertiary) }
        }
    }
}
