-- RMSM ITT Practice Diary
-- Idempotent Supabase schema. Run the whole file in the SQL editor.
-- Safe to re-run: it refreshes functions, triggers and policies and does not
-- delete diaries.
--
-- Requires Supabase Auth (the auth schema and the anon / authenticated roles).
-- Staff status is not granted by registration. An administrator sets it with
-- SQL, as described in SETUP.md. The service_role key bypasses these policies
-- and must never be placed in the website.

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table if not exists public.sections (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  sort_order integer not null default 0,
  constraint sections_name_len check (char_length(name) between 1 and 40)
);

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  rank text not null default '',
  section_id uuid references public.sections (id) on delete restrict,
  instrument text not null default '',
  email text not null default '',
  username text,
  is_staff boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_name_len check (char_length(full_name) between 1 and 120),
  constraint profiles_rank_len check (char_length(rank) <= 40),
  constraint profiles_instrument_len check (char_length(instrument) <= 80),
  constraint profiles_email_len check (char_length(email) <= 320),
  constraint profiles_username_format check (
    username is null or username ~ '^[a-z][a-z0-9]{2,29}$'
  )
);

create table if not exists public.diary_months (
  id uuid primary key default gen_random_uuid(),
  trainee_id uuid not null references public.profiles (id) on delete cascade,
  year integer not null,
  month smallint not null,
  created_at timestamptz not null default now(),
  constraint diary_months_year_check check (year between 2020 and 2100),
  constraint diary_months_month_check check (month between 1 and 12),
  constraint diary_months_trainee_month_key unique (trainee_id, year, month)
);

create table if not exists public.diary_comments (
  id uuid primary key default gen_random_uuid(),
  diary_month_id uuid not null references public.diary_months (id) on delete cascade,
  box_type text not null,
  sort_order smallint not null,
  body text not null default '',
  -- No foreign key: the display name is copied at edit time, and a key back to
  -- profiles would clash with the delete cascade from a trainee's own diary.
  last_edited_by uuid,
  last_edited_name text,
  last_edited_at timestamptz,
  constraint diary_comments_box_key unique (diary_month_id, box_type),
  constraint diary_comments_box_type_check check (
    box_type in (
      'instrumental_professor',
      'academic_bandmaster',
      'section_commander',
      'senior_instructor',
      'trainee'
    )
  ),
  constraint diary_comments_body_len check (char_length(body) <= 12000),
  constraint diary_comments_editor_len check (
    last_edited_name is null or char_length(last_edited_name) <= 120
  )
);

create index if not exists profiles_section_id_idx on public.profiles (section_id);
create index if not exists profiles_staff_idx on public.profiles (is_staff);
create unique index if not exists profiles_email_lower_idx
  on public.profiles (lower(email))
  where email <> '';

alter table public.profiles add column if not exists username text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'profiles_username_format'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_username_format
      check (username is null or username ~ '^[a-z][a-z0-9]{2,29}$');
  end if;
end $$;

create unique index if not exists profiles_username_lower_idx
  on public.profiles (lower(username))
  where username is not null;
create unique index if not exists sections_name_lower_idx
  on public.sections (lower(name));

insert into public.sections (name, sort_order)
values ('Section 1', 1), ('Section 2', 2), ('Section 3', 3)
on conflict (name) do nothing;

comment on table public.profiles is
  'One row per account. Trainees own a diary. is_staff is set only from the SQL editor.';
comment on column public.profiles.is_staff is
  'True for ITT staff. Registration cannot set this. Change it from the SQL editor while auth.uid() is null.';

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function private.is_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select p.is_staff from public.profiles p where p.id = auth.uid()),
    false
  );
$$;

revoke all on function private.is_staff() from public;
grant execute on function private.is_staff() to authenticated;

