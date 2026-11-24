-- RLS checks for the ITT practice diary.
-- Creates fictional accounts in a throwaway database. Do not run this on a
-- project that already holds diaries.

insert into auth.users (email, raw_user_meta_data)
values (
  'alexriver@trainee.itt-diary.invalid',
  jsonb_build_object(
    'username', 'AlexRiver',
    'full_name', 'Alex River',
    'rank', 'Musn',
    'instrument', 'Cornet',
    'section_id', (select id::text from public.sections where name = 'Section 1'),
    'is_staff', true
  )
);

insert into auth.users (email, raw_user_meta_data)
values (
  'samquinn@trainee.itt-diary.invalid',
  jsonb_build_object(
    'username', 'samquinn',
    'full_name', 'Sam Quinn',
    'rank', 'Musn',
    'instrument', 'Clarinet',
    'section_id', (select id::text from public.sections where name = 'Section 2')
  )
);

insert into auth.users (email, raw_user_meta_data)
values (
  'ben.james@example.test',
  '{}'::jsonb
);

do $$
declare
  sections int;
  alex_staff boolean;
  alex_comments int;
  ben_months int;
begin
  select count(*) into sections from public.sections;
  if sections <> 3 then
    raise exception 'Expected the three seeded sections, found %', sections;
  end if;

  select is_staff into alex_staff from public.profiles where email = 'alexriver@trainee.itt-diary.invalid';
  if alex_staff then
    raise exception 'Registration metadata was able to set is_staff';
  end if;
  if (select username from public.profiles where email = 'alexriver@trainee.itt-diary.invalid')
     is distinct from 'alexriver' then
    raise exception 'Username was not stored in lower case';
  end if;

  select count(*) into alex_comments
  from public.diary_comments c
  join public.diary_months m on m.id = c.diary_month_id
  join public.profiles p on p.id = m.trainee_id
  where p.email = 'alexriver@trainee.itt-diary.invalid';
  if alex_comments <> 5 then
    raise exception 'Registration should open the current month with 5 boxes, found %', alex_comments;
  end if;

  select count(*) into ben_months
  from public.diary_months m
  join public.profiles p on p.id = m.trainee_id
  where p.email = 'ben.james@example.test';
  if ben_months <> 0 then
    raise exception 'A dashboard account should not get a diary until it is a trainee registration';
  end if;
end $$;

do $$
begin
  insert into auth.users (email, raw_user_meta_data)
  values (
    'ab@trainee.itt-diary.invalid',
    jsonb_build_object(
      'username', 'ab',
      'full_name', 'Too Short',
      'rank', 'Musn',
      'instrument', 'Horn',
      'section_id', (select id::text from public.sections where name = 'Section 1')
    )
  );
  raise exception 'A short username was accepted';
exception
  when others then
    if sqlerrm ilike '%3 to 30%' then
      null;
    else
      raise;
    end if;
end $$;

do $$
begin
  insert into auth.users (email, raw_user_meta_data)
  values (
    'ittstaff@trainee.itt-diary.invalid',
    jsonb_build_object(
      'username', 'ittstaff',
      'full_name', 'Reserved Name',
      'rank', 'Musn',
      'instrument', 'Horn',
      'section_id', (select id::text from public.sections where name = 'Section 1')
    )
  );
  raise exception 'The reserved username was accepted';
exception
  when others then
    if sqlerrm ilike '%reserved%' then
      null;
    else
      raise;
    end if;
end $$;

do $$
begin
  insert into auth.users (email, raw_user_meta_data)
  values (
    'ittprof@trainee.itt-diary.invalid',
    jsonb_build_object(
      'username', 'ittprof',
      'full_name', 'Reserved Professor',
      'rank', 'Musn',
      'instrument', 'Horn',
      'section_id', (select id::text from public.sections where name = 'Section 1')
    )
  );
  raise exception 'The reserved professor username was accepted';
exception
  when others then
    if sqlerrm ilike '%reserved%' then
      null;
    else
      raise;
    end if;
end $$;

