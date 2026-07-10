# CAST9 バックエンド設計書(アーティファクト版 → 本番Supabase移行)

現在のプロトタイプ(cast9.html / cast9-admin.html)は、ブラウザ内の疑似ストレージ(`cast9_profiles` などのキー)にJSONで全データを保持している。本番化にあたり、この構造をそのままSupabase(PostgreSQL)のテーブル設計に落とし込む。

---

## 1. 全体方針

- **認証**:Supabase Auth を使用。出演者アカウントと依頼者(企業/個人)アカウントは別ロールとして管理する
- **権限分離**:Row Level Security (RLS) を全テーブルで有効化し、「本人と管理者以外は書けない・見えない」を徹底する
- **管理者**:専用の `admin_users` テーブルで判定し、Supabase Auth の管理者権限とは別に、アプリ内ロールとして扱う(cast9-admin.html は Service Role を経由するサーバー関数越しにアクセスさせる)

---

## 2. テーブル定義(SQL)

```sql
-- =========================================
-- 1. アカウント関連
-- =========================================

-- 出演者アカウント(Supabase Authのuser_idと1:1)
-- ★本人が自由に編集してよい項目のみ。信用スコアに関わる数値は含めない(下のperformer_statsに分離)
create table performers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  genre text not null check (genre in ('model','actor','beginner')),
  area text not null,
  bio text default '',
  video_url text default '',
  avatar_path text, -- Supabase Storageのパス
  created_at timestamptz default now()
);

-- 出演者の信用スコア関連データ(本人は書き込み不可・Edge Function/管理者のみ更新)
create table performer_stats (
  performer_id uuid primary key references performers(id) on delete cascade,
  completion numeric default 100,   -- 完遂率
  delay numeric default 0,          -- 遅刻率
  reply numeric default 90,         -- 返信速度
  penalty_points numeric default 0,
  minor_violation_count integer default 0,
  ban_candidate boolean default false,
  suspended boolean default false,
  ban_reason text,
  total_jobs integer default 0,
  big_client boolean default false,
  updated_at timestamptz default now()
);

-- 出演者の案件タイプ別料金
create table performer_job_types (
  id uuid primary key default gen_random_uuid(),
  performer_id uuid not null references performers(id) on delete cascade,
  name text not null,
  price integer not null check (price > 0)
);

-- 出演可能な曜日
create table performer_availability_days (
  performer_id uuid not null references performers(id) on delete cascade,
  day text not null check (day in ('月','火','水','木','金','土','日')),
  primary key (performer_id, day)
);

-- 出演可能な時間帯
create table performer_availability_times (
  performer_id uuid not null references performers(id) on delete cascade,
  time_slot text not null,
  primary key (performer_id, time_slot)
);

-- 出演NG条件
create table performer_ng_conditions (
  id uuid primary key default gen_random_uuid(),
  performer_id uuid not null references performers(id) on delete cascade,
  condition text not null
);

-- 依頼者アカウント(企業 or 個人)
-- ★本人編集可能な項目のみ
create table requesters (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  type text not null check (type in ('company','individual')),
  name text not null,
  industry text default '',
  area text not null,
  created_at timestamptz default now()
);

-- 依頼者の信用スコア関連データ(本人は書き込み不可)
create table requester_stats (
  requester_id uuid primary key references requesters(id) on delete cascade,
  completion numeric default 100,
  delay numeric default 0,
  reply numeric default 90,
  penalty_points numeric default 0,
  total_jobs integer default 0,
  suspended boolean default false,
  ban_reason text,
  updated_at timestamptz default now()
);

-- =========================================
-- 2. 案件・チャット
-- =========================================

-- チャットスレッド(出演者 × 依頼者 の組み合わせで1つ)
create table chat_threads (
  id uuid primary key default gen_random_uuid(),
  performer_id uuid not null references performers(id) on delete cascade,
  requester_id uuid not null references requesters(id) on delete cascade,
  created_at timestamptz default now(),
  unique (performer_id, requester_id)
);

-- メッセージ(テキスト・画像・システム通知を1テーブルで管理)
create table messages (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references chat_threads(id) on delete cascade,
  sender_type text not null check (sender_type in ('performer','requester','system')),
  msg_type text not null check (msg_type in ('text','image','quote','system')),
  text_content text,
  image_path text,          -- Supabase Storageのパス(署名付きURLで配信)
  created_at timestamptz default now()
);

-- 見積もり(messagesの msg_type='quote' に対応する詳細データ)
create table quotes (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references messages(id) on delete cascade,
  thread_id uuid not null references chat_threads(id) on delete cascade,
  job_type_name text not null,
  amount integer not null check (amount > 0),
  desired_date text,
  status text not null default 'pending' check (status in ('pending','accepted','cancelled','declined')),
  payment_status text default 'unpaid' check (payment_status in ('unpaid','escrowed','released','refunded')),
  created_at timestamptz default now(),
  resolved_at timestamptz
);

-- =========================================
-- 3. レビュー
-- =========================================

create table reviews (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null references quotes(id) on delete cascade,
  target_type text not null check (target_type in ('performer','requester')),
  target_id uuid not null, -- performers.id または requesters.id
  rating integer not null check (rating between 1 and 5),
  comment text,
  reviewer_name text,
  created_at timestamptz default now()
);

-- =========================================
-- 4. 通報・モデレーション・監査ログ
-- =========================================

create table reports (
  id uuid primary key default gen_random_uuid(),
  target_type text not null check (target_type in ('performer','requester')),
  target_id uuid not null,
  reporter_type text not null,
  reason text not null,
  status text not null default '未対応' check (status in ('未対応','対応済み','却下')),
  severity text check (severity in ('軽度','重大')),
  resolution_note text,
  evidence jsonb default '[]',
  notes jsonb default '[]',
  ai_suggestion jsonb,
  created_at timestamptz default now()
);

create table image_moderation_queue (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references messages(id) on delete cascade,
  reason text,
  status text not null default 'pending' check (status in ('pending','resolved_ok','resolved_removed')),
  created_at timestamptz default now()
);

create table admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz default now()
);

create table admin_logs (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid references auth.users(id),
  action_text text not null,
  created_at timestamptz default now()
);
```

