-- ============================================================================
-- Migration: flat company_access / process_access tables, replacing
-- profile_companies (scope='all'/'specific') + user_company_access_processes.
-- Run this once in the Supabase SQL editor (Project → SQL Editor → New query).
-- Requires migration_groups.sql to already be applied.
--
-- Model change: a process_access row for a grantee is a full override of
-- that same grantee's company_access row, not something merged with it —
-- see the resolve_grant_level() function in section 4 for the exact rule.
-- ============================================================================

-- 1) New tables ----------------------------------------------------------------
-- Plain UNIQUE constraints below, not partial indexes: in Postgres, NULL is
-- never considered equal to another NULL for uniqueness purposes, so
-- unique(company_id, profile_id) already permits unlimited rows with
-- profile_id null (the group grants) exactly like a partial
-- `... where profile_id is not null` index would — the behavior is
-- identical. A plain constraint is required here rather than a partial
-- index because Supabase's upsert(..., {onConflict}) sends only a bare
-- column list, and Postgres can only use a partial index as an ON CONFLICT
-- arbiter when the conflict target also repeats that index's WHERE clause
-- (which PostgREST has no way to do) — with a plain constraint, the column
-- list alone is enough for Postgres to find it, which is what makes the
-- atomic upsert in the app's addAccessToSelectedNode() work.
create table if not exists company_access (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  profile_id uuid references profiles(id) on delete cascade,
  group_id uuid references groups(id) on delete cascade,
  level text not null check (level in ('view','edit')),
  created_at timestamptz not null default now(),
  constraint company_access_grantee_check check (
    (profile_id is not null and group_id is null)
    or (profile_id is null and group_id is not null)
  ),
  constraint company_access_profile_uniq unique (company_id, profile_id),
  constraint company_access_group_uniq unique (company_id, group_id)
);

alter table company_access enable row level security;
drop policy if exists "company_access_select_all" on company_access;
create policy "company_access_select_all"
  on company_access for select to authenticated using (true);
drop policy if exists "company_access_admin_write" on company_access;
create policy "company_access_admin_write"
  on company_access for all to authenticated
  using ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') )
  with check ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') );

create table if not exists process_access (
  id uuid primary key default gen_random_uuid(),
  process_id uuid not null references processes(id) on delete cascade,
  profile_id uuid references profiles(id) on delete cascade,
  group_id uuid references groups(id) on delete cascade,
  level text not null check (level in ('view','edit')),
  created_at timestamptz not null default now(),
  constraint process_access_grantee_check check (
    (profile_id is not null and group_id is null)
    or (profile_id is null and group_id is not null)
  ),
  constraint process_access_profile_uniq unique (process_id, profile_id),
  constraint process_access_group_uniq unique (process_id, group_id)
);

alter table process_access enable row level security;
drop policy if exists "process_access_select_all" on process_access;
create policy "process_access_select_all"
  on process_access for select to authenticated using (true);
drop policy if exists "process_access_admin_write" on process_access;
create policy "process_access_admin_write"
  on process_access for all to authenticated
  using ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') )
  with check ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') );

-- 2) Migrate existing data -------------------------------------------------------
-- scope='all' rows -> one company_access row each.
insert into company_access (company_id, profile_id, group_id, level)
select company_id, profile_id, group_id, level
from profile_companies
where scope = 'all';

-- scope='specific' rows -> one process_access row per linked process.
insert into process_access (process_id, profile_id, group_id, level)
select ucap.process_id, pc.profile_id, pc.group_id, pc.level
from profile_companies pc
join user_company_access_processes ucap on ucap.user_company_access_id = pc.id
where pc.scope = 'specific';

-- Sanity check — compare row counts (shows as NOTICE output in the SQL
-- editor). If these don't roughly match 1:1, stop and investigate before
-- continuing to section 5's drops.
do $$
declare
  v_old_all int;
  v_new_company int;
  v_old_specific int;
  v_new_process int;
begin
  select count(*) into v_old_all from profile_companies where scope = 'all';
  select count(*) into v_new_company from company_access;
  select count(*) into v_old_specific from user_company_access_processes;
  select count(*) into v_new_process from process_access;
  raise notice 'company_access: % old all-scope rows -> % new rows', v_old_all, v_new_company;
  raise notice 'process_access: % old ucap rows -> % new rows', v_old_specific, v_new_process;
