# 合宿 部屋予約システム 要件定義書

**版数**: v2 ／ **最終更新**: 2026-08-23 ／ **状態**: 全項目確定済み（未決事項なし）

> **この文書の使い方（コーディングエージェント向け）**
> 本書は実装の唯一の仕様源です。v2 時点で未決事項はすべて解消されています。
> 仕様に曖昧さや矛盾を見つけた場合は、勝手に解釈せず質問すること。
> 本書の記述と異なる実装を行う必要が生じた場合は、コードを変更する前に本書を改訂すること。

---

## 1. 目的とスコープ

サークル合宿において、5つの部屋を1時間単位で交代利用するための予約システムを構築する。
参加者は代表名（グループ名）で任意の空き枠を予約でき、予約状況は全員がリアルタイムに近い形で閲覧できる。

**運用期間**: 2026-09-01(火) と 2026-09-02(水) の2晩。各晩 22:00〜翌07:00（JST）。

### スコープ内
- 部屋 × 時間枠のグリッド表示（各晩 22:00〜翌07:00）
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
- **主催者用の一括操作UI**（全消し・CSV出力）。Supabase ダッシュボードで代替する

---

## 2. 用語定義

| 用語 | 定義 |
|---|---|
| 部屋 (room) | 予約対象となる物理的な部屋。全5室。 |
| スロット (slot) | 予約の最小時間単位。1時間、毎正時開始。 |
| セル (cell) | 部屋 × スロットの組み合わせ。予約の実体はセル1つに対応する。 |
| **セッション (session)** | **1晩の利用単位。22:00 から翌07:00 までの連続した9スロットを1セッションとする。`session_date` はその晩の開始日（JST）で識別する（例：9/1 22:00 も 9/2 03:00 も session_date = 2026-09-01）。** |
| グループ | 予約主体。代表者名またはグループ名の文字列で識別する。 |
| PIN | 予約時にグループが設定する4桁数字。キャンセル時の本人確認に使う。 |

> **セッションという概念を導入した理由**：本システムの全スロットは深夜をまたぐ。暦日で区切ると 9/1 22:00 と 9/2 01:00 が別の日になり、「1日あたり2枠」の上限が1晩で実質4枠になってしまう。日付タブの分割、枠数上限の判定、時刻表示のすべてをセッション単位で行う。

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
- 横軸を部屋（5列）、縦軸を時間スロット（9行）とするグリッドを表示する。
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
- セッションをまたげば別枠として数える（9/1夜に2枠、9/2夜に2枠、計4枠まで可）。
- 同一スロットに同一グループが複数部屋を予約することは禁止する。
- 判定はグループ名の**正規化キー**（`group_key`）で行う。正規化は「前後空白の除去 → Unicode NFKC 正規化 → 小文字化」の順で行い、大文字小文字・全角半角・半角カナの表記揺れを同一グループとみなす（「Aチーム」「Ａチーム」「aチーム」は同一）。
- **同時実行下でも上限を超えてはならない**（実現方法は第8章、検証は第12章-12）。

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
create extension if not exists pgcrypto;

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
```

### 設計意図（変更してはならない点）

1. **PINハッシュの分離**：フロントエンドが `select *` を書いてもハッシュが漏れない構造にするため。この分離は変更しないこと。
2. **`session_date` の複合外部キー**：予約の `session_date` が `slots` の定義と食い違う可能性をアプリ層ではなくDB制約で排除する。単独の `start_at` FK では session_date の正しさを保証できない。
3. **`group_key` 生成列**：正規化ルールをDBに1箇所だけ持たせる。フロントとRPCで正規化ロジックが二重管理されると、必ずどちらかがずれる。

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

-- 読み取りのみ許可
create policy p_rooms_select on rooms        for select to anon using (true);
create policy p_slots_select on slots        for select to anon using (true);
create policy p_res_select   on reservations for select to anon using (true);

-- reservation_secrets にはポリシーを一切作らない（= anon からアクセス不可）
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
| 参加者が偽のグループ名を次々に使って枠を占拠する | レート制限は実装しない（無料プランでの実装が困難）。抑止は「1晩2枠の上限」と「主催者がダッシュボードから削除できること」に依存する。 |
| 4桁PINの総当たり | `pg_sleep(0.5)` のみで許容する（7.4-4）。 |
| クリックジャッキング | GitHub Pages で `frame-ancestors` を設定できないため受容する。 |
| 他人のグループ名を騙った予約 | 認証を行わない設計上、防止できない。主催者が手動で修正する。 |

---

## 8. API（RPC）

クライアントは以下の2関数のみを書き込みに使う。いずれも `security definer` かつ `set search_path = public`。

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
  p_pin        text
) returns uuid
```

