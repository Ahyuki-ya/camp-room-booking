# 合宿 部屋予約システム 要件定義書

**版数**: v2 ／ **最終更新**: 2026-09-01 ／ **状態**: 全項目確定済み（未決事項なし）

> **この文書の使い方（コーディングエージェント向け）**
> 本書は実装の唯一の仕様源です。v2 時点で未決事項はすべて解消されています。
> 仕様に曖昧さや矛盾を見つけた場合は、勝手に解釈せず質問すること。
> 本書の記述と異なる実装を行う必要が生じた場合は、コードを変更する前に本書を改訂すること。

---

## 1. 目的とスコープ

サークル合宿において、7つの部屋を1時間単位で交代利用するための予約システムを構築する。
参加者は代表名（グループ名）で任意の空き枠を予約でき、予約状況は全員がリアルタイムに近い形で閲覧できる。

**運用期間**: 2026-09-02(水) と 2026-09-03(木) の2晩。各晩 22:00〜翌08:00（JST）。

### スコープ内
- 部屋 × 時間枠のグリッド表示（各晩 22:00〜翌08:00）
- グループ名＋PINによる予約・キャンセル
- 二重予約の防止
- 主催者による予約状況の閲覧・手動修正（Supabase ダッシュボード経由）

### スコープ外
- ユーザーアカウント登録・ログイン
- 決済、メール/LINE通知
- 部屋ごとの設備管理・備品予約
- 予約履歴の統計分析
- **予約のメモ機能**（v2 で廃止）
- **予約の変更（枠の移動）**。キャンセルしてから取り直す運用とする
- **主催者用の一括操作UI**（全消し・CSV出力）。Supabase ダッシュボードで代替する。ただし**予約1件ごとの削除と復元は §14 の管理モードでスコープ内**とした（2026-08-24）

---

## 2. 用語定義

| 用語 | 定義 |
|---|---|
| 部屋 (room) | 予約対象となる物理的な部屋。全5室。 |
| スロット (slot) | 予約の最小時間単位。1時間、毎正時開始。 |
| セル (cell) | 部屋 × スロットの組み合わせ。予約の実体はセル1つに対応する。 |
| **セッション (session)** | **1晩の利用単位。22:00 から翌08:00 までの連続した10スロットを1セッションとする。`session_date` はその晩の開始日（JST）で識別する（例：9/2 22:00 も 9/3 03:00 も session_date = 2026-09-02）。** |
| グループ | 予約主体。代表者名またはグループ名の文字列で識別する。 |
| PIN | 予約時にグループが設定する4桁数字。キャンセル時の本人確認に使う。 |

> **セッションという概念を導入した理由**：本システムの全スロットは深夜をまたぐ。暦日で区切ると 9/2 22:00 と 9/3 01:00 が別の日になり、「1日あたり2枠」の上限が1晩で実質4枠になってしまう。日付タブの分割、枠数上限の判定、時刻表示のすべてをセッション単位で行う。

---

## 3. 利用者と権限

| 利用者 | 手段 | できること |
|---|---|---|
| 参加者 | 公開URL（GitHub Pages） | 予約状況の閲覧、予約の作成、PINを知っている予約のキャンセル |
| 主催者 | Supabase ダッシュボード | 全データの閲覧・編集・削除、スロット定義の変更 |

- 参加者向けの認証は行わない。URLを知っている者＝サークル関係者として運用する。
- ただし**予約の改ざん・一括削除は技術的に不可能**でなければならない（第7章）。

---

## 4. 機能要件

### FR-01 予約状況の一覧表示
- 横軸を部屋（7列）、縦軸を時間スロット（9行）とするグリッドを表示する。
- 空きセルは「空」と表示し、タップ可能であることが視覚的に分かること。
- 予約済みセルはグループ名を表示する。
- **セッション（晩）ごとにタブで分ける**（詳細は第9章）。
- 現在時刻より過去のスロットはグレーアウトし、操作不可とする。**この判定はサーバ時刻に基づく**（FR-06）。
- 画面は30秒間隔で自動再取得する。手動リロードボタンも設置する。**ただしモーダル表示中とタブ非表示中はポーリングを停止する**（FR-07）。

### FR-02 予約の作成
- 空きセルをタップするとモーダルが開く。入力項目：
  - グループ名（必須、1〜30文字、前後空白はトリム）
  - PIN（必須、半角数字4桁）
- モーダルには「**開始30分前を過ぎるとキャンセルできません**」という注記を常時表示する（FR-03 との関係）。
- 確定ボタン押下で RPC `create_reservation` を呼ぶ。
- 成功時：モーダルを閉じ、グリッドを再取得して結果を反映する。
- 失敗時：第10章のエラー表示規則に従う。
- 二重送信防止のため、送信中は確定ボタンを無効化する。
- **予約可能な期限**：スロット開始時刻まで。開始済みスロットへの予約はサーバ側で `PAST_SLOT` として拒否される。

### FR-03 予約のキャンセル
- 予約済みセルをタップするとモーダルが開き、予約内容とPIN入力欄を表示する。
- PINが一致した場合のみ削除する。RPC `cancel_reservation` を呼ぶ。
- PIN不一致時はエラーを表示し、予約は残す。
- **キャンセル可能な期限**：スロット開始の30分前まで。それ以降はサーバ側で `TOO_LATE` として拒否される。
- 期限切れの予約セルは、キャンセルボタンを無効化して表示する（サーバ側検証は省略しない）。

> **既知の非対称性**：作成は開始時刻まで可能、キャンセルは開始30分前まで。したがって開始30分を切ってから作成した予約は、作成直後からキャンセル不能になる。直前の空き枠を活用できることを優先した意図的な仕様であり、FR-02 の注記で参加者に明示する。

### FR-04 予約数の上限
- 1グループが保有できる予約は **1セッション（1晩）あたり最大2枠**とする。
- セッションをまたげば別枠として数える（9/2夜に2枠、9/3夜に2枠、計4枠まで可）。
- 同一スロットに同一グループが複数部屋を予約することは禁止する。
- 判定はグループ名の**正規化キー**（`group_key`）で行う。正規化は「前後空白の除去 → Unicode NFKC 正規化 → 小文字化」の順で行い、大文字小文字・全角半角・半角カナの表記揺れを同一グループとみなす（「Aチーム」「Ａチーム」「aチーム」は同一）。
- **同時実行下でも上限を超えてはならない**（実現方法は第8章、検証は第12章-12）。

**端末単位の上限（2026-08-24 追加）**

- 1つの端末から取れる予約も **1セッション（1晩）あたり最大2枠**とする。グループ名による上限とは**独立に、両方が同時に適用される**。別のグループ名を名乗っても、同じ端末からはその晩3枠目を取れない。
- 単位はセッションであり暦日ではない。§2 のとおり暦日で数えると 22:00 と 01:00 が別日になり、1晩で実質4枠になってしまう。
- 端末の識別は、初回アクセス時に生成して `localStorage` に保存する UUID で行う。
- **この上限に強制力はない。** `localStorage` の消去・プライベートブラウズ・別ブラウザ・別端末のいずれでも回避できる。「うっかり取りすぎ」と「軽い気持ちの取りすぎ」を止める柵であって、認証の代替ではない（§7 の受容リスク参照）。強制力を求めるなら認証が必要だが、それは §1 でスコープ外と決めている。
- **IPアドレスによる識別を採用してはならない。** 合宿所のWiFiはNATで参加者全員が同一のグローバルIPになるため、最初の2枠で全員がブロックされる。携帯回線のCGNATでも同じ事故が起きる。
- `localStorage` が使えない環境では端末IDを永続化できない。その場合もエラーにせず、その場限りのIDで動作を続ける。上限は実質無効になるが、柵である以上それを許容する。

### FR-08 部屋の順次開放

参加者に部屋を左から詰めて使ってもらうため、**左に3部屋以上ある部屋（＝並び順で4番目以降）は、同じ枠で左隣の部屋が予約されるまで予約できない**。

- 1〜3番目の部屋（B2大・D1中・D2中）は常に予約できる。**最初から開けておく数は部屋数に合わせて調整する**。5部屋のときは2、7部屋にした 2026-09-01 に3へ増やした（§13 決定事項 #16）。開放数が少なすぎると、同時に来た参加者が1枠を取り合って渋滞する。
- 判定は**同一スロット内**で行う。ある枠で4番目が開いていても、別の枠では独立に判定する。
- 並び順は `rooms.sort_order` を基準とする。`sort_order` が連番でなくても機能するよう、判定は「`sort_order` がひとつ下の部屋」を引いて行う。
- 画面では斜線で「未開放」を示す。**押せなくはせず、押したら「〇〇が予約されると開きます」と表示する**。押せなくすると理由が伝わらないため。
- **DB でも検査する。** 画面の表示だけに頼ると、RPC を直接呼んで迂回できる（§8.2 の方針）。違反時は `ROOM_LOCKED`。