---

## 3. RLS(Row Level Security)ポリシー

```sql
alter table performers enable row level security;
alter table performer_stats enable row level security;
alter table requesters enable row level security;
alter table requester_stats enable row level security;
alter table chat_threads enable row level security;
alter table messages enable row level security;
alter table quotes enable row level security;
alter table reviews enable row level security;
alter table reports enable row level security;
alter table image_moderation_queue enable row level security;
alter table admin_logs enable row level security;

-- 管理者判定用の共通関数
create function is_admin() returns boolean as $$
  select exists (select 1 from admin_users where user_id = auth.uid());
$$ language sql security definer;

-- --- performers(本人が自由編集できる項目) ---
create policy "performers_public_read" on performers
  for select using (true); -- 停止判定はperformer_statsを見て行う(下記)
create policy "performers_owner_write" on performers
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "performers_owner_insert" on performers
  for insert with check (user_id = auth.uid());
create policy "performers_admin_all" on performers
  for all using (is_admin());

-- --- performer_stats(信用スコア関連。本人は読むだけ、書き込みは一切不可) ---
create policy "performer_stats_read_all" on performer_stats
  for select using (true);
-- ★insertポリシーもupdateポリシーも意図的に用意しない
--   → authenticatedロールでは一切書き込めず、Edge Function(Service Role)からのみ更新可能
create policy "performer_stats_admin_all" on performer_stats
  for all using (is_admin());

-- --- requesters / requester_stats(依頼者側も同じ考え方) ---
create policy "requesters_public_read" on requesters for select using (true);
create policy "requesters_owner_write" on requesters
  for update using (user_id = auth.uid());
create policy "requesters_owner_insert" on requesters
  for insert with check (user_id = auth.uid());
create policy "requesters_admin_all" on requesters for all using (is_admin());

create policy "requester_stats_read_all" on requester_stats for select using (true);
create policy "requester_stats_admin_all" on requester_stats for all using (is_admin());

-- --- chat_threads ---
create policy "threads_participant_only" on chat_threads
  for all using (
    exists (select 1 from performers p where p.id = performer_id and p.user_id = auth.uid())
    or exists (select 1 from requesters r where r.id = requester_id and r.user_id = auth.uid())
    or is_admin()
  );

-- --- messages ---
-- 閲覧・テキスト送信は当事者同士で自由に。ただし画像メッセージ(msg_type='image')は
-- クライアントから直接INSERT不可にし、モデレーションを挟むEdge Function経由のみに限定する
create policy "messages_select_participant" on messages
  for select using (
    exists (
      select 1 from chat_threads t
      join performers p on p.id = t.performer_id
      join requesters r on r.id = t.requester_id
      where t.id = thread_id and (p.user_id = auth.uid() or r.user_id = auth.uid())
    ) or is_admin()
  );

create policy "messages_insert_participant_nonimage" on messages
  for insert with check (
    msg_type <> 'image'
    and exists (
      select 1 from chat_threads t
      join performers p on p.id = t.performer_id
      join requesters r on r.id = t.requester_id
      where t.id = thread_id and (p.user_id = auth.uid() or r.user_id = auth.uid())
    )
  );
-- image_moderation_queueへの登録とmessages(msg_type='image')への挿入は
-- send-image-message Edge Function(Service Role)のみが行う

-- --- quotes ---
-- 新規作成・キャンセルは当事者が可能。ただし 'accepted' への遷移は
-- 決済確定(Stripe Webhook)を経たEdge Functionのみが行えるようwith checkで制限する
create policy "quotes_select_participant" on quotes
  for select using (
    exists (
      select 1 from chat_threads t
      join performers p on p.id = t.performer_id
      join requesters r on r.id = t.requester_id
      where t.id = thread_id and (p.user_id = auth.uid() or r.user_id = auth.uid())
    ) or is_admin()
  );

create policy "quotes_insert_participant" on quotes
  for insert with check (
    status = 'pending'
    and exists (
      select 1 from chat_threads t
      join performers p on p.id = t.performer_id
      join requesters r on r.id = t.requester_id
      where t.id = thread_id and (p.user_id = auth.uid() or r.user_id = auth.uid())
    )
  );

create policy "quotes_update_cancel_only" on quotes
  for update using (
    exists (
      select 1 from chat_threads t
      join performers p on p.id = t.performer_id
      join requesters r on r.id = t.requester_id
      where t.id = thread_id and (p.user_id = auth.uid() or r.user_id = auth.uid())
    )
  )
  with check (status in ('pending','cancelled')); -- 'accepted'への変更はここでは不可

create policy "quotes_admin_all" on quotes for all using (is_admin());

-- --- reviews ---
-- 誰でも閲覧可(信用の透明性のため公開情報とする)
create policy "reviews_public_read" on reviews for select using (true);
-- ★insertポリシーは用意しない → submit-review Edge Function(Service Role)経由のみ

-- --- reports / moderation / logs ---
-- 通報の閲覧・対応は管理者のみ。投稿(insert)も直接は許可せず、
-- submit-report Edge Function が「実在するスレッドの当事者かどうか」を検証してから書き込む
create policy "reports_admin_read_write" on reports for all using (is_admin());
create policy "moderation_admin_only" on image_moderation_queue for all using (is_admin());
create policy "logs_admin_only" on admin_logs for all using (is_admin());
```

