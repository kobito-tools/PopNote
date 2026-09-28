INSERT INTO tag_categories(id, name, description, display_order)
VALUES ('general', '一般', '日記で共通して使うタグ', 1)
ON CONFLICT(id) DO NOTHING;

CREATE TABLE import_runs (
  id TEXT PRIMARY KEY,
  source_type TEXT NOT NULL,
  source_path_hash TEXT NOT NULL,
  source_content_hash TEXT NOT NULL UNIQUE,
  started_at TEXT NOT NULL,
  completed_at TEXT,
  result_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE legacy_import_records (
  import_run_id TEXT NOT NULL REFERENCES import_runs(id) ON DELETE RESTRICT,
  source_file TEXT NOT NULL,
  source_id TEXT NOT NULL,
  record_type TEXT NOT NULL,
  raw_json TEXT NOT NULL,
  PRIMARY KEY (import_run_id, source_file, source_id)
);
