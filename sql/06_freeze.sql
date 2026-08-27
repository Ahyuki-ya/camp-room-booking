-- =====================================================================
-- 過去記録の凍結と訂正台帳 / 要件定義書 v2 §15
-- 実行順: 01 -> 02 -> 03 -> 04 -> 05 -> 06
--
-- 目的: 使用した部屋の申請根拠として予約記録を使うため、開始時刻を過ぎた
--       行を「動かない事実」にする。訂正は禁止しないが、必ず台帳に残す。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 訂正台帳。追記のみ。
-- ---------------------------------------------------------------------
create table if not exists reservation_ledger (
  id             bigint generated always as identity primary key,
  occurred_at    timestamptz not null default now(),
  action         text        not null check (action in ('insert', 'update', 'delete')),
  reason         text        not null,
  reservation_id uuid        not null,
  session_date   date,
  before_row     jsonb,
  after_row      jsonb
);

create index if not exists ix_ledger_occurred on reservation_ledger (occurred_at desc);

alter table reservation_ledger enable row level security;
-- ポリシーを作らない = anon から到達不能

-- 追記のみを DB で強制する。台帳が書き換えられるなら台帳の意味がない。
create or replace function ledger_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception using errcode = 'P0001', message = 'LEDGER_IS_APPEND_ONLY';
end;
$$;

drop trigger if exists trg_ledger_append_only on reservation_ledger;
create trigger trg_ledger_append_only
before update or delete on reservation_ledger
for each row execute function ledger_append_only();

-- TRUNCATE は行トリガーを通らないため、文レベルでも塞ぐ。
-- これが無いと台帳を一括で消せてしまう。
drop trigger if exists trg_ledger_no_truncate on reservation_ledger;
create trigger trg_ledger_no_truncate
before truncate on reservation_ledger
for each statement execute function ledger_append_only();

-- ---------------------------------------------------------------------
-- 凍結トリガー
--
-- 開始時刻を過ぎた行への insert / update / delete を拒否する。
-- 訂正するときだけ、呼び出し側が app.amend_reason にトランザクション
-- ローカルの設定を立てる。set_config(..., true) なので commit / rollback
-- のどちらでも自動的に消え、次のリクエストに漏れない。
--
-- ダッシュボードからの直接操作もこのトリガーを通るため、同じように止まる。
-- ---------------------------------------------------------------------
create or replace function reservations_freeze()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_when   timestamptz;
  v_reason text;
  v_row    reservations;
begin
  v_when := case tg_op when 'INSERT' then new.start_at else old.start_at end;
  v_row  := case tg_op when 'DELETE' then old else new end;

  -- まだ開始していない枠は通常どおり自由に扱える
  if v_when > now() then
    return v_row;
  end if;

  v_reason := nullif(btrim(coalesce(current_setting('app.amend_reason', true), '')), '');
  if v_reason is null then
    raise exception using errcode = 'P0001', message = 'RECORD_FROZEN';
  end if;

  insert into reservation_ledger
    (action, reason, reservation_id, session_date, before_row, after_row)
  values (
    lower(tg_op),
    v_reason,
    case tg_op when 'INSERT' then new.id           else old.id           end,
    case tg_op when 'INSERT' then new.session_date else old.session_date end,
    case tg_op when 'INSERT' then null             else to_jsonb(old)    end,
    case tg_op when 'DELETE' then null             else to_jsonb(new)    end
  );

  return v_row;
end;
$$;

drop trigger if exists trg_reservations_freeze on reservations;
create trigger trg_reservations_freeze
before insert or update or delete on reservations
for each row execute function reservations_freeze();

