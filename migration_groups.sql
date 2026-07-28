-- ============================================================================
-- Migration: user groups as a first-class grantee alongside individual users
-- Run this once in the Supabase SQL editor (Project → SQL Editor → New query).
-- Requires migration_company_access_levels.sql to already be applied.
-- ============================================================================

-- 1) Groups + membership -------------------------------------------------------
create table if not exists groups (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists group_members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references groups(id) on delete cascade,
  profile_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (group_id, profile_id)
);

alter table groups enable row level security;
drop policy if exists "groups_select_all" on groups;
create policy "groups_select_all"
  on groups for select to authenticated using (true);
drop policy if exists "groups_admin_write" on groups;
create policy "groups_admin_write"
  on groups for all to authenticated
  using ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') )
  with check ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') );

alter table group_members enable row level security;
drop policy if exists "group_members_select_all" on group_members;
create policy "group_members_select_all"
  on group_members for select to authenticated using (true);
drop policy if exists "group_members_admin_write" on group_members;
create policy "group_members_admin_write"
  on group_members for all to authenticated
  using ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') )
  with check ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') );

-- 2) profile_companies can now target a group instead of a user ---------------
alter table profile_companies add column if not exists group_id uuid references groups(id) on delete cascade;
alter table profile_companies alter column profile_id drop not null;

-- Existing rows all have profile_id set and group_id null, so they already
-- satisfy this — no backfill needed.
alter table profile_companies drop constraint if exists profile_companies_grantee_check;
alter table profile_companies add constraint profile_companies_grantee_check
  check (
    (profile_id is not null and group_id is null)
    or (profile_id is null and group_id is not null)
  );

-- user_company_access_processes needs no change — it links to a
-- profile_companies row by id regardless of whether that row is a user grant
-- or a group grant.

-- 3) can_view()/can_edit(): resolve via direct profile_id OR group membership
-- Same signature as before, so create-or-replace in place — no policy on
-- processes/etc. needs to change, since they call these functions by name.
create or replace function can_view(target_company uuid, target_process uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_is_admin boolean;
  v_row record;
begin
  select (role = 'admin') into v_is_admin from profiles where id = v_uid;
  if v_is_admin then
    return true;
  end if;

  for v_row in
    select id, scope from profile_companies
    where company_id = target_company
      and (
        profile_id = v_uid
        or group_id in (select group_id from group_members where profile_id = v_uid)
      )
  loop
    if v_row.scope = 'all' then
      return true;
    end if;
    if v_row.scope = 'specific' and target_process is not null then
      if exists (
        select 1 from user_company_access_processes ucap
        where ucap.user_company_access_id = v_row.id
          and ucap.process_id = target_process
      ) then
        return true;
      end if;
    end if;
  end loop;

  return false;
end;
$$;

create or replace function can_edit(target_company uuid, target_process uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_is_admin boolean;
  v_row record;
begin
  select (role = 'admin') into v_is_admin from profiles where id = v_uid;
  if v_is_admin then
    return true;
  end if;

  for v_row in
    select id, scope from profile_companies
    where company_id = target_company
      and level = 'edit'
      and (
        profile_id = v_uid
        or group_id in (select group_id from group_members where profile_id = v_uid)
      )
  loop
    if v_row.scope = 'all' then
      return true;
    end if;
    if v_row.scope = 'specific' and target_process is not null then
      if exists (
        select 1 from user_company_access_processes ucap
        where ucap.user_company_access_id = v_row.id
          and ucap.process_id = target_process
      ) then
        return true;
      end if;
    end if;
  end loop;

  return false;
end;
$$;

grant execute on function can_view(uuid, uuid) to authenticated;
grant execute on function can_edit(uuid, uuid) to authenticated;

-- ============================================================================
-- Note: audit_log.target_id references profiles(id). A group grant's
-- target isn't a profile, so the app logs those rows with target_id = NULL
-- (valid — the column has no NOT NULL constraint, and NULL always satisfies
-- a FK) and puts the group's name in the old_value/new_value text instead.
-- ============================================================================