> **この規則は新規の予約だけを制限する。** 4番目が予約された後に3番目がキャンセルされても、4番目の予約はそのまま残る。すでに成立した予約を後から無効にはしない。同様に、5番目は4番目が予約されている限り開いたままである。キャンセルによって一時的に「左が空いているのに右が埋まっている」状態が生じうるが、これは許容する。

### FR-05 スロット定義
- 予約可能な日時の集合は `slots` テーブルで定義する。フロントエンドにハードコードしない。
- 各スロット行は `session_date` を持ち、どの晩に属するかを保持する。
- スロットに存在しない日時への予約は外部キー制約で拒否される（`NO_SUCH_SLOT`）。
- 主催者はダッシュボードから行を追加・削除するだけで予約可能時間を変更できる。ただし**予約が入っているスロット行は削除できない**（第11章の運用注意を参照）。

### FR-06 サーバ時刻の同期
- 「過去かどうか」の判定を端末の時計で行うと、時計のずれた端末でサーバと食い違い、UIでは操作できるのにRPCが拒否する（またはその逆）状態が起きる。
- APIレスポンスの HTTP `Date` ヘッダからサーバ時刻とのオフセットを算出し、以後アプリ内の「現在時刻」はすべて `Date.now() + offset` で求める。追加のリクエストは発生させない。
- オフセットは取得のたびに更新する。
- **前提**: `Date` は CORS のセーフリスト対象外だが、PostgREST は `Access-Control-Expose-Headers` に `Date` を含めて返すため読み取れる。**この点は実機の Supabase エンドポイントで確認すること**（DevTools の Network で `Access-Control-Expose-Headers` に `Date` があるか見る）。読めない場合はオフセット0（端末時計）に自動的に縮退する実装とし、必要なら `server_now()` RPC の追加を検討する。
- `Date` ヘッダの精度は秒単位のため、最大1秒のずれが残る。30分・0分の境界判定には十分。

### FR-07 ポーリングの制御
- 30秒間隔の自動再取得は、以下の条件で停止する。
  - モーダルが開いている間（入力中の再描画を防ぐ）
  - `document.hidden === true` の間（不安定回線での通信量を削減する）
- `visibilitychange` でタブが再表示された時点で、即座に1回再取得する。

---

## 5. 非機能要件

| 項目 | 要件 |
|---|---|
| 同時利用者 | 最大20名程度 |
| デバイス | スマートフォン主体。レスポンシブ必須。iOS Safari / Android Chrome で検証すること。 |
| 通信環境 | 合宿所の回線は不安定な想定。初回ロードのペイロードを小さく保つ。**外部CDNへの依存を禁止する**（第7章）。 |
| 応答時間 | 予約操作は通常1秒以内に結果を返す。 |
| データ整合性（二重予約） | **二重予約は如何なる同時実行下でも発生してはならない。** `uq_room_slot` による**宣言的なDB制約**で保証する。アプリケーション層のチェックに依存しない。 |
| データ整合性（枠数上限） | PostgreSQL に COUNT を対象とする宣言的制約は存在しないため、**トランザクション内の advisory lock ＋ カウント**で保証する（第8章）。この一点のみ制約ではなく関数で担保する。 |
| タイムゾーン | データは `timestamptz`（UTC）で保持し、表示は `Asia/Tokyo` 固定。端末のTZ設定に依存してはならない（`Intl.DateTimeFormat` に `timeZone: 'Asia/Tokyo'` を明示する）。 |
| ブラウザ保存 | localStorage / sessionStorage / Cookie は使用しない（グループ名の再入力補助が必要な場合のみ、メモリ上の状態で対応）。 |

---

## 6. データモデル（Supabase / PostgreSQL）

```sql
create extension if not exists pgcrypto;  -- Supabase では extensions スキーマに導入済みのため実質 no-op

-- 部屋マスタ
create table rooms (
  id         smallint primary key,
  name       text not null,
  sort_order smallint not null
);

-- 予約可能スロット（主催者が事前に投入）
create table slots (
  start_at     timestamptz primary key,
  session_date date not null,
  -- reservations からの複合FKの参照先として必要
  constraint uq_slot_session unique (start_at, session_date)
);

create index ix_slots_session on slots (session_date, start_at);

-- 予約本体
create table reservations (
  id           uuid primary key default gen_random_uuid(),
  room_id      smallint    not null references rooms(id),
  start_at     timestamptz not null,
  session_date date        not null,
  group_name   text        not null,
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

-- PINハッシュは本体から分離し、anonからは一切読めなくする
create table reservation_secrets (
  reservation_id uuid primary key references reservations(id) on delete cascade,
  pin_hash       text not null
);

-- 端末ごとの枠数を数えるための対応表（FR-04）。
-- anon からは読めない。session_date は数える側の都合で非正規化して持つ。
create table reservation_devices (
  reservation_id uuid primary key references reservations(id) on delete cascade,
  device_id      uuid not null,
  session_date   date not null
);

create index ix_resdev_device_session on reservation_devices (device_id, session_date);
```

### 設計意図（変更してはならない点）

1. **PINハッシュの分離**：フロントエンドが `select *` を書いてもハッシュが漏れない構造にするため。この分離は変更しないこと。
2. **`session_date` の複合外部キー**：予約の `session_date` が `slots` の定義と食い違う可能性をアプリ層ではなくDB制約で排除する。単独の `start_at` FK では session_date の正しさを保証できない。
3. **`group_key` 生成列**：正規化ルールをDBに1箇所だけ持たせる。フロントとRPCで正規化ロジックが二重管理されると、必ずどちらかがずれる。
4. **`device_id` を `reservations` に持たせない**：`reservations` は anon が自由に SELECT できる。同じ表に `device_id` を置くと「どの予約が同一端末から取られたか」を誰でも突き合わせられ、匿名運用の前提が崩れる。PINハッシュと同じ理由で別表に分離する。

### 実装時の最初の検証タスク

`normalize(text, NFKC)` は PostgreSQL 13 以降で IMMUTABLE として提供されており、生成列に使用できる。**実装の最初のステップとして、上記 `create table reservations` が Supabase の SQL Editor で実際に通ることを確認すること。** 通らなかった場合は生成列の式を `lower(btrim(group_name))` にフォールバックし、その旨と「全角半角の表記揺れは別グループ扱いになる」制約を本書に追記した上で進めること（勝手にフォールバックして黙って進めないこと）。

---

## 7. セキュリティ / RLS

前提：GitHub Pages にデプロイするため、Supabase の URL と anon key はソース上で公開される。**anon key は秘密情報として扱わない**設計にすること。

### 7.1 RLS ポリシー

```sql
alter table rooms                enable row level security;
alter table slots                enable row level security;
alter table reservations         enable row level security;
alter table reservation_secrets  enable row level security;
alter table reservation_devices  enable row level security;

-- 読み取りのみ許可
create policy p_rooms_select on rooms        for select to anon using (true);
create policy p_slots_select on slots        for select to anon using (true);
create policy p_res_select   on reservations for select to anon using (true);

-- reservation_secrets と reservation_devices にはポリシーを一切作らない（= anon からアクセス不可）
-- reservations への INSERT / UPDATE / DELETE ポリシーも作らない（= RPC 経由のみ）
```

RPC は `security definer` で関数所有者（postgres）の権限で動作し、テーブル所有者として RLS をバイパスして書き込む。**`force row level security` は設定しないこと**（設定すると所有者もポリシーに従うようになり、RPC が書き込めなくなる）。

### 7.2 フロントエンドの依存構成

**supabase-js を使用しない。** `fetch` で PostgREST のエンドポイントを直接呼ぶ。

決定理由（安全性の観点）：
- 本システムのセキュリティ境界はDB側（RLS + RPC）にあり、フロントに悪意あるコードが混入してもDBに対してできることは正規参加者と同じである。したがって供給チェーン攻撃の被害は「**参加者が入力したPINの窃取**」と「偽画面の表示」に限定される。予約データの一括破壊は起こり得ない。
- しかしPINの窃取は実害である（PINは他所で使い回されがち）。外部CDNからスクリプトを読むと、そのCDNが乗っ取られた時点でこれが成立する。CDNを使わなければ攻撃面はゼロになる。
- supabase-js の価値の大半は認証・セッション管理・トークンリフレッシュ・Realtime にある。本件は認証なし・30秒ポーリングであり、実際に必要なのは `GET /rest/v1/...` と `POST /rest/v1/rpc/...` の2種類のみ。SDKを使わないことによる自前実装バグのリスクは極小。
- ペイロードが数KBに収まり、§5 の不安定回線要件にも最も強い。

必要なリクエストヘッダは以下の2つ（両方とも anon key）：

```
apikey: <ANON_KEY>
Authorization: Bearer <ANON_KEY>
```

### 7.3 Content Security Policy

GitHub Pages は HTTP レスポンスヘッダを設定できないため、`index.html` の `<meta http-equiv="Content-Security-Policy">` で宣言する。

```
default-src 'none';
script-src 'self';
style-src 'self';
connect-src https://<project-ref>.supabase.co;
img-src 'self' data:;
base-uri 'none';
form-action 'none'
```