select set_config('itt.trainee_a', (select id::text from public.profiles where email = 'alexriver@trainee.itt-diary.invalid'), false);
select set_config('itt.trainee_b', (select id::text from public.profiles where email = 'samquinn@trainee.itt-diary.invalid'), false);
select set_config('itt.staff', (select id::text from public.profiles where email = 'ben.james@example.test'), false);
select set_config('itt.month_a', (
  select m.id::text
  from public.diary_months m
  where m.trainee_id = current_setting('itt.trainee_a')::uuid
), false);

-- SQL editor path: no JWT, so staff status can be set.
select set_config('request.jwt.claim.sub', '', false);
select set_config('request.jwt.claims', '', false);
update public.profiles
set is_staff = true,
    full_name = 'Ben James',
    rank = ''
where email = 'ben.james@example.test';

insert into auth.users (email, raw_user_meta_data)
values ('ittprof@staff.itt-diary.invalid', '{}'::jsonb);

update public.profiles
set role = 'professor',
    full_name = 'Instrumental Professor',
    username = 'ittprof',
    rank = ''
where email = 'ittprof@staff.itt-diary.invalid';

select set_config('itt.professor', (select id::text from public.profiles where email = 'ittprof@staff.itt-diary.invalid'), false);

create or replace function public._test_become(p_user uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claim.sub', p_user::text, false);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated')::text,
    false
  );
end;
$$;

set role authenticated;
select public._test_become(current_setting('itt.trainee_a')::uuid);

do $$
declare
  n int;
  body text;
begin
  select count(*) into n from public.profiles;
  if n <> 1 then
    raise exception 'Trainee A can see % profiles; expected only their own', n;
  end if;

  select count(*) into n from public.diary_months;
  if n <> 1 then
    raise exception 'Trainee A can see % months; expected 1', n;
  end if;

  select count(*) into n from public.diary_comments;
  if n <> 5 then
    raise exception 'Trainee A can see % comments; expected the 5 boxes on their own month', n;
  end if;

  select count(*) into n
  from public.profiles
  where id = current_setting('itt.trainee_b')::uuid;
  if n <> 0 then
    raise exception 'Trainee A can read trainee B';
  end if;

  update public.diary_comments
  set body = 'My practice notes.'
  where box_type = 'trainee'
    and diary_month_id = current_setting('itt.month_a')::uuid;
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'Trainee A could not save their own box (% rows)', n;
  end if;

  select c.last_edited_name into body
  from public.diary_comments c
  where c.box_type = 'trainee'
    and c.diary_month_id = current_setting('itt.month_a')::uuid;
  if body is distinct from 'Alex River' then
    raise exception 'Trainee box was stamped %, expected Alex River', body;
  end if;

  update public.diary_comments
  set body = 'should not stick'
  where box_type = 'instrumental_professor'
    and diary_month_id = current_setting('itt.month_a')::uuid;
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'Trainee A updated a staff box';
  end if;

  select c.body into body
  from public.diary_comments c
  where c.box_type = 'instrumental_professor'
    and c.diary_month_id = current_setting('itt.month_a')::uuid;
  if body <> '' then
    raise exception 'Staff box changed to %', body;
  end if;

  update public.profiles
  set full_name = 'Alex R. River'
  where id = auth.uid();
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'Trainee A could not update their own name';
  end if;

  update public.profiles
  set full_name = 'Hacked'
  where id = current_setting('itt.trainee_b')::uuid;
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'Trainee A updated trainee B';
  end if;
end $$;

do $$
begin
  update public.profiles set is_staff = true where id = auth.uid();
  raise exception 'Trainee A was able to set is_staff';
exception
  when insufficient_privilege then
    null;
  when others then
    if sqlerrm ilike '%staff status%' or sqlerrm ilike '%permission denied%' then
      null;
    else
      raise;
    end if;
end $$;

do $$
declare
  name text;
begin
  select full_name into name from public.profiles where id = auth.uid();
  if name is distinct from 'Alex R. River' then
    raise exception 'A rejected staff-flag update changed the name to %', name;
  end if;