-- ---------------------------------------------------------------------
-- 訂正の共通前処理。内部専用。
-- ---------------------------------------------------------------------
create or replace function admin_begin_amend(p_password text, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_reason text;
begin
  perform admin_check(p_password);
  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  if v_reason is null or char_length(v_reason) > 200 then
    raise exception using errcode = 'P0001', message = 'REASON_REQUIRED';
  end if;
  perform set_config('app.amend_reason', v_reason, true);
end;
$$;

-- 訂正の後始末。理由の設定はトランザクション全体に残るため、操作を終えたら
-- 明示的に消す。PostgREST は1リクエスト=1トランザクションなので通常は問題に
-- ならないが、複数の操作を1トランザクションに束ねられた場合に、最初の理由が
-- 2件目以降に流用されるのを防ぐ。
create or replace function admin_end_amend()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform set_config('app.amend_reason', '', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 訂正: グループ名を直す
-- ---------------------------------------------------------------------
create or replace function admin_amend_group_name(
  p_id         uuid,
  p_group_name text,
  p_reason     text,
  p_password   text
) returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_name text;
begin
  perform admin_begin_amend(p_password, p_reason);
  v_name := btrim(coalesce(p_group_name, ''));
  if char_length(v_name) < 1 or char_length(v_name) > 30 then
    raise exception using errcode = 'P0001', message = 'INVALID_GROUP_NAME';
  end if;
  update reservations set group_name = v_name where id = p_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'NO_SUCH_RESERVATION';
  end if;
  perform admin_end_amend();
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- 訂正: 使わなかった記録を外す
--
-- 退避表には移さない。台帳の before_row に行全体が残るため、そちらが
-- 復元の材料になる。退避表に入れると admin_restore_reservation から
-- 理由なしで戻せてしまい、凍結の意味が薄れる。
-- ---------------------------------------------------------------------
create or replace function admin_amend_remove(
  p_id       uuid,
  p_reason   text,
  p_password text
) returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform admin_begin_amend(p_password, p_reason);
  delete from reservations where id = p_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'NO_SUCH_RESERVATION';
  end if;
  perform admin_end_amend();
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- 訂正: 予約せずに使われた分を足す
--
-- PIN は作らない。過去の枠なので参加者がキャンセルすることはない
-- （cancel_reservation は TOO_LATE で弾く）。
-- ---------------------------------------------------------------------
create or replace function admin_amend_add(
  p_room_id    smallint,
  p_start_at   timestamptz,
  p_group_name text,
  p_reason     text,
  p_password   text
) returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_name    text;
  v_session date;
  v_id      uuid;
begin
  perform admin_begin_amend(p_password, p_reason);

  v_name := btrim(coalesce(p_group_name, ''));
  if char_length(v_name) < 1 or char_length(v_name) > 30 then
    raise exception using errcode = 'P0001', message = 'INVALID_GROUP_NAME';
  end if;

  select s.session_date into v_session from slots s where s.start_at = p_start_at;
  if not found then
    raise exception using errcode = 'P0001', message = 'NO_SUCH_SLOT';
  end if;

  begin
    insert into reservations (room_id, start_at, session_date, group_name)
    values (p_room_id, p_start_at, v_session, v_name)
    returning id into v_id;
  exception
    when unique_violation then
      raise exception using errcode = 'P0001', message = 'SLOT_TAKEN';
    when foreign_key_violation then
      raise exception using errcode = 'P0001', message = 'NO_SUCH_ROOM';
  end;

  perform admin_end_amend();
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 台帳の閲覧
-- ---------------------------------------------------------------------
create or replace function admin_list_ledger(p_password text)
returns table (
  occurred_at    timestamptz,
  action         text,
  reason         text,
  reservation_id uuid,
  session_date   date,
  before_row     jsonb,
  after_row      jsonb
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform admin_check(p_password);
  return query
    select l.occurred_at, l.action, l.reason, l.reservation_id,
           l.session_date, l.before_row, l.after_row
      from reservation_ledger l
     -- now() はトランザクション開始時刻なので、1トランザクションで複数の
     -- 訂正を行うと occurred_at が同値になる。連番で順序を確定させる。
     order by l.occurred_at desc, l.id desc
     limit 100;
end;
$$;

-- ---------------------------------------------------------------------
-- 権限付与
-- Supabase は public スキーマの新規関数に anon / authenticated へ EXECUTE を
-- 自動付与する（§14.4）。内部専用はロールを名指しで revoke すること。
-- ---------------------------------------------------------------------
revoke all on function ledger_append_only()               from public, anon, authenticated;
revoke all on function reservations_freeze()              from public, anon, authenticated;
revoke all on function admin_begin_amend(text, text)      from public, anon, authenticated;
revoke all on function admin_end_amend()                  from public, anon, authenticated;

revoke all on function admin_amend_group_name(uuid, text, text, text)          from public;
revoke all on function admin_amend_remove(uuid, text, text)                     from public;
revoke all on function admin_amend_add(smallint, timestamptz, text, text, text) from public;
revoke all on function admin_list_ledger(text)                                  from public;

grant execute on function admin_amend_group_name(uuid, text, text, text)          to anon;
grant execute on function admin_amend_remove(uuid, text, text)                     to anon;
grant execute on function admin_amend_add(smallint, timestamptz, text, text, text) to anon;
grant execute on function admin_list_ledger(text)                                  to anon;