- `frame-ancestors` は meta タグでは無効である。クリックジャッキング対策はGitHub Pagesでは実施できないため、リスクとして受容する（7.5）。
- インラインスクリプト・インラインスタイルは使用しない（`'unsafe-inline'` を書かなくて済むようにする）。

### 7.4 満たすべきセキュリティ特性

1. ブラウザのDevToolsから `reservations` への直接 `delete` / `update` / `insert` を実行しても失敗すること。
2. `reservation_secrets` の内容がクライアントから一切取得できないこと。
3. PINは平文で保存されないこと（`crypt()` + `gen_salt('bf')`）。
4. **PIN総当たり対策**：`cancel_reservation` の失敗時に `pg_sleep(0.5)` を入れる。1予約あたりの平均試行時間は約83分となる。4桁PINは原理的に総当たり可能だが、部内利用かつ運用期間が2晩であるため許容する（決定事項6）。
5. **存在しない予約IDへのキャンセル要求は、PIN不一致と同一の応答（`pg_sleep(0.5)` 後に `INVALID_PIN`）を返すこと。** 予約IDの存在有無を漏らさないため。
6. **XSS対策**：グループ名を含むすべてのユーザー入力は `textContent` で DOM に挿入する。**`innerHTML` の使用を禁止する。**

### 7.5 受容するリスク（対策しないと決めた事項）

以下は本システムでは技術的に対策せず、運用でカバーする。実装者はこれらの対策コードを追加しないこと。

| リスク | 判断 |
|---|---|
| 参加者が偽のグループ名を次々に使って枠を占拠する | レート制限は実装しない（無料プランでの実装が困難）。抑止は「1晩2枠の上限」「**端末ごとの1晩2枠の上限**（FR-04、2026-08-24 追加）」「主催者がダッシュボードから削除できること」に依存する。端末上限は `localStorage` の消去等で回避できるため、決定的な対策ではない。 |
| 4桁PINの総当たり | `pg_sleep(0.5)` のみで許容する（7.4-4）。 |
| クリックジャッキング | GitHub Pages で `frame-ancestors` を設定できないため受容する。 |
| 他人のグループ名を騙った予約 | 認証を行わない設計上、防止できない。主催者が手動で修正する。 |

---

## 8. API（RPC）

クライアントは以下の2関数のみを書き込みに使う。いずれも `security definer` かつ `set search_path = public, extensions`。

> **`extensions` を含める理由**（2026-08-24 追記）：Supabase は `pgcrypto` を `public` ではなく `extensions` スキーマに事前導入している（実プロジェクト `camp-room-booking` / PG 17.6 で確認）。`search_path` を `public` だけに固定すると `create_reservation` 内の `crypt()` / `gen_salt()` が解決できず**実行時に**失敗する。plpgsql の関数本体は作成時に検証されないため、SQL の投入自体は成功し、参加者が実際に予約を押したときだけ落ちるという発覚の遅い壊れ方をする。`public` を先頭に保ったまま `extensions` を追記すること。

### 8.1 エラー返却の規約

すべてのエラーは以下の形式で raise する。

```sql
raise exception using errcode = 'P0001', message = '<ERROR_CODE>';
```

- PostgREST は HTTP 400 と `{"code":"P0001","message":"<ERROR_CODE>","details":null,"hint":null}` を返す。
- **クライアントは `message` フィールドの完全一致でエラーを判別する。** 人間向けの日本語文言はクライアント側の文言テーブルが持ち、DBのメッセージには機械可読なコードのみを入れる（DBの文言変更がUIを壊さないようにするため）。
- `PT` で始まるカスタム SQLSTATE は PostgREST が HTTP ステータス制御に予約しているため使用しない。

### 8.2 create_reservation

```
create_reservation(
  p_room_id    smallint,
  p_start_at   timestamptz,
  p_group_name text,
  p_pin        text,
  p_device_id  uuid default null   -- FR-04 端末上限。既定値ありは意図的（後述）
) returns uuid
```

処理順序：

1. `p_pin` が `^[0-9]{4}$` に一致しなければ `INVALID_PIN` を raise
2. `btrim(p_group_name)` の長さが 1〜30 の範囲外なら `INVALID_GROUP_NAME` を raise（`chk_group_name` 制約に到達させると `check_violation` になり、機械可読コードを返せないため関数側で先に弾く）
3. `slots` から `p_start_at` の行を取得し `session_date` を得る。行がなければ `NO_SUCH_SLOT` を raise
4. **`p_start_at <= now()` なら `PAST_SLOT` を raise**（FR-01のグレーアウトはUI上の便宜にすぎず、サーバ側の検証を省略してはならない）
4b. `rooms` から `p_room_id` の `sort_order` を得る。行がなければ `NO_SUCH_ROOM` を raise。`sort_order` がそれより小さい部屋が**3つ以上**あり、かつ**そのうち最大の部屋**（＝左隣）が同じ `p_start_at` で予約されていなければ `ROOM_LOCKED` を raise（FR-08）
5. 正規化キー `v_group_key := lower(normalize(btrim(p_group_name), NFKC))` を算出する。**生成列 `group_key` と同一の式でなければならない**
6. **`perform pg_advisory_xact_lock(1, hashtext(v_group_key));`** を実行する。続けて `p_device_id` が null でなければ **`perform pg_advisory_xact_lock(2, hashtext(p_device_id::text));`** を実行する。**グループ → 端末というこの順序を入れ替えてはならない**（理由は後述）
7. `reservations` を `group_key = v_group_key and session_date = <手順3の値>` で数え、2以上なら `LIMIT_EXCEEDED` を raise
7b. `p_device_id` が null でなければ、`reservation_devices` を `device_id = p_device_id and session_date = <手順3の値>` で数え、2以上なら `DEVICE_LIMIT_EXCEEDED` を raise
8. `reservations` に insert（`group_name` はトリム済みの値。`group_key` は生成列なので指定しない）。例外を捕捉して分岐する
   - `unique_violation` → `get stacked diagnostics` で制約名を取得し、`uq_group_slot` なら `DUPLICATE_IN_SLOT`、それ以外（`uq_room_slot`）なら `SLOT_TAKEN` を raise
   - `foreign_key_violation` → `NO_SUCH_ROOM` を raise（存在しない `room_id` を送られた場合）
9. `reservation_secrets` に `crypt(p_pin, gen_salt('bf'))` を insert
10. `p_device_id` が null でなければ `reservation_devices` に insert する

**手順6が本設計の要**。これがないと「数える → insert」の間に別トランザクションが割り込み、同一グループが同時送信で3枠目・4枠目を取得できてしまう（§5 の枠数上限要件を満たさなくなる）。advisory lock は**同一グループ名のリクエスト同士のみを直列化**し、無関係なグループはブロックしない。`hashtext` が衝突した場合の実害は「無関係な2グループが一瞬待たされる」ことだけである。ロックはトランザクション終了時に自動解放されるため、明示的な解放は不要。

**手順6でロックの取得順序を固定する理由**：1つのトランザクションが2種類のロックを取るため、順序がばらつくとデッドロックしうる。「必ずグループを先、端末を後」に固定すると、端末ロックを待っているトランザクションは必ずグループロックを保持済みであり、その逆（グループロックを待ちながら端末ロックを保持する）が発生しない。待ちの向きが一方向に揃うため循環が作れず、デッドロックは原理的に起きない。なお classid をグループ = 1、端末 = 2 と分けているので、両者のハッシュ値がたまたま一致しても互いに干渉しない。

**`p_device_id` に既定値 `null` を置く理由**：GitHub Pages は JS をキャッシュするため、DB を更新した直後は端末IDを送らない古い `app.js` がしばらく残る。引数を必須にすると PostgREST が関数を解決できず、その間の予約がすべて失敗する。既定値を置けば古いクライアントも動き続け、端末上限だけが適用されない状態で済む。「端末IDを送らなければ上限を回避できる」ことになるが、そもそも端末IDは利用者が自由に詐称できる柵であり（FR-04）、この抜け道で失うものはない。

**手順9で制約名による分岐が必要な理由**：`uq_group_slot`（同一グループが同一スロットで2部屋）と `uq_room_slot`（他グループに先を越された）はどちらも `unique_violation` になる。区別せずに `SLOT_TAKEN` を返すと、自分が既に同じ時間帯に別の部屋を取っているだけなのに「他のグループが予約しました」と表示され、参加者が混乱する。

### 8.3 cancel_reservation

```
cancel_reservation(p_id uuid, p_pin text) returns boolean
```

処理順序：

1. `reservations` を `id = p_id` で取得する。**行がなければ `pg_sleep(0.5)` の後 `INVALID_PIN` を raise**（存在有無を漏らさないため、PIN不一致と同一の応答にする）
2. **`start_at - interval '30 minutes' <= now()` なら `TOO_LATE` を raise**（FR-03のキャンセル期限。UIでのボタン無効化に依存しない）
3. `reservation_secrets` から `pin_hash` を取得し PIN を照合する。不一致なら `pg_sleep(0.5)` の後 `INVALID_PIN` を raise
   - **判定は `crypt(p_pin, v_hash) is distinct from v_hash` で行うこと。** 単純な `<>` を使うと `p_pin` が null のとき比較結果が null になり、条件が偽と評価されて**PINなしで削除が通ってしまう**
