import { createClient, type SupabaseClient, type User } from "jsr:@supabase/supabase-js@2";

/** 서버 전용 클라이언트 (RLS 우회). 함수 실행 환경이 SUPABASE_SERVICE_ROLE_KEY를 자동으로 넣어 준다. */
export const admin = (): SupabaseClient =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

/** 요청한 앱 사용자를 확인한다. 로그인 안 했으면 null. */
export async function requestUser(req: Request): Promise<User | null> {
  const auth = req.headers.get("Authorization");
  if (!auth) return null;
  const client = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false },
  });
  const { data } = await client.auth.getUser();
  return data.user;
}

export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
