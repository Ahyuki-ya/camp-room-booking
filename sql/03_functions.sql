-- =====================================================================
-- RPC 定義 / 要件定義書 v2 §8
--
-- エラー返却の規約 (§8.1):
--   raise exception using errcode = 'P0001', message = '<ERROR_CODE>'
--   クライアントは message の完全一致で分岐する。
--   DB 側には機械可読コードのみを入れ、日本語文言はクライアントが持つ。
-- =====================================================================

-- ---------------------------------------------------------------------
-- create_reservation
-- ---------------------------------------------------------------------
-- 引数が増えたため、旧シグネチャを明示的に落とす。create or replace では
-- 引数リストを変更できず、放置すると多重定義になって PostgREST が
-- どちらを呼ぶか決められなくなる。新規構築時は何もしない。
drop function if exists create_reservation(smallint, timestamptz, text, text);

create or replace function create_reservation(
  p_room_id    smallint,
  p_start_at   timestamptz,
  p_group_name text,
  p_pin        text,
  -- FR-04 端末上限。既定値ありは意図的（§8.2 参照）。GitHub Pages が
  -- 古い app.js をキャッシュしている間も予約を失敗させないため。
  p_device_id  uuid default null
) returns uuid
language plpgsql
security definer
set search_path = public, extensions  -- pgcrypto が extensions にあるため（§8）
as $$
declare
  v_group_name   text;
  v_group_key    text;
  v_session_date date;
  v_id           uuid;
  v_constraint   text;
  v_sort         smallint;
  v_left_id      smallint;
begin
  -- 1. PIN 形式（クライアント検証を信用しない）
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    raise exception using errcode = 'P0001', message = 'INVALID_PIN';
  end if;

  -- 2. グループ名の形式
  v_group_name := btrim(coalesce(p_group_name, ''));
  if char_length(v_group_name) < 1 or char_length(v_group_name) > 30 then
    raise exception using errcode = 'P0001', message = 'INVALID_GROUP_NAME';
  end if;

  -- 3. スロットの存在確認と session_date の取得
  select s.session_date into v_session_date
    from slots s where s.start_at = p_start_at;
  if not found then
    raise exception using errcode = 'P0001', message = 'NO_SUCH_SLOT';
  end if;

  -- 4. 開始済みスロットの拒否（UIのグレーアウトを迂回させない）
  if p_start_at <= now() then
    raise exception using errcode = 'P0001', message = 'PAST_SLOT';
  end if;

  -- 4b. 左から順に埋めてもらう (FR-08)。左に2部屋以上ある部屋（＝3番目以降）
  --     は、同じ枠で左隣が予約されるまで開かない。画面側でも塞いでいるが、
  --     UIのグレーアウトを迂回させないため DB でも検査する。
  --
  --     並び順は sort_order を基準にし、連番でなくても機能するように
  --     「sort_order がひとつ下の部屋」を引いている。
  select r.sort_order into v_sort from rooms r where r.id = p_room_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'NO_SUCH_ROOM';
  end if;

  select r.id into v_left_id
    from rooms r where r.sort_order < v_sort
   order by r.sort_order desc limit 1;

  if (select count(*) from rooms r where r.sort_order < v_sort) >= 2
     and not exists (select 1 from reservations x
                      where x.start_at = p_start_at and x.room_id = v_left_id) then
    raise exception using errcode = 'P0001', message = 'ROOM_LOCKED';
  end if;

  -- 5. 正規化キー。生成列 group_key と同一の式でなければならない。
  v_group_key := lower(normalize(v_group_name, NFKC));

  -- 6. 同一グループ名／同一端末のリクエストのみを直列化する。
  --    これがないと「数える -> insert」の間に別トランザクションが割り込み、
  --    同時送信で上限を突破できてしまう（§5 枠数上限の整合性要件）。
  --    無関係なグループ・端末はブロックしない。ロックは commit/rollback で自動解放。
  --
  --    順序は必ず「グループ -> 端末」。逆順の経路が存在しないため、
  --    待ちの向きが一方向に揃い、デッドロックが原理的に起きない（§8.2）。
  --    classid を 1 と 2 に分けているので両者のハッシュ値は干渉しない。
  perform pg_advisory_xact_lock(1, hashtext(v_group_key));
  if p_device_id is not null then
    perform pg_advisory_xact_lock(2, hashtext(p_device_id::text));
  end if;

  -- 7. 枠数上限（グループ名基準。1セッションあたり2枠）
  if (select count(*) from reservations r
        where r.group_key = v_group_key
          and r.session_date = v_session_date) >= 2 then
    raise exception using errcode = 'P0001', message = 'LIMIT_EXCEEDED';
  end if;

  -- 7b. 枠数上限（端末基準。1セッションあたり2枠）。グループ名上限とは
  --     独立に適用する。別のグループ名を名乗っても同じ端末なら通さない。
  if p_device_id is not null then
    if (select count(*) from reservation_devices d
          where d.device_id = p_device_id
            and d.session_date = v_session_date) >= 2 then
      raise exception using errcode = 'P0001', message = 'DEVICE_LIMIT_EXCEEDED';
    end if;
  end if;

  -- 8. 予約本体の作成
  begin
    insert into reservations (room_id, start_at, session_date, group_name)
    values (p_room_id, p_start_at, v_session_date, v_group_name)
    returning id into v_id;
  exception
    when unique_violation then
      -- uq_group_slot と uq_room_slot はどちらも unique_violation になる。
      -- 区別しないと「自分が同じ時間帯に別部屋を予約済み」なのに
      -- 「他のグループが予約しました」と表示され参加者が混乱する。
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint = 'uq_group_slot' then
        raise exception using errcode = 'P0001', message = 'DUPLICATE_IN_SLOT';
      else
        raise exception using errcode = 'P0001', message = 'SLOT_TAKEN';
      end if;
    when foreign_key_violation then
      raise exception using errcode = 'P0001', message = 'NO_SUCH_ROOM';
  end;

  -- 9. PIN ハッシュ
  insert into reservation_secrets (reservation_id, pin_hash)
  values (v_id, crypt(p_pin, gen_salt('bf')));

  -- 10. 端末の記録（FR-04）
  if p_device_id is not null then
    insert into reservation_devices (reservation_id, device_id, session_date)
    values (v_id, p_device_id, v_session_date);
  end if;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- cancel_reservation