4. 一致すれば `reservations` から delete（`on delete cascade` で secrets も消える）し `true` を返す

### 8.4 権限付与

`security definer` 関数はデフォルトで `PUBLIC` に EXECUTE が付くため、明示的に絞ってから付与する。

```sql
revoke all on function create_reservation(smallint, timestamptz, text, text) from public;
revoke all on function cancel_reservation(uuid, text) from public;
grant execute on function create_reservation(smallint, timestamptz, text, text) to anon;
grant execute on function cancel_reservation(uuid, text) to anon;
```

---

## 9. 画面仕様

ビルド不要の静的ファイル構成とする（第11章）。フレームワークは使用しない。

| 画面 | 内容 |
|---|---|
| メイン | ヘッダー（合宿名・現在時刻・更新ボタン）／セッションタブ／予約グリッド／凡例／スタジオの機材（§17） |
| 予約モーダル | 対象セル名の表示、グループ名・PIN の入力、キャンセル期限の注記、確定／閉じる |
| 削除モーダル | 予約内容の表示、PIN入力、削除／閉じる |
| トースト | 成功・失敗メッセージの表示（3秒で自動消滅） |

### 9.1 セッションタブ

- タブは2つ：「**9/2(水)の夜**」「**9/3(木)の夜**」。
- タブは `slots.session_date` の distinct 値から生成する。**日付も曜日もハードコードしない。** 曜日は `Intl.DateTimeFormat('ja-JP', { timeZone: 'Asia/Tokyo', weekday: 'short' })` で導出する。
- 初期表示は、サーバ時刻（FR-06）から見て「まだ終わっていない最も早いセッション」を選択する。すべて終了していれば最後のセッションを選択する。

### 9.2 時刻表示

- 各行のラベルは `22:00` `23:00` `翌00:00` `翌01:00` … `翌06:00` の9行。
- 「翌」を付ける判定は、`start_at` のJST日付が当該行の `session_date` と異なるかどうかで行う。
- **26時制（24:00、25:00 …）は採用しない。** 初見の参加者が戸惑うため。
- すべての時刻整形に `timeZone: 'Asia/Tokyo'` を明示する。端末のTZ設定に依存させない。

### 9.3 グリッド

- 7列が画面幅に収まるようにする（横スクロールさせない。スマホ縦持ちで判読可能なこと）。幅 320px でも1列 36px を確保できることを実測で確認している（左右余白 `--gutter` と時刻列の幅を詰めて捻出した）。
- 列の順序は `rooms.sort_order` に従う。
- セルの状態は4種類：**空き**（タップ可）／**予約済み**（グループ名を表示、タップでキャンセルモーダル）／**過去**（グレーアウト、操作不可）／**キャンセル期限切れの予約済み**（グループ名を表示、タップは可だがキャンセルボタンは無効）。
- 凡例でこの4状態を説明する。

### 9.4 入力

- PIN入力欄は `inputmode="numeric"` と `maxlength="4"` を指定する。
- `autocomplete="off"` を指定する（§5 のブラウザ保存禁止の趣旨に合わせる）。

### 9.5 データ取得

- 初回のみ：`GET /rest/v1/rooms?select=id,name,sort_order&order=sort_order`
- 初回のみ：`GET /rest/v1/slots?select=start_at,session_date&order=start_at`
- 30秒ごと：`GET /rest/v1/reservations?select=id,room_id,start_at,group_name`

`rooms` と `slots` は運用中に変化しないためメモリに保持し、ポーリング対象は `reservations` のみとする。

---

## 10. バリデーションとエラー表示

| エラーコード | 発生条件 | 参加者への表示 | 追加動作 |
|---|---|---|---|
| `SLOT_TAKEN` | 同時操作で他グループに先を越された | 「この枠は他のグループが予約しました」 | グリッドを即再取得 |
| `DUPLICATE_IN_SLOT` | 同じ時間帯に自グループが別の部屋を予約済み | 「同じ時間帯にすでに別の部屋を予約しています」 | グリッドを即再取得 |
| `LIMIT_EXCEEDED` | グループ名基準の枠数上限の超過 | 「1グループの予約は**その晩あたり**最大2枠までです。既存の予約をキャンセルしてください」 | — |
| `DEVICE_LIMIT_EXCEEDED` | 端末基準の枠数上限の超過（FR-04） | 「この端末からの予約は**その晩あたり**最大2枠までです。既存の予約をキャンセルしてください」 | — |
| `PAST_SLOT` | 開始済みスロットへの予約 | 「この時間帯はすでに開始しています」 | グリッドを即再取得 |
| `NO_SUCH_SLOT` | 予約対象外の日時 | 「この時間帯は予約対象外です」 | グリッドを即再取得 |
| `TOO_LATE` | 開始30分前を過ぎたキャンセル | 「開始30分前を過ぎたためキャンセルできません」 | グリッドを即再取得 |
| `INVALID_PIN`（作成時） | PIN形式不正 | 「PINは数字4桁で入力してください」 | — |
| `INVALID_GROUP_NAME` | グループ名が1〜30文字の範囲外 | 「グループ名は1〜30文字で入力してください」 | — |
| `NO_SUCH_ROOM` | 存在しない部屋ID（改ざん時のみ） | 「その部屋は存在しません」 | グリッドを即再取得 |
| `ROOM_LOCKED` | 左隣が未予約の部屋への予約（FR-08） | 「この部屋はまだ予約できません。左の部屋から順にお使いください」 | グリッドを即再取得 |
| `INVALID_PIN`（削除時） | PIN不一致、または予約が存在しない | 「PINが違います」 | — |
| `INVALID_ADMIN_PASSWORD` | 管理パスワード不一致（§14） | 「管理パスワードが違います」 | — |
| `NO_SUCH_RESERVATION` | 管理削除の対象が既に存在しない（§14） | 「その予約は見つかりません。すでに削除されている可能性があります」 | グリッドを即再取得 |
| `NO_SUCH_DELETED` | 復元対象が退避表にない（§14） | 「その削除済み予約は見つかりません」 | 一覧を再取得 |
| `RECORD_FROZEN` | 開始時刻を過ぎた記録への変更（§15） | 「開始時刻を過ぎた記録は固定されています。訂正には理由の記録が必要です」 | グリッドを即再取得 |
| `REASON_REQUIRED` | 訂正の理由が空（§15） | 「訂正には理由の入力が必要です」 | — |
| ネットワークエラー | 通信失敗 | 「通信に失敗しました。再度お試しください」 | 再試行ボタン |

- 上記コードは §8 で raise されるものと1対1で対応する。**対応表にないコードをDB側で追加してはならない。**
- 未知のコードを受信した場合は「エラーが発生しました（コード）」と生のコードを添えて表示する（デバッグのため）。
- クライアント側でも送信前に形式チェックを行うが、**サーバー側の検証を省略してはならない**。

---

## 11. 環境とデプロイ

### 11.1 ファイル構成

```
index.html          画面。CSPのmetaタグを含む
app.js              全ロジック（外部依存なし）
styles.css          スタイル
config.js           Supabase URL / anon key
sql/01_schema.sql   第6章のテーブル定義
sql/02_rls.sql      第7章のRLSポリシー
sql/03_functions.sql 第8章のRPC定義と権限付与
sql/04_seed.sql     rooms 7件、slots 20件
sql/05_admin.sql    第14章の管理機能（管理パスワード・退避表・管理RPC）
sql/06_freeze.sql   第15章の凍結トリガーと訂正台帳
sql/07_launch_reset.sql 第16章の一般公開前の自動初期化
sql/08_rooms_update.sql 稼働中DBの rooms を現在の7部屋に合わせる（04 の代わり）
sql/test_acceptance.sh  受け入れ基準のうちDBで検証できる項目の自動テスト
tools/localdev.sh       ローカル検証環境をワンコマンドで起動（開発専用）
tools/devserver.py      ローカルPG に対する PostgREST 互換ミニサーバ（開発専用）
```

> ⚠️ **`sql/test_acceptance.sh` を Supabase に対して実行してはならない。**
> このスクリプトは**ローカルPG専用**である。冒頭で `grant select, insert, update, delete on all tables in schema public to anon` を実行して Supabase 相当の権限を再現し、時刻依存テストのために `session_date = current_date` のスロットを3件挿入する。末尾に後片付けがない。本番に流すと anon の権限を広げ、画面に存在しない日付のタブが生える。ローカル（`tools/localdev.sh`）に対してのみ使うこと。

`tools/` は **Supabase を用意する前に手元で画面を確認するための開発専用ツール**であり、GitHub Pages には配置しない。不要なら削除してよい。使い方:

