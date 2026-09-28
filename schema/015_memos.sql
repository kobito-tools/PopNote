CREATE TABLE memos (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 300),
  body_html TEXT NOT NULL DEFAULT '',
  body_text TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
  deleted_at TEXT
) STRICT;

CREATE INDEX memos_created_idx ON memos(created_at DESC);
CREATE INDEX memos_updated_idx ON memos(updated_at DESC);
CREATE INDEX memos_deleted_idx ON memos(deleted_at);

CREATE TABLE memo_tags (
  memo_id TEXT NOT NULL REFERENCES memos(id) ON DELETE CASCADE,
  tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE RESTRICT,
  PRIMARY KEY (memo_id, tag_id)
) STRICT;

CREATE INDEX memo_tags_tag_idx ON memo_tags(tag_id, memo_id);

CREATE TABLE memo_managed_files (
  memo_id TEXT NOT NULL REFERENCES memos(id) ON DELETE CASCADE,
  managed_file_id TEXT NOT NULL REFERENCES managed_files(id) ON DELETE RESTRICT,
  PRIMARY KEY (memo_id, managed_file_id)
) STRICT;

CREATE INDEX memo_managed_files_file_idx ON memo_managed_files(managed_file_id, memo_id);

CREATE TABLE memo_uploads (
  memo_id TEXT NOT NULL REFERENCES memos(id) ON DELETE CASCADE,
  upload_id TEXT NOT NULL REFERENCES managed_uploads(id) ON DELETE RESTRICT,
  PRIMARY KEY (memo_id, upload_id)
) STRICT;

CREATE INDEX memo_uploads_upload_idx ON memo_uploads(upload_id, memo_id);

-- メモを日記・作業履歴と同じタイムラインへ載せる。作成日時はUTCで保存し、表示用にPCの現地時刻へ変換する。
DROP VIEW timeline_view;
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
FROM manual_timeline_events WHERE deleted_at IS NULL
UNION ALL
SELECT id, strftime('%Y-%m-%dT%H:%M:%S', created_at, 'localtime'), 'memo',
       title, substr(body_text, 1, 240)
FROM memos WHERE deleted_at IS NULL;
