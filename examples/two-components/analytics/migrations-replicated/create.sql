CREATE TABLE fixture_app.chm_replicated_events (id UInt64, ver UInt64) ENGINE=ReplicatedReplacingMergeTree(ver) ORDER BY id