```
./tools/localdev.sh            # ローカルPGを立てて http://127.0.0.1:8777 で配信
./tools/localdev.sh stop       # 停止と後片付け
```

- フロントエンド：GitHub Pages（リポジトリルート配信）
- バックエンド：Supabase 無料プラン
- `config.js` の値は公開前提のためリポジトリにコミットしてよい。
- SQLは `01` → `04` の順に Supabase SQL Editor で実行する。

### 11.4 実環境の値（2026-08-24 構築）

| 項目 | 値 |
|---|---|
| GitHub リポジトリ | `Ahyuki-ya/camp-room-booking`（public） |
| 公開URL | https://ahyuki-ya.github.io/camp-room-booking/ |
| Supabase 組織 | `yukidaruma.daisuki@gmail.com's Org`（個人アカウント） |
| Supabase プロジェクト | `camp-room-booking` / ref `zdborpxhbggshicyoaoj` |
| リージョン | `ap-northeast-1`（東京） |
| PostgreSQL | 17.6 |
| 使用する公開鍵 | **publishable key**（`sb_publishable_...`）。legacy の anon JWT も発行されているが、Supabase が legacy 鍵を段階的に廃止する方針のため新形式を採用した。どちらも動作することは実測済み |

DB パスワードと Management API のトークンは `.env.local`（gitignore 済み）に置く。リポジトリには含めない。

### 11.2 seed.sql

日程を1箇所で変更できるようにする。

```sql
insert into rooms (id, name, sort_order) values
  (1,'B2大',1),(2,'D1中',2),(3,'D2中',3),(4,'D3中',4),
  (5,'E1中',5),(6,'E2中',6),(7,'E3中',7);

-- 22時〜31時(=翌7時)開始の10スロット × 2セッション = 20行
insert into slots (start_at, session_date)
select (d + make_interval(hours => h)) at time zone 'Asia/Tokyo', d
from (values ('2026-09-02'::date), ('2026-09-03'::date)) as s(d),
     generate_series(22, 31) as h;
```

- `(timestamp) at time zone 'Asia/Tokyo'` により、JSTの壁時計時刻を正しく `timestamptz`（UTC）へ変換する。
- 日程を変更する場合は `values` 句の日付のみを書き換える。時間帯を変更する場合は `generate_series` の範囲のみを書き換える。
- 部屋名を実際の部屋番号に変える場合は `rooms` の insert 文のみを書き換える。
- **部屋名は表示専用である。** `reservations` は `room_id` を参照しており、名前を変えても既存の予約は一切影響を受けない。運用中に名前が確定・変更されても `rooms` を `update` するだけでよい（`id` と `sort_order` は変えないこと）。
- 部屋名に「（大）（中）」の括弧を付けないのは、7列になって1列 36px まで詰まったため。全角括弧2文字分がヘッダーの折り返しを招く。
- **既に稼働している DB には `04_seed.sql` を流せない**（`rooms` の id が衝突する）。部屋を入れ替えるときは `sql/08_rooms_update.sql`（upsert + 余りの delete）を使う。何度流しても同じ状態になる。

### 11.3 運用上の注意

- **予約が入っているスロット行は削除できない**（`on delete restrict`）。主催者が時間帯を削る場合は、先に該当スロットの予約を削除する必要がある。これは事故防止のための意図的な設計である。
- **参加者によるキャンセルは物理削除**であり、復元手段はない。一方、**§14 の管理モードによる削除は論理削除**であり、`deleted_reservations` から復元できる。主催者が消す場合は必ず管理モードを使うこと。Supabase ダッシュボードから直接行を消すと退避されず、復元できない。
- **GitHub Pages は `Cache-Control: max-age=600` を返す。** デプロイしても、既に開いたことのある端末には最大10分間、古い `app.js` と `styles.css` が配信され続ける。合宿当日に修正を入れる場合はこの遅延を見込むこと。RPC の引数を増やすときに既定値を置くのは、この10分間に古いクライアントが関数を解決できず全予約が失敗するのを避けるためである（§8.2）。

---

## 12. 受け入れ基準

以下がすべて満たされたときに完成とする。

1. 2つの端末から**同一セルを同時に**予約したとき、片方のみ成功し、もう片方に `SLOT_TAKEN` のメッセージが出て画面が最新状態に更新される。
2. 枠数上限に達したグループが、その晩の3枠目を予約しようとすると拒否される。
3. 同一グループが同じ時間帯に2部屋を予約しようとすると `DUPLICATE_IN_SLOT` で拒否され、「他のグループが予約しました」ではなく「同じ時間帯にすでに別の部屋を予約しています」と表示される。
4. 正しいPINでキャンセルでき、誤ったPINではキャンセルできない。
5. DevToolsのコンソールから `reservations` へ直接 delete / update / insert を試みても、**データが一切変更されない**。
   - `insert` は RLS ポリシーが無いためエラーになる。
   - **`delete` と `update` はエラーにならず「0行」で弾かれる**（RLSは該当ポリシーが無い行を対象外にするだけで例外を投げない）。PostgREST 経由では 204 が返るため成功したように見える。検証すべきは戻り値ではなく**件数と内容が変わらないこと**。
6. DevToolsから `reservation_secrets` の内容を取得できない。
7. 過去のスロットが操作不可になっている。
8. iPhone実機（Safari）で7列のグリッドが横スクロールなしに判読・操作できる。
9. 全端末で表示時刻がJSTで一致する（端末のTZ設定を変更しても表示が変わらないこと）。
10. **DevTools から `rpc/create_reservation` を開始済みスロットに対して直接呼ぶと `PAST_SLOT` で失敗する**（UIのグレーアウトを迂回できないこと）。
11. **開始30分を切った予約は、正しいPINを入力しても `TOO_LATE` でキャンセルできない。**
12. **同一グループ名で3件の予約要求を同時送信しても、その晩の保有枠が2を超えない**（advisory lock の検証。`xargs -P` などで並列にRPCを叩いて確認する）。
13. **「Aチーム」と「Ａチーム」が同一グループとして枠数上限に合算される。**
14. **9/2 22:00 と 9/3 01:00 が同一セッションとして上限にカウントされる**（暦日で分割されないこと）。
15. **外部CDNへのリクエストが1件も発生しない**（DevTools の Network タブで、自オリジンと Supabase 以外への通信がゼロであること）。
16. **同一端末から、異なるグループ名を使ってその晩3枠目を取ろうとすると `DEVICE_LIMIT_EXCEEDED` で拒否される**（FR-04 の端末上限。グループ名上限とは独立に効くこと）。
17. **`localStorage` を消去してから予約すると、端末上限がリセットされて再び2枠取れる**（回避可能であることを仕様として確認する。これは不具合ではない）。
18. **管理モードで予約を削除でき、削除した予約を復元できる**（§14）。復元後、その予約は元のPINで参加者自身がキャンセルできる。
19. **誤った管理パスワードでは削除も復元もできない**（`INVALID_ADMIN_PASSWORD`）。
20. **DevToolsから `admin_settings` の内容を取得できない**（管理パスワードのハッシュが漏れないこと）。
21. **開始時刻を過ぎた予約は、ダッシュボードからの直接 `update` / `delete` / `insert` を含めて拒否される**（`RECORD_FROZEN`、§15）。
22. **理由を付けた訂正RPCでのみ過去記録を変更でき、変更内容が台帳に残る**（§15）。理由が空なら `REASON_REQUIRED`。
23. **台帳は `update` / `delete` / `TRUNCATE` のいずれでも書き換えられない**（`LEDGER_IS_APPEND_ONLY`）。
24. **凍結を入れても、開始前の枠の予約・キャンセルは従来どおり動く。**
25. **左から順に予約すれば全部屋が取れ、右端から予約しようとすると4番目以降が `ROOM_LOCKED` で拒否される**（FR-08）。最初の3部屋はいつでも取れる。
26. **未開放のセルをタップすると、どの部屋が埋まれば開くかが表示される。**

---

### 検証状況（2026-08-23 時点）

`sql/test_acceptance.sh` により、DBで検証できる項目は**ローカルの PostgreSQL 18.4 上で全21アサーションが通過済み**。ブラウザ実機（375px 幅）での画面確認も実施し、基準7・8とエラー表示の全経路を確認済み。

#### Supabase 実環境での確認結果（2026-08-24）

プロジェクト `camp-room-booking`（PG 17.6 / ap-northeast-1）に対して確認した。

