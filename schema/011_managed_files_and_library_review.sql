ALTER TABLE library_items ADD COLUMN bibtex_code TEXT NOT NULL DEFAULT '';
ALTER TABLE library_items ADD COLUMN review_status TEXT NOT NULL DEFAULT 'confirmed' CHECK (review_status IN ('unverified', 'confirmed'));

UPDATE library_items SET review_status = 'unverified' WHERE intake_status = 'uploaded';

CREATE TABLE managed_files (
  id TEXT PRIMARY KEY,
  root_id TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  name TEXT NOT NULL,
  extension TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
  deleted_at TEXT,
  UNIQUE(root_id, relative_path)
) STRICT;

CREATE INDEX managed_files_name_idx ON managed_files(name COLLATE NOCASE);
CREATE INDEX managed_files_path_idx ON managed_files(root_id, relative_path);

CREATE TABLE daily_action_managed_files (
  daily_action_id TEXT NOT NULL REFERENCES daily_actions(id) ON DELETE CASCADE,
  managed_file_id TEXT NOT NULL REFERENCES managed_files(id) ON DELETE RESTRICT,
  PRIMARY KEY (daily_action_id, managed_file_id)
) STRICT;

CREATE TABLE todo_managed_files (
  todo_id TEXT NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
  managed_file_id TEXT NOT NULL REFERENCES managed_files(id) ON DELETE RESTRICT,
  PRIMARY KEY (todo_id, managed_file_id)
) STRICT;

CREATE TABLE todo_library_items (
  todo_id TEXT NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
  library_item_id TEXT NOT NULL REFERENCES library_items(id) ON DELETE RESTRICT,
  PRIMARY KEY (todo_id, library_item_id)
) STRICT;

CREATE INDEX daily_action_managed_files_file_idx ON daily_action_managed_files(managed_file_id, daily_action_id);
CREATE INDEX todo_managed_files_file_idx ON todo_managed_files(managed_file_id, todo_id);