-- ---------------------------------------------------------------------
create or replace function cancel_reservation(
  p_id  uuid,
  p_pin text
) returns boolean
language plpgsql
security definer
set search_path = public, extensions  -- pgcrypto が extensions にあるため（§8）
as $$
declare
  v_start_at timestamptz;
  v_hash     text;
begin
  -- 1. 予約の存在確認。
  --    行がない場合も PIN 不一致と同一の応答にする（存在有無を漏らさない）。
  select r.start_at into v_start_at from reservations r where r.id = p_id;
  if not found then
    perform pg_sleep(0.5);
    raise exception using errcode = 'P0001', message = 'INVALID_PIN';
  end if;

  -- 2. キャンセル期限（開始30分前まで）。UIのボタン無効化に依存しない。
  if v_start_at - interval '30 minutes' <= now() then
    raise exception using errcode = 'P0001', message = 'TOO_LATE';
  end if;

  -- 3. PIN 照合。
  --    p_pin が null だと crypt() が null を返すため is distinct from で受ける。
  --    単純な <> だと null 比較が null になり、削除に進んでしまう。
  select s.pin_hash into v_hash
    from reservation_secrets s where s.reservation_id = p_id;
  if v_hash is null
     or p_pin is null
     or crypt(p_pin, v_hash) is distinct from v_hash then
    perform pg_sleep(0.5);
    raise exception using errcode = 'P0001', message = 'INVALID_PIN';
  end if;

  -- 4. 削除（on delete cascade で reservation_secrets も消える）
  delete from reservations where id = p_id;
  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- 権限付与 (§8.4)
-- security definer 関数はデフォルトで PUBLIC に EXECUTE が付くため、
-- 明示的に剥がしてから anon にのみ付与する。
-- ---------------------------------------------------------------------
revoke all on function create_reservation(smallint, timestamptz, text, text, uuid) from public;
revoke all on function cancel_reservation(uuid, text) from public;
grant execute on function create_reservation(smallint, timestamptz, text, text, uuid) to anon;
grant execute on function cancel_reservation(uuid, text) to anon;
