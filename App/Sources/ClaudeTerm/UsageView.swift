import SwiftUI

struct UsageView: View {
    @ObservedObject var usage: UsageModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                quotaSection
                costSection
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Quota

    @ViewBuilder private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Plan quota").font(.headline)
            if usage.quotaMissingTool {
                Text("Install codexbar to see quota: brew install --cask codexbar").foregroundStyle(.secondary)
            } else if let q = usage.quota {
                quotaRow("5-hour window", q.fiveHour)
                quotaRow("Weekly", q.weekly)
                if let t = q.updatedAt {
                    Text("Updated \(t.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.tertiary)
                }
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
                Text("not reported").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Cost

    @ViewBuilder private var costSection: some View {
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
                    figure(dollars(c.monthTotal(now: now)), now.formatted(.dateTime.month(.wide)))
                    figure(dollars(c.today(now: now)), "Today")
                }
                DailyBars(days: c.recent(30, now: now))
            } else if usage.costMissingTool {
                Text("Install ccusage to see cost: bun add -g ccusage").foregroundStyle(.secondary)
            } else {
                Text("Scanning transcripts with ccusage; the first run can take a few minutes.").foregroundStyle(.secondary)
            }
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.monospacedDigit()).fontWeight(.semibold)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func dollars(_ v: Double) -> String { v.formatted(.currency(code: "USD")) }
}

struct QuotaBar: View {
    let title: String
    let window: QuotaWindow

    var body: some View {
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
                    Capsule().fill(color).frame(width: max(4, w * fraction(window.usedPercent)))
                    if let e = window.expectedPercent {
                        Rectangle().fill(.primary.opacity(0.6)).frame(width: 2, height: 14)
                            .offset(x: w * fraction(e) - 1)
                            .help("Even pace: \(Int(e.rounded()))% by now")
                    }
                }
            }
            .frame(height: 10)
            HStack {
                if let r = window.resetText ?? window.resetsAt?.formatted(date: .abbreviated, time: .shortened) {
                    Text("Resets \(r)")
                }
                Spacer()
                if let s = window.paceSummary { Text(s) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func fraction(_ p: Double) -> CGFloat { CGFloat(min(100, max(0, p)) / 100) }

    private var color: Color {
        window.usedPercent >= 90 ? .red : window.usedPercent >= 70 ? Palette.accent : .secondary
    }
}

struct DailyBars: View {
    let days: [(day: String, cost: Double)]

    var body: some View {
        let top = max(days.map(\.cost).max() ?? 0, 0.01)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days, id: \.day) { d in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(d.day == days.last?.day ? Palette.accent : Color.secondary.opacity(0.55))
                        .frame(height: max(2, 90 * d.cost / top))
                        .frame(maxWidth: .infinity)
                        .help(String(format: "%@: $%.2f", d.day, d.cost))
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
        }
    }
}
