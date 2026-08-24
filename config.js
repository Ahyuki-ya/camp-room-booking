// =====================================================================
// 接続設定 / 要件定義書 v2 §11
// anon key は公開前提の設計（守りは全て RLS + RPC 側）のためコミットしてよい。
//
// ※ index.html の Content-Security-Policy の connect-src にも
//    同じホストを書く必要がある。2箇所とも書き換えること。
// =====================================================================
window.CONFIG = {
  SUPABASE_URL: 'https://zdborpxhbggshicyoaoj.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_BjN-s5B2z1HUiFB2yxSr_w_Aem3tAaT',
  CAMP_NAME: 'サークル合宿 2026',
};