| 項目 | 結果 |
|---|---|
| `normalize(..., NFKC)` 生成列 | ✅ **PG 17.6 で問題なく作成できた。** `lower(btrim(...))` へのフォールバックは不要。`' Ａチーム '` → `'aチーム'` への正規化も実測で確認 |
| `Date` レスポンスヘッダの露出 | ✅ **`access-control-expose-headers` に `Date` が含まれる**ことを実測で確認。FR-06 のサーバ時刻同期は動作する。端末時計への縮退は発生しない |
| `pgcrypto` のスキーマ | ⚠️ **`public` ではなく `extensions` にあった。** そのため §8 のとおり関数の `search_path` に `extensions` を追加した。この修正がないと予約作成が実行時に失敗する |
| RPC 経由の予約作成・キャンセル | ✅ anon 相当の publishable key で `create_reservation` / `cancel_reservation` の正常系・`INVALID_PIN`・`DUPLICATE_IN_SLOT` を実測で確認 |
| `reservation_secrets` の秘匿 | ✅ DB に行が存在する状態で anon から `GET /rest/v1/reservation_secrets` を叩き、`[]` が返ることを確認（RLS による遮断であることを、管理者権限での行数照会と突き合わせて確定） |
| `reservations` への直接 INSERT | ✅ anon からの直接 INSERT は HTTP 401 / `42501` で拒否されることを確認 |
| 基準2/13/14（上限・表記ゆれ・セッション境界） | ✅ anon から `Bチーム` / `Ｂチーム` / `bチーム` の3表記で予約し、単一の `group_key`（`bチーム`）に統合されること、9/2 22:00 と 9/3 01:00 が同一セッションと判定されること、3枠目が `LIMIT_EXCEEDED` になることを確認 |
| 基準5（anon の直接 DELETE / UPDATE） | ✅ 1行も変化しないことを確認。ただし **PostgREST は HTTP 204 を返す**（RLS で対象行が見えず空振りするため）。エラーにはならないが実害はない |
| `NO_SUCH_SLOT` | ✅ slots に存在しない時刻を指定すると `NO_SUCH_SLOT` が返ることを確認 |
| UI からの予約・キャンセル（GitHub Pages 本番） | ✅ 公開URL上でセルのタップ→予約→誤PINで「PINが違います」→正PINでキャンセル、の全経路を実測。コンソールエラーなし、CSP 違反なし |
| 基準21〜24（凍結と台帳） | ✅ 実プロジェクトで検証。過去枠への直接 insert/update/delete がいずれも `RECORD_FROZEN`、理由なしの訂正が `REASON_REQUIRED`、誤パスワードが `INVALID_ADMIN_PASSWORD`、正規の訂正が成功して台帳に記録され、台帳の update/delete が `LEDGER_IS_APPEND_ONLY`、開始前の枠の予約・取消が従来どおり動くことを確認。検証は1トランザクション内で行い、最後に例外で巻き戻して本番データと台帳を汚していない |
| 基準18（管理モードの削除・復元） | ⚠️ **RPC層は完全に検証済み**（作成→管理削除→一覧→復元→元のPINでキャンセル、まで実測）。ただし**画面から本物のパスワードで削除・復元する経路は未検証**。検証には管理パスワードの平文が必要で、それを作業ログに残さない判断をしたため |
| 基準19（誤パスワードでは操作できない） | ✅ 画面・RPC の両方で `INVALID_ADMIN_PASSWORD` を確認 |
| 基準20（`admin_settings` が取得できない） | ✅ 行が存在する状態で anon から `[]` |
| 管理モードの画面遷移 | ✅ 認証前は管理バーが出ないこと、認証後にヘッダーが変わること、予約済みセルのタップで PIN 欄のない削除モーダルが開くこと、モード終了で参加者用モーダルの文言が戻ることを実測 |
| 基準16（端末上限） | ✅ 同一端末から別々のグループ名で3枠目を取ろうとすると `DEVICE_LIMIT_EXCEEDED`。別端末なら同じ枠を取れることも確認 |
| グループ名上限と端末上限の独立性 | ✅ 新しい端末からでも同じグループ名の3枠目は `LIMIT_EXCEEDED`。両者が独立に適用されることを確認 |
| 端末IDを送らない旧クライアント | ✅ `p_device_id` を省略しても予約が成功する（既定値 `null` による後方互換）|
| `reservation_devices` の秘匿 | ✅ 3行存在する状態で anon から読んで `[]` |
| `PAST_SLOT` / `TOO_LATE` | ⏸ 時刻依存のため本番では未実施（過去スロットや30分以内のスロットを本番に挿入する必要があるため）。ローカルの `test_acceptance.sh` で検証済み |

**実機確認（2026-08-24）**:

| 項目 | 結果 |
|---|---|
| 基準8（実機での表示・操作） | ✅ Android と iPhone の両方で確認（5列のとき）。**7列にしたので実機での再確認が必要**。ブラウザ上では幅 320px でも横スクロールなしに収まることを確認済み |
| 基準9（端末TZを変えても表示が一致） | ✅ 実機で確認。タイムゾーン依存の表示崩れは発生しない |

**受け入れ基準は全17項目を満たした。**

なお advisory lock については、ロックを外した対照関数と同条件で比較する実験を行い、**ロックなしでは8並列で上限2枠を無視して8枠取得できる**こと、ロックありでは常に2枠に収まることを確認済み。

---

## 13. 決定事項の記録

v1 で `【要確認】` としていた項目は、2026-08-23 にすべて確定した。**未決事項は存在しない。**

| # | 項目 | 確定値 | 決定日 |
|---|---|---|---|
| 1 | 合宿の日程 | 2026-09-02(水)夜 ／ 2026-09-03(木)夜 の2晩 | 2026-08-24 に 9/1・9/2 から変更 |
| 2 | 予約可能な時間帯 | 各晩 22:00〜翌08:00（1時間×10スロット） | 2026-08-24 に翌07:00開始の枠を追加 |
| 3 | 部屋の名称と数 | **7部屋：B2大 ／ D1中 ／ D2中 ／ D3中 ／ E1中 ／ E2中 ／ E3中** | 2026-09-01 に5部屋（E6・D1・D3・E1・E2）から変更。予約が0件の状態で入れ替えた |
| 4 | 1グループの保有上限 | **1セッション（1晩）あたり2枠** | 2026-08-23 |
| 5 | キャンセル可能期限 | **開始30分前まで**（作成は開始時刻まで可） | 2026-08-23 |
| 6 | PINの桁数 | 4桁 | 2026-08-23 |
| 7 | 主催者用の一括操作 | **一括操作は引き続き不要**。ただし1件ごとの削除・復元は §14 の管理モードで提供する | 2026-08-24 に一部変更 |
| 8 | メモ機能 | **廃止**（列・制約・引数・表示をすべて削除） | 2026-08-23 |
| 9 | フロントエンドの依存構成 | **supabase-js を使わず fetch で直叩き**（CDN依存ゼロ） | 2026-08-23 |
| 10 | 予約の変更（枠移動） | 提供しない。キャンセル後に取り直す | 2026-08-23 |
| 11 | 端末単位の保有上限 | **1セッション（1晩）あたり2枠。グループ名上限と併用**。`localStorage` の UUID で識別し、回避可能であることを許容する | 2026-08-24 |
| 12 | 主催者の管理手段 | **画面内の管理モード**（`#admin`）＋管理パスワード。削除は**論理削除**とし復元できる | 2026-08-24 |
| 13 | 過去記録の扱い | **開始時刻を過ぎた行はトリガーで凍結**。訂正は理由必須の専用RPC経由のみとし、追記型の台帳に必ず残す。申請の根拠は**予約の記録**とし、実使用の記録は別途持たない | 2026-08-27 |
| 14 | 訂正用の画面 | **作らない**。訂正はダッシュボードの SQL Editor から訂正RPCを呼ぶ（§15.5） | 2026-08-27 |
| 15 | 一般公開の時刻 | **2026-09-02(水) 14:00 JST**。この時刻に準備期間中のデータを自動削除する（§16） | 2026-08-27 |
| 16 | 部屋の順次開放 | **4番目以降の部屋は、同じ枠で左隣が予約されるまで開かない**（＝最初の3部屋は常に開いている）。効率的に部屋を使ってもらうため | 2026-08-27 に決定（当時は3番目以降）。7部屋化にあわせ 2026-09-01 に開放数を2→3へ |
| 17 | 主催者の固定枠 | **PA講習会 ／ B2 ／ 9/3(木) 22:00〜24:00**。一般公開前の初期化と同一トランザクションで自動投入する（§16.6） | 2026-09-01 |

### v1 からの主な仕様変更

実装済みコードがある場合、以下は破壊的変更となる。

- `reservations.note` と `chk_note`、`create_reservation` の `p_note` 引数を**削除**
- `slots.session_date` を**追加**し、`reservations` から複合外部キーで参照
- `reservations.group_key` 生成列を**追加**（`uq_group_slot` の定義もこれに変更）
- `create_reservation` に advisory lock、`PAST_SLOT`、`NO_SUCH_SLOT`、`DUPLICATE_IN_SLOT` を追加
- `cancel_reservation` に `TOO_LATE` を追加
- 枠数上限の単位を「全体で2枠」から「1セッションあたり2枠」に変更


---

## 14. 管理機能（主催者向け）

参加者の予約を主催者がその場で削除できるようにする。合宿現場でスマホから使えることが要件であり、Supabase ダッシュボードを開く運用では遅すぎるため導入した（§13 決定事項 #12）。

### 14.1 前提と限界

