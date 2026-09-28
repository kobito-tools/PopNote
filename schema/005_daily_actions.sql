CREATE TABLE daily_actions (
  id TEXT PRIMARY KEY,
  action_date TEXT NOT NULL CHECK (action_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  start_time TEXT NOT NULL CHECK (start_time GLOB '[0-2][0-9]:[0-5][0-9]'),
  end_time TEXT NOT NULL CHECK (end_time GLOB '[0-2][0-9]:[0-5][0-9]'),
  action TEXT NOT NULL CHECK (length(trim(action)) > 0),
  location TEXT NOT NULL DEFAULT '',
  progress INTEGER NOT NULL DEFAULT 0 CHECK (progress BETWEEN 0 AND 100),
  display_order INTEGER NOT NULL DEFAULT 1 CHECK (display_order >= 1),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
  deleted_at TEXT,
  CHECK (start_time < end_time)
) STRICT;

CREATE INDEX daily_actions_date_time_idx ON daily_actions(action_date DESC, start_time, display_order);
CREATE INDEX daily_actions_deleted_idx ON daily_actions(deleted_at);

CREATE TABLE daily_action_tags (
  daily_action_id TEXT NOT NULL REFERENCES daily_actions(id) ON DELETE CASCADE,
  tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE RESTRICT,
  PRIMARY KEY (daily_action_id, tag_id)
) STRICT;

CREATE INDEX daily_action_tags_tag_idx ON daily_action_tags(tag_id, daily_action_id);

CREATE TABLE daily_action_completions (
  id TEXT PRIMARY KEY,
  daily_action_id TEXT NOT NULL REFERENCES daily_actions(id) ON DELETE CASCADE,
  content TEXT NOT NULL CHECK (length(trim(content)) > 0),
  display_order INTEGER NOT NULL DEFAULT 1 CHECK (display_order >= 1)
) STRICT;

CREATE INDEX daily_action_completions_action_idx ON daily_action_completions(daily_action_id, display_order);
