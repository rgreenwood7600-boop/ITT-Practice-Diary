-- Monthly grades for the RMSM Monthly Trainee Assessment Form.
-- Idempotent. Safe to run on the live diary database after 003_professor_role.sql.
-- Does not delete diaries or comments.

create table if not exists public.diary_grades (
  id uuid primary key default gen_random_uuid(),
  diary_month_id uuid not null references public.diary_months (id) on delete cascade,
  item_key text not null,
  sort_order smallint not null,
  grade text,
  last_edited_by uuid,
  last_edited_name text,
  last_edited_at timestamptz,
  constraint diary_grades_month_item_key unique (diary_month_id, item_key),
  constraint diary_grades_item_key_check check (
    item_key in (
      'to1_1_tech_ex',
      'to1_1_ipe',
      'to2_1_gm',
      'to2_1_aural',
      'to3_1_equipment',
      'to4_1_concert',
      'to5_1_marching',
      'to6_1_ethos',
      'motivation',
      'work_ethic',
      'discipline',
      'physical_training',
      'opg'
    )
  ),
  constraint diary_grades_grade_check check (
    grade is null or grade in ('A', 'A-', 'B+', 'B', 'B-', 'C')
  ),
  constraint diary_grades_editor_len check (
    last_edited_name is null or char_length(last_edited_name) <= 120
  )
);

create or replace function private.create_diary_grades()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.diary_grades (diary_month_id, item_key, sort_order)
  values
    (new.id, 'to1_1_tech_ex', 1),
    (new.id, 'to1_1_ipe', 2),
    (new.id, 'to2_1_gm', 3),
    (new.id, 'to2_1_aural', 4),
    (new.id, 'to3_1_equipment', 5),
    (new.id, 'to4_1_concert', 6),
    (new.id, 'to5_1_marching', 7),
    (new.id, 'to6_1_ethos', 8),
    (new.id, 'motivation', 9),
    (new.id, 'work_ethic', 10),
    (new.id, 'discipline', 11),
    (new.id, 'physical_training', 12),
    (new.id, 'opg', 13)
  on conflict (diary_month_id, item_key) do nothing;
  return new;
end;
$$;

drop trigger if exists diary_months_create_grades on public.diary_months;
create trigger diary_months_create_grades
  after insert on public.diary_months
  for each row execute function private.create_diary_grades();

create or replace function private.stamp_grade_edit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
begin
  if new.diary_month_id is distinct from old.diary_month_id
     or new.item_key is distinct from old.item_key
     or new.id is distinct from old.id
     or new.sort_order is distinct from old.sort_order then
    raise exception 'Grade identity cannot be changed';
  end if;

  if new.grade is not null and new.grade not in ('A', 'A-', 'B+', 'B', 'B-', 'C') then
    raise exception 'Choose a grade of A, A-, B+, B, B- or C';
  end if;

  if auth.uid() is null then
    new.last_edited_at := coalesce(new.last_edited_at, now());
    return new;
  end if;

  select p.full_name into v_name
  from public.profiles p
  where p.id = auth.uid();

  new.last_edited_by := auth.uid();
  new.last_edited_name := coalesce(v_name, 'Unknown');
  new.last_edited_at := now();
  return new;
end;
$$;

drop trigger if exists diary_grades_stamp on public.diary_grades;
create trigger diary_grades_stamp
  before update on public.diary_grades
  for each row execute function private.stamp_grade_edit();

revoke all on function private.create_diary_grades() from public;
revoke all on function private.stamp_grade_edit() from public;
grant execute on function private.create_diary_grades() to authenticated;
grant execute on function private.stamp_grade_edit() to authenticated;

insert into public.diary_grades (diary_month_id, item_key, sort_order)
select m.id, k.item_key, k.sort_order::smallint
from public.diary_months m
cross join (
  values
    ('to1_1_tech_ex', 1),
    ('to1_1_ipe', 2),
    ('to2_1_gm', 3),
    ('to2_1_aural', 4),
    ('to3_1_equipment', 5),
    ('to4_1_concert', 6),
    ('to5_1_marching', 7),
    ('to6_1_ethos', 8),
    ('motivation', 9),
    ('work_ethic', 10),
    ('discipline', 11),
    ('physical_training', 12),
    ('opg', 13)
) as k(item_key, sort_order)
on conflict (diary_month_id, item_key) do nothing;

alter table public.diary_grades enable row level security;

drop policy if exists diary_grades_select_own on public.diary_grades;
create policy diary_grades_select_own
  on public.diary_grades
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.diary_months m
      where m.id = diary_month_id
        and m.trainee_id = auth.uid()
    )
  );

drop policy if exists diary_grades_select_staff on public.diary_grades;
create policy diary_grades_select_staff
  on public.diary_grades
  for select
  to authenticated
  using (private.is_staff());

drop policy if exists diary_grades_select_professor on public.diary_grades;
create policy diary_grades_select_professor
  on public.diary_grades
  for select
  to authenticated
  using (private.is_professor());

drop policy if exists diary_grades_update_staff on public.diary_grades;
create policy diary_grades_update_staff
  on public.diary_grades
  for update
  to authenticated
  using (private.is_staff())
  with check (private.is_staff());

revoke all on public.diary_grades from public, anon, authenticated;
grant select on public.diary_grades to authenticated;
grant update (grade) on public.diary_grades to authenticated;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant all privileges on public.diary_grades to service_role;
    grant execute on function private.create_diary_grades() to service_role;
    grant execute on function private.stamp_grade_edit() to service_role;
  end if;
end $$;

notify pgrst, 'reload schema';
