-- Confirms a second run of supabase/schema.sql did not wipe diaries or staff.
do $$
declare
  comments int;
  expected int;
begin
  select count(*) into comments from public.diary_comments;
  select expected_comments into expected from public._rls_sentinel where id = 1;
  if expected is null then
    raise exception 'The RLS sentinel is missing after re-running the schema';
  end if;
  if comments <> expected then
    raise exception 'Re-running the schema changed diary comments from % to %', expected, comments;
  end if;
  if not exists (
    select 1 from public.profiles
    where email = 'ben.james@example.test' and is_staff
  ) then
    raise exception 'Re-running the schema cleared staff status';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and column_name ilike '%service%'
  ) then
    raise exception 'A service-number-like column exists';
  end if;
end $$;