処理順序：

1. `p_pin` が `^[0-9]{4}$` に一致しなければ `INVALID_PIN` を raise
2. `btrim(p_group_name)` の長さが 1〜30 の範囲外なら `INVALID_GROUP_NAME` を raise（`chk_group_name` 制約に到達させると `check_violation` になり、機械可読コードを返せないため関数側で先に弾く）
3. `slots` から `p_start_at` の行を取得し `session_date` を得る。行がなければ `NO_SUCH_SLOT` を raise
4. **`p_start_at <= now()` なら `PAST_SLOT` を raise**（FR-01のグレーアウトはUI上の便宜にすぎず、サーバ側の検証を省略してはならない）
5. 正規化キー `v_group_key := lower(normalize(btrim(p_group_name), NFKC))` を算出する。**生成列 `group_key` と同一の式でなければならない**
6. **`perform pg_advisory_xact_lock(1, hashtext(v_group_key));`** を実行する
7. `reservations` を `group_key = v_group_key and session_date = <手順3の値>` で数え、2以上なら `LIMIT_EXCEEDED` を raise
8. `reservations` に insert（`group_name` はトリム済みの値。`group_key` は生成列なので指定しない）。例外を捕捉して分岐する
   - `unique_violation` → `get stacked diagnostics` で制約名を取得し、`uq_group_slot` なら `DUPLICATE_IN_SLOT`、それ以外（`uq_room_slot`）なら `SLOT_TAKEN` を raise
   - `foreign_key_violation` → `NO_SUCH_ROOM` を raise（存在しない `room_id` を送られた場合）
9. `reservation_secrets` に `crypt(p_pin, gen_salt('bf'))` を insert

**手順6が本設計の要**。これがないと「数える → insert」の間に別トランザクションが割り込み、同一グループが同時送信で3枠目・4枠目を取得できてしまう（§5 の枠数上限要件を満たさなくなる）。advisory lock は**同一グループ名のリクエスト同士のみを直列化**し、無関係なグループはブロックしない。`hashtext` が衝突した場合の実害は「無関係な2グループが一瞬待たされる」ことだけである。ロックはトランザクション終了時に自動解放されるため、明示的な解放は不要。

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
| メイン | ヘッダー（合宿名・現在時刻・更新ボタン）／セッションタブ／予約グリッド／凡例 |
| 予約モーダル | 対象セル名の表示、グループ名・PIN の入力、キャンセル期限の注記、確定／閉じる |
| 削除モーダル | 予約内容の表示、PIN入力、削除／閉じる |
| トースト | 成功・失敗メッセージの表示（3秒で自動消滅） |

### 9.1 セッションタブ

- タブは2つ：「**9/1(火)の夜**」「**9/2(水)の夜**」。
- タブは `slots.session_date` の distinct 値から生成する。**日付も曜日もハードコードしない。** 曜日は `Intl.DateTimeFormat('ja-JP', { timeZone: 'Asia/Tokyo', weekday: 'short' })` で導出する。
- 初期表示は、サーバ時刻（FR-06）から見て「まだ終わっていない最も早いセッション」を選択する。すべて終了していれば最後のセッションを選択する。

### 9.2 時刻表示

- 各行のラベルは `22:00` `23:00` `翌00:00` `翌01:00` … `翌06:00` の9行。
- 「翌」を付ける判定は、`start_at` のJST日付が当該行の `session_date` と異なるかどうかで行う。
- **26時制（24:00、25:00 …）は採用しない。** 初見の参加者が戸惑うため。
- すべての時刻整形に `timeZone: 'Asia/Tokyo'` を明示する。端末のTZ設定に依存させない。