end $$;

do $$
begin
  update public.diary_comments
  set body = 'forged',
      last_edited_name = 'Forged Name'
  where box_type = 'trainee'
    and diary_month_id = current_setting('itt.month_a')::uuid;
  raise exception 'Trainee A was able to set the editor name';
exception
  when insufficient_privilege then
    null;
end $$;

do $$
declare
  body text;
begin
  select c.body into body
  from public.diary_comments c
  where c.box_type = 'trainee'
    and c.diary_month_id = current_setting('itt.month_a')::uuid;
  if body is distinct from 'My practice notes.' then
    raise exception 'Rejected stamp left the trainee box as %', body;
  end if;
end $$;

do $$
begin
  insert into public.diary_comments (diary_month_id, box_type, sort_order, body)
  values (current_setting('itt.month_a')::uuid, 'trainee', 9, 'extra');
  raise exception 'Trainee A inserted a comment row';
exception
  when insufficient_privilege then
    null;
end $$;

do $$
begin
  insert into public.profiles (id, full_name, email, is_staff)
  values (gen_random_uuid(), 'Ghost', 'ghost@example.test', true);
  raise exception 'Trainee A inserted a profile';
exception
  when insufficient_privilege then
    null;
end $$;

do $$
begin
  perform public.set_trainee_password(current_setting('itt.trainee_b')::uuid, 'New-password-1');
  raise exception 'Trainee A set another password';
exception
  when others then
    if sqlerrm ilike '%Only staff%' then
      null;
    else
      raise;
    end if;
end $$;

do $$
begin
  perform public.delete_trainee(current_setting('itt.trainee_b')::uuid);
  raise exception 'Trainee A deleted trainee B';
exception
  when others then
    if sqlerrm ilike '%Only staff%' then
      null;
    else
      raise;
    end if;
end $$;

do $$
begin
  perform public.ensure_diary_month(current_setting('itt.trainee_b')::uuid, 2024, 6);
  raise exception 'Trainee A opened trainee B diary';
exception
  when others then
    if sqlerrm ilike '%cannot open another trainee%' then
      null;
    else
      raise;
    end if;
end $$;

do $$
begin
  insert into public.sections (name, sort_order) values ('Rogue section', 9);
  raise exception 'Trainee A added a section';
exception
  when insufficient_privilege then
    null;
  when others then
    if sqlerrm ilike '%row-level security%' or sqlerrm ilike '%permission denied%' then
      null;
    else
      raise;
    end if;
end $$;

-- Staff can read and write the four staff boxes, and cannot write the trainee box.
select public._test_become(current_setting('itt.staff')::uuid);

do $$
declare
  n int;
  body text;
  editor text;
  prev uuid;
  y int;
  m int;
begin
  select count(*) into n from public.profiles where is_staff = false;
  if n < 2 then
    raise exception 'Staff can see % trainees; expected at least Alex and Sam', n;
  end if;

  update public.diary_comments
  set body = 'Scales are settling.'
  where box_type = 'instrumental_professor'
    and diary_month_id = current_setting('itt.month_a')::uuid;
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'Staff could not write the professor box (% rows)', n;
  end if;

  select c.body, c.last_edited_name into body, editor
  from public.diary_comments c
  where c.box_type = 'instrumental_professor'
    and c.diary_month_id = current_setting('itt.month_a')::uuid;
  if body is distinct from 'Scales are settling.' or editor is distinct from 'Ben James' then
    raise exception 'Professor box is "%" by %', body, editor;
  end if;

  update public.diary_comments
  set body = 'staff should not write here'
  where box_type = 'trainee'
    and diary_month_id = current_setting('itt.month_a')::uuid;
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'Staff wrote in the trainee box';
  end if;

  update public.profiles
  set rank = 'LCpl'
  where id = current_setting('itt.trainee_a')::uuid;
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'Staff could not edit the trainee rank';
  end if;

  y := extract(year from timezone('Europe/London', now()))::int;
  m := extract(month from timezone('Europe/London', now()))::int;
  if m = 1 then
    y := y - 1;
    m := 12;
  else
    m := m - 1;
  end if;
  prev := public.ensure_diary_month(current_setting('itt.trainee_a')::uuid, y, m);
  select count(*) into n from public.diary_comments where diary_month_id = prev;
  if n <> 5 then
    raise exception 'Staff opening a past month created % boxes', n;
  end if;
  perform set_config('itt.month_prev', prev::text, false);

  insert into public.sections (name, sort_order) values ('Section 4', 4);
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'Staff could not add a section';
  end if;
