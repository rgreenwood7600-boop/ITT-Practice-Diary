-- Roles used only by the local PostgREST stand-in. Not part of supabase/schema.sql.
alter table auth.users add column if not exists encrypted_password text;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator noinherit login password 'itt_local_only';
  end if;
  if not exists (select 1 from pg_roles where rolname = 'itt_admin') then
    create role itt_admin login superuser password 'itt_local_only';
  end if;
end $$;

grant anon to authenticator;
grant authenticated to authenticator;
grant usage on schema public to authenticator;
grant connect on database itt_diary to authenticator, itt_admin;
