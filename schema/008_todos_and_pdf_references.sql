ALTER TABLE library_items ADD COLUMN source_root_id TEXT;
ALTER TABLE library_items ADD COLUMN source_relative_path TEXT;
CREATE TABLE todos (
 id TEXT PRIMARY KEY, title TEXT NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 300),
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1,
 completed_at TEXT, deleted_at TEXT
) STRICT;
CREATE TABLE todo_tags (
 todo_id TEXT NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
 tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE RESTRICT,
 PRIMARY KEY(todo_id,tag_id)
) STRICT;
CREATE INDEX todos_updated_idx ON todos(updated_at);
ALTER TABLE daily_actions ADD COLUMN todo_id TEXT REFERENCES todos(id) ON DELETE RESTRICT;
