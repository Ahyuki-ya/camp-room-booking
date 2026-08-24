#!/bin/bash
# 受け入れ基準（要件定義書 v2 §12）のうち DB で検証できる項目を自動実行する。
# 使い方: PGHOST/PGPORT/PGUSER/PGDATABASE を指定して実行する。
#   PGHOST=127.0.0.1 PGPORT=55432 PGUSER=postgres PGDATABASE=camp ./sql/test_acceptance.sh
set -u
PSQL="psql -q -v ON_ERROR_STOP=0 -tA"
pass=0; fail=0

ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
ng()   { echo "  ❌ $1 -- $2"; fail=$((fail+1)); }
# RPC を呼び、成功なら戻り値、失敗ならエラーコードを標準出力に返す
call() { $PSQL -c "$1" 2>&1 | grep -v '^$' | sed -n '1p' | sed 's/^ERROR:  //'; }

echo "== 準備: Supabase 相当の grant を再現し、時刻依存テスト用スロットを追加 =="
$PSQL >/dev/null 2>&1 <<'SQL'
grant usage on schema public to anon;
grant select, insert, update, delete on all tables in schema public to anon;
-- 過去スロット / 30分以内スロット / 十分先のスロット
insert into slots (start_at, session_date) values
  (now() - interval '2 hours', current_date),
  (now() + interval '10 minutes', current_date),
  (now() + interval '5 hours', current_date)
on conflict do nothing;
SQL
PAST=$($PSQL -c "select start_at from slots where start_at < now() order by start_at desc limit 1;")
SOON=$($PSQL -c "select start_at from slots where start_at > now() and start_at < now() + interval '30 minutes' limit 1;")
FUT=$($PSQL -c "select start_at from slots where start_at > now() + interval '1 hour' and session_date = current_date limit 1;")

echo
echo "== 基準10: 開始済みスロットへの予約は PAST_SLOT で拒否される =="
r=$(call "select create_reservation(1::smallint,'$PAST'::timestamptz,'過去テスト','1234');")
[ "$r" = "PAST_SLOT" ] && ok "PAST_SLOT" || ng "PAST_SLOT" "$r"

