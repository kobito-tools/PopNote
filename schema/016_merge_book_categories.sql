-- 「くらしの本」「まなびの本」を共通の「書籍」へ統合する。
-- source_root_id は既存PDFを元の場所から参照し続けるため変更しない。
UPDATE library_items
SET item_type = 'book',
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
    revision = revision + 1
WHERE item_type = 'textbook';