> **設計の要点**:「本人が読むだけの数値(信用スコア・停止フラグなど)」と「本人が編集してよい項目(プロフィール文章など)」を別テーブルに分離し、スコア側にはINSERT/UPDATEポリシーを一切設定しない。これにより、たとえクライアントのコードを改造されても、信用スコア・案件成立・レビュー・通報の4つは物理的にクライアントから直接操作できなくなる。すべてEdge Function(Service Roleキーを使い、RLSを迂回する)経由に集約することで、不正対応のたびに手作業で調べる手間を最初から減らせる。

---

## 4. Supabase Storage(画像)

- バケット:`chat-images`(非公開)
- パス規則:`chat-images/{thread_id}/{message_id}.jpg`
- 表示時は署名付きURL(有効期限1時間)を都度発行するEdge Functionを用意する
- アップロード前のクライアント側リサイズ・圧縮は現行の実装(長辺1200px・段階的品質調整)をそのまま流用可能

Storageのポリシーも同様に「スレッド当事者のみ読み書き可」に設定する。

---

## 5. 決済プロバイダの比較

エスクロー(依頼確定時に一時的に預かり、成立後に出演者へ払い出す)を日本国内で行う前提での比較。

| 項目 | Stripe Connect | Komoju | PAY.JP |
|---|---|---|---|
| 日本での事業実態 | あり(Stripe Japan) | あり(日本のスタートアップ発、後にNaverが買収) | あり(BASE子会社) |
| マーケットプレイス/エスクロー向け機能 | ◎ Connect機能で「預かり→複数日後に送金」が標準対応 | ○ 対応事例あり、ただしAPI・ドキュメントはStripeよりシンプル | △ 基本は即時決済向け、エスクロー用途は追加実装が必要 |
| 出演者への送金(Payout) | 銀行口座へ自動送金、KYCも組み込み(Stripe Identity連携) | 対応、ただし個人の受け取り側KYCの柔軟性はStripeに劣る | 個人受け取りは弱い(主に法人向け) |
| 決済手段の幅 | クレジットカード中心、コンビニ決済は別途連携が必要 | クレジットカード+コンビニ決済+銀行振込に標準対応 | クレジットカード中心 |
| 手数料目安 | 3.6%前後+Connect手数料 | 3.5〜4%程度 | 3.6%前後 |
| 個人(出演者)がすぐ受け取れるか | Stripe Expressアカウントで比較的簡単 | 可能だが個人の本人確認フローがやや重い | 主に法人契約向けで個人には不向き |

