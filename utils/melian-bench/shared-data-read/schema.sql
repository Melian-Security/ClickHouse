CREATE TABLE bench.t
(
    k String,
    ts DateTime,
    id UInt64,
    event JSON(max_dynamic_paths=64, action String, action_id Int64, activity_id Int64, activity_name String, `actor.process.file.name` String, `actor.process.file.path` String, `actor.process.name` String, `actor.user.name` String, `actor.user.type` String, `actor.user.uid` String, auth_protocol String, category_name String, category_uid Int64, class_name String, class_uid Int64, `cloud.account.uid` String, `cloud.provider` String, `cloud.region` String, `connection_info.direction_id` Int64, `connection_info.protocol_name` String, `device.hostname` String, `device.os.type` String, `device.type` String, disposition String, disposition_id Int64, `dst_endpoint.hostname` String, `dst_endpoint.ip` Nullable(String), `dst_endpoint.port` Int64, `file.name` String, `file.path` String, `finding.title` String, `finding.uid` String, `http_request.http_method` String, `http_request.url.hostname` String, logon_type_id Int64, message String, `metadata.event_code` String, `metadata.product.name` String, `metadata.product.vendor_name` String, `metadata.tenant_uid` String, `metadata.uid` UUID, `process.cmd_line` String, `process.file.name` String, `process.file.path` String, `process.name` String, `process.pid` Int64, `query.hostname` String, `query.type` String, `service.name` String, severity String, severity_id Int64, `src_endpoint.hostname` String, `src_endpoint.ip` Nullable(String), `src_endpoint.port` Int64, status String, status_id Int64, type_name String, type_uid Int64, `user.name` String, `user.uid` String)
)
ENGINE = ReplacingMergeTree
PARTITION BY toDate(ts)
ORDER BY (k, ts, id)
SETTINGS
    storage_policy = 's3',
    min_bytes_for_wide_part = 0,
    object_serialization_version = 'v3',
    object_shared_data_serialization_version = 'advanced',
    object_shared_data_serialization_version_for_zero_level_parts = 'map_with_buckets';
