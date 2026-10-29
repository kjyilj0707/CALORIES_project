import Foundation
import Supabase

/// Supabase 연결. publishable 키는 앱에 들어가도 되는 공개 키이고, 실제 접근 범위는 RLS가 막는다.
/// secret 키는 절대 앱에 넣지 않는다 (서버·스크립트 전용).
enum Backend {
    static let url = URL(string: "https://uzhtkykhkfcqsswfityg.supabase.co")!
    static let publishableKey = "sb_publishable_W1wixIqs4wtHtaynLB_vtQ_NRm4I4Uw"

    static let client = SupabaseClient(supabaseURL: url, supabaseKey: publishableKey)
}