**推奨:Stripe Connect(Expressアカウント)**

理由:
- 「依頼者から一時的に預かり、案件成立後に出演者へ送金する」というエスクロー的な流れが、Connectの「Destination Charge + 遅延送金」の仕組みでそのまま実現できる
- 出演者側のアカウント開設・本人確認(KYC)がStripe側のUIで完結するため、CAST9側で個人情報を大量に保持するリスクを避けられる(前回話した「連絡先を運営が持たない」という設計思想と相性が良い)
- 将来的に海外展開する場合も対応国が広い

**注意点**
- Stripe ConnectのExpressアカウント開設には出演者自身の本人確認情報の入力が必要(運転免許証等)。これは「顔写真は公開OK、連絡先は非公開」という方針と両立できるが、KYC情報はStripe側に預ける形になるため、利用規約でその旨を明記する必要がある
- コンビニ決済など日本特有の決済手段を厚くしたい場合は、Komojuとの併用も検討の余地あり(依頼者側の支払い手段の幅を優先するなら)

---

## 6. 移行時のデータマッピング(現行アーティファクト → Supabase)

| 現行のストレージキー | 移行先テーブル |
|---|---|
| `cast9_profiles` | `performers` + `performer_stats` + `performer_job_types` + `performer_availability_days` + `performer_availability_times` + `performer_ng_conditions` |
| `cast9_companies` | `requesters` + `requester_stats` |
| `cast9_chats`(profileId→メッセージ配列) | `chat_threads` + `messages` + `quotes` |
| プロフィール内の `reviews` 配列 | `reviews` |
| `cast9_reports` | `reports` |
| `cast9_imagequeue` | `image_moderation_queue` |
| `cast9_adminlogs` | `admin_logs` |

## 7. 実装の優先順位(提案)

1. Supabase プロジェクト作成 → 上記スキーマ・RLSを適用
2. Supabase Auth 導入(出演者/依頼者の新規登録・ログイン画面をcast9.htmlに追加)
3. プロフィール・企業データのCRUDをSupabase経由に置き換え(まずは検索・登録機能から)
4. チャット・見積もりをSupabase Realtimeで同期(現行のポーリング的な仕組みから置き換え)
5. Stripe Connect Expressアカウント連携(出演者のオンボーディング)
6. 決済フロー(見積もり承諾時に与信 → 案件成立後に送金)の実装
7. 管理者画面(cast9-admin.html)をService Role経由のAPIに切り替え
8. 下記のEdge Function群を実装(優先順位はセクション8参照)

---

## 8. 最初に仕組み化しておくと後で楽になるポイント

「クライアントを信用しない」設計にしておくべき処理を洗い出した。共通パターンは同じで、
**「重要な状態変化はクライアントに直接書かせず、必ずEdge Function(Service Role)を経由させる」**。
一つ実装すれば、あとは全部同じ型で量産できる。

| # | 処理 | なぜクライアント任せにすると危ないか | 対応するEdge Function |
|---|---|---|---|
| 1 | レビュー投稿 | 成立していない案件に偽レビューを書ける | `submit-review` |
| 2 | 信用スコア関連の数値(完遂率・遅刻率など) | 本人が自分のスコアを直接書き換えられる | `performer_stats` / `requester_stats` はEdge Functionのみ書込み |
| 3 | 見積もりの「成立」への変更 | 決済せずに「成立した」と偽装できる | `confirm-quote`(Stripe Webhook駆動) |
| 4 | 通報の投稿 | 存在しない相手・関係のないスレッドに対して通報を乱発できる | `submit-report` |
| 5 | 画像メッセージの送信 | モデレーションを素通りさせて不適切画像を送れる | `send-image-message` |
| 6 | 軽度違反の累積・BAN候補フラグ | 通報対応の結果を偽装してペナルティを回避・捏造できる | `resolve-report`(管理者操作もここに集約) |

以下、代表的なものの実装イメージ(Supabase Edge Functions / Deno想定の疑似コード)。

### 8-1. `submit-review`(レビュー投稿)

