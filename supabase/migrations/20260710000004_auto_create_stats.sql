-- =========================================================
-- statsテーブル行の自動作成トリガー
--
-- performer_stats / requester_stats はRLSでクライアントから
-- 一切書き込めないため、performers / requesters に行が作られた
-- タイミングでDB側が自動的に初期行を用意する。
-- (security definer なのでRLSの影響を受けずに挿入できる)
-- =========================================================

create function handle_new_performer() returns trigger as $$
begin
  insert into performer_stats (performer_id) values (new.id);
  return new;
end;
$$ language plpgsql security definer;

create trigger on_performer_created
  after insert on performers
  for each row execute function handle_new_performer();

create function handle_new_requester() returns trigger as $$
begin
  insert into requester_stats (requester_id) values (new.id);
  return new;
end;
$$ language plpgsql security definer;

create trigger on_requester_created
  after insert on requesters
  for each row execute function handle_new_requester();