**anon key は公開されているため、本章で定義する RPC は誰でも呼び出せる。守りは管理パスワードの強度のみである。** この事実を前提に設計すること。

- 誤りには `pg_sleep(0.5)` を挟む。ただし並列に呼ばれれば効果は薄い。レート制限は実装しない（§7 の判断を踏襲）。20並列で毎秒40回試せると仮定して見積もると、必要な長さは次のようになる。

| パスワード | 組み合わせ | 総当たりの所要時間 | 可否 |
|---|---|---|---|
| 数字4桁 | 1万 | **約4分** | ❌ 論外 |
| 英数6文字 | 8.9億 | 約260日 | △ |
| 英数8文字 | 8500億 | 約670年 | ✅ |
| 英数10文字 | 3700兆 | 事実上不可能 | ✅ |

- **最低ライン：英数8文字以上、かつ辞書にある単語をそのまま使わないこと。** 数字4桁のような短い値を設定してはならない。総当たり以前に、「管理パスワード」欄を見た参加者が最初に試す値（`0000` など）は一発で当てられる。
- 長さが足りていても、**サークル内で通じるあだ名など、関係者に推測されうる語**は総当たり以外の経路を残す。運用上許容するかは主催者の判断とする。
- 総当たりが成功した場合の被害は「予約が消える」であり、**退避表から復元できる**。壊滅的ではない。
- 生成時は紛らわしい文字（`i` `l` `o` `0` `1`）を避けると現場での打ち間違いが減る。`admin_norm` がハイフンと大文字小文字を吸収するため、`xxxx-xxxx-xxxx-xxxx` の形で配ってよい。

### 14.2 テーブル

| テーブル | 用途 |
|---|---|
| `admin_settings` | 管理パスワードの bcrypt ハッシュを1行だけ持つ |
| `deleted_reservations` | 管理者が削除した予約の退避先。`pin_hash` と `device_id` も保存する |

どちらも RLS を有効にし、**ポリシーを一切作らない**（anon から到達不能）。

`deleted_reservations` に `pin_hash` と `device_id` を持たせるのは、復元したときに**参加者が元のPINで自分でキャンセルでき、端末上限の計上も元に戻る**ようにするため。これらを捨てると、復元した予約は参加者が触れない宙ぶらりんの行になる。

`reservations` への外部キーは張らない。退避表に行がある時点で本体の行は存在しないため。

### 14.3 RPC

| 関数 | anon から実行 | 用途 |
|---|---|---|
| `admin_verify(p_password)` | ✅ | 管理モードに入るときのパスワード確認 |
| `admin_delete_reservation(p_id, p_password)` | ✅ | 退避表へ移してから削除 |
| `admin_restore_reservation(p_id, p_password)` | ✅ | 退避表から復元 |
| `admin_list_deleted(p_password)` | ✅ | 復元候補の一覧（最大50件） |
| `admin_check(p_password)` | ❌ **内部専用** | パスワード照合。上記4つから呼ばれる |
| `admin_norm(p_text)` | ❌ **内部専用** | 入力の正規化 |

**復元は枠数上限を検査しない。** もともと成立していた状態に戻す操作であり、上限で弾くと誤削除から復旧できなくなるため。削除している間に他のグループがその枠を取っていた場合は `SLOT_TAKEN` を返す。

### 14.4 権限付与の落とし穴

**Supabase は `public` スキーマに作られた関数に対して、デフォルト権限で `anon` / `authenticated` / `service_role` に EXECUTE を自動付与する。** そのため `revoke all on function ... from public` だけでは剥がれず、内部専用のつもりの関数が PostgREST 経由で公開されてしまう。

内部専用の関数は**ロールを名指しで revoke すること**。

```sql
revoke all on function admin_check(text) from public, anon, authenticated;
```

実プロジェクトで `pg_proc.proacl` を確認して判明した（2026-08-24）。`has_function_privilege('anon', p.oid, 'EXECUTE')` で検証できる。

### 14.5 画面（管理モード）

- URL に `#admin` を付けて開いたときだけ入口が現れる。参加者に配る URL には付けない。
- 管理パスワードは **`sessionStorage`** に置く。`localStorage` にすると、端末を人に貸したときに管理権限まで貸すことになる。タブを閉じれば失効する。
- 管理モード中は**ヘッダーの地色を変え、「管理モード（終了する）」のバッジを出す**。参加者に端末を渡す前に気づけるようにするため。
- 予約済みセルをタップすると **PIN なしで削除**できる。**キャンセル期限切れの予約も消せる**（期限を過ぎた予約を消せることが管理モードの主目的のため）。
- 「削除履歴」から復元できる。
- 参加者用のキャンセルモーダルと DOM を共有しているため、**開くたびに見出しとボタンの文言を戻すこと**。戻し忘れると参加者に「予約の削除（管理）」と表示される。
- `hidden` 属性による非表示は、`.hd-row { display: flex }` のような**表示指定に詳細度で負ける**。管理バーには `[hidden]` を明示的に打ち消す規則が要る（`.overlay[hidden]` と同じ理由）。

**管理者が削除した枠は即座に他のグループが予約できる。** 削除は `reservations` の行を実際に消すため、次のポーリング（最大30秒）で「空」として現れる。その間に誰かが取ると復元は `SLOT_TAKEN` で失敗する。**論理削除は「必ず戻せる」ではなく「戻せることが多い」**である。取られた場合は、その新しい予約を先に管理モードで削除してから復元する。

### 14.6 管理パスワードの保管

平文は `.env.local`（gitignore 済み）の `ADMIN_PASSWORD` に置く。**リポジトリには絶対に含めない。** DBにはハッシュのみを保存し、平文は再表示できない。紛失した場合は再生成して `admin_settings` を上書きする。


---

## 15. 過去記録の凍結と訂正台帳

使用した部屋の申請根拠として予約記録を使うため、**開始時刻を過ぎた行を「動かない事実」にする**（§13 決定事項 #13）。

### 15.1 何を保証するか

`reservations` に対する `insert` / `update` / `delete` は、対象行の `start_at` が現在時刻を過ぎている場合、**トリガーで拒否される**（`RECORD_FROZEN`）。

これは RPC 層ではなく**テーブルのトリガー**なので、次のすべてに等しく効く。

- 参加者の操作
- 管理モードの削除・復元
- **Supabase ダッシュボードからの直接操作**
- SQL Editor での手打ち

開始時刻がまだ来ていない行は、従来どおり自由に変更できる。凍結は過去にだけ効く。

### 15.2 訂正の扱い

凍結は「変更禁止」ではなく「**理由なしの変更を禁止**」である。当日の口頭でのやりとり（部屋を交換した、予約し忘れた）を申請に反映できないと、記録の正確さがかえって損なわれるため。

訂正は次の3つの RPC 経由でのみ行う。いずれも管理パスワードと**理由（1〜200文字）**が必須で、変更内容は台帳に記録される。

| 関数 | 用途 |
|---|---|
| `admin_amend_group_name(p_id, p_group_name, p_reason, p_password)` | 使用者名の訂正 |
| `admin_amend_remove(p_id, p_reason, p_password)` | 使わなかった記録を外す |
| `admin_amend_add(p_room_id, p_start_at, p_group_name, p_reason, p_password)` | 予約せず使われた分を足す |
| `admin_list_ledger(p_password)` | 台帳の閲覧（最新100件） |

`admin_amend_add` で足した記録には **PIN が無い**。過去の枠なので参加者がキャンセルすることはない（`cancel_reservation` は `TOO_LATE` で弾く）。このため `deleted_reservations.pin_hash` は **nullable でなければならない**。`not null` にすると、PIN の無い記録を管理削除したときに退避が失敗し、削除だけが通る。

`admin_amend_remove` は退避表に移さない。台帳の `before_row` に行全体が残るためそちらが復元の材料になる。退避表に入れると `admin_restore_reservation` から理由なしで戻せてしまい、凍結の意味が薄れる。

### 15.3 台帳

`reservation_ledger` は**追記のみ**。RLS を有効にしてポリシーを作らず、さらに次の2つのトリガーで DB レベルの追記専用を強制する。

- `before update or delete ... for each row` … 行単位の書き換えを拒否
- `before truncate ... for each statement` … **`TRUNCATE` は行トリガーを通らない**ため、文レベルでも塞ぐ

`occurred_at` の既定値 `now()` は**トランザクション開始時刻**を返す。1トランザクションで複数の訂正を行うと同値になるため、並び順は `occurred_at` だけでなく**連番 `id` を併用**して確定させる。

### 15.4 訂正フラグの受け渡し

訂正中であることは `app.amend_reason` というトランザクションローカルの設定で示す。`set_config(..., true)` なので commit / rollback のどちらでも自動的に消え、次のリクエストに漏れない。

各訂正 RPC は**処理を終えたら明示的に空へ戻す**（`admin_end_amend`）。PostgREST は1リクエスト＝1トランザクションなので通常は問題にならないが、複数の操作を1トランザクションに束ねられた場合に、最初の理由が2件目以降に流用されるのを防ぐ。

