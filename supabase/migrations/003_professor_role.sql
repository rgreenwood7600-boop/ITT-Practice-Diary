-- Instrumental Professor role.
-- Idempotent. Safe to run on the live diary database after 002_usernames.sql.
-- Does not delete diaries. An existing is_staff account stays full staff.

alter table public.profiles add column if not exists role text;

update public.profiles
set role = case when is_staff then 'staff' else 'trainee' end
where role is null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'profiles_role_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_role_check
      check (role in ('trainee', 'staff', 'professor'));
  end if;
end $$;

alter table public.profiles alter column role set default 'trainee';

do $$
begin
  if not exists (select 1 from public.profiles where role is null) then
    alter table public.profiles alter column role set not null;
  end if;
end $$;

create or replace function private.is_professor()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (
      select p.role = 'professor' and p.is_staff = false
      from public.profiles p
      where p.id = auth.uid()
    ),
    false
  );
$$;

revoke all on function private.is_professor() from public;
grant execute on function private.is_professor() to authenticated;

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

  if p_trainee is distinct from auth.uid()
     and not private.is_staff()
     and not private.is_professor() then
    raise exception 'You cannot open another trainee diary';
  end if;

  if not exists (
    select 1
    from public.profiles p
    where p.id = p_trainee
      and p.role = 'trainee'
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
      and p.role = 'trainee'
  ) then
    raise exception 'Trainee not found';
  end if;

  delete from auth.users where id = p_trainee;
end;
$$;

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
      and p.role = 'trainee'
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
    if v_username in ('ittstaff', 'ittprof') then
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
    id, full_name, rank, section_id, instrument, email, username, role, is_staff
  )
  values (
    new.id,
    coalesce(v_name, 'New account'),
    v_rank,
    v_section,
    v_instrument,
    coalesce(new.email, ''),
    v_username,
    'trainee',
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

  if auth.uid() is null then
    if new.role is null or new.role not in ('trainee', 'staff', 'professor') then
      new.role := case when new.is_staff then 'staff' else 'trainee' end;
    end if;
    if new.is_staff and new.role = 'trainee' then
      new.role := 'staff';
    end if;
    if not new.is_staff and new.role = 'staff' then
      new.role := 'trainee';
    end if;
  end if;

  if tg_op = 'INSERT' then
    if auth.uid() is not null then
      new.is_staff := false;
      new.role := 'trainee';
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
    if new.role is distinct from old.role then
      raise exception 'Role can only be changed from the Supabase SQL editor';
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

-- Professors must not keep the old "any signed-in user can edit their own row"
-- rule, and they need read access plus one comment box. Drop the policies this
-- migration replaces, then create the current set. Other policies stay.
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own
  on public.profiles
  for update
  to authenticated
  using (id = auth.uid() and not private.is_professor())
  with check (id = auth.uid() and not private.is_professor());

drop policy if exists profiles_select_professor on public.profiles;
create policy profiles_select_professor
  on public.profiles
  for select
  to authenticated
  using (private.is_professor());

drop policy if exists diary_months_select_professor on public.diary_months;
create policy diary_months_select_professor
  on public.diary_months
  for select
  to authenticated
  using (private.is_professor());

drop policy if exists diary_comments_select_professor on public.diary_comments;
create policy diary_comments_select_professor
  on public.diary_comments
  for select
  to authenticated
  using (private.is_professor());

drop policy if exists diary_comments_update_professor on public.diary_comments;
create policy diary_comments_update_professor
  on public.diary_comments
  for update
  to authenticated
  using (
    private.is_professor()
    and box_type = 'instrumental_professor'
  )
  with check (
    private.is_professor()
    and box_type = 'instrumental_professor'
  );

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function private.is_professor() to service_role;
  end if;
end $$;

notify pgrst, 'reload schema';

-- After creating the auth user ittprof@staff.itt-diary.invalid (auto confirm),
-- promote that profile. Do not set is_staff. Full staff remain is_staff = true.
-- update public.profiles set role = 'professor', full_name = 'Instrumental Professor', username = 'ittprof' where email = 'ittprof@staff.itt-diary.invalid';
