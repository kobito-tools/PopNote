ALTER TABLE daily_actions ADD COLUMN target_end_time TEXT;

UPDATE daily_actions
SET target_end_time = planned_end_time
WHERE execution_status = 'in_progress';
