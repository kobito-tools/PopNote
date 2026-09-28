ALTER TABLE todos ADD COLUMN due_date TEXT CHECK(due_date IS NULL OR due_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]');
ALTER TABLE todos ADD COLUMN progress INTEGER NOT NULL DEFAULT 0 CHECK(progress BETWEEN 0 AND 100);
CREATE INDEX todos_due_date_idx ON todos(due_date, completed_at, deleted_at);
