-- Tags: zookeeper, no-shared-merge-tree
-- no-shared-merge-tree: checks the replication queue of ReplicatedMergeTree

-- The log entry of an insert is not copied to the replication queue of the replica that made the insert:
-- the part is already there. The other replicas still fetch the part.

DROP TABLE IF EXISTS t_05384_r1 SYNC;
DROP TABLE IF EXISTS t_05384_r2 SYNC;

CREATE TABLE t_05384_r1 (x UInt64) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{database}/05384', 'r1') ORDER BY tuple();
CREATE TABLE t_05384_r2 (x UInt64) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{database}/05384', 'r2') ORDER BY tuple();

SYSTEM STOP FETCHES t_05384_r1;
SYSTEM STOP FETCHES t_05384_r2;
SYSTEM STOP MERGES t_05384_r1;
SYSTEM STOP MERGES t_05384_r2;

INSERT INTO t_05384_r1 VALUES (1);
INSERT INTO t_05384_r1 VALUES (2);
INSERT INTO t_05384_r1 VALUES (3);
INSERT INTO t_05384_r2 VALUES (4);
INSERT INTO t_05384_r2 VALUES (5);

SYSTEM SYNC REPLICA t_05384_r1 PULL;
SYSTEM SYNC REPLICA t_05384_r2 PULL;

SELECT 'queue', replica_name, type, source_replica, count()
FROM system.replication_queue
WHERE database = currentDatabase() AND table LIKE 't_05384_%'
GROUP BY ALL
ORDER BY ALL;

SELECT 'replicas', replica_name, queue_size, inserts_in_queue, log_pointer > 0
FROM system.replicas
WHERE database = currentDatabase() AND table LIKE 't_05384_%'
ORDER BY ALL;

SYSTEM START FETCHES t_05384_r1;
SYSTEM START FETCHES t_05384_r2;
SYSTEM SYNC REPLICA t_05384_r1;
SYSTEM SYNC REPLICA t_05384_r2;

SELECT 'parts', table, count(), sum(rows) FROM system.parts
WHERE database = currentDatabase() AND table LIKE 't_05384_%' AND active
GROUP BY table ORDER BY table;

SYSTEM START MERGES t_05384_r1;
SYSTEM START MERGES t_05384_r2;
ALTER TABLE t_05384_r1 UPDATE x = x * 10 WHERE 1 SETTINGS mutations_sync = 2;
SELECT 'mutations', table, is_done, parts_to_do FROM system.mutations
WHERE database = currentDatabase() AND table LIKE 't_05384_%'
ORDER BY table;

OPTIMIZE TABLE t_05384_r1 FINAL SETTINGS alter_sync = 2;

SELECT 'r1', groupArray(x) FROM (SELECT x FROM t_05384_r1 ORDER BY x);
SELECT 'r2', groupArray(x) FROM (SELECT x FROM t_05384_r2 ORDER BY x);
SELECT 'active parts', table, count() FROM system.parts
WHERE database = currentDatabase() AND table LIKE 't_05384_%' AND active
GROUP BY table ORDER BY table;

-- The inserts are still deduplicated.
INSERT INTO t_05384_r1 VALUES (6);
INSERT INTO t_05384_r1 VALUES (6);
SYSTEM SYNC REPLICA t_05384_r2;
SELECT 'dedup', count() FROM t_05384_r2 WHERE x = 6;

DROP TABLE t_05384_r1 SYNC;
DROP TABLE t_05384_r2 SYNC;
