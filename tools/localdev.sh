#!/bin/bash
# ローカル検証環境をワンコマンドで立ち上げる（Supabase なしで画面を確認するため）。
# 本番デプロイには一切関係しない開発専用ツール。PostgreSQL のクライアント
# ツール群（initdb / pg_ctl / psql）が PATH にあることが前提。
#
#   ./tools/localdev.sh          起動して http://127.0.0.1:8777 を開く
#   ./tools/localdev.sh stop     停止して後片付け
set -euo pipefail
cd "$(dirname "$0")/.."
PGDATA="${TMPDIR:-/tmp}/camp-pgdata"
PGPORT=55432
PSQL=(psql -h 127.0.0.1 -p $PGPORT -U postgres)

stop() {
  pkill -f 'tools/devserver.py' 2>/dev/null || true
  [ -d "$PGDATA" ] && pg_ctl -D "$PGDATA" -m fast stop 2>/dev/null || true
  rm -rf "$PGDATA"
  echo "停止しました。"
}
[ "${1:-}" = "stop" ] && { stop; exit 0; }

rm -rf "$PGDATA"
initdb -D "$PGDATA" -U postgres --auth=trust -E UTF8 --locale=C >/dev/null
pg_ctl -D "$PGDATA" -o "-p $PGPORT -h 127.0.0.1 -c unix_socket_directories=/tmp" \
       -l "$PGDATA/pg.log" -w start >/dev/null
"${PSQL[@]}" -q -c "do \$\$ begin if not exists (select from pg_roles where rolname='anon')
                    then create role anon nologin; end if; end \$\$;"
"${PSQL[@]}" -q -c "create database camp;"
for f in sql/01_schema.sql sql/02_rls.sql sql/03_functions.sql sql/04_seed.sql; do
  "${PSQL[@]}" -d camp -q -v ON_ERROR_STOP=1 -f "$f"
done
echo "DB 準備完了（スロット $("${PSQL[@]}" -d camp -tA -c 'select count(*) from slots;') 件）"
echo "受け入れテスト: PGHOST=127.0.0.1 PGPORT=$PGPORT PGUSER=postgres PGDATABASE=camp ./sql/test_acceptance.sh"
echo "ブラウザ:       http://127.0.0.1:8777"
echo "停止:           ./tools/localdev.sh stop"
python3 tools/devserver.py