end $$;

do $$
begin
  update public.profiles
  set is_staff = true
  where id = current_setting('itt.trainee_a')::uuid;
  raise exception 'Staff were able to grant staff status through the API';
exception
  when insufficient_privilege then
    null;
  when others then
    if sqlerrm ilike '%staff status%' or sqlerrm ilike '%permission denied%' then
      null;
    else
      raise;
    end if;
end $$;

do $$
begin
  perform public.delete_trainee(current_setting('itt.staff')::uuid);
  raise exception 'Staff were able to delete a staff account';
exception
  when others then
    if sqlerrm ilike '%Trainee not found%' or sqlerrm ilike '%cannot delete this account%' then
      null;
    else
      raise;
    end if;
end $$;

-- Professors can read diaries and write only the Instrumental Professor box.
select public._test_become(current_setting('itt.professor')::uuid);

do $$
declare
  n int;
  body text;
  editor text;
begin
  if (select role from public.profiles where id = auth.uid()) is distinct from 'professor' then
    raise exception 'Professor profile role was not professor';
  end if;
  if (select is_staff from public.profiles where email = 'ben.james@example.test') is not true
     or (select role from public.profiles where email = 'ben.james@example.test') is distinct from 'staff' then
    raise exception 'Full staff lost is_staff or the staff role';
  end if;

  select count(*) into n from public.profiles where role = 'trainee';
  if n < 2 then
    raise exception 'Professor can see % trainees', n;
  end if;

  select count(*) into n from public.diary_comments
  where diary_month_id = current_setting('itt.month_a')::uuid;
  if n <> 5 then
    raise exception 'Professor can see % comment boxes', n;
  end if;

  update public.diary_comments
  set body = 'Tone is developing.'
  where box_type = 'instrumental_professor'
    and diary_month_id = current_setting('itt.month_a')::uuid;
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'Professor could not write the instrumental box (% rows)', n;
  end if;

  select c.body, c.last_edited_name into body, editor
  from public.diary_comments c
  where c.box_type = 'instrumental_professor'
    and c.diary_month_id = current_setting('itt.month_a')::uuid;
  if body is distinct from 'Tone is developing.' or editor is distinct from 'Instrumental Professor' then
    raise exception 'Instrumental box is "%" by %', body, editor;
  end if;

  update public.diary_comments
  set body = 'professor should not write here'
  where box_type = 'academic_bandmaster'
    and diary_month_id = current_setting('itt.month_a')::uuid;
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'Professor wrote in the academic box';
  end if;

  update public.diary_comments
  set body = 'professor should not write the trainee box'
  where box_type = 'trainee'
    and diary_month_id = current_setting('itt.month_a')::uuid;
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'Professor wrote in the trainee box';
  end if;

  update public.profiles
  set full_name = 'Changed by professor'
  where id = current_setting('itt.trainee_a')::uuid;
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'Professor edited a trainee profile';
  end if;

  update public.profiles
  set full_name = 'Professor renamed'
  where id = auth.uid();
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'Professor edited their own profile';
  end if;
end $$;

do $$
begin
  perform public.delete_trainee(current_setting('itt.trainee_a')::uuid);
  raise exception 'Professor deleted a trainee';
exception
  when others then
    if sqlerrm ilike '%Only staff%' then
      null;
    else
      raise;
    end if;
end $$;

do $$
begin
  perform public.set_trainee_password(current_setting('itt.trainee_a')::uuid, 'Professor-password-1');
  raise exception 'Professor set a trainee password';
