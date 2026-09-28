-- アクションとTodoへ、基準パス内のフォルダを添付する。クリックするとOSのファイル管理アプリで開く。
CREATE TABLE daily_action_folders (
  daily_action_id TEXT NOT NULL REFERENCES daily_actions(id) ON DELETE CASCADE,
  relative_path TEXT NOT NULL CHECK (length(relative_path) BETWEEN 1 AND 1024),
  PRIMARY KEY (daily_action_id, relative_path)
) STRICT;

CREATE TABLE todo_folders (
  todo_id TEXT NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
  relative_path TEXT NOT NULL CHECK (length(relative_path) BETWEEN 1 AND 1024),
  PRIMARY KEY (todo_id, relative_path)
) STRICT;