end $$;

-- 3) Companies visibility: admin, OR a company_access row, OR a process_access
--    row for ANY process under that company (so a user with only a single
--    mega-cycle's worth of process_access can still reach the company at
--    all) — resolved through direct profile_id OR group membership, same as
--    the functions in section 4.
drop policy if exists "companies_select_authenticated" on companies;
create policy "companies_select_authenticated"
  on companies for select
  to authenticated
  using (
    exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin')
    or exists (
      select 1 from company_access ca
      where ca.company_id = companies.id
        and (
          ca.profile_id = auth.uid()
          or ca.group_id in (select gm.group_id from group_members gm where gm.profile_id = auth.uid())
        )
    )
    or exists (
      select 1 from process_access pa
      join processes pr on pr.id = pa.process_id
      where pr.company_id = companies.id
        and (
          pa.profile_id = auth.uid()
          or pa.group_id in (select gm.group_id from group_members gm where gm.profile_id = auth.uid())
        )
    )
  );

-- 4) can_view()/can_edit(): process_access is an override, not a merge -------
-- Same (target_company, target_process) signatures as before, so no
-- downstream policy on processes/subprocesses/steps/tasks/work_instructions
-- needs to change.
--
-- Per grantee path (the caller's own profile, plus each group they belong
-- to): if a process_access row exists for that path + target_process, that
-- row's level is the ONLY thing that matters for this process on this
-- path — company_access is not consulted for that path at all. Only when no
-- process_access row exists for a path does that path fall back to its
-- company_access row. When several paths (e.g. direct + one or more groups)
-- each resolve to a level, the highest wins (edit beats view) across paths —
-- the "process overrides company" rule applies within a single path, not
-- across different paths.
create or replace function resolve_grant_level(target_company uuid, target_process uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_best_level text := null;
  v_group_id uuid;
  v_level text;
begin
  -- direct profile grantee path
  v_level := null;
  if target_process is not null then
    select level into v_level from process_access where process_id = target_process and profile_id = v_uid;
  end if;
  if v_level is null then
    select level into v_level from company_access where company_id = target_company and profile_id = v_uid;
  end if;
  if v_level is not null then
    v_best_level := v_level;
  end if;

  -- one grantee path per group the caller belongs to
  for v_group_id in select gm.group_id from group_members gm where gm.profile_id = v_uid loop
    v_level := null;
    if target_process is not null then
      select pa.level into v_level from process_access pa where pa.process_id = target_process and pa.group_id = v_group_id;
    end if;
    if v_level is null then
      select ca.level into v_level from company_access ca where ca.company_id = target_company and ca.group_id = v_group_id;
    end if;
    if v_level is not null and (v_best_level is null or (v_level = 'edit' and v_best_level = 'view')) then
      v_best_level := v_level;
    end if;
  end loop;

  return v_best_level;
end;
$$;

create or replace function can_view(target_company uuid, target_process uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_is_admin boolean;
begin
  select (role = 'admin') into v_is_admin from profiles where id = auth.uid();
  if v_is_admin then
    return true;
  end if;
  return resolve_grant_level(target_company, target_process) is not null;
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
  v_is_admin boolean;
begin
  select (role = 'admin') into v_is_admin from profiles where id = auth.uid();
  if v_is_admin then
    return true;
  end if;
  return resolve_grant_level(target_company, target_process) = 'edit';
end;
$$;

grant execute on function resolve_grant_level(uuid, uuid) to authenticated;
grant execute on function can_view(uuid, uuid) to authenticated;
grant execute on function can_edit(uuid, uuid) to authenticated;

-- 5) Drop the old tables ---------------------------------------------------------
-- Child first (FK to profile_companies), then the parent.
drop table if exists user_company_access_processes;
drop table if exists profile_companies;

-- ============================================================================
-- Note on audit_log: the app will start writing 'company_access_granted' /
-- 'company_access_revoked' for company_access rows and
-- 'process_access_granted' / 'process_access_revoked' for process_access
-- rows (previously everything used the company_access_* action names
-- regardless of scope) — no schema change needed since audit_log.action has
-- no CHECK constraint restricting its values.
-- ============================================================================
