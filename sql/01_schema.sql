-- =====================================================================
-- 合宿 部屋予約システム / スキーマ定義
-- 要件定義書 v2 §6 に対応。実行順: 01 -> 02 -> 03 -> 04
-- =====================================================================

-- Supabase では extensions スキーマに導入済みのため実質 no-op。
-- crypt()/gen_salt() の解決は 03 の search_path 側で担保する。
create extension if not exists pgcrypto;

-- 部屋マスタ ---------------------------------------------------------
create table rooms (
  id         smallint primary key,
  name       text     not null,
  sort_order smallint not null
);

-- 予約可能スロット（主催者が事前に投入） -----------------------------
-- session_date はその晩の開始日（JST）。22:00〜翌07:00 が1セッション。
create table slots (
  start_at     timestamptz primary key,
  session_date date not null,
  -- reservations からの複合FKの参照先として必要
  constraint uq_slot_session unique (start_at, session_date)
);

create index ix_slots_session on slots (session_date, start_at);

-- 予約本体 -----------------------------------------------------------
create table reservations (
  id           uuid primary key default gen_random_uuid(),
  room_id      smallint    not null references rooms(id),
  start_at     timestamptz not null,
  session_date date        not null,
  group_name   text        not null,
  -- 正規化キー。前後空白除去 -> NFKC -> 小文字化。
  -- 「Aチーム」「Ａチーム」「aチーム」を同一グループとみなす（FR-04）。
  group_key    text generated always as (lower(normalize(btrim(group_name), NFKC))) stored,
  created_at   timestamptz not null default now(),

  -- start_at と session_date の組が slots の定義と一致することをDBが保証する
  constraint fk_slot foreign key (start_at, session_date)
    references slots (start_at, session_date) on delete restrict,

  constraint uq_room_slot   unique (room_id, start_at),
  constraint chk_group_name check (char_length(btrim(group_name)) between 1 and 30)
);

-- 同一スロットで同一グループが複数部屋を取ることを禁止（FR-04）
create unique index uq_group_slot on reservations (start_at, group_key);

-- 枠数上限のカウントを高速化する（FR-04）
create index ix_res_group_session on reservations (group_key, session_date);

-- PINハッシュ本体から分離し、anon からは一切読めなくする ---------------
create table reservation_secrets (
  reservation_id uuid primary key references reservations(id) on delete cascade,
  pin_hash       text not null
);
