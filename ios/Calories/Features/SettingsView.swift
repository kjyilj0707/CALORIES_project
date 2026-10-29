import Supabase
import SwiftUI

/// 설정: 연결된 카드(해제), 내 데이터 삭제
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var cards: [Card] = []
    @State private var revoking: Card?
    @State private var confirmDelete = false

    struct Card: Decodable, Identifiable {
        let id: UUID
        let card_company: String
        let status: String
        let last_polled_at: Date?
    }

    var body: some View {
        List {
            Section {
                ForEach(cards) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(c.card_company)카드")
                            Text(statusText(c)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if c.status == "active" {
                            Button("해제", role: .destructive) { revoking = c }
                        }
                    }
                }
            } header: {
                Text("연결된 카드")
            } footer: {
                Text("조회 전용이에요. 해제하면 그 카드의 결제 조회를 바로 멈춰요.")
            }

            Section {
                Label("좌표는 저장하지 않고 매장 체인과 시각만 기록해요", systemImage: "location")
                Label("카드사 비밀번호는 어디에도 저장하지 않아요", systemImage: "lock")
            } header: {
                Text("개인정보")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Section {
                Button("내 데이터 모두 삭제", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("결제·기록·내 군것질 목록·카드 연결이 모두 지워지고 되돌릴 수 없어요.")
            }
        }
        .navigationTitle("설정")
        .task { await load() }
        .confirmationDialog("\(revoking?.card_company ?? "")카드 연결을 해제할까요?",
                            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            titleVisibility: .visible) {
            Button("해제", role: .destructive) {
                guard let c = revoking else { return }
                Task {
                    try? await Backend.client.rpc("revoke_card", params: ["card": c.id]).execute()
                    await load()
                    await model.refresh()
                }
            }
        }
        .confirmationDialog("내 데이터를 모두 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("모두 삭제", role: .destructive) { Task { await model.deleteAllData() } }
        } message: {
            Text("되돌릴 수 없어요.")
        }
    }

    private func load() async {
        guard let userID = model.userID else { return }
        cards = (try? await Backend.client.from("card_connections")
            .select("id, card_company, status, last_polled_at")
            .eq("user_id", value: userID).neq("status", value: "revoked")
            .order("created_at").execute().value) ?? []
    }

    private func statusText(_ c: Card) -> String {
        switch c.status {
        case "active":
            if let t = c.last_polled_at { return "마지막 확인 \(t.formatted(.relative(presentation: .named)))" }
            return "연결됨"
        case "expired": return "다시 연결이 필요해요"
        default: return "확인이 필요해요"
        }
    }
}
