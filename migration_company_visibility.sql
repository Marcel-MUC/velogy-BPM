-- ============================================================================
-- Migration: scope company visibility by profile_companies assignment
-- Run this once in the Supabase SQL editor (Project → SQL Editor → New query).
-- Requires migration_profile_companies.sql to already be applied.
-- ============================================================================

-- 1) Companies table: admins see every company; everyone else only sees
--    companies they have an explicit profile_companies assignment for.
--    This replaces the earlier "any authenticated user sees every company"
--    policy from migration_companies.sql — assignment is now enforced here,
--    not just in the UI.
drop policy if exists "companies_select_authenticated" on companies;
create policy "companies_select_authenticated"
  on companies for select
  to authenticated
  using (
    exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin')
    or exists (
      select 1 from profile_companies pc
      where pc.company_id = companies.id and pc.profile_id = auth.uid()
    )
  );

-- ============================================================================
-- REVIEW REQUIRED — this migration does NOT touch `processes` or its
-- children (subprocesses, steps, tasks, work_instructions), and it should.
--
-- Hiding a company from the `companies` table only hides it from the
-- Companies-tab UI. It does nothing to stop a non-admin from directly
-- querying `processes` (or subprocesses/steps/tasks/work_instructions under
-- it) for a company they aren't assigned to — that table has its own SELECT
-- policy, most likely still scoped by department_id the way earlier
-- migrations flagged, not by company assignment. Whether that's actually a
-- gap depends on what that policy currently says, which I can't inspect from
-- here — please check it in the Supabase dashboard (Authentication →
-- Policies → processes) before treating company hiding as a real access
-- boundary rather than just a UI convenience.
--
-- If `processes` needs the same "admin or assigned" scoping, something in
-- this shape (adjust to match whatever your current policy already checks,
-- e.g. keep any existing department_id clause alongside this if you still
-- want department to also grant access):
--
--   drop policy if exists "<your current processes select policy name>" on processes;
--   create policy "processes_select_scoped"
--     on processes for select
--     to authenticated
--     using (
--       exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin')
--       or exists (
--         select 1 from profile_companies pc
--         where pc.company_id = processes.company_id and pc.profile_id = auth.uid()
--       )
--     );
--
-- subprocesses/steps/tasks/work_instructions typically inherit visibility by
-- joining back up to `processes` (e.g. "exists (select 1 from processes pr
-- where pr.id = subprocesses.process_id and <same check>)"). If that's how
-- they're currently written, fixing `processes` alone should be enough for
-- the whole chain; if any of them instead duplicate the department_id logic
-- independently, each one needs the same update. Please confirm the actual
-- policy text in the dashboard rather than assuming from this comment.
-- ============================================================================