### 9.3 グリッド

- 5列が画面幅に収まるようにする（横スクロールさせない。スマホ縦持ちで判読可能なこと）。
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
| `LIMIT_EXCEEDED` | 枠数上限の超過 | 「1グループの予約は**その晩あたり**最大2枠までです。既存の予約をキャンセルしてください」 | — |
| `PAST_SLOT` | 開始済みスロットへの予約 | 「この時間帯はすでに開始しています」 | グリッドを即再取得 |
| `NO_SUCH_SLOT` | 予約対象外の日時 | 「この時間帯は予約対象外です」 | グリッドを即再取得 |
| `TOO_LATE` | 開始30分前を過ぎたキャンセル | 「開始30分前を過ぎたためキャンセルできません」 | グリッドを即再取得 |
| `INVALID_PIN`（作成時） | PIN形式不正 | 「PINは数字4桁で入力してください」 | — |
| `INVALID_GROUP_NAME` | グループ名が1〜30文字の範囲外 | 「グループ名は1〜30文字で入力してください」 | — |
| `NO_SUCH_ROOM` | 存在しない部屋ID（改ざん時のみ） | 「その部屋は存在しません」 | グリッドを即再取得 |
| `INVALID_PIN`（削除時） | PIN不一致、または予約が存在しない | 「PINが違います」 | — |
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
sql/04_seed.sql     rooms 5件、slots 18件
sql/test_acceptance.sh  受け入れ基準のうちDBで検証できる項目の自動テスト
tools/localdev.sh       ローカル検証環境をワンコマンドで起動（開発専用）
tools/devserver.py      ローカルPG に対する PostgREST 互換ミニサーバ（開発専用）
```

`tools/` は **Supabase を用意する前に手元で画面を確認するための開発専用ツール**であり、GitHub Pages には配置しない。不要なら削除してよい。使い方:

```
./tools/localdev.sh            # ローカルPGを立てて http://127.0.0.1:8777 で配信
./tools/localdev.sh stop       # 停止と後片付け
```

- フロントエンド：GitHub Pages（リポジトリルート配信）
- バックエンド：Supabase 無料プラン
- `config.js` の値は公開前提のためリポジトリにコミットしてよい。
- SQLは `01` → `04` の順に Supabase SQL Editor で実行する。

### 11.2 seed.sql

日程を1箇所で変更できるようにする。

```sql
insert into rooms (id, name, sort_order) values
  (1,'部屋1',1),(2,'部屋2',2),(3,'部屋3',3),(4,'部屋4',4),(5,'部屋5',5);

-- 22時〜30時(=翌6時)開始の9スロット × 2セッション = 18行
insert into slots (start_at, session_date)
select (d + make_interval(hours => h)) at time zone 'Asia/Tokyo', d
from (values ('2026-09-01'::date), ('2026-09-02'::date)) as s(d),
     generate_series(22, 30) as h;
