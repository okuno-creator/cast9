-- =========================================================
-- CAST9 RLS(Row Level Security)ポリシー
-- 出典: cast9-backend-design.md セクション3
--
-- 設計の要点:
--   「本人が読むだけの数値(信用スコア・停止フラグなど)」と
--   「本人が編集してよい項目(プロフィール文章など)」を別テーブルに分離し、
--   スコア側にはINSERT/UPDATEポリシーを一切設定しない。
--   重要な状態変化(レビュー投稿・案件成立・通報・画像送信)は
--   Edge Function(Service Role)経由のみに集約する。
-- =========================================================

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

-- 補助テーブルも同様に保護する(本人のみ書き込み可・閲覧は公開)
alter table performer_job_types enable row level security;
alter table performer_availability_days enable row level security;
alter table performer_availability_times enable row level security;
alter table performer_ng_conditions enable row level security;
alter table admin_users enable row level security;

-- 管理者判定用の共通関数
create function is_admin() returns boolean as $$
  select exists (select 1 from admin_users where user_id = auth.uid());
$$ language sql security definer;

-- --- performers(本人が自由編集できる項目) ---
create policy "performers_public_read" on performers
  for select using (true); -- 停止判定はperformer_statsを見て行う
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

-- --- performerの補助テーブル(料金・出演可能条件・NG条件) ---
-- 閲覧は公開、書き込みは本人と管理者のみ
create policy "job_types_public_read" on performer_job_types
  for select using (true);
create policy "job_types_owner_write" on performer_job_types
  for all using (
    exists (select 1 from performers p where p.id = performer_id and p.user_id = auth.uid())
    or is_admin()
  );

create policy "avail_days_public_read" on performer_availability_days
  for select using (true);
create policy "avail_days_owner_write" on performer_availability_days
  for all using (
    exists (select 1 from performers p where p.id = performer_id and p.user_id = auth.uid())
    or is_admin()
  );

create policy "avail_times_public_read" on performer_availability_times
  for select using (true);
create policy "avail_times_owner_write" on performer_availability_times
  for all using (
    exists (select 1 from performers p where p.id = performer_id and p.user_id = auth.uid())
    or is_admin()
  );

create policy "ng_conditions_public_read" on performer_ng_conditions
  for select using (true);
create policy "ng_conditions_owner_write" on performer_ng_conditions
  for all using (
    exists (select 1 from performers p where p.id = performer_id and p.user_id = auth.uid())
    or is_admin()
  );

-- --- requesters / requester_stats(依頼者側も同じ考え方) ---
create policy "requesters_public_read" on requesters for select using (true);
create policy "requesters_owner_write" on requesters
  for update using (user_id = auth.uid());
create policy "requesters_owner_insert" on requesters
  for insert with check (user_id = auth.uid());
create policy "requesters_admin_all" on requesters for all using (is_admin());

create policy "requester_stats_read_all" on requester_stats for select using (true);
create policy "requester_stats_admin_all" on requester_stats for all using (is_admin());

-- --- admin_users(管理者一覧は管理者のみ閲覧可。追加はService Role/SQLでのみ行う) ---
create policy "admin_users_admin_read" on admin_users
  for select using (is_admin());

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