echo
echo "== 基準2/13/14: 枠数上限（1セッション2枠）と正規化とセッション境界 =="
$PSQL -c "delete from reservations;" >/dev/null
a=$(call "select create_reservation(1::smallint,'2026-09-02 22:00+09'::timestamptz,'Aチーム','1111');")
b=$(call "select create_reservation(2::smallint,'2026-09-03 01:00+09'::timestamptz,'Ａチーム','1111');")
c=$(call "select create_reservation(3::smallint,'2026-09-03 03:00+09'::timestamptz,'aチーム','1111');")
[ ${#a} -eq 36 ] && ok "1枠目(Aチーム 9/2 22:00) 作成成功" || ng "1枠目" "$a"
[ ${#b} -eq 36 ] && ok "2枠目(Ａチーム 9/3 01:00) 作成成功 = 全角Aが同一グループ扱い" || ng "2枠目" "$b"
[ "$c" = "LIMIT_EXCEEDED" ] && ok "基準2/13/14: 3枠目が LIMIT_EXCEEDED（9/2 22:00 と 9/3 03:00 が同一セッション）" || ng "3枠目" "$c"
n=$($PSQL -c "select count(distinct group_key) from reservations;")
[ "$n" = "1" ] && ok "基準13: 3つの表記が単一の group_key に統合されている" || ng "group_key" "distinct=$n"

echo
echo "== 基準14の裏: 別セッション(9/3の晩)なら取れる =="
d=$(call "select create_reservation(1::smallint,'2026-09-03 22:00+09'::timestamptz,'Aチーム','1111');")
[ ${#d} -eq 36 ] && ok "9/3の晩は別枠として作成できる" || ng "別セッション" "$d"

echo
echo "== 基準3: 同一グループ同一スロットの別部屋は DUPLICATE_IN_SLOT =="
$PSQL -c "delete from reservations;" >/dev/null
call "select create_reservation(1::smallint,'2026-09-02 22:00+09'::timestamptz,'Bチーム','2222');" >/dev/null
r=$(call "select create_reservation(2::smallint,'2026-09-02 22:00+09'::timestamptz,'Bチーム','2222');")
[ "$r" = "DUPLICATE_IN_SLOT" ] && ok "DUPLICATE_IN_SLOT（SLOT_TAKEN と正しく区別されている）" || ng "DUPLICATE_IN_SLOT" "$r"

echo
echo "== 基準1: 同一セルへの同時予約は片方だけ成功 =="
$PSQL -c "delete from reservations;" >/dev/null
for i in 1 2 3 4 5; do
  ( $PSQL -c "select create_reservation(1::smallint,'2026-09-02 23:00+09'::timestamptz,'同時${i}','333${i}');" >/dev/null 2>&1 ) &
done
wait
n=$($PSQL -c "select count(*) from reservations where room_id=1 and start_at='2026-09-02 23:00+09';")
[ "$n" = "1" ] && ok "5並列で成功したのは1件のみ" || ng "同時予約" "成功=$n件"

echo
echo "== 基準12: 同一グループの同時送信でも1セッション2枠を超えない（advisory lock）=="
# 同一セッションの別々のスロットを狙わせる。uq_group_slot も uq_room_slot も
# 抵触しない配置なので、枠数上限のチェックだけが最後の砦になる。
# 全接続を同一時刻に発火させないと接続確立のオーバーヘッドで勝手に直列化し、
# ロックが無くてもテストが通ってしまう（＝無意味なテストになる）。
$PSQL -c "delete from reservations;" >/dev/null
T=$($PSQL -c "select (clock_timestamp() + interval '3 seconds')::text;")
SLOTS=$($PSQL -c "select string_agg(start_at::text,'|') from (select start_at from slots where session_date='2026-09-02' order by start_at limit 8) t;")
OLDIFS=$IFS; IFS='|'; read -ra ARR <<< "$SLOTS"; IFS=$OLDIFS
for s in "${ARR[@]}"; do
  ( $PSQL -c "select pg_sleep(greatest(0, extract(epoch from ('$T'::timestamptz - clock_timestamp()))));
              select create_reservation(1::smallint,'$s'::timestamptz,'限界チーム','4444');" >/dev/null 2>&1 ) &
done
wait
n=$($PSQL -c "select count(*) from reservations where group_key='限界チーム' and session_date='2026-09-02';")
[ "$n" = "2" ] && ok "8並列同時発火でも保有枠はちょうど2枠（ロックを外すと8枠取れることを対照実験で確認済み）" || ng "advisory lock" "${n}枠"

echo
echo "== 基準4/11: PIN 照合とキャンセル期限 =="
$PSQL -c "delete from reservations;" >/dev/null
id=$(call "select create_reservation(1::smallint,'$FUT'::timestamptz,'キャンセル試験','5555');")
r=$(call "select cancel_reservation('$id'::uuid,'9999');")
[ "$r" = "INVALID_PIN" ] && ok "基準4: 誤ったPINでは削除できない" || ng "誤PIN" "$r"
r=$(call "select cancel_reservation('$id'::uuid,null);")
[ "$r" = "INVALID_PIN" ] && ok "PIN が null でも削除されない（null比較の穴を塞いである）" || ng "null PIN" "$r"
r=$(call "select cancel_reservation('$id'::uuid,'5555');")
[ "$r" = "t" ] && ok "基準4: 正しいPINで削除できる" || ng "正PIN" "$r"
r=$(call "select cancel_reservation('$(uuidgen | tr 'A-Z' 'a-z')'::uuid,'1234');")
[ "$r" = "INVALID_PIN" ] && ok "存在しないIDも INVALID_PIN（存在有無を漏らさない）" || ng "存在しないID" "$r"

id=$(call "select create_reservation(2::smallint,'$SOON'::timestamptz,'期限試験','6666');")
r=$(call "select cancel_reservation('$id'::uuid,'6666');")
[ "$r" = "TOO_LATE" ] && ok "基準11: 開始30分を切ると正しいPINでもキャンセル不可" || ng "TOO_LATE" "$r"

echo
echo "== 基準5/6: anon の直接書き込みがデータを変更できない =="
$PSQL -c "delete from reservations;" >/dev/null
call "select create_reservation(3::smallint,'$FUT'::timestamptz,'RLS試験','7777');" >/dev/null
before=$($PSQL -c "select count(*) from reservations;")
# DELETE / UPDATE は RLS にポリシーが無い場合エラーにならず「0行」で弾かれる。
# PostgREST 経由では 204 が返るため、検査すべきはデータが変わらないこと。
for stmt in "delete from reservations" "update reservations set group_name='侵入済み'"; do
  $PSQL -c "set role anon; $stmt;" >/dev/null 2>&1
done
after=$($PSQL -c "select count(*) from reservations;")
tampered=$($PSQL -c "select count(*) from reservations where group_name='侵入済み';")
[ "$before" = "$after" ] && ok "基準5: anon の delete で件数が変わらない（$before 件のまま）" || ng "anon delete" "$before -> $after"
[ "$tampered" = "0" ] && ok "基準5: anon の update で書き換えられた行が0件" || ng "anon update" "$tampered 件書き換えられた"
r=$($PSQL -c "set role anon; insert into reservations (room_id,start_at,session_date,group_name) values (1,'2026-09-02 22:00+09','2026-09-02','侵入');" 2>&1 | head -1)
case "$r" in
  *"row-level security"*|*"permission denied"*) ok "基準5: anon の insert は RLS エラーで拒否" ;;
  *) ng "anon insert" "$r" ;;
esac
r=$($PSQL -c "set role anon; select count(*) from reservation_secrets;" 2>&1 | head -1)
[ "$r" = "0" ] && ok "基準6: anon から reservation_secrets は0件（RLSで不可視）" || ng "基準6" "$r"
r=$($PSQL -c "set role anon; select count(*) from reservations;" 2>&1 | head -1)
[ "$r" -ge 1 ] 2>/dev/null && ok "anon は reservations を閲覧できる（$r 件）" || ng "anon select" "$r"

echo
echo "== 基準7(DB側): PIN が平文で保存されていない =="
r=$($PSQL -c "select pin_hash from reservation_secrets limit 1;")
if [ "${r#\$2}" != "$r" ]; then ok "bcrypt ハッシュで保存されている (${r:0:7}...)"
else ng "PIN保存" "平文もしくは想定外の形式: $r"; fi
r=$($PSQL -c "select count(*) from reservation_secrets where pin_hash like '%7777%';")
[ "$r" = "0" ] && ok "PIN の平文が pin_hash に含まれていない" || ng "PIN平文" "$r 件"

echo
echo "================================================"
echo "  成功 $pass 件 / 失敗 $fail 件"
echo "================================================"
[ $fail -eq 0 ]
