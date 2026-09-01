-- =====================================================================
-- 初期データ / 要件定義書 v2 §11.2
--
-- 日程を変える場合   : values 句の日付だけを書き換える
-- 時間帯を変える場合 : generate_series の範囲だけを書き換える
-- 部屋名を変える場合 : rooms の insert 文だけを書き換える
-- =====================================================================

insert into rooms (id, name, sort_order) values
  (1, 'B2大', 1),
  (2, 'D1中', 2),
  (3, 'D2中', 3),
  (4, 'D3中', 4),
  (5, 'E1中', 5),
  (6, 'E2中', 6),
  (7, 'E3中', 7);

-- 22時〜31時(=翌7時)開始の10スロット × 2セッション = 20行
--   session_date はその晩の開始日。9/2 22:00 も 9/3 03:00 も 2026-09-02。
--   (timestamp) at time zone 'Asia/Tokyo' で JST の壁時計時刻を
--   timestamptz (UTC) に正しく変換する。
insert into slots (start_at, session_date)
select (d + make_interval(hours => h)) at time zone 'Asia/Tokyo', d
from (values ('2026-09-02'::date), ('2026-09-03'::date)) as s(d),
     generate_series(22, 31) as h;