```ts
// supabase/functions/submit-review/index.ts
import { createClient } from "@supabase/supabase-js";

serve(async (req) => {
  const { quote_id, target_type, rating, comment } = await req.json();
  const authHeader = req.headers.get("Authorization")!;

  // 呼び出したユーザーを特定(RLSが効くクライアント)
  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } }
  });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return new Response("unauthorized", { status: 401 });

  // Service Roleクライアント(RLSを迂回して検証・書き込みを行う)
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // 1. そのquoteが本当に'accepted'で、かつ呼び出し主が当事者かを検証
  const { data: quote } = await admin
    .from("quotes")
    .select("*, chat_threads(performer_id, requester_id, performers(user_id), requesters(user_id))")
    .eq("id", quote_id)
    .single();

  if (!quote || quote.status !== "accepted") {
    return new Response("この案件はまだ成立していません", { status: 400 });
  }
  const isParticipant =
    quote.chat_threads.performers.user_id === user.id ||
    quote.chat_threads.requesters.user_id === user.id;
  if (!isParticipant) return new Response("forbidden", { status: 403 });

  // 2. 二重投稿チェック(同じquote×同じtarget_typeへの重複レビューを禁止)
  const { data: existing } = await admin
    .from("reviews")
    .select("id")
    .eq("quote_id", quote_id)
    .eq("target_type", target_type)
    .maybeSingle();
  if (existing) return new Response("既にレビュー済みです", { status: 400 });

  // 3. 書き込み
  await admin.from("reviews").insert({ quote_id, target_type, rating, comment });

  return new Response("ok");
});
```

### 8-2. `confirm-quote`(Stripe Webhookからの案件成立確定)

```ts
// supabase/functions/confirm-quote/index.ts
// Stripeからの Webhook(payment_intent.succeeded 等)を受けて実行
serve(async (req) => {
  const event = await verifyStripeSignature(req); // Stripe SDKで署名検証必須
  if (event.type !== "payment_intent.succeeded") return new Response("ignored");

  const quoteId = event.data.object.metadata.quote_id;
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const { data: quote } = await admin.from("quotes").select("*").eq("id", quoteId).single();
  if (!quote || quote.status !== "pending") return new Response("skip");

  await admin.from("quotes").update({
    status: "accepted",
    payment_status: "escrowed",
    resolved_at: new Date().toISOString()
  }).eq("id", quoteId);

  // 双方のtotal_jobsを加算(performer_stats / requester_stats はここでのみ更新)
  await admin.rpc("increment_total_jobs", { quote_id: quoteId });

  return new Response("ok");
});
```

### 8-3. `submit-report`(通報投稿)

```ts
// supabase/functions/submit-report/index.ts
serve(async (req) => {
  const { target_type, target_id, thread_id, reason } = await req.json();
  const user = await getUserFromAuthHeader(req);
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // そのthread_idの当事者であり、target_idがそのスレッドの相手であることを検証
  const { data: thread } = await admin
    .from("chat_threads")
    .select("*, performers(user_id), requesters(user_id)")
    .eq("id", thread_id)
    .single();

  const isParticipant =
    thread?.performers.user_id === user.id || thread?.requesters.user_id === user.id;
  if (!isParticipant) return new Response("forbidden", { status: 403 });

  const reporterType = thread.performers.user_id === user.id ? "出演者" : "依頼者";

  await admin.from("reports").insert({
    target_type, target_id, reporter_type: reporterType, reason, status: "未対応"
  });

  return new Response("ok");
});
```

### 8-4. `send-image-message`(画像モデレーション込みの送信)

現行のブラウザ内でClaude APIを直接呼んでいる処理を、そのままEdge Function側に移すだけでよい。
やることは変わらない:①クライアント側で圧縮 → ②Edge Functionへ画像を渡す → ③モデレーションAPI判定
→ ④`block`なら保存せずエラーを返す/`review`ならmessagesとimage_moderation_queueの両方に書き込む/
`safe`ならmessagesにのみ書き込む。この一連の流れをEdge Function内でトランザクション的に行うことで、
「モデレーションだけすり抜けて画像を送る」という抜け道自体をなくせる。

---

### この方針で得られること

- 今回のように「あとから気づいて手作業で直す」対応が減る(通報の捏造・自演レビュー・スコア改ざん・
  決済していないのに成立扱いにする、といった不正がそもそも物理的にできない)
- Edge Functionは6個とも同じ骨格(①呼び出し主を特定→②Service Roleで実データを検証→③条件を満たせば書き込む)
  なので、1つ書けば残りは横展開でき、実装コストの割に効果が大きい
- 「管理者の手間」は増えない。手間が増えるのは佑樹さん(開発側)の初期実装だけで、運用フェーズでは
  むしろ不正対応の作業が減る
