CREATE TABLE library_items (
  id TEXT PRIMARY KEY,
  item_type TEXT NOT NULL CHECK (item_type IN ('book', 'textbook', 'paper')),
  title TEXT NOT NULL CHECK (length(trim(title)) > 0),
  authors_json TEXT NOT NULL DEFAULT '[]',
  publication_year INTEGER CHECK (publication_year BETWEEN 1000 AND 2200),
  publication TEXT NOT NULL DEFAULT '',
  reading_status TEXT NOT NULL DEFAULT 'unread' CHECK (reading_status IN ('unread', 'reading', 'read', 'cited')),
  priority INTEGER NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
  takeaway_markdown TEXT NOT NULL DEFAULT '',
  url TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
  deleted_at TEXT
) STRICT;

CREATE INDEX library_items_type_status_idx ON library_items(item_type, reading_status, priority DESC, title);
CREATE INDEX library_items_updated_idx ON library_items(updated_at DESC);

CREATE TABLE library_item_tags (
  library_item_id TEXT NOT NULL REFERENCES library_items(id) ON DELETE CASCADE,
  tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE RESTRICT,
  PRIMARY KEY (library_item_id, tag_id)
) STRICT;

CREATE INDEX library_item_tags_tag_idx ON library_item_tags(tag_id, library_item_id);

CREATE TABLE library_item_journals (
  library_item_id TEXT NOT NULL REFERENCES library_items(id) ON DELETE CASCADE,
  journal_id TEXT NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
  PRIMARY KEY (library_item_id, journal_id)
) STRICT;

CREATE INDEX library_item_journals_journal_idx ON library_item_journals(journal_id, library_item_id);
