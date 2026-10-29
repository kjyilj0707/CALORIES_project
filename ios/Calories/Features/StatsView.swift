import Charts
import Supabase
import SwiftUI

/// my_stats(days) 결과
struct SnackStats: Decodable {
    struct Day: Decodable, Identifiable { let date: String; let kcal: Double; let sugar_g: Double; var id: String { date } }
    struct Top: Decodable, Identifiable { let name: String; let count: Double; let kcal: Double; var id: String { name } }
    struct Hour: Decodable, Identifiable { let hour: Int; let count: Double; var id: Int { hour } }
    let days: Int
    let total_kcal: Double
    let total_sugar_g: Double
    let count: Double
    let daily: [Day]
    let top: [Top]
    let hours: [Hour]

    static func load(days: Int) async throws -> SnackStats {
        try await Backend.client.rpc("my_stats", params: ["days": days]).execute().value
    }
}

/// 통계: 최근 7일 / 30일
struct StatsView: View {
    @State private var days = 7
    @State private var stats: SnackStats?

    var body: some View {
        List {
            Picker("기간", selection: $days) {
                Text("7일").tag(7)
                Text("30일").tag(30)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            if let s = stats {
                Section {
                    HStack {
                        summary("칼로리", "\(Int(s.total_kcal).formatted())kcal")
                        summary("당류", "\(Int(s.total_sugar_g))g")
                        summary("군것질", "\(Int(s.count))개")
                    }
                    Text("하루 평균 \(Int(s.total_kcal / Double(s.days)))kcal · 당류 \(Int(s.total_sugar_g / Double(s.days)))g")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !s.daily.isEmpty {
                    Section("날짜별 칼로리") {
                        Chart(s.daily) { d in
                            BarMark(x: .value("날짜", String(d.date.suffix(5))), y: .value("kcal", d.kcal))
                        }
                        .frame(height: 160)
                    }
                }
                if !s.top.isEmpty {
                    Section("많이 먹은 군것질") {
                        ForEach(Array(s.top.enumerated()), id: \.element.id) { i, t in
                            HStack {
                                Text("\(i + 1)").foregroundStyle(.secondary).frame(width: 20)
                                Text(t.name)
                                Spacer()
                                Text("\(Int(t.count))개 · \(Int(t.kcal))kcal").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !s.hours.isEmpty {
                    Section("언제 먹었나") {
                        Chart(s.hours) { h in
                            BarMark(x: .value("시", h.hour), y: .value("개수", h.count))
                        }
                        .chartXScale(domain: 0...23)
                        .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) { AxisValueLabel() } }
                        .frame(height: 120)
                        if let peak = s.hours.max(by: { $0.count < $1.count }) {
                            Text("\(peak.hour)시에 가장 많이 먹었어요").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if s.count == 0 {
                    Text("아직 기록이 없어요.").foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("통계")
        .task(id: days) { stats = try? await SnackStats.load(days: days) }
    }

    private func summary(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
