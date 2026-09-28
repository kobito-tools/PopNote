ALTER TABLE library_items ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0 CHECK (favorite IN (0, 1));
ALTER TABLE library_items ADD COLUMN keywords_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE library_items ADD COLUMN doi TEXT NOT NULL DEFAULT '';
ALTER TABLE library_items ADD COLUMN bibtex_key TEXT NOT NULL DEFAULT '';

CREATE INDEX library_items_favorite_idx ON library_items(item_type, favorite DESC, title);

ALTER TABLE file_index_items ADD COLUMN metadata_revision INTEGER NOT NULL DEFAULT 1 CHECK (metadata_revision >= 1);

CREATE TABLE file_index_item_tags (
  file_index_item_id TEXT NOT NULL REFERENCES file_index_items(id) ON DELETE CASCADE,
  tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE RESTRICT,
  PRIMARY KEY (file_index_item_id, tag_id)
);

CREATE INDEX file_index_item_tags_tag_idx ON file_index_item_tags(tag_id, file_index_item_id);