create or replace function public.ensure_diary_month(
  p_trainee uuid,
  p_year integer,
  p_month integer
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_now timestamp;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if p_trainee is null or p_year is null or p_month is null then
    raise exception 'A trainee and a valid month are required';
  end if;

  if p_month < 1 or p_month > 12 or p_year < 2020 or p_year > 2100 then
    raise exception 'Choose a month between 2020 and 2100';
  end if;

  -- Same error for a missing id and for someone else's id, so a trainee
  -- cannot use this function to discover other accounts.
  if p_trainee is distinct from auth.uid() and not private.is_staff() then
    raise exception 'You cannot open another trainee diary';
  end if;

  if not exists (
    select 1
    from public.profiles p
    where p.id = p_trainee
      and p.is_staff = false
  ) then
    raise exception 'Diary months belong to trainees';
  end if;

  v_now := timezone('Europe/London', now());
  if p_year > extract(year from v_now)::integer
     or (
       p_year = extract(year from v_now)::integer
       and p_month > extract(month from v_now)::integer
     ) then
    raise exception 'Future months are not open yet';
  end if;

  insert into public.diary_months (trainee_id, year, month)
  values (p_trainee, p_year, p_month)
  on conflict (trainee_id, year, month) do nothing;

  select m.id
    into v_id
  from public.diary_months m
  where m.trainee_id = p_trainee
    and m.year = p_year
    and m.month = p_month;

  return v_id;
end;
$$;

create or replace function public.delete_trainee(p_trainee uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not private.is_staff() then
    raise exception 'Only staff can delete a trainee';
  end if;

  if p_trainee is null or p_trainee = auth.uid() then
    raise exception 'You cannot delete this account';
  end if;

  if not exists (
    select 1
    from public.profiles p
    where p.id = p_trainee
      and p.is_staff = false
  ) then
    raise exception 'Trainee not found';
  end if;

  delete from auth.users where id = p_trainee;
end;
$$;

revoke all on function public.ensure_diary_month(uuid, integer, integer) from public, anon, authenticated;
revoke all on function public.delete_trainee(uuid) from public, anon, authenticated;
grant execute on function public.ensure_diary_month(uuid, integer, integer) to authenticated;
grant execute on function public.delete_trainee(uuid) to authenticated;

-- pgcrypto supplies bcrypt for set_trainee_password. Supabase usually already
-- has it in the extensions schema; a database that does not gets it there.
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pgcrypto') then
    create schema if not exists extensions;
    create extension pgcrypto with schema extensions;
  end if;
end $$;

create or replace function public.set_trainee_password(p_trainee uuid, p_password text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if auth.uid() is null or not private.is_staff() then
    raise exception 'Only staff can set a trainee password';
  end if;

  if p_trainee is null or p_trainee = auth.uid() then
    raise exception 'You cannot change this password here';
  end if;

  if p_password is null
     or char_length(p_password) < 8
     or char_length(p_password) > 72 then
    raise exception 'Use a password of 8 to 72 characters';
  end if;

  if not exists (
    select 1
    from public.profiles p
    where p.id = p_trainee
      and p.is_staff = false
  ) then
    raise exception 'Trainee not found';
  end if;

  update auth.users
  set encrypted_password = crypt(p_password, gen_salt('bf', 10))
  where id = p_trainee;

  if not found then
    raise exception 'Trainee not found';
  end if;
end;
$$;

revoke all on function public.set_trainee_password(uuid, text) from public, anon, authenticated;
grant execute on function public.set_trainee_password(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

-- Trigger functions live in private so PostgREST does not publish them as API
-- calls. The authenticated role can still execute them, which is what lets a
-- normal update fire the trigger.
drop trigger if exists on_auth_user_created on auth.users;
drop trigger if exists profiles_protect on public.profiles;
drop trigger if exists diary_months_create_comments on public.diary_months;
drop trigger if exists diary_comments_stamp on public.diary_comments;
drop function if exists public.handle_new_user();
drop function if exists public.protect_profile();
drop function if exists public.create_diary_comments();
drop function if exists public.stamp_comment_edit();

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_name text := nullif(trim(meta->>'full_name'), '');
  v_rank text := coalesce(trim(meta->>'rank'), '');
  v_instrument text := coalesce(trim(meta->>'instrument'), '');
  v_username text := nullif(lower(trim(coalesce(meta->>'username', ''))), '');
  v_section uuid;
  v_section_text text := nullif(trim(meta->>'section_id'), '');
  v_now timestamp := timezone('Europe/London', now());
begin
  if v_section_text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_section := v_section_text::uuid;
  end if;

  -- Self-registration always sends a name and a username. Accounts added in
  -- the Auth dashboard do not, and stay without a diary until promoted.
  -- is_staff in the metadata is ignored. Staff are promoted with SQL.
  if v_name is not null then
    if char_length(v_name) > 120 then
      raise exception 'Name is too long';
    end if;
    if v_rank = '' or char_length(v_rank) > 40
       or v_instrument = '' or char_length(v_instrument) > 80
       or v_section is null then
      raise exception 'Name, rank, section and instrument are required';
    end if;
    if v_username is null or v_username !~ '^[a-z][a-z0-9]{2,29}$' then
      raise exception 'Use 3 to 30 letters and numbers, starting with a letter';
    end if;
    if v_username = 'ittstaff' then
      raise exception 'That username is reserved';
    end if;
    if lower(coalesce(new.email, '')) is distinct from v_username || '@trainee.itt-diary.invalid' then
      raise exception 'The username could not be registered';
    end if;
    if not exists (select 1 from public.sections s where s.id = v_section) then
      raise exception 'Choose a section from the list';
    end if;
  end if;

  insert into public.profiles (
    id, full_name, rank, section_id, instrument, email, username, is_staff
  )
  values (
    new.id,
    coalesce(v_name, 'New account'),
    v_rank,
    v_section,
    v_instrument,
    coalesce(new.email, ''),
    v_username,
    false
  );

  if v_name is not null then
    insert into public.diary_months (trainee_id, year, month)
    values (
      new.id,
      extract(year from v_now)::integer,
      extract(month from v_now)::integer
    );
  end if;

  return new;
end;
$$;

create or replace function private.protect_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.full_name := trim(coalesce(new.full_name, ''));
  new.rank := trim(coalesce(new.rank, ''));
  new.instrument := trim(coalesce(new.instrument, ''));
  new.username := nullif(lower(trim(coalesce(new.username, ''))), '');

  if new.username is not null and new.username !~ '^[a-z][a-z0-9]{2,29}$' then
    raise exception 'Use 3 to 30 letters and numbers, starting with a letter';
  end if;

  if char_length(new.full_name) < 1 or char_length(new.full_name) > 120 then
    raise exception 'Enter a name of up to 120 characters';
  end if;
  if char_length(new.rank) > 40 then
    raise exception 'Rank is too long';
  end if;
  if char_length(new.instrument) > 80 then
    raise exception 'Instrument is too long';
  end if;

  if tg_op = 'INSERT' then
    if auth.uid() is not null then
      new.is_staff := false;
    end if;
    new.created_at := coalesce(new.created_at, now());
    new.updated_at := now();
    return new;
  end if;

  if auth.uid() is not null then
    if new.is_staff is distinct from old.is_staff then
      raise exception 'Staff status can only be changed from the Supabase SQL editor';
    end if;
    if new.email is distinct from old.email then
      raise exception 'Email is managed by the account and cannot be edited here';
    end if;
    if new.username is distinct from old.username then
      raise exception 'The username cannot be changed here';
    end if;
    if new.id is distinct from old.id then
      raise exception 'The account id cannot be changed';
    end if;
    new.created_at := old.created_at;
    if not new.is_staff then
      if new.section_id is null
         or char_length(new.rank) < 1
         or char_length(new.instrument) < 1 then
        raise exception 'Name, rank, section and instrument are required';
      end if;
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create or replace function private.create_diary_comments()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.diary_comments (diary_month_id, box_type, sort_order, body)
  values
    (new.id, 'instrumental_professor', 1, ''),
    (new.id, 'academic_bandmaster', 2, ''),
    (new.id, 'section_commander', 3, ''),
    (new.id, 'senior_instructor', 4, ''),
    (new.id, 'trainee', 5, '');
  return new;
end;
$$;

create or replace function private.stamp_comment_edit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
begin
  if new.diary_month_id is distinct from old.diary_month_id
     or new.box_type is distinct from old.box_type
     or new.id is distinct from old.id
     or new.sort_order is distinct from old.sort_order then
    raise exception 'Comment identity cannot be changed';
  end if;

  new.body := coalesce(new.body, '');
  if char_length(new.body) > 12000 then
    raise exception 'A comment cannot be longer than 12000 characters';
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

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

create trigger profiles_protect
  before insert or update on public.profiles
  for each row execute function private.protect_profile();

create trigger diary_months_create_comments
  after insert on public.diary_months
  for each row execute function private.create_diary_comments();

create trigger diary_comments_stamp
  before update on public.diary_comments
  for each row execute function private.stamp_comment_edit();

revoke all on function private.handle_new_user() from public;
revoke all on function private.protect_profile() from public;
revoke all on function private.create_diary_comments() from public;
revoke all on function private.stamp_comment_edit() from public;
grant execute on function private.handle_new_user() to authenticated;
grant execute on function private.protect_profile() to authenticated;
grant execute on function private.create_diary_comments() to authenticated;
grant execute on function private.stamp_comment_edit() to authenticated;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    grant execute on function private.handle_new_user() to supabase_auth_admin;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.sections enable row level security;
alter table public.profiles enable row level security;
alter table public.diary_months enable row level security;
alter table public.diary_comments enable row level security;

do $$
declare
  r record;
begin
  for r in
    select policyname, tablename
    from pg_policies
    where schemaname = 'public'
      and tablename in ('sections', 'profiles', 'diary_months', 'diary_comments')
  loop
    execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

create policy sections_read
  on public.sections
  for select
  to anon, authenticated
  using (true);

create policy sections_insert
  on public.sections
  for insert
  to authenticated
  with check (private.is_staff());

create policy sections_update
  on public.sections
  for update
  to authenticated
  using (private.is_staff())
  with check (private.is_staff());

create policy sections_delete
  on public.sections
  for delete
  to authenticated
  using (private.is_staff());

create policy profiles_select_own
  on public.profiles
  for select
  to authenticated
  using (id = auth.uid());

create policy profiles_select_staff
  on public.profiles
  for select
  to authenticated
  using (private.is_staff());

create policy profiles_update_own
  on public.profiles
  for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

create policy profiles_update_staff
  on public.profiles
  for update
  to authenticated
  using (private.is_staff())
  with check (private.is_staff());

create policy diary_months_select_own
  on public.diary_months
  for select
  to authenticated
  using (trainee_id = auth.uid());

create policy diary_months_select_staff
  on public.diary_months
  for select
  to authenticated
  using (private.is_staff());

create policy diary_comments_select_own
  on public.diary_comments
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

create policy diary_comments_select_staff
  on public.diary_comments
  for select
  to authenticated
  using (private.is_staff());

create policy diary_comments_update_trainee
  on public.diary_comments
  for update
  to authenticated
  using (
    box_type = 'trainee'
    and exists (
      select 1
      from public.diary_months m
      where m.id = diary_month_id
        and m.trainee_id = auth.uid()
    )
  )
  with check (
    box_type = 'trainee'
    and exists (
      select 1
      from public.diary_months m
      where m.id = diary_month_id
        and m.trainee_id = auth.uid()
    )
  );

create policy diary_comments_update_staff
  on public.diary_comments
  for update
  to authenticated
  using (
    private.is_staff()
    and box_type in (
      'instrumental_professor',
      'academic_bandmaster',
      'section_commander',
      'senior_instructor'
    )
  )
  with check (
    private.is_staff()
    and box_type in (
      'instrumental_professor',
      'academic_bandmaster',
      'section_commander',
      'senior_instructor'
    )
  );

-- ---------------------------------------------------------------------------
-- Grants. Column grants sit on top of the policies: the API role cannot
-- update is_staff, email, or the comment stamp even if a policy is widened.
-- There is no insert or delete grant on profiles or comments. Months are
-- opened through ensure_diary_month. Trainees are removed through
-- delete_trainee, which also removes the login.
-- ---------------------------------------------------------------------------

revoke all on public.sections from public, anon, authenticated;
revoke all on public.profiles from public, anon, authenticated;
revoke all on public.diary_months from public, anon, authenticated;
revoke all on public.diary_comments from public, anon, authenticated;

grant usage on schema public to anon, authenticated;

grant select on public.sections to anon, authenticated;
grant insert, update, delete on public.sections to authenticated;

grant select on public.profiles to authenticated;
grant update (full_name, rank, section_id, instrument) on public.profiles to authenticated;

grant select on public.diary_months to authenticated;

grant select on public.diary_comments to authenticated;
grant update (body) on public.diary_comments to authenticated;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant usage on schema public to service_role;
    grant all privileges on all tables in schema public to service_role;
    grant all privileges on all functions in schema public to service_role;
    grant usage on schema private to service_role;
    grant execute on function private.is_staff() to service_role;
  end if;
end $$;

notify pgrst, 'reload schema';
