-- =====================================================================
-- RLS ポリシー / 要件定義書 v2 §7.1
--
-- 方針: anon には SELECT のみ許可する。書き込みは §8 の RPC 経由のみ。
-- reservation_secrets にはポリシーを一切作らない = anon から到達不能。
--
-- 注意: force row level security は設定しないこと。設定すると
--       security definer 関数（所有者権限）も書き込めなくなる。
-- =====================================================================

alter table rooms                enable row level security;
alter table slots                enable row level security;
alter table reservations         enable row level security;
alter table reservation_secrets  enable row level security;
alter table reservation_devices  enable row level security;

-- 読み取りのみ許可
create policy p_rooms_select on rooms        for select to anon using (true);
create policy p_slots_select on slots        for select to anon using (true);
create policy p_res_select   on reservations for select to anon using (true);

-- reservations への INSERT / UPDATE / DELETE ポリシーは作らない
-- reservation_secrets と reservation_devices へのポリシーは一切作らない
