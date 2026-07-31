-- ============================================================================
-- Migration: consolidate work_instructions' transaction/field/tool columns
-- into a single free-text `text` column — matching every other L2-L5 level
-- (subprocesses.name, steps.text, tasks.text), which already store their
-- content as one field instead of several.
-- Run this once in the Supabase SQL editor (Project → SQL Editor → New query).
-- ============================================================================

alter table work_instructions add column if not exists text text not null default '';

-- Backfill: join whichever of the three old fields were non-empty, in order,
-- separated by " · " (only for rows not already backfilled, so this is safe
-- to re-run).
update work_instructions
set text = trim(both ' · ' from concat_ws(' · ',
  nullif(trim(transaction), ''),
  nullif(trim(field), ''),
  nullif(trim(tool), '')
))
where text = '';

alter table work_instructions drop column if exists transaction;
alter table work_instructions drop column if exists field;
alter table work_instructions drop column if exists tool;

-- No RLS changes needed — work_instructions' existing policies check
-- can_view/can_edit via the task/step/subprocess/process chain, not the
-- specific columns being selected.
-- ============================================================================
