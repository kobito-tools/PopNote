ALTER TABLE tags ADD COLUMN archived_at TEXT;
CREATE INDEX tags_archived_idx ON tags(archived_at, category_id, display_order, name);

INSERT INTO tag_categories(id, name, description, display_order) VALUES
  ('relation', '関係', '所属先、人、組織などとの関係', 1),
  ('field', '分野', '知識や仕事の分野', 2),
  ('activity', '活動', '読む、書く、調べるなどの行動', 5),
  ('context', '文脈', '場所、状況、利用場面', 6),
  ('medium', '媒体', '道具、アプリ、連絡手段、資料形式', 7)
ON CONFLICT(id) DO UPDATE SET
  name=excluded.name, description=excluded.description,
  display_order=excluded.display_order, deleted_at=NULL;

UPDATE tags SET category_id='relation' WHERE category_id='affiliation';
UPDATE tags SET category_id='medium' WHERE category_id IN ('channel','tool');
UPDATE tag_categories SET name='テーマ', description='横断的な話題や関心', display_order=3, deleted_at=NULL WHERE id='theme';
UPDATE tag_categories SET name='プロジェクト', description='期限や成果物を持つまとまり', display_order=4, deleted_at=NULL WHERE id='project';
UPDATE tag_categories SET name='その他', description='ほかの分類に当てはまらないもの', display_order=8, deleted_at=NULL WHERE id='other';
DELETE FROM tag_categories WHERE id IN ('affiliation','channel','tool');

ALTER TABLE daily_actions ADD COLUMN planned_end_time TEXT;
ALTER TABLE daily_actions ADD COLUMN completion_flow_enabled INTEGER NOT NULL DEFAULT 0 CHECK(completion_flow_enabled IN (0,1));
UPDATE daily_actions SET planned_end_time=end_time;
UPDATE daily_actions SET completion_flow_enabled=1
WHERE finished_at IS NULL AND deleted_at IS NULL AND action_date >= date('now','localtime');
CREATE INDEX daily_actions_review_idx ON daily_actions(completion_flow_enabled, finished_at, action_date, end_time);
