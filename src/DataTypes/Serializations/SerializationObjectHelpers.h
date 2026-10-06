#pragma once

#include <DataTypes/IDataType.h>
#include <Columns/ColumnObject.h>
#include <Common/PODArray.h>
#include <Common/VectorWithMemoryTracking.h>

namespace DB
{

/// Object column can store only limited number of paths as subcolumns.
/// If this limit is reached, all other paths are stored together in a
/// single column called shared data.
/// This function collects all the paths stored in Object column into
/// separate columns (except typed paths, they are not returned and
/// should be processed separately).
/// IMPORTANT: returned string_views reference path data inside the Object column (shared data paths
/// and dynamic paths map keys), which must stay alive while the result is used.
std::vector<std::pair<std::string_view, ColumnPtr>> flattenPaths(const ColumnObject & object_column);

/// Flatten paths from shared data for a single bucket only.
/// Only materializes ColumnDynamic columns for paths belonging to target_bucket.
/// IMPORTANT: returned string_views reference data inside shared_data_column,
/// which must stay alive while the result is used.
std::vector<std::pair<std::string_view, ColumnPtr>> flattenSharedDataPathsForBucket(
    const IColumn & shared_data_column, size_t start, size_t end,
    const DataTypePtr & dynamic_type, size_t target_bucket, size_t num_buckets);

/// Scan shared data for path names belonging to a single bucket without materializing ColumnDynamic columns.
/// Returns a sorted list of unique path names. Used by Compact serialization to write StructurePrefix
/// headers before writing Data.
/// IMPORTANT: returned string_views reference data inside shared_data_column,
/// which must stay alive while the result is used.
std::vector<std::string_view> scanPathNamesForBucket(
    const IColumn & shared_data_column, size_t start, size_t end,
    size_t target_bucket, size_t num_buckets);

/// Insert data from flattened representation of an Object column to a usual Object column.
/// Callers hold the paths in different containers, so it is explicitly instantiated for each of them.
template <typename PathsContainer>
void unflattenAndInsertPaths(const PathsContainer & flattened_paths, MutableColumns && flattened_columns, ColumnObject & object_column, size_t num_rows);

/// Get the bucket number for a specific path.
size_t getSharedDataPathBucket(std::string_view path, size_t num_buckets);

/// Splits the shared data of rows [start, end) into buckets, one bucket at a time, to reduce peak
/// memory: instead of materializing all `num_buckets` buckets simultaneously, the caller builds/
/// serializes/frees one bucket at a time. Two output shapes are supported, both driven by the same
/// bucket assignment:
///   - `extractBucket` returns a shared data column for one bucket (used by MAP_WITH_BUCKETS);
///   - `getBucketPaths` groups the occurrences of one bucket by path and `flattenPath` builds the column
///     of one of its paths (used by ADVANCED).
/// Every distinct path gets a dense id and its bucket is hashed once per distinct path in the constructor,
/// so no call hashes a path again, and per-bucket sizes are precomputed so each `extractBucket` column is
/// allocated exactly (avoiding power-of-two over-allocation). `createPathsIndexes` builds the paths
/// indexes of the ADVANCED copy section from the same ids.
class SharedDataBucketsSplitter
{
public:
    SharedDataBucketsSplitter(const IColumn & shared_data_column_, size_t start_, size_t end_, size_t num_buckets_);

    /// Build the shared data column for a single bucket.
    ColumnPtr extractBucket(size_t bucket) const;

    /// The path occurrences of a single bucket grouped by path, with the paths sorted.
    struct BucketPaths
    {
        /// IMPORTANT: string_views reference path data inside the shared data column.
        std::vector<std::string_view> paths;
        /// The occurrences of `paths[i]` are [occurrences_begin[i], occurrences_begin[i + 1]) in `rows` and `values`.
        std::vector<size_t> occurrences_begin;
        /// The row of each occurrence relative to `start`, ascending within a path.
        PODArray<UInt64> rows;
        /// The position of each occurrence's value in the shared data values column.
        PODArray<UInt64> values;
    };

    /// Group the path occurrences of a single bucket by path, without reading any value.
    BucketPaths getBucketPaths(size_t bucket) const;

    /// Flatten one path of `bucket_paths` into a separate column with one value per row: the stored value
    /// where the path is present and a default where it is absent.
    MutableColumnPtr flattenPath(const BucketPaths & bucket_paths, size_t path_index, const DataTypePtr & dynamic_type) const;

    size_t getNumRows() const { return end - start; }

    /// The shared data values column the occurrences of `BucketPaths` refer to.
    const ColumnString & getValuesColumn() const;

    /// Sorted unique path names of a single bucket, without materializing any value column. Returns the
    /// same list as `getBucketPaths`.
    /// IMPORTANT: returned string_views reference path data inside the shared data column.
    std::vector<std::string_view> getBucketPathNames(size_t bucket) const;

    /// Column with the index of every path occurrence of rows [start, end) in the concatenation of the
    /// sorted per-bucket path lists (bucket 0 first), and the smallest unsigned type that fits all indexes.
    /// Built from the path ids, so no path is hashed or compared.
    std::pair<ColumnPtr, DataTypePtr> createPathsIndexes() const;

private:
    const IColumn & shared_data_column;
    size_t start;
    size_t end;
    size_t num_buckets;
    /// Dense path id for each path occurrence, in the order paths are traversed (rows [start, end), paths within a row).
    PODArray<UInt32> path_ids;
    /// Indexed by path id.
    std::vector<std::string_view> id_to_path;
    PODArray<UInt8> id_to_bucket;
    /// Position of the path among the distinct paths of its bucket, in first-seen order.
    PODArray<UInt32> id_to_bucket_position;
    std::vector<size_t> bucket_num_paths;
    std::vector<size_t> bucket_paths_chars_size;
    std::vector<size_t> bucket_values_chars_size;
    /// Ids of the distinct paths of each bucket, in first-seen order.
    std::vector<std::vector<UInt32>> bucket_unique_paths;
    /// Occurrence indexes (positions in `path_ids`) grouped by bucket and ascending within a bucket: the
    /// occurrences of bucket `b` are [bucket_occurrences_begin[b], bucket_occurrences_begin[b + 1]).
    /// Lets `getBucketPaths` visit only its own occurrences instead of scanning all of them per bucket.
    PODArray<UInt64> bucket_occurrences;
    std::vector<size_t> bucket_occurrences_begin;
};
/// Collect paths from bucket columns into a single shared data column.
/// If paths_prefix != nullptr collect only paths that matches this prefix
/// and write paths without this prefix in the result column.
void collectSharedDataFromBuckets(const Columns & shared_data_buckets, IColumn & shared_data_column, const String * paths_prefix = nullptr);

/// Deserialize up to limit indexes from the read buffer and collect corresponding paths to the paths_column.
void deserializeIndexesAndCollectPaths(IColumn & paths_column, ReadBuffer & istr, VectorWithMemoryTracking<String> && paths, size_t limit);

}