### 15.5 訂正の手順（画面を作らない場合）

訂正用の画面は用意していない（§13 決定事項 #14）。合宿後に申請用の訂正が必要になったら、Supabase ダッシュボードの SQL Editor から訂正 RPC を呼ぶ。RPC を経由すればパスワードの照合と理由の必須チェックが働き、台帳にも残る。

対象の `id` を調べる:

```sql
select id, group_name, room_id,
       (start_at at time zone 'Asia/Tokyo')::text as jst
  from reservations
 where session_date = '2026-09-02'
 order by start_at, room_id;
```

使用者名を直す / 使わなかった記録を外す / 予約せず使われた分を足す:

```sql
select admin_amend_group_name('<id>', '正しいグループ名', '当日部屋を交換したため', '<管理パスワード>');
select admin_amend_remove('<id>', '実際には使用しなかったため', '<管理パスワード>');
select admin_amend_add(3::smallint, timestamptz '2026-09-02 22:00+09',
                       'グループ名', '予約せず使用したため', '<管理パスワード>');
```

台帳を確認する:

```sql
select occurred_at, action, reason, before_row, after_row
  from reservation_ledger order by occurred_at desc, id desc;
```

**生の SQL で直接書き換えてはならない。** 凍結トリガーが `RECORD_FROZEN` で拒否する。どうしても一括で処理する必要がある場合のみ、1トランザクション内で `set_config('app.amend_reason', '<理由>', true)` を立ててから DML を実行する。この場合も台帳には残る。

### 15.6 受け入れたリスク

**訂正 RPC は anon key で誰でも呼べる面に増える。** 管理パスワードを破られた場合の被害が「今の予約を消される（復元可）」から「**過去の記録を捏造される**」に広がる。申請の根拠を守るという目的に対して、これは無視できないトレードオフである。

台帳に全ての訂正が残るため**捏造は必ず検出できる**。この検出可能性をもって受容する。より強く守るなら、訂正 RPC を anon に公開せず、ダッシュボードから `set_config('app.amend_reason', ...)` を立てたトランザクションで行う構成に切り替える。


---

## 16. 一般公開前の自動初期化

準備期間中に入れたテストデータを、URL を一般公開する時刻に自動で消す。

**目標時刻: 2026-09-02(水) 14:00 JST**（§13 決定事項 #15）。この時刻から参加者がアクセスを始める。

### 16.1 何を消して何を残すか

| 対象 | 扱い |
|---|---|
| `reservations` | **削除**（`reservation_secrets` と `reservation_devices` は cascade で消える）|
| `deleted_reservations` | **削除** |
| `reservation_ledger` | **削除** |
| `slots` / `rooms` | **残す**（日程と部屋の定義そのもの）|
| `admin_settings` | **残す**（管理パスワード）|

削除のあと、**同じトランザクションで主催者の固定枠を投入する**（§16.6）。

### 16.2 実行の仕組み

`pg_cron` でDB内から実行する。誰かの端末が起動している必要はない。

**cron 式で時刻を指定していない。** 毎分 `reset_before_launch()` を呼び、関数側で `now() >= '2026-09-02 14:00+09'` を判定する。理由は、`cron.timezone` の解釈を取り違えた場合に**早発して本番データを消す**のを防ぐため。毎分走らせておけば、タイムゾーンの解釈がどうであれ目標時刻の1分以内に実行される。実行後は `cron.unschedule` で自分の登録を外し、二度と走らない。

処理本体は `do_launch_reset()` に分けてある。時刻を待たずに、巻き戻し前提のトランザクション内で動作確認できるようにするため。

どちらの関数も **anon / authenticated には EXECUTE を与えない**。

実行の記録は `cron.job_run_details` に自動で残る。

```sql
select jobid, status, return_message, start_time
  from cron.job_run_details
 where jobid = (select jobid from cron.job where jobname = 'reset-before-launch')
 order by start_time desc limit 20;
```

### 16.3 台帳の追記専用に開けた穴

初期化は `reservation_ledger` の追記専用トリガー（§15.3）を**一時的に無効化して**削除する。つまり**所有者権限には台帳を消す経路がある**。

これは避けられない。トリガーの無効化はテーブル所有者にしかできず、anon からこの経路には到達できないため、§15 の保証（参加者・管理モード・ダッシュボードの通常操作からは書き換え不可）は維持される。ただし「台帳は絶対に消えない」ではなく「**所有者が意図的に消さない限り消えない**」が正確な表現である。

### 16.4 時刻や内容を変える場合

```sql
-- 予定の確認
select jobname, schedule, active from cron.job where jobname = 'reset-before-launch';

-- 中止する
select cron.unschedule('reset-before-launch');

-- 時刻を変える: sql/07_launch_reset.sql の v_target を書き換えて再実行する
```

### 16.5 注意

- **この時刻より前に入った予約は、本物であっても消える。** 参加者に URL を知らせるのは初期化の後にすること。
- **URL は既に技術的には公開されている。** リポジトリが public で GitHub Pages に配信しているため、URL を知った人は今でも予約できる。「一般開放」は告知の話であり、アクセス制御ではない。
- 初期化は**取り消せない**。退避表も台帳も消えるため、復元手段は残らない。

### 16.6 主催者の固定枠

初期化と同時に、次の予約を自動で入れる。

| 項目 | 値 |
|---|---|
| グループ名 | `PA講習会` |
| 部屋 | `B2大`（`rooms.name` で引く） |
| 枠 | 2026-09-03(木) 22:00 と 23:00 の2枠（＝22:00〜24:00） |

- **削除と同一トランザクションで投入する。** 別々に実行すると、その隙間に参加者が同じ枠を取れてしまう。`do_launch_reset()` の中に入れているのはこのため。
- **PIN はその場で作った乱数で、誰にも渡さない。** 参加者に消されては困る枠だからである。主催者が取り消すときは管理モード（§14）から削除する。
- **部屋は `rooms.name` で引く。** 見つからなければ `raise warning` を出して固定枠だけを諦める。ここで例外にすると初期化そのものが巻き戻り、cron が毎分再試行して永久に完了しない。**部屋名を変えたら `do_launch_reset()` の `v_fixed_room` も直すこと。**
- 想定の枠数が入らなかった場合も `raise warning` を出す（スロットの日付を変えて固定枠の日時を直し忘れたときにここへ来る）。
- `do_launch_reset()` を二度呼んでも重複しない（同じトランザクションで先に `reservations` を全削除しているため。`on conflict do nothing` はその保険）。

時刻を待たずに確かめる場合は、巻き戻し前提で呼ぶ。

```sql
begin;
  select do_launch_reset();
  select r.group_name, rm.name, r.start_at at time zone 'Asia/Tokyo'
    from reservations r join rooms rm on rm.id = r.room_id order by r.start_at;
rollback;   -- 必ず rollback すること
```
- 固定枠は FR-04 の枠数上限を通らない（RPC ではなく直接 insert のため）。`PA講習会` の名前で参加者が同じセッションに予約しようとすると上限に当たるが、実害はないので許容する。

---

## 17. スタジオの機材

サイト下部に、各スタジオの備え付け機材を参照できる欄を置く。ボタン（B2／D1／D2／D3／E1／E2／E3）を押すと、その部屋の広さと機材が表に出る。初期表示は B2。

### 17.1 どこに持つか

**DB ではなく `app.js` の `GEAR` 配列に持つ。** 理由は3つ。

- 機材は予約の整合性に一切関わらない。参照するだけの静的な案内文であり、`rooms` に列を足すと RLS と RPC の検討対象が無意味に増える。
- 通信に依存しないので、Supabase が落ちていても、`config.js` が未設定でも表示できる。`boot()` の設定チェックより**前**に `renderGear()` を呼んでいるのはこのため。
- 更新は合宿ごとに一度あるかどうかで、しかも主催者ではなく開発者が行う。デプロイと同じ頻度なら配列で足りる。

### 17.2 `rooms` との関係

`GEAR` の `room`（`'B2'` など）と `rooms.name`（`'B2大'` など）は**独立している**。突き合わせていないので、部屋の並び順や表記を変えてもこちらは追随しなくてよい。逆に、機材欄に出る部屋と予約できる部屋を一致させる責任は人間の側にある。

### 17.3 表記について

原資料（スタジオの掲示）からの転記にあたり、次の整形を行った。**機材名そのものは変えていない。**

- 「ギターアンプ／ベースアンプ／ドラム／ミキサー／スピーカー」の分類ラベルを付けた。原資料には無く、こちらで補ったもの。
- 型番の区切りを揃えた（`JCM2000-DSL50` → `JCM2000 DSL50`）。
- スピーカーの台数を `×2` に統一した。

### 17.4 変更する場合

`app.js` の `GEAR` 配列だけを書き換える。部屋を増やす場合も配列に足せばボタンが1つ増える。CSS の `.gear-tab` は `flex-wrap` なので、狭い画面では自動的に2段になる。
