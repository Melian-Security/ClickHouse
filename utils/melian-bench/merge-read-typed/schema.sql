CREATE TABLE IF NOT EXISTS bench.src
(
    id UInt64,
    ts DateTime,
    event JSON(max_dynamic_paths=64, action String, action_id Int64, activity_id Int64, activity_name String, `actor.process.file.name` String, `actor.process.file.path` String, `actor.process.name` String, `actor.user.name` String, `actor.user.type` String, `actor.user.uid` String, auth_protocol String, category_name String, category_uid Int64, class_name String, class_uid Int64, `cloud.account.uid` String, `cloud.provider` String, `cloud.region` String, `connection_info.direction_id` Int64, `connection_info.protocol_name` String, `device.hostname` String, `device.os.type` String, `device.type` String, disposition String, disposition_id Int64, `dst_endpoint.hostname` String, `dst_endpoint.ip` Nullable(String), `dst_endpoint.port` Int64, `file.name` String, `file.path` String, `finding.title` String, `finding.uid` String, `http_request.http_method` String, `http_request.url.hostname` String, logon_type_id Int64, message String, `metadata.event_code` String, `metadata.product.name` String, `metadata.product.vendor_name` String, `metadata.tenant_uid` String, `metadata.uid` UUID, `process.cmd_line` String, `process.file.name` String, `process.file.path` String, `process.name` String, `process.pid` Int64, `query.hostname` String, `query.type` String, `service.name` String, severity String, severity_id Int64, `src_endpoint.hostname` String, `src_endpoint.ip` Nullable(String), `src_endpoint.port` Int64, status String, status_id Int64, type_name String, type_uid Int64, `user.name` String, `user.uid` String, `ext.s0` String, `ext.s1` String, `ext.s2` String, `ext.s3` String, `ext.s4` String, `ext.s5` String, `ext.s6` String, `ext.s7` String, `ext.s8` String, `ext.s9` String, `ext.s10` String, `ext.s11` String, `ext.s12` String, `ext.s13` String, `ext.s14` String, `ext.s15` String, `ext.s16` String, `ext.s17` String, `ext.s18` String, `ext.s19` String, `ext.s20` String, `ext.s21` String, `ext.s22` String, `ext.s23` String, `ext.s24` String, `ext.s25` String, `ext.s26` String, `ext.n0` Int64, `ext.n1` Int64, `ext.n2` Int64, `ext.n3` Int64, `ext.n4` Int64, `ext.n5` Int64, `ext.n6` Int64, `ext.n7` Int64, `ext.n8` Int64, `ext.n9` Int64, `ext.b0` Bool, `ext.b1` Bool, `ext.b2` Bool, `ext.b3` Bool, `ext.b4` Bool, `ext.b5` Bool, `ext.b6` Bool, `ext.b7` Bool, `ext.a0` Array(Nullable(String)), `ext.a1` Array(Nullable(String)), `ext.a2` Array(Nullable(String)), `ext.a3` Array(Nullable(String)), `ext.a4` Array(Nullable(String)), `ext.a5` Array(Nullable(String)), `ext.a6` Array(Nullable(String)), `ext.a7` Array(Nullable(String)), `ext.a8` Array(Nullable(String)), `ext.a9` Array(Nullable(String)))
)
ENGINE = ReplacingMergeTree
ORDER BY (ts, id)
SETTINGS
    min_bytes_for_wide_part = 0,
    object_serialization_version = 'v3',
    object_shared_data_serialization_version = 'advanced',
    object_shared_data_serialization_version_for_zero_level_parts = 'map_with_buckets',
    vertical_merge_algorithm_min_rows_to_activate = 1,
    vertical_merge_algorithm_min_columns_to_activate = 1,
    -- No background merges; OPTIMIZE ... FINAL ignores these limits, so only the measured merge runs.
    max_bytes_to_merge_at_max_space_in_pool = 1,
    max_bytes_to_merge_at_min_space_in_pool = 1;
