-- =====================================================================
-- 一般公開前の初期化 / 要件定義書 v2 §16
-- 実行順: 01 -> ... -> 06 -> 07
--
-- 準備期間中のテストデータを、URL を一般公開する時刻に自動で消す。
-- pg_cron でDB内から実行するため、誰かの端末が起動している必要はない。
--
-- 削除と同じトランザクションで、主催者が押さえておく固定枠
-- （PA講習会 / B2 / 9/3 22:00〜24:00）を投入する（§16.6）。
-- 別々に実行すると、その隙間に参加者が同じ枠を取れてしまう。
-- =====================================================================

create extension if not exists pg_cron;

-- ---------------------------------------------------------------------
-- 実際の初期化処理。内部専用。
-- 時刻の判定は呼び出し側が行う（この関数を分けているのは、時刻を待たずに
-- 巻き戻し前提で動作確認できるようにするため）。
-- ---------------------------------------------------------------------
create or replace function do_launch_reset()
returns text
language plpgsql
security definer
-- crypt() / gen_salt() が extensions スキーマにあるため（§8 と同じ理由）。
-- 固定枠の PIN を作るのに必要。
set search_path = public, extensions
as $$
declare
  -- 主催者が押さえておく固定枠（§16.6）。増減はこの3つを書き換える。
  v_fixed_room  constant text        := 'B2大';
  v_fixed_name  constant text        := 'PA講習会';
  v_fixed_slots constant timestamptz[] := array[
    timestamptz '2026-09-03 22:00+09',
    timestamptz '2026-09-03 23:00+09'
  ];
  v_res int; v_del int; v_led int; v_fix int := 0;
  v_room_id smallint;
  v_pin     text;
begin
  -- 凍結トリガー(§15)を通すための理由。開始時刻を過ぎた予約が残っていても
  -- 消せるようにする。この時点では消す対象がテストデータのみである前提。
  perform set_config('app.amend_reason', '一般公開前の初期化', true);

  delete from reservations;            -- secrets / devices は cascade で消える
  get diagnostics v_res = row_count;

  delete from deleted_reservations;
  get diagnostics v_del = row_count;

  -- 台帳は追記専用トリガーで守られている(§15.3)。初期化のときだけ外す。
  -- 所有者権限でしか外せないため、anon からこの経路には到達できない。
  alter table reservation_ledger disable trigger trg_ledger_append_only;
  alter table reservation_ledger disable trigger trg_ledger_no_truncate;
  delete from reservation_ledger;
  get diagnostics v_led = row_count;
  alter table reservation_ledger enable trigger trg_ledger_append_only;
  alter table reservation_ledger enable trigger trg_ledger_no_truncate;

  -- 固定枠の投入（§16.6）。削除と同一トランザクションなので、
  -- 「消えた瞬間から埋まっている」状態になり、割り込まれる隙間がない。
  --
  -- PIN はその場で作った乱数で、誰にも渡さない。参加者に消されては困る枠
  -- だからである。主催者が取り消すときは管理モード（§14）から削除する。
  select r.id into v_room_id from rooms r where r.name = v_fixed_room;
  if v_room_id is null then
    -- 部屋名を変えたときに気づけるようにする。ここで例外にすると初期化
    -- そのものが巻き戻り、毎分の再試行を繰り返して永久に完了しない。
    raise warning '固定枠を投入できない: 部屋「%」が rooms に無い', v_fixed_room;
  else
    v_pin := lpad((floor(random() * 10000))::int::text, 4, '0');
    with ins as (
      insert into reservations (room_id, start_at, session_date, group_name)
      select v_room_id, s.start_at, s.session_date, v_fixed_name
        from slots s
       where s.start_at = any (v_fixed_slots)
      on conflict do nothing
      returning id
    )
    insert into reservation_secrets (reservation_id, pin_hash)
    select i.id, crypt(v_pin, gen_salt('bf')) from ins i;
    get diagnostics v_fix = row_count;

    if v_fix <> array_length(v_fixed_slots, 1) then
      -- スロットの日付を変えたのに固定枠の日時を直し忘れた場合にここへ来る。
      raise warning '固定枠が % 件しか入らなかった（想定 % 件）',
                    v_fix, array_length(v_fixed_slots, 1);
    end if;
  end if;

  return format('予約 %s件 / 退避表 %s件 / 台帳 %s件 を削除、固定枠 %s件 を投入',
                v_res, v_del, v_led, v_fix);
end;
$$;

-- ---------------------------------------------------------------------
-- cron から毎分呼ばれる入口。目標時刻に達するまで何もしない。
--
-- cron 式ではなく関数側で時刻を判定しているのは、cron.timezone の解釈を
-- 取り違えた場合に早発して本番データを消すのを防ぐため。毎分走らせて
-- おけば、タイムゾーンの解釈がどうであれ目標時刻の1分以内に実行される。
-- ---------------------------------------------------------------------
create or replace function reset_before_launch()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  -- URL を一般公開する時刻。ここを変えれば初期化の時刻が変わる。
  v_target constant timestamptz := timestamptz '2026-09-02 14:00+09';
  v_msg text;
begin
  if now() < v_target then
    return;
  end if;

  v_msg := do_launch_reset();
  raise notice '一般公開前の初期化を実行: %', v_msg;

  -- 二度と走らないように自分の予約を解除する
  begin
    perform cron.unschedule('reset-before-launch');
  exception when others then
    raise notice '解除済み、または解除に失敗: %', sqlerrm;
  end;
end;
$$;

-- ---------------------------------------------------------------------
-- 権限。anon / authenticated からは呼べないようにする。
-- Supabase は public スキーマの新規関数に EXECUTE を自動付与する(§14.4)。
-- ---------------------------------------------------------------------
revoke all on function do_launch_reset()      from public, anon, authenticated;
revoke all on function reset_before_launch()  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 毎分の実行を登録する。すでに登録済みなら作り直す。
-- ---------------------------------------------------------------------
do $$
begin
  begin
    perform cron.unschedule('reset-before-launch');
  exception when others then
    null;  -- 未登録なら何もしない
  end;
  perform cron.schedule('reset-before-launch', '* * * * *',
                        'select public.reset_before_launch()');
end $$;
