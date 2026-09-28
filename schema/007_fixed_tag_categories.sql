INSERT INTO tag_categories(id, name, description, display_order) VALUES
  ('project', 'プロジェクト', '継続的な計画や案件', 4),
  ('tool', 'ツール', '利用する道具やアプリ', 5)
ON CONFLICT(id) DO UPDATE SET
  name = excluded.name,
  description = excluded.description,
  display_order = excluded.display_order,
  deleted_at = NULL;

UPDATE tags
SET category_id = 'other'
WHERE category_id NOT IN ('affiliation', 'theme', 'channel', 'project', 'tool', 'other');

UPDATE tag_categories SET name = '所属', display_order = 1 WHERE id = 'affiliation';
UPDATE tag_categories SET name = 'テーマ', display_order = 2 WHERE id = 'theme';
UPDATE tag_categories SET name = 'チャンネル', display_order = 3 WHERE id = 'channel';
UPDATE tag_categories SET name = 'その他', display_order = 6 WHERE id = 'other';

DELETE FROM tag_categories
WHERE id NOT IN ('affiliation', 'theme', 'channel', 'project', 'tool', 'other');
