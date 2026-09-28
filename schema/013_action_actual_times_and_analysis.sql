ALTER TABLE daily_actions ADD COLUMN planned_start_time TEXT;
ALTER TABLE daily_actions ADD COLUMN actual_start_time TEXT;
ALTER TABLE daily_actions ADD COLUMN actual_end_time TEXT;
ALTER TABLE daily_actions ADD COLUMN execution_status TEXT NOT NULL DEFAULT 'planned'
  CHECK (execution_status IN ('planned', 'in_progress', 'completed', 'skipped'));

UPDATE daily_actions SET planned_start_time = start_time;
UPDATE daily_actions SET planned_end_time = coalesce(planned_end_time, end_time);
UPDATE daily_actions
SET actual_start_time = start_time,
    actual_end_time = end_time,
    execution_status = 'completed'
WHERE finished_at IS NOT NULL;
UPDATE daily_actions SET end_time = planned_end_time WHERE planned_end_time IS NOT NULL;

CREATE INDEX daily_actions_execution_idx
  ON daily_actions(execution_status, action_date, start_time, end_time);

CREATE TABLE daily_analyses (
  analysis_date TEXT PRIMARY KEY CHECK (analysis_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  source_fingerprint TEXT NOT NULL,
  llm_summary TEXT NOT NULL DEFAULT '',
  llm_insights_json TEXT NOT NULL DEFAULT '[]',
  llm_suggestions_json TEXT NOT NULL DEFAULT '[]',
  model_path TEXT NOT NULL DEFAULT '',
  analyzed_at TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1)
) STRICT;