exception
  when others then
    if sqlerrm ilike '%Only staff%' then
      null;
    else
      raise;
    end if;
end $$;

do $$
begin
  insert into public.sections (name, sort_order) values ('Professor section', 9);
  raise exception 'Professor added a section';
exception
  when insufficient_privilege then
    null;
  when others then
    if sqlerrm ilike '%row-level security%' or sqlerrm ilike '%permission denied%' then
      null;
    else
      raise;
    end if;
end $$;

select public.ensure_diary_month(current_setting('itt.trainee_b')::uuid, 2026, 1);

-- Restore the staff stamp the later trainee assertion expects.
select public._test_become(current_setting('itt.staff')::uuid);

update public.diary_comments
set body = 'Scales are settling.'
where box_type = 'instrumental_professor'
  and diary_month_id = current_setting('itt.month_a')::uuid;

select public.set_trainee_password(current_setting('itt.trainee_a')::uuid, 'New-password-1');

select public.delete_trainee(current_setting('itt.trainee_b')::uuid);

do $$
declare
  n int;
begin
  select count(*) into n from public.profiles where email = 'samquinn@trainee.itt-diary.invalid';
  if n <> 0 then
    raise exception 'Sam Quinn is still listed after delete_trainee';
  end if;
end $$;

-- The deleted trainee's diary is gone, and the other trainee is still private.
select public._test_become(current_setting('itt.trainee_a')::uuid);

do $$
declare
  n int;
  body text;
  editor text;
begin
  select count(*) into n from public.profiles;
  if n <> 1 then
    raise exception 'After the delete, trainee A can see % profiles', n;
  end if;

  select c.body, c.last_edited_name into body, editor
  from public.diary_comments c
  where c.box_type = 'instrumental_professor'
    and c.diary_month_id = current_setting('itt.month_a')::uuid;
  if body is distinct from 'Scales are settling.' or editor is distinct from 'Ben James' then
    raise exception 'Trainee A cannot read the staff comment ("%") by %', body, editor;
  end if;
end $$;

reset role;
select set_config('request.jwt.claim.sub', '', false);
select set_config('request.jwt.claims', '', false);

do $$
declare
  n int;
begin
  select count(*) into n from public.profiles where email = 'samquinn@trainee.itt-diary.invalid';
  if n <> 0 then
    raise exception 'Sam profile survived delete_trainee';
  end if;
  if exists (select 1 from auth.users where email = 'samquinn@trainee.itt-diary.invalid') then
    raise exception 'Sam login survived delete_trainee';
  end if;
  if exists (
    select 1
    from public.diary_months m
    where m.trainee_id = current_setting('itt.trainee_b')::uuid
  ) then
    raise exception 'Sam diary months survived delete_trainee';
  end if;
  if not exists (
    select 1 from public.profiles
    where email = 'alexriver@trainee.itt-diary.invalid' and rank = 'LCpl' and is_staff = false
  ) then
    raise exception 'Alex was changed by the delete or the staff flag';
  end if;
  if not exists (
    select 1 from auth.users
    where id = current_setting('itt.trainee_a')::uuid
      and encrypted_password = extensions.crypt('New-password-1', encrypted_password)
  ) then
    raise exception 'Staff password reset did not store a matching bcrypt hash';
  end if;
end $$;

set role anon;
select set_config('request.jwt.claim.sub', '', false);
select set_config('request.jwt.claims', '', false);

do $$
declare
  n int;
begin
  select count(*) into n from public.sections;
  if n < 3 then
    raise exception 'Anonymous visitors cannot read the section list (% rows)', n;
  end if;
end $$;

do $$
begin
  perform 1 from public.profiles;
  raise exception 'Anonymous visitors can read profiles';
exception
  when insufficient_privilege then
    null;
end $$;

reset role;

drop function public._test_become(uuid);

create table public._rls_sentinel (
  id integer primary key,
  expected_comments integer not null
);

insert into public._rls_sentinel (id, expected_comments)
select 1, count(*) from public.diary_comments;
