#!/usr/bin/env bash
# Tags: zookeeper, no-shared-merge-tree
# no-shared-merge-tree: checks the per-partition part counts of (Replicated)MergeTree

# The number of parts in the largest partition and its size, which are used by the insert
# throttling (`parts_to_throw_insert`, `inactive_parts_to_throw_insert`), must follow every
# operation that adds, removes or changes the state of parts.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

# Checks that the count and the average part size reported by an insert that is rejected because
# of the active parts of the largest partition match `system.parts`.
function check_active()
{
    local table=$1
    local actual expected
    actual=$($CLICKHOUSE_CLIENT -q "INSERT INTO $table SETTINGS async_insert = 0, parts_to_throw_insert = 1 VALUES (0, 0)" 2>&1 \
        | grep -o 'Too many parts ([0-9]* with average size of [^)]*)' | head -n1)
    expected=$($CLICKHOUSE_CLIENT -q "
        SELECT format('Too many parts ({} with average size of {})', c, formatReadableSize(intDiv(b, c)))
        FROM
        (
            SELECT partition_id, count() AS c, sum(bytes_on_disk) AS b
            FROM system.parts
            WHERE database = currentDatabase() AND table = '$table' AND active
            GROUP BY partition_id
            ORDER BY c DESC, partition_id
            LIMIT 1
        )")
    if [ "$actual" == "$expected" ]; then
        echo "active ok"
    else
        echo "active mismatch: got '$actual', expected '$expected'"
    fi
}

# The same for the outdated parts and `inactive_parts_to_throw_insert`.
function check_outdated()
{
    local table=$1
    local actual expected
    $CLICKHOUSE_CLIENT -q "ALTER TABLE $table MODIFY SETTING inactive_parts_to_throw_insert = 1"
    actual=$($CLICKHOUSE_CLIENT -q "INSERT INTO $table SETTINGS async_insert = 0 VALUES (0, 0)" 2>&1 | grep -o 'Too many inactive parts ([0-9]*)' | head -n1)
    $CLICKHOUSE_CLIENT -q "ALTER TABLE $table RESET SETTING inactive_parts_to_throw_insert"
    expected=$($CLICKHOUSE_CLIENT -q "
        SELECT format('Too many inactive parts ({})', count()) AS c
        FROM system.parts
        WHERE database = currentDatabase() AND table = '$table' AND _state = 'Outdated'
        GROUP BY partition_id
        ORDER BY count() DESC, partition_id
        LIMIT 1")
    if [ "$actual" == "$expected" ]; then
        echo "outdated ok"
    else
        echo "outdated mismatch: got '$actual', expected '$expected'"
    fi
}

for engine in "MergeTree" "ReplicatedMergeTree('/clickhouse/tables/$CLICKHOUSE_TEST_ZOOKEEPER_PREFIX/05383', 'r1')"; do
    echo "$engine" | grep -o '^[A-Za-z]*'
    $CLICKHOUSE_CLIENT -m -q "
        DROP TABLE IF EXISTS t_05383 SYNC;
        DROP TABLE IF EXISTS t_05383_dst SYNC;
        CREATE TABLE t_05383 (p UInt64, x UInt64) ENGINE = $engine PARTITION BY p ORDER BY x
        SETTINGS old_parts_lifetime = 100000, parts_to_delay_insert = 0, parts_to_throw_insert = 100000;
        SYSTEM STOP MERGES t_05383;
    "

    # Partitions 1, 2 and 3 get 3, 6 and 6 parts of different sizes; the first of the two largest
    # partitions (2) defines the reported size.
    for i in $(seq 1 3); do $CLICKHOUSE_CLIENT -q "INSERT INTO t_05383 SELECT 1, number FROM numbers($i * 10)"; done
    for i in $(seq 1 6); do $CLICKHOUSE_CLIENT -q "INSERT INTO t_05383 SELECT 2, number FROM numbers($i * 1000)"; done
    for i in $(seq 1 6); do $CLICKHOUSE_CLIENT -q "INSERT INTO t_05383 SELECT 3, number FROM numbers($i * 100)"; done
    check_active t_05383

    $CLICKHOUSE_CLIENT -q "INSERT INTO t_05383 SELECT 3, number FROM numbers(5)"
    check_active t_05383

    $CLICKHOUSE_CLIENT -q "ALTER TABLE t_05383 DETACH PARTITION 3"
    check_active t_05383
    $CLICKHOUSE_CLIENT -q "ALTER TABLE t_05383 ATTACH PARTITION 3"
    check_active t_05383

    $CLICKHOUSE_CLIENT -q "ALTER TABLE t_05383 DROP PART '$($CLICKHOUSE_CLIENT -q "SELECT name FROM system.parts WHERE database = currentDatabase() AND table = 't_05383' AND active AND partition_id = '3' ORDER BY name LIMIT 1")'"
    check_active t_05383

    $CLICKHOUSE_CLIENT -q "SYSTEM START MERGES t_05383"
    $CLICKHOUSE_CLIENT -q "OPTIMIZE TABLE t_05383 PARTITION 2 FINAL"
    $CLICKHOUSE_CLIENT -q "SYSTEM STOP MERGES t_05383"
    check_active t_05383
    check_outdated t_05383

    $CLICKHOUSE_CLIENT -q "SYSTEM START MERGES t_05383"
    $CLICKHOUSE_CLIENT -q "ALTER TABLE t_05383 DELETE WHERE x = 1 SETTINGS mutations_sync = 2"
    $CLICKHOUSE_CLIENT -q "SYSTEM STOP MERGES t_05383"
    check_active t_05383
    check_outdated t_05383

    $CLICKHOUSE_CLIENT -q "CREATE TABLE t_05383_dst AS t_05383 ENGINE = MergeTree PARTITION BY p ORDER BY x SETTINGS old_parts_lifetime = 100000"
    $CLICKHOUSE_CLIENT -q "ALTER TABLE t_05383_dst REPLACE PARTITION 3 FROM t_05383"
    check_active t_05383_dst
    $CLICKHOUSE_CLIENT -q "ALTER TABLE t_05383 MOVE PARTITION 1 TO TABLE t_05383_dst" 2>/dev/null || $CLICKHOUSE_CLIENT -q "ALTER TABLE t_05383 DROP PARTITION 1"
    check_active t_05383

    $CLICKHOUSE_CLIENT -q "ALTER TABLE t_05383 DROP PARTITION 3"
    check_active t_05383
    check_outdated t_05383

    $CLICKHOUSE_CLIENT -q "DETACH TABLE t_05383"
    $CLICKHOUSE_CLIENT -q "ATTACH TABLE t_05383"
    check_active t_05383

    $CLICKHOUSE_CLIENT -q "TRUNCATE TABLE t_05383"
    $CLICKHOUSE_CLIENT -q "INSERT INTO t_05383 SELECT 4, number FROM numbers(10)"
    check_active t_05383

    $CLICKHOUSE_CLIENT -m -q "
        DROP TABLE t_05383 SYNC;
        DROP TABLE t_05383_dst SYNC;
    "
done
