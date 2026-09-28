CREATE TABLE journal_entries (
  id TEXT PRIMARY KEY,
  entry_date TEXT NOT NULL UNIQUE CHECK (entry_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  title TEXT NOT NULL CHECK (length(trim(title)) > 0),
  body_markdown TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
  deleted_at TEXT
);

CREATE INDEX journal_entries_date_idx ON journal_entries(entry_date DESC);
CREATE INDEX journal_entries_updated_idx ON journal_entries(updated_at DESC);
CREATE INDEX journal_entries_deleted_idx ON journal_entries(deleted_at);

CREATE TABLE tag_categories (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  description TEXT NOT NULL DEFAULT '',
  display_order INTEGER NOT NULL DEFAULT 1 CHECK (display_order >= 1),
  deleted_at TEXT
);

CREATE TABLE tags (
  id TEXT PRIMARY KEY,
  category_id TEXT REFERENCES tag_categories(id) ON UPDATE RESTRICT ON DELETE RESTRICT,
  name TEXT NOT NULL UNIQUE,
  description TEXT NOT NULL DEFAULT '',
  display_order INTEGER NOT NULL DEFAULT 1 CHECK (display_order >= 1),
  deleted_at TEXT
);

CREATE INDEX tags_category_order_idx ON tags(category_id, display_order, name);

CREATE TABLE journal_tags (
  journal_id TEXT NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
  tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE RESTRICT,
  PRIMARY KEY (journal_id, tag_id)
);

CREATE INDEX journal_tags_tag_idx ON journal_tags(tag_id, journal_id);

CREATE TABLE file_links (
  id TEXT PRIMARY KEY,
  journal_id TEXT NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
  root_id TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  target_type TEXT NOT NULL DEFAULT 'file' CHECK (target_type IN ('file', 'folder')),
  display_name TEXT NOT NULL DEFAULT '',
  note TEXT NOT NULL DEFAULT '',
  display_order INTEGER NOT NULL DEFAULT 1 CHECK (display_order >= 1),
  created_at TEXT NOT NULL,
  UNIQUE (journal_id, root_id, relative_path)
);

CREATE INDEX file_links_path_idx ON file_links(root_id, relative_path);

CREATE TABLE projects (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  description TEXT NOT NULL DEFAULT '',
  display_order INTEGER NOT NULL DEFAULT 1 CHECK (display_order >= 1),
  archived INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
  deleted_at TEXT
);

CREATE INDEX projects_state_order_idx ON projects(archived, display_order, name);

CREATE TABLE journal_projects (
  journal_id TEXT NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
  PRIMARY KEY (journal_id, project_id)
);

CREATE INDEX journal_projects_project_idx ON journal_projects(project_id, journal_id);

CREATE TABLE activity_sources (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  last_seen_at TEXT
);

CREATE TABLE activity_events (
  id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL REFERENCES activity_sources(id) ON DELETE RESTRICT,
  external_id TEXT NOT NULL,
  started_at TEXT NOT NULL,
  ended_at TEXT,
  application_name TEXT NOT NULL DEFAULT '',
  window_title TEXT NOT NULL DEFAULT '',
  root_id TEXT,
  relative_path TEXT,
  project_name TEXT NOT NULL DEFAULT '',
  source_revision INTEGER NOT NULL DEFAULT 1,
  source_updated_at TEXT,
  received_at TEXT NOT NULL,
  deleted_at TEXT,
  UNIQUE (source_id, external_id)
);

CREATE INDEX activity_events_started_idx ON activity_events(started_at DESC);
CREATE INDEX activity_events_source_idx ON activity_events(source_id, external_id);
CREATE INDEX activity_events_project_idx ON activity_events(project_name, started_at DESC);

CREATE TABLE file_index_sources (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  last_seen_at TEXT
);

CREATE TABLE file_index_items (
  id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL REFERENCES file_index_sources(id) ON DELETE RESTRICT,
  external_id TEXT NOT NULL,
  root_id TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  name TEXT NOT NULL,
  extension TEXT NOT NULL DEFAULT '',
  size_bytes INTEGER,
  modified_at TEXT,
  indexed_at TEXT NOT NULL,
  source_revision INTEGER NOT NULL DEFAULT 1,
  missing INTEGER NOT NULL DEFAULT 0 CHECK (missing IN (0, 1)),
  deleted_at TEXT,
  UNIQUE (source_id, external_id)
);

CREATE INDEX file_index_items_path_idx ON file_index_items(root_id, relative_path);
CREATE INDEX file_index_items_name_idx ON file_index_items(name);

CREATE TABLE manual_timeline_events (
  id TEXT PRIMARY KEY,
  occurred_at TEXT NOT NULL,
  event_type TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1,
  deleted_at TEXT
);

CREATE INDEX manual_timeline_occurred_idx ON manual_timeline_events(occurred_at DESC);

CREATE TABLE integration_cursors (
  source_id TEXT NOT NULL,
  stream_name TEXT NOT NULL,
  cursor_value TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (source_id, stream_name)
);

CREATE TABLE idempotency_keys (
  client_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  response_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (client_id, idempotency_key)
);

CREATE VIRTUAL TABLE journal_fts USING fts5(
  journal_id UNINDEXED,
  title,
  body_markdown,
  tokenize = 'unicode61'
);

CREATE TRIGGER journal_fts_insert AFTER INSERT ON journal_entries
WHEN new.deleted_at IS NULL BEGIN
  INSERT INTO journal_fts(journal_id, title, body_markdown)
  VALUES (new.id, new.title, new.body_markdown);
END;

CREATE TRIGGER journal_fts_delete AFTER DELETE ON journal_entries BEGIN
  DELETE FROM journal_fts WHERE journal_id = old.id;
END;

CREATE TRIGGER journal_fts_update AFTER UPDATE ON journal_entries BEGIN
  DELETE FROM journal_fts WHERE journal_id = old.id;
  INSERT INTO journal_fts(journal_id, title, body_markdown)
  SELECT new.id, new.title, new.body_markdown WHERE new.deleted_at IS NULL;
END;

CREATE VIEW timeline_view AS
SELECT id, entry_date || 'T12:00:00' AS occurred_at, 'journal' AS event_type,
       title, substr(body_markdown, 1, 240) AS description
FROM journal_entries WHERE deleted_at IS NULL
UNION ALL
SELECT id, started_at, 'activity',
       CASE WHEN window_title = '' THEN application_name ELSE window_title END,
       application_name || CASE WHEN project_name = '' THEN '' ELSE ' · ' || project_name END
FROM activity_events WHERE deleted_at IS NULL
UNION ALL
SELECT id, occurred_at, event_type, title, description
FROM manual_timeline_events WHERE deleted_at IS NULL;
