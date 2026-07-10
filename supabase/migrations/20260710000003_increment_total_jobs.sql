-- =========================================================
-- confirm-quote Edge Function から呼び出すRPC
-- 出典: cast9-backend-design.md セクション8-2
--   決済確定時に、案件の当事者双方(出演者・依頼者)の
--   total_jobs を加算する。stats系テーブルの更新は
--   このようにService Role経由のみに限定する。
-- =========================================================

create function increment_total_jobs(quote_id uuid)
returns void as $$
declare
  v_performer_id uuid;
  v_requester_id uuid;
begin
  select t.performer_id, t.requester_id
    into v_performer_id, v_requester_id
  from quotes q
  join chat_threads t on t.id = q.thread_id
  where q.id = quote_id;

  if not found then
    return;
  end if;

  update performer_stats
     set total_jobs = total_jobs + 1, updated_at = now()
   where performer_id = v_performer_id;

  update requester_stats
     set total_jobs = total_jobs + 1, updated_at = now()
   where requester_id = v_requester_id;
end;
$$ language plpgsql security definer;

-- クライアント(anon/authenticated)からは呼び出せないようにする
-- (Service Roleキーを使うEdge Functionからのみ実行可能)
revoke execute on function increment_total_jobs(uuid) from public;
revoke execute on function increment_total_jobs(uuid) from anon;
revoke execute on function increment_total_jobs(uuid) from authenticated;
grant execute on function increment_total_jobs(uuid) to service_role;
