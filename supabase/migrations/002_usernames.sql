-- Usernames and staff password reset.
-- Idempotent. Run this whole file in the Supabase SQL editor on the
-- project that already has supabase/schema.sql applied.
-- It does not delete diaries.

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

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pgcrypto') then
    create schema if not exists extensions;
    create extension pgcrypto with schema extensions;
  end if;
end $$;

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

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.set_trainee_password(uuid, text) to service_role;
  end if;
end $$;

notify pgrst, 'reload schema';
