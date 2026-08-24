-- =====================================================================
-- 主催者向けの管理機能 / 要件定義書 v2 §14
-- 実行順: 01 -> 02 -> 03 -> 04 -> 05
--
-- 前提: anon key は公開されているため、ここで定義する RPC は誰でも
--       呼び出せる。守りは管理パスワードの強度のみである（§14）。
-- =====================================================================

-- 管理パスワード。1行だけ持つ。anon からは到達不能。
create table if not exists admin_settings (
  id            smallint primary key default 1 check (id = 1),
  password_hash text        not null,
  updated_at    timestamptz not null default now()
);

-- 管理者が削除した予約の退避先（論理削除）。
-- reservations への外部キーは張らない。本体の行はもう存在しないため。
-- pin_hash と device_id も保存する。復元したときに参加者が自分で
-- キャンセルでき、端末上限の計上も元通りになるようにするため。
create table if not exists deleted_reservations (
  id           uuid primary key,
  room_id      smallint    not null,
  start_at     timestamptz not null,
  session_date date        not null,
  group_name   text        not null,
  pin_hash     text        not null,
  device_id    uuid,
  created_at   timestamptz not null,
  deleted_at   timestamptz not null default now()
);

create index if not exists ix_delres_deleted_at on deleted_reservations (deleted_at desc);

alter table admin_settings       enable row level security;
alter table deleted_reservations enable row level security;
-- どちらもポリシーを作らない = anon から到達不能

-- ---------------------------------------------------------------------
-- 入力の正規化。見やすさのために入れるハイフンや大文字小文字を吸収する。
-- 管理パスワードをスマホで打つ前提なので、この寛容さは実用上の要件。
-- ---------------------------------------------------------------------
create or replace function admin_norm(p_text text)
returns text
language sql
immutable
as $$
  select lower(regexp_replace(coalesce(p_text, ''), '[^0-9A-Za-z]', '', 'g'))
$$;

-- ---------------------------------------------------------------------
-- パスワード照合。内部専用。anon には EXECUTE を与えない。
-- 呼び出し元が security definer なので、所有者権限のまま実行される。
-- ---------------------------------------------------------------------
create or replace function admin_check(p_password text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_hash text;
begin
  select password_hash into v_hash from admin_settings where id = 1;
  -- crypt() は引数が null だと null を返すため is distinct from で受ける。
  -- 単純な <> だと比較結果が null になり、認証を素通りしてしまう。
  if v_hash is null
     or p_password is null
     or crypt(admin_norm(p_password), v_hash) is distinct from v_hash then
    perform pg_sleep(0.5);
    raise exception using errcode = 'P0001', message = 'INVALID_ADMIN_PASSWORD';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- admin_verify: 管理モードに入るときのパスワード確認だけを行う
-- ---------------------------------------------------------------------
create or replace function admin_verify(p_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform admin_check(p_password);
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- admin_delete_reservation: 予約を退避表へ移してから削除する
-- ---------------------------------------------------------------------
create or replace function admin_delete_reservation(p_id uuid, p_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform admin_check(p_password);

  if not exists (select 1 from reservations where id = p_id) then
    raise exception using errcode = 'P0001', message = 'NO_SUCH_RESERVATION';
  end if;

  -- 同じ id が「削除 -> 復元 -> 再削除」された場合に備えて上書きする
  insert into deleted_reservations
    (id, room_id, start_at, session_date, group_name, pin_hash, device_id, created_at)
  select r.id, r.room_id, r.start_at, r.session_date, r.group_name,
         s.pin_hash, d.device_id, r.created_at
    from reservations r
    join reservation_secrets s on s.reservation_id = r.id
    left join reservation_devices d on d.reservation_id = r.id
   where r.id = p_id
  on conflict (id) do update set
    room_id      = excluded.room_id,
    start_at     = excluded.start_at,
    session_date = excluded.session_date,
    group_name   = excluded.group_name,
    pin_hash     = excluded.pin_hash,
    device_id    = excluded.device_id,
    created_at   = excluded.created_at,
    deleted_at   = now();

  -- reservation_secrets と reservation_devices は cascade で消える
  delete from reservations where id = p_id;
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- admin_restore_reservation: 退避表から予約を戻す
--
-- 復元は枠数上限（グループ名・端末とも）を検査しない。もともと成立して
-- いた状態に戻す操作であり、上限で弾くと誤削除から復旧できなくなるため。
-- ---------------------------------------------------------------------
create or replace function admin_restore_reservation(p_id uuid, p_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_row deleted_reservations%rowtype;
begin
  perform admin_check(p_password);

  select * into v_row from deleted_reservations where id = p_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'NO_SUCH_DELETED';
  end if;

  begin
    -- group_key は生成列なので指定しない
    insert into reservations (id, room_id, start_at, session_date, group_name, created_at)
    values (v_row.id, v_row.room_id, v_row.start_at, v_row.session_date,
            v_row.group_name, v_row.created_at);
  exception
    when unique_violation then
      -- 削除している間に別のグループがその枠を取った
      raise exception using errcode = 'P0001', message = 'SLOT_TAKEN';
    when foreign_key_violation then
      -- スロット定義が変わり、その日時がもう存在しない
      raise exception using errcode = 'P0001', message = 'NO_SUCH_SLOT';
  end;

  insert into reservation_secrets (reservation_id, pin_hash)
  values (v_row.id, v_row.pin_hash);

  if v_row.device_id is not null then
    insert into reservation_devices (reservation_id, device_id, session_date)
    values (v_row.id, v_row.device_id, v_row.session_date);
  end if;

  delete from deleted_reservations where id = p_id;
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- admin_list_deleted: 復元候補の一覧
-- ---------------------------------------------------------------------
create or replace function admin_list_deleted(p_password text)
returns table (
  id           uuid,
  room_id      smallint,
  start_at     timestamptz,
  session_date date,
  group_name   text,
  deleted_at   timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform admin_check(p_password);
  return query
    select d.id, d.room_id, d.start_at, d.session_date, d.group_name, d.deleted_at
      from deleted_reservations d
     order by d.deleted_at desc
     limit 50;
end;
$$;

-- ---------------------------------------------------------------------
-- 権限付与
--
-- 重要: Supabase は public スキーマに作られた関数に対して、デフォルト権限で
-- anon / authenticated / service_role に EXECUTE を自動付与する。したがって
-- 「revoke ... from public」だけでは剥がれず、内部専用のつもりの関数が
-- PostgREST 経由で公開されてしまう。ロールを名指しで revoke すること。
-- （実プロジェクトで proacl を確認して判明。2026-08-24）
--
-- admin_norm と admin_check は内部専用。呼び出し元が security definer なので
-- 所有者権限で実行され、anon に EXECUTE がなくても内部からは呼べる。
-- ---------------------------------------------------------------------
revoke all on function admin_norm(text)  from public, anon, authenticated;
revoke all on function admin_check(text) from public, anon, authenticated;

revoke all on function admin_verify(text)                      from public;
revoke all on function admin_delete_reservation(uuid, text)    from public;
revoke all on function admin_restore_reservation(uuid, text)   from public;
revoke all on function admin_list_deleted(text)                from public;

grant execute on function admin_verify(text)                    to anon;
grant execute on function admin_delete_reservation(uuid, text)  to anon;
grant execute on function admin_restore_reservation(uuid, text) to anon;
grant execute on function admin_list_deleted(text)              to anon;
