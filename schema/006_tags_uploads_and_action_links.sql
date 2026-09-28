INSERT INTO tag_categories(id, name, description, display_order) VALUES
  ('affiliation', '所属', '所属先やコミュニティ', 1),
  ('theme', '__DailyLog_theme__', '継続して扱う主題', 2),
  ('channel', 'チャンネル', '活動場所や連絡手段', 4),
  ('other', 'その他', '他の分類に当てはまらないもの', 5)
ON CONFLICT(id) DO NOTHING;

UPDATE tag_categories SET name = '分野', display_order = 3 WHERE id = 'field';
UPDATE tags SET category_id = 'other' WHERE category_id = 'general';
UPDATE tags SET category_id = 'theme' WHERE category_id = 'topic';
DELETE FROM tag_categories WHERE id IN ('general', 'topic');
UPDATE tag_categories SET name = 'テーマ' WHERE id = 'theme';

ALTER TABLE tag_categories ADD COLUMN revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1);
ALTER TABLE tags ADD COLUMN revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1);

CREATE TABLE managed_uploads (
  id TEXT PRIMARY KEY,
  stored_name TEXT NOT NULL UNIQUE,
  original_name TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  size_bytes INTEGER NOT NULL CHECK (size_bytes >= 0),
  created_at TEXT NOT NULL,
  deleted_at TEXT
) STRICT;

CREATE INDEX managed_uploads_created_idx ON managed_uploads(created_at DESC);

CREATE TABLE daily_action_file_items (
  daily_action_id TEXT NOT NULL REFERENCES daily_actions(id) ON DELETE CASCADE,
  file_index_item_id TEXT NOT NULL REFERENCES file_index_items(id) ON DELETE RESTRICT,
  PRIMARY KEY (daily_action_id, file_index_item_id)
) STRICT;

CREATE TABLE daily_action_library_items (
  daily_action_id TEXT NOT NULL REFERENCES daily_actions(id) ON DELETE CASCADE,
  library_item_id TEXT NOT NULL REFERENCES library_items(id) ON DELETE RESTRICT,
  PRIMARY KEY (daily_action_id, library_item_id)
) STRICT;

CREATE TABLE daily_action_uploads (
  daily_action_id TEXT NOT NULL REFERENCES daily_actions(id) ON DELETE CASCADE,
  upload_id TEXT NOT NULL REFERENCES managed_uploads(id) ON DELETE RESTRICT,
  PRIMARY KEY (daily_action_id, upload_id)
) STRICT;

ALTER TABLE library_items ADD COLUMN intake_status TEXT NOT NULL DEFAULT 'ready' CHECK (intake_status IN ('uploaded', 'ready'));
ALTER TABLE library_items ADD COLUMN source_upload_id TEXT REFERENCES managed_uploads(id) ON DELETE SET NULL;
ALTER TABLE library_items ADD COLUMN cover_upload_id TEXT REFERENCES managed_uploads(id) ON DELETE SET NULL;
