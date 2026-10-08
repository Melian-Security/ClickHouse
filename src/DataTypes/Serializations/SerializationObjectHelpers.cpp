#include <DataTypes/Serializations/SerializationObjectHelpers.h>
#include <DataTypes/DataTypeObject.h>
#include <DataTypes/DataTypeDynamic.h>
#include <DataTypes/DataTypesNumber.h>
#include <Columns/ColumnObject.h>
#include <Common/SipHash.h>
#include <Common/HashTable/HashMap.h>
#include <IO/ReadHelpers.h>


namespace DB
{

namespace ErrorCodes
{
    extern const int LOGICAL_ERROR;
}

std::vector<std::pair<std::string_view, ColumnPtr>> flattenSharedDataPathsForBucket(
    const IColumn & shared_data_column, size_t start, size_t end,
    const DataTypePtr & dynamic_type, size_t target_bucket, size_t num_buckets)
{
    /// First, iterate over shared data and collect values of
    /// all paths that are stored there into separate columns.
    /// Each column is densified to have a value for every row (a default where the path is absent).
    /// Gaps in a path column are backfilled with a single bulk insertManyDefaults right before storing
    /// a real value (and once at the end), which removes the per-row scan over every accumulated path
    /// column. The number of defaults materialized is unchanged; only the scan is removed.
    /// Use string_view keys referencing data in shared_data_paths column to avoid copying path strings.
    std::unordered_map<std::string_view, MutableColumnPtr> flattened_shared_data_paths;
    const auto [shared_data_paths, shared_data_values, shared_data_offsets] = ColumnObject::getSharedDataPathsValuesAndOffsets(shared_data_column);
    for (size_t i = start; i != end; ++i)
    {
        size_t offset_start = (*shared_data_offsets)[ssize_t(i) - 1];
        size_t offset_end = (*shared_data_offsets)[ssize_t(i)];
        size_t row = i - start;
        for (size_t j = offset_start; j != offset_end; ++j)
        {
            std::string_view path = shared_data_paths->getDataAt(j);
            /// Skip paths not belonging to target bucket.
            if (getSharedDataPathBucket(path, num_buckets) != target_bucket)
                continue;

            auto it = flattened_shared_data_paths.find(path);
            /// If we see this path for the first time, add it to the list and create a column for it.
            if (it == flattened_shared_data_paths.end())
                it = flattened_shared_data_paths.emplace(path, dynamic_type->createColumn()).first;

            /// Backfill defaults for the rows where this path was absent, up to the current row.
            if (it->second->size() < row)
                it->second->insertManyDefaults(row - it->second->size());

            ColumnObject::deserializeValueFromSharedData(shared_data_values, j, *it->second);
        }
    }

    /// Backfill defaults for the trailing rows where each path was absent.
    size_t num_rows = end - start;
    for (const auto & [_, column] : flattened_shared_data_paths)
    {
        if (column->size() < num_rows)
            column->insertManyDefaults(num_rows - column->size());
    }

    /// Collect into a sorted vector.
    std::vector<std::pair<std::string_view, ColumnPtr>> result;
    result.reserve(flattened_shared_data_paths.size());
    for (auto & [path, column] : flattened_shared_data_paths)
        result.emplace_back(path, column->getPtr());

    std::sort(result.begin(), result.end());
    return result;
}

std::vector<std::string_view> scanPathNamesForBucket(
    const IColumn & shared_data_column, size_t start, size_t end,
    size_t target_bucket, size_t num_buckets)
{
    /// Collect unique path names belonging to target_bucket without materializing ColumnDynamic columns.
    /// Use string_view referencing data in shared_data_paths column to avoid copying path strings.
    std::unordered_set<std::string_view> path_names;
    const auto [shared_data_paths, shared_data_values, shared_data_offsets] = ColumnObject::getSharedDataPathsValuesAndOffsets(shared_data_column);
    for (size_t i = start; i != end; ++i)
    {
        size_t offset_start = (*shared_data_offsets)[ssize_t(i) - 1];
        size_t offset_end = (*shared_data_offsets)[ssize_t(i)];
        for (size_t j = offset_start; j != offset_end; ++j)
        {
            std::string_view path = shared_data_paths->getDataAt(j);
            if (getSharedDataPathBucket(path, num_buckets) != target_bucket)
                continue;
            path_names.insert(path);
        }
    }

    std::vector<std::string_view> result(path_names.begin(), path_names.end());
    std::sort(result.begin(), result.end());
    return result;
}

std::vector<std::pair<std::string_view, ColumnPtr>> flattenPaths(const ColumnObject & object_column)
{
    auto all_paths = flattenSharedDataPathsForBucket(*object_column.getSharedDataPtr(), 0, object_column.size(), object_column.getDynamicType(), 0, 1);
    for (const auto & [path, column] : object_column.getDynamicPaths())
        all_paths.emplace_back(path, column);
    std::sort(all_paths.begin(), all_paths.end());
    return all_paths;
}

template <typename PathsContainer>
void unflattenAndInsertPaths(const PathsContainer & flattened_paths, MutableColumns && flattened_columns, ColumnObject & object_column, size_t num_rows)
{
    /// Iterate over paths and try to add them to dynamic paths until the limit is reached.
    /// All remaining paths will be inserted into shared data.
    std::map<std::string_view, ColumnPtr> paths_for_shared_data;
    for (size_t i = 0; i != flattened_paths.size(); ++i)
    {
        if (object_column.canAddNewDynamicPath())
            object_column.addNewDynamicPath(flattened_paths[i], std::move(flattened_columns[i]));
        else
            paths_for_shared_data.emplace(flattened_paths[i], std::move(flattened_columns[i]));
    }

    auto [shared_data_paths, shared_data_values] = object_column.getSharedDataPathsAndValues();
    auto & shared_data_offsets = object_column.getSharedDataOffsets();
    std::unordered_map<std::string_view, const ColumnDynamic *> dynamic_columns_ptrs;
    dynamic_columns_ptrs.reserve(flattened_paths.size());
    for (const auto & [path, column] : paths_for_shared_data)
        dynamic_columns_ptrs[path] = assert_cast<const ColumnDynamic *>(column.get());

    for (size_t i = 0; i != num_rows; ++i)
    {
        for (const auto & [path, column] : paths_for_shared_data)
            ColumnObject::serializePathAndValueIntoSharedData(shared_data_paths, shared_data_values, path, *dynamic_columns_ptrs[path], i);
        shared_data_offsets.push_back(shared_data_paths->size());
    }
}

template void unflattenAndInsertPaths<std::vector<String>>(
    const std::vector<String> &, MutableColumns &&, ColumnObject &, size_t);

template void unflattenAndInsertPaths<VectorWithMemoryTracking<String>>(
    const VectorWithMemoryTracking<String> &, MutableColumns &&, ColumnObject &, size_t);

size_t getSharedDataPathBucket(std::string_view path, size_t num_buckets)
{
    /// Do not change the hash function here, it will break paths
    /// reading from buckets as we read only corresponding bucket.
    SipHash hash;
    hash.update(path);
    return hash.get64() % num_buckets;
}

SharedDataBucketsSplitter::SharedDataBucketsSplitter(const IColumn & shared_data_column_, size_t start_, size_t end_, size_t num_buckets_)
    : shared_data_column(shared_data_column_)
    , start(start_)
    , end(end_)
    , num_buckets(num_buckets_)
    , bucket_num_paths(num_buckets_, 0)
    , bucket_paths_chars_size(num_buckets_, 0)
    , bucket_values_chars_size(num_buckets_, 0)
    , bucket_unique_paths(num_buckets_)
{
    const auto [shared_data_paths, shared_data_values, shared_data_offsets] = ColumnObject::getSharedDataPathsValuesAndOffsets(shared_data_column);
    const auto & paths_offsets = shared_data_paths->getOffsets();
    const auto & values_offsets = shared_data_values->getOffsets();

    /// A block holds few distinct paths repeated across many rows, so every distinct path gets a
    /// dense id on first sight and its bucket hash is computed once per block instead of once per
    /// occurrence. The per-occurrence id lets `flattenBucket` address its path column by index.
    HashMapWithSavedHash<std::string_view, UInt32> path_to_id;
    path_ids.reserve((*shared_data_offsets)[ssize_t(end) - 1] - (*shared_data_offsets)[ssize_t(start) - 1]);
    for (size_t i = start; i != end; ++i)
    {
        size_t offset_start = (*shared_data_offsets)[ssize_t(i) - 1];
        size_t offset_end = (*shared_data_offsets)[ssize_t(i)];
        for (size_t j = offset_start; j != offset_end; ++j)
        {
            std::string_view path = shared_data_paths->getDataAt(j);
            HashMapWithSavedHash<std::string_view, UInt32>::LookupResult it;
            bool inserted;
            path_to_id.emplace(path, it, inserted);
            if (inserted)
            {
                UInt32 new_id = static_cast<UInt32>(id_to_path.size());
                it->getMapped() = new_id;
                size_t path_bucket = getSharedDataPathBucket(path, num_buckets);
                id_to_path.push_back(path);
                id_to_bucket.push_back(static_cast<UInt8>(path_bucket));
                id_to_bucket_position.push_back(static_cast<UInt32>(bucket_unique_paths[path_bucket].size()));
                bucket_unique_paths[path_bucket].push_back(new_id);
            }

            UInt32 id = it->getMapped();
            path_ids.push_back(id);
            size_t bucket = id_to_bucket[id];
            ++bucket_num_paths[bucket];
            /// The number of chars occupied by value `j` (exactly what `insertFrom` appends) is the
            /// difference of consecutive string offsets.
            bucket_paths_chars_size[bucket] += paths_offsets[ssize_t(j)] - paths_offsets[ssize_t(j) - 1];
            bucket_values_chars_size[bucket] += values_offsets[ssize_t(j)] - values_offsets[ssize_t(j) - 1];
        }
    }

    /// Counting sort of the occurrences by bucket, stable so each bucket keeps the traversal order.
    bucket_occurrences_begin.resize(num_buckets + 1);
    bucket_occurrences_begin[0] = 0;
    for (size_t bucket = 0; bucket != num_buckets; ++bucket)
        bucket_occurrences_begin[bucket + 1] = bucket_occurrences_begin[bucket] + bucket_num_paths[bucket];
    std::vector<size_t> next_position(bucket_occurrences_begin.begin(), bucket_occurrences_begin.end() - 1);
    bucket_occurrences.resize(path_ids.size());
    for (size_t occurrence = 0; occurrence != path_ids.size(); ++occurrence)
        bucket_occurrences[next_position[id_to_bucket[path_ids[occurrence]]]++] = occurrence;
}

ColumnPtr SharedDataBucketsSplitter::extractBucket(size_t bucket) const
{
    const auto [shared_data_paths, shared_data_values, shared_data_offsets] = ColumnObject::getSharedDataPathsValuesAndOffsets(shared_data_column);

    auto bucket_column = shared_data_column.cloneEmpty();
    auto [bucket_paths, bucket_values, bucket_offsets] = ColumnObject::getSharedDataPathsValuesAndOffsets(*bucket_column);

    /// Pre-allocate exactly to avoid power-of-two over-allocation.
    bucket_paths->getChars().reserve_exact(bucket_paths_chars_size[bucket]);
    bucket_paths->getOffsets().reserve_exact(bucket_num_paths[bucket]);
    bucket_values->getChars().reserve_exact(bucket_values_chars_size[bucket]);
    bucket_values->getOffsets().reserve_exact(bucket_num_paths[bucket]);
    bucket_offsets->reserve_exact(end - start);

    /// Visit only the occurrences of this bucket: they are in traversal order, so they are walked together with the rows.
    const size_t first_occurrence = (*shared_data_offsets)[ssize_t(start) - 1];
    size_t position = bucket_occurrences_begin[bucket];
    const size_t bucket_end = bucket_occurrences_begin[bucket + 1];
    for (size_t i = start; i != end; ++i)
    {
        size_t row_end = (*shared_data_offsets)[ssize_t(i)] - first_occurrence;
        for (; position != bucket_end && bucket_occurrences[position] < row_end; ++position)
        {
            size_t j = first_occurrence + bucket_occurrences[position];
            bucket_paths->insertFrom(*shared_data_paths, j);
            bucket_values->insertFrom(*shared_data_values, j);
        }

        bucket_offsets->push_back(bucket_paths->size());
    }

    return bucket_column;
}

std::vector<std::string_view> SharedDataBucketsSplitter::getBucketPathNames(size_t bucket) const
{
    std::vector<std::string_view> result;
    result.reserve(bucket_unique_paths[bucket].size());
    for (UInt32 id : bucket_unique_paths[bucket])
        result.push_back(id_to_path[id]);
    std::sort(result.begin(), result.end());
    return result;
}

SharedDataBucketsSplitter::BucketPaths SharedDataBucketsSplitter::getBucketPaths(size_t bucket) const
{
    const auto [shared_data_paths, shared_data_values, shared_data_offsets] = ColumnObject::getSharedDataPathsValuesAndOffsets(shared_data_column);

    BucketPaths result;
    const auto & unique_ids = bucket_unique_paths[bucket];
    if (unique_ids.empty())
        return result;

    /// Paths are addressed by their position among the distinct paths of the bucket (first-seen order) and
    /// written in sorted order, so `sorted_index` maps one to the other.
    std::vector<UInt32> order(unique_ids.size());
    for (size_t local = 0; local != unique_ids.size(); ++local)
        order[local] = static_cast<UInt32>(local);
    std::sort(order.begin(), order.end(), [&](UInt32 lhs, UInt32 rhs) { return id_to_path[unique_ids[lhs]] < id_to_path[unique_ids[rhs]]; });
    std::vector<UInt32> sorted_index(unique_ids.size());
    result.paths.reserve(unique_ids.size());
    for (size_t i = 0; i != order.size(); ++i)
    {
        sorted_index[order[i]] = static_cast<UInt32>(i);
        result.paths.push_back(id_to_path[unique_ids[order[i]]]);
    }

    const size_t bucket_begin = bucket_occurrences_begin[bucket];
    const size_t bucket_end = bucket_occurrences_begin[bucket + 1];

    /// Counting sort of the occurrences by path, stable so each path keeps its rows ascending.
    result.occurrences_begin.assign(unique_ids.size() + 1, 0);
    for (size_t position = bucket_begin; position != bucket_end; ++position)
        ++result.occurrences_begin[sorted_index[id_to_bucket_position[path_ids[bucket_occurrences[position]]]] + 1];
    for (size_t i = 0; i != unique_ids.size(); ++i)
        result.occurrences_begin[i + 1] += result.occurrences_begin[i];

    std::vector<size_t> next(result.occurrences_begin.begin(), result.occurrences_begin.end() - 1);
    result.rows.resize(bucket_end - bucket_begin);
    result.values.resize(bucket_end - bucket_begin);
    const size_t first_occurrence = (*shared_data_offsets)[ssize_t(start) - 1];
    size_t row = start;
    for (size_t position = bucket_begin; position != bucket_end; ++position)
    {
        size_t occurrence = bucket_occurrences[position];
        size_t j = first_occurrence + occurrence;
        while ((*shared_data_offsets)[ssize_t(row)] <= j)
            ++row;

        size_t index = next[sorted_index[id_to_bucket_position[path_ids[occurrence]]]]++;
        result.rows[index] = row - start;
        result.values[index] = j;
    }

    return result;
}

MutableColumnPtr SharedDataBucketsSplitter::flattenPath(const BucketPaths & bucket_paths, size_t path_index, const DataTypePtr & dynamic_type) const
{
    const auto * shared_data_values = &getValuesColumn();
    size_t num_rows = end - start;
    auto column = dynamic_type->createColumn();
    /// Every row gets a value or a default, so the discriminators and offsets of all rows are allocated at once.
    column->reserve(num_rows);
    auto & dynamic_column = assert_cast<ColumnDynamic &>(*column);
    /// Most paths keep one type across rows, so the column remembers the type of its last value.
    ColumnObject::SharedDataValueTypeCache type_cache;
    /// The values of one path are spread over the values column, so the ones a few iterations ahead are prefetched.
    static constexpr size_t prefetch_distance = 8;
    const auto & values_offsets = shared_data_values->getOffsets();
    const auto * values_chars = shared_data_values->getChars().data();
    const size_t occurrences_end = bucket_paths.occurrences_begin[path_index + 1];
    for (size_t i = bucket_paths.occurrences_begin[path_index]; i != occurrences_end; ++i)
    {
        if (i + prefetch_distance < occurrences_end)
            __builtin_prefetch(values_chars + values_offsets[ssize_t(bucket_paths.values[i + prefetch_distance]) - 1]);

        /// Backfill defaults for the rows where this path was absent, up to the current row.
        size_t row = bucket_paths.rows[i];
        if (column->size() < row)
            column->insertManyDefaults(row - column->size());
        ColumnObject::deserializeValueFromSharedData(shared_data_values, bucket_paths.values[i], dynamic_column, type_cache);
    }

    /// Backfill defaults for the trailing rows where the path was absent.
    if (column->size() < num_rows)
        column->insertManyDefaults(num_rows - column->size());
    return column;
}

const ColumnString & SharedDataBucketsSplitter::getValuesColumn() const
{
    return *std::get<1>(ColumnObject::getSharedDataPathsValuesAndOffsets(shared_data_column));
}

void collectSharedDataFromBuckets(const Columns & shared_data_buckets, IColumn & shared_data_column, const String * paths_prefix)
{
    const auto [shared_data_paths, shared_data_values, shared_data_offsets] = ColumnObject::getSharedDataPathsValuesAndOffsets(shared_data_column);
    std::vector<const ColumnString *> shared_data_paths_buckets(shared_data_buckets.size());
    std::vector<const ColumnString *> shared_data_values_buckets(shared_data_buckets.size());
    std::vector<const ColumnArray::Offsets *> shared_data_offsets_buckets(shared_data_buckets.size());
    for (size_t i = 0; i != shared_data_buckets.size(); ++i)
        std::tie(shared_data_paths_buckets[i], shared_data_values_buckets[i], shared_data_offsets_buckets[i]) = ColumnObject::getSharedDataPathsValuesAndOffsets(*shared_data_buckets[i]);

    size_t num_rows = shared_data_buckets[0]->size();
    /// Every row is collected from all buckets at once, so a shorter bucket would be indexed out of bounds.
    for (size_t bucket = 1; bucket != shared_data_buckets.size(); ++bucket)
    {
        if (shared_data_buckets[bucket]->size() != num_rows)
            throw Exception(
                ErrorCodes::LOGICAL_ERROR,
                "Bucket {} of Object shared data has {} rows, but bucket 0 has {} rows",
                bucket,
                shared_data_buckets[bucket]->size(),
                num_rows);
    }

    /// Without a prefix every path and value of every bucket is collected, so the result sizes are known in advance.
    if (!paths_prefix)
    {
        size_t num_values = shared_data_paths->size();
        size_t paths_bytes = shared_data_paths->getChars().size();
        size_t values_bytes = shared_data_values->getChars().size();
        for (size_t bucket = 0; bucket != shared_data_buckets.size(); ++bucket)
        {
            num_values += shared_data_paths_buckets[bucket]->size();
            paths_bytes += shared_data_paths_buckets[bucket]->getChars().size();
            values_bytes += shared_data_values_buckets[bucket]->getChars().size();
        }

        shared_data_paths->reserve(num_values);
        shared_data_paths->getChars().reserve_exact(paths_bytes);
        shared_data_values->reserve(num_values);
        shared_data_values->getChars().reserve_exact(values_bytes);
        shared_data_offsets->reserve_exact(shared_data_offsets->size() + num_rows);
    }

    /// Reused across rows to avoid an allocation per row.
    std::vector<std::tuple<std::string_view, size_t, size_t>> all_paths;
    for (size_t i = 0; i != num_rows; ++i)
    {
        /// Shared data contains paths in sorted order in each row.
        /// Collect all paths from all buckets in this row and sort them.
        /// Save each path bucket and index to be able find corresponding value later.
        all_paths.clear();
        for (size_t bucket = 0; bucket != shared_data_buckets.size(); ++bucket)
        {
            size_t offset_start = (*shared_data_offsets_buckets[bucket])[ssize_t(i) - 1];
            size_t offset_end = (*shared_data_offsets_buckets[bucket])[ssize_t(i)];

            /// If no paths prefix specified, collect all paths.
            if (!paths_prefix)
            {
                for (size_t j = offset_start; j != offset_end; ++j)
                {
                    auto path = shared_data_paths_buckets[bucket]->getDataAt(j);
                    all_paths.emplace_back(path, bucket, j);
                }
            }
            /// Otherwise collect only paths that match the prefix.
            else
            {
                size_t lower_bound_index = ColumnObject::findPathLowerBoundInSharedData(*paths_prefix, *shared_data_paths_buckets[bucket], offset_start, offset_end);
                for (; lower_bound_index != offset_end; ++lower_bound_index)
                {
                    auto path = shared_data_paths_buckets[bucket]->getDataAt(lower_bound_index);
                    if (!path.starts_with(*paths_prefix))
                        break;
                    auto sub_path = path.substr(paths_prefix->size());
                    all_paths.emplace_back(sub_path, bucket, lower_bound_index);
                }
            }
        }

        std::sort(all_paths.begin(), all_paths.end());
        for (const auto [path, bucket, offset] : all_paths)
        {
            shared_data_paths->insertData(path.data(), path.size());
            shared_data_values->insertFrom(*shared_data_values_buckets[bucket], offset);
        }

        shared_data_offsets->push_back(shared_data_paths->size());
    }
}

namespace
{

template <typename T>
ColumnPtr createPathsIndexesImpl(const PODArray<UInt32> & path_ids, const PODArray<UInt64> & id_to_index)
{
    auto indexes_column = ColumnVector<T>::create();
    auto & data = indexes_column->getData();
    data.resize(path_ids.size());
    for (size_t i = 0; i != path_ids.size(); ++i)
        data[i] = static_cast<T>(id_to_index[path_ids[i]]);
    return indexes_column;
}

template <typename T = UInt8>
void deserializeIndexesAndCollectPathsImpl(ColumnString & paths_column, ReadBuffer & istr, VectorWithMemoryTracking<String> && paths, size_t limit)
{
    auto & data = paths_column.getChars();
    auto & offsets = paths_column.getOffsets();
    size_t offset = data.size();

    /// Avoiding calling resize in a loop improves the performance.
    data.resize(std::max(data.capacity(), static_cast<size_t>(4096)));

    /// The number of indexes comes from the offsets, so stopping at the end of the stream would leave the
    /// paths column shorter than the offsets say and it would be read out of bounds.
    for (size_t i = 0; i != limit; ++i)
    {
        T index;
        readBinaryLittleEndian(index, istr);

        if (index >= paths.size())
            throw Exception(ErrorCodes::LOGICAL_ERROR, "Object path index is out of range: {} >= {}", static_cast<UInt64>(index), paths.size());

        const String & path = paths[index];
        offset += path.size();
        offsets.push_back(offset);

        /// Reallocate data if needed.
        if (unlikely(offset > data.size()))
            data.resize_exact(roundUpToPowerOfTwoOrZero(std::max(offset, data.size() * 2)));

        memcpy(&data[offset - path.size()], path.data(), path.size());
    }

    data.resize_exact(offset);
}

}

std::pair<ColumnPtr, DataTypePtr> SharedDataBucketsSplitter::createPathsIndexes() const
{
    PODArray<UInt64> id_to_index(id_to_path.size());
    size_t index = 0;
    std::vector<UInt32> ids;
    for (size_t bucket = 0; bucket != num_buckets; ++bucket)
    {
        ids = bucket_unique_paths[bucket];
        std::sort(ids.begin(), ids.end(), [&](UInt32 lhs, UInt32 rhs) { return id_to_path[lhs] < id_to_path[rhs]; });
        for (UInt32 id : ids)
            id_to_index[id] = index++;
    }

    auto indexes_type = getSmallestIndexesType(id_to_path.size());
    switch (indexes_type->getTypeId())
    {
        case TypeIndex::UInt8:
            return {createPathsIndexesImpl<UInt8>(path_ids, id_to_index), indexes_type};
        case TypeIndex::UInt16:
            return {createPathsIndexesImpl<UInt16>(path_ids, id_to_index), indexes_type};
        case TypeIndex::UInt32:
            return {createPathsIndexesImpl<UInt32>(path_ids, id_to_index), indexes_type};
        case TypeIndex::UInt64:
            return {createPathsIndexesImpl<UInt64>(path_ids, id_to_index), indexes_type};
        default:
            throw Exception(ErrorCodes::LOGICAL_ERROR, "Unexpected type of paths indexes: {}", indexes_type->getName());
    }
}

void deserializeIndexesAndCollectPaths(IColumn & paths_column, ReadBuffer & istr, VectorWithMemoryTracking<String> && paths, size_t limit)
{
    auto & paths_string_column = assert_cast<ColumnString &>(paths_column);
    auto indexes_type = getSmallestIndexesType(paths.size());
    switch (indexes_type->getTypeId())
    {
        case TypeIndex::UInt8:
            deserializeIndexesAndCollectPathsImpl<UInt8>(paths_string_column, istr, std::move(paths), limit);
            break;
        case TypeIndex::UInt16:
            deserializeIndexesAndCollectPathsImpl<UInt16>(paths_string_column, istr, std::move(paths), limit);
            break;
        case TypeIndex::UInt32:
            deserializeIndexesAndCollectPathsImpl<UInt32>(paths_string_column, istr, std::move(paths), limit);
            break;
        case TypeIndex::UInt64:
            deserializeIndexesAndCollectPathsImpl<UInt64>(paths_string_column, istr, std::move(paths), limit);
            break;
        default:
            throw Exception(ErrorCodes::LOGICAL_ERROR, "Unexpected column type of paths indexes: {}", indexes_type->getName());
    }
}

}
