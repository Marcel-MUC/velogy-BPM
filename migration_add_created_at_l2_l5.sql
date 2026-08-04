-- ============================================================================
-- Migration: add created_at to subprocesses/steps/tasks/work_instructions
-- Run this once in the Supabase SQL editor (Project → SQL Editor → New query).
--
-- Only `processes` had created_at before this. The Statistics tab's
-- "Recently added" report (this week/month/year counts per level) needs it
-- at every level.
-- ============================================================================

alter table subprocesses add column if not exists created_at timestamptz;
alter table steps add column if not exists created_at timestamptz;
alter table tasks add column if not exists created_at timestamptz;
alter table work_instructions add column if not exists created_at timestamptz;

alter table subprocesses alter column created_at set default now();
alter table steps alter column created_at set default now();
alter table tasks alter column created_at set default now();
alter table work_instructions alter column created_at set default now();

-- ============================================================================
-- Deliberately nullable, not backfilled: existing rows get NULL ("unknown
-- creation time") rather than now(), since backfilling would make every
-- pre-existing row look like it was just created — which would make the
-- Statistics tab's "This week" column show every historical row as newly
-- added the first time it's viewed after this migration runs. A plain
-- `created_at >= <window start>` comparison already treats NULL correctly
-- (NULL comparisons are false in SQL/Postgres), so nothing on the app side
-- needs special-case handling — new rows get now() via the column default
-- going forward, and only those show up as "recently added".
-- ============================================================================