```

- `(timestamp) at time zone 'Asia/Tokyo'` により、JSTの壁時計時刻を正しく `timestamptz`（UTC）へ変換する。
- 日程を変更する場合は `values` 句の日付のみを書き換える。時間帯を変更する場合は `generate_series` の範囲のみを書き換える。
- 部屋名を実際の部屋番号に変える場合は `rooms` の insert 文のみを書き換える。

### 11.3 運用上の注意

- **予約が入っているスロット行は削除できない**（`on delete restrict`）。主催者が時間帯を削る場合は、先に該当スロットの予約を削除する必要がある。これは事故防止のための意図的な設計である。
- 予約の削除は物理削除であり、復元手段はない。主催者が誤って削除した場合は再作成する（PINは新たに設定し直す）。

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
8. iPhone実機（Safari）で5列のグリッドが横スクロールなしに判読・操作できる。
9. 全端末で表示時刻がJSTで一致する（端末のTZ設定を変更しても表示が変わらないこと）。
10. **DevTools から `rpc/create_reservation` を開始済みスロットに対して直接呼ぶと `PAST_SLOT` で失敗する**（UIのグレーアウトを迂回できないこと）。
11. **開始30分を切った予約は、正しいPINを入力しても `TOO_LATE` でキャンセルできない。**
12. **同一グループ名で3件の予約要求を同時送信しても、その晩の保有枠が2を超えない**（advisory lock の検証。`xargs -P` などで並列にRPCを叩いて確認する）。
13. **「Aチーム」と「Ａチーム」が同一グループとして枠数上限に合算される。**
14. **9/1 22:00 と 9/2 01:00 が同一セッションとして上限にカウントされる**（暦日で分割されないこと）。
15. **外部CDNへのリクエストが1件も発生しない**（DevTools の Network タブで、自オリジンと Supabase 以外への通信がゼロであること）。

---

### 検証状況（2026-08-23 時点）

`sql/test_acceptance.sh` により、DBで検証できる項目は**ローカルの PostgreSQL 18.4 上で全21アサーションが通過済み**。ブラウザ実機（375px 幅）での画面確認も実施し、基準7・8とエラー表示の全経路を確認済み。

**未検証で、Supabase 上で必ず確認すべき項目**:

| 項目 | 理由 |
|---|---|
| `normalize(..., NFKC)` 生成列 | ローカルは PG18。Supabase の PG バージョン（15/17）で通ることを確認する |
| `Date` レスポンスヘッダの露出 | FR-06 のサーバ時刻同期が依存する。読めない場合の縮退動作は実装済み |
| 基準8（iPhone実機 Safari） | ブラウザのモバイルエミュレーションでの確認に留まる |
| 基準9（端末TZを変えても表示が一致） | `Intl` に `timeZone` を明示済みだが実機で確認する |

なお advisory lock については、ロックを外した対照関数と同条件で比較する実験を行い、**ロックなしでは8並列で上限2枠を無視して8枠取得できる**こと、ロックありでは常に2枠に収まることを確認済み。

---

## 13. 決定事項の記録

v1 で `【要確認】` としていた項目は、2026-08-23 にすべて確定した。**未決事項は存在しない。**

| # | 項目 | 確定値 | 決定日 |
|---|---|---|---|
| 1 | 合宿の日程 | 2026-09-01(火)夜 ／ 2026-09-02(水)夜 の2晩 | 2026-08-23 |
| 2 | 予約可能な時間帯 | 各晩 22:00〜翌07:00（1時間×9スロット） | 2026-08-23 |
| 3 | 部屋の名称 | 「部屋1」〜「部屋5」（seed.sql の書き換えで変更可） | 2026-08-23 |
| 4 | 1グループの保有上限 | **1セッション（1晩）あたり2枠** | 2026-08-23 |
| 5 | キャンセル可能期限 | **開始30分前まで**（作成は開始時刻まで可） | 2026-08-23 |
| 6 | PINの桁数 | 4桁 | 2026-08-23 |
| 7 | 主催者用の一括操作 | 不要（Supabase ダッシュボードで代替） | 2026-08-23 |
| 8 | メモ機能 | **廃止**（列・制約・引数・表示をすべて削除） | 2026-08-23 |
| 9 | フロントエンドの依存構成 | **supabase-js を使わず fetch で直叩き**（CDN依存ゼロ） | 2026-08-23 |
| 10 | 予約の変更（枠移動） | 提供しない。キャンセル後に取り直す | 2026-08-23 |

### v1 からの主な仕様変更

実装済みコードがある場合、以下は破壊的変更となる。

- `reservations.note` と `chk_note`、`create_reservation` の `p_note` 引数を**削除**
- `slots.session_date` を**追加**し、`reservations` から複合外部キーで参照
- `reservations.group_key` 生成列を**追加**（`uq_group_slot` の定義もこれに変更）
- `create_reservation` に advisory lock、`PAST_SLOT`、`NO_SUCH_SLOT`、`DUPLICATE_IN_SLOT` を追加
- `cancel_reservation` に `TOO_LATE` を追加
- 枠数上限の単位を「全体で2枠」から「1セッションあたり2枠」に変更
