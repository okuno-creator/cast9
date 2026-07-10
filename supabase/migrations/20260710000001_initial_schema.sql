-- =========================================================
-- CAST9 初期スキーマ
-- 出典: cast9-backend-design.md セクション2「テーブル定義」
-- =========================================================

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
