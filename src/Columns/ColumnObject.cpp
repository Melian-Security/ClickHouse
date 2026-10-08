#include <DataTypes/DataTypesBinaryEncoding.h>
#include <DataTypes/DataTypesCache.h>
#include <DataTypes/DataTypeDynamic.h>
#include <DataTypes/DataTypeVariant.h>
#include <DataTypes/Serializations/SerializationString.h>
#include <Columns/ColumnObject.h>
#include <Columns/ColumnCompressed.h>
#include <Columns/ColumnConst.h>
#include <Columns/ColumnNullable.h>
#include <Columns/ColumnVariant.h>
#include <IO/Operators.h>
#include <IO/VarInt.h>
#include <IO/WriteBufferFromString.h>
#include <Common/Arena.h>
#include <atomic>
#include <bit>
#include <optional>
#include <Common/HashTable/Hash.h>
#include <Common/HashTable/HashMap.h>
#include <Common/HashTable/HashSet.h>
#include <Common/PODArray.h>
#include <Common/SipHash.h>
#include <Common/UnorderedSetWithMemoryTracking.h>
#include <Common/logger_useful.h>
#include <Common/memcpySmall.h>
#include <Common/typeid_cast.h>
#include <Processors/Transforms/ColumnGathererTransform.h>
#include <base/scope_guard.h>

namespace DB
{

namespace ErrorCodes
{
    extern const int ATTEMPT_TO_READ_AFTER_EOF;
    extern const int NOT_IMPLEMENTED;
    extern const int LOGICAL_ERROR;
    extern const int PARAMETER_OUT_OF_BOUND;
}

namespace
{

const FormatSettings & getFormatSettings()
{
    static thread_local const FormatSettings settings;
    return settings;
}

template <typename Container, typename Compare>
void sortAndKeepTop(Container & container, size_t limit, Compare compare)
{
    if (container.size() <= limit)
    {
        std::sort(container.begin(), container.end(), compare);
        return;
    }

    if (limit == 0)
    {
        container.clear();
        return;
    }

    auto nth = container.begin() + limit;
    std::nth_element(container.begin(), nth, container.end(), compare);
    container.resize(limit);
    std::sort(container.begin(), container.end(), compare);
}

const SerializationPtr & getDynamicSerialization()
{
    static thread_local const SerializationPtr dynamic_serialization = DataTypeDynamic().getDefaultSerialization();
    return dynamic_serialization;
}

struct ColumnObjectCheckpoint : public ColumnCheckpoint
{
    using CheckpointsMap = UnorderedMapWithMemoryTracking<std::string_view, ColumnCheckpointPtr>;

    ColumnObjectCheckpoint(size_t size_, CheckpointsMap typed_paths_, CheckpointsMap dynamic_paths_, ColumnCheckpointPtr shared_data_)
        : ColumnCheckpoint(size_)
        , typed_paths(std::move(typed_paths_))
        , dynamic_paths(std::move(dynamic_paths_))
        , shared_data(std::move(shared_data_))
    {
    }

    CheckpointsMap typed_paths;
    CheckpointsMap dynamic_paths;
    ColumnCheckpointPtr shared_data;
};

}

ColumnObject::ColumnObject(
    UnorderedMapWithMemoryTracking<String, MutableColumnPtr> typed_paths_,
    UnorderedMapWithMemoryTracking<String, MutableColumnPtr> dynamic_paths_,
    MutableColumnPtr shared_data_,
    size_t max_dynamic_paths_,
    size_t max_dynamic_paths_upper_bound_,
    size_t global_max_dynamic_paths_,
    size_t max_dynamic_types_,
    const StatisticsPtr & statistics_)
    : shared_data(std::move(shared_data_))
    , max_dynamic_paths(max_dynamic_paths_)
    , max_dynamic_paths_upper_bound(max_dynamic_paths_upper_bound_)
    , global_max_dynamic_paths(global_max_dynamic_paths_)
    , max_dynamic_types(max_dynamic_types_)
    , statistics(statistics_)
{
    typed_paths.reserve(typed_paths_.size());
    sorted_typed_paths.reserve(typed_paths_.size());
    for (auto & [path, column] : typed_paths_)
    {
        auto it = typed_paths.emplace(path, std::move(column)).first;
        sorted_typed_paths.push_back(it->first);
    }
    std::sort(sorted_typed_paths.begin(), sorted_typed_paths.end());

    sorted_typed_path_columns.reserve(sorted_typed_paths.size());
    for (const auto & path : sorted_typed_paths)
        sorted_typed_path_columns.push_back(typed_paths.find(path)->second.get());

    dynamic_paths.reserve(dynamic_paths_.size());
    dynamic_paths_ptrs.reserve(dynamic_paths_.size());
    for (auto & [path, column] : dynamic_paths_)
    {
        auto it = dynamic_paths.emplace(path, std::move(column)).first;
        dynamic_paths_ptrs[path] = assert_cast<ColumnDynamic *>(it->second.get());
        sorted_dynamic_paths.insert(it->first);
    }
}

ColumnObject::ColumnObject(
    UnorderedMapWithMemoryTracking<String, MutableColumnPtr> typed_paths_, size_t max_dynamic_paths_, size_t max_dynamic_types_)
    : max_dynamic_paths(max_dynamic_paths_)
    , max_dynamic_paths_upper_bound(max_dynamic_paths_)
    , global_max_dynamic_paths(max_dynamic_paths_)
    , max_dynamic_types(max_dynamic_types_)
{
    typed_paths.reserve(typed_paths_.size());
    sorted_typed_paths.reserve(typed_paths_.size());
    for (auto & [path, column] : typed_paths_)
    {
        if (!column->empty())
            throw Exception(ErrorCodes::LOGICAL_ERROR, "Unexpected non-empty typed path column in ColumnObject constructor");
        auto it = typed_paths.emplace(path, std::move(column)).first;
        sorted_typed_paths.push_back(it->first);
    }

    std::sort(sorted_typed_paths.begin(), sorted_typed_paths.end());

    sorted_typed_path_columns.reserve(sorted_typed_paths.size());
    for (const auto & path : sorted_typed_paths)
        sorted_typed_path_columns.push_back(typed_paths.find(path)->second.get());

    MutableColumns paths_and_values;
    paths_and_values.emplace_back(ColumnString::create());
    paths_and_values.emplace_back(ColumnString::create());
    shared_data = ColumnArray::create(ColumnTuple::create(std::move(paths_and_values)));
}

ColumnObject::ColumnObject(const ColumnObject & other)
    : COWHelper<IColumnHelper<ColumnObject>, ColumnObject>(other)
    , typed_paths(other.typed_paths)
    , dynamic_paths(other.dynamic_paths)
    , dynamic_paths_ptrs(other.dynamic_paths_ptrs)
    , shared_data(other.shared_data)
    , max_dynamic_paths(other.max_dynamic_paths)
    , max_dynamic_paths_upper_bound(other.max_dynamic_paths_upper_bound)
    , global_max_dynamic_paths(other.global_max_dynamic_paths)
    , max_dynamic_types(other.max_dynamic_types)
    , statistics(other.statistics)
{
    /// We should update string_view in sorted_typed_paths and sorted_dynamic_paths so they
    /// point to the new strings in typed_paths and dynamic_paths.
    sorted_typed_paths.clear();
    for (const auto & [path, _] : typed_paths)
        sorted_typed_paths.emplace_back(path);
    std::sort(sorted_typed_paths.begin(), sorted_typed_paths.end());

    sorted_typed_path_columns.clear();
    sorted_typed_path_columns.reserve(sorted_typed_paths.size());
    for (const auto & path : sorted_typed_paths)
        sorted_typed_path_columns.push_back(typed_paths.find(path)->second.get());

    sorted_dynamic_paths.clear();
    for (const auto & [path, _] : dynamic_paths)
        sorted_dynamic_paths.emplace(path);
}

void ColumnObject::rebuildSortedTypedPathColumns()
{
    sorted_typed_path_columns.clear();
    sorted_typed_path_columns.reserve(sorted_typed_paths.size());
    for (const auto & path : sorted_typed_paths)
        sorted_typed_path_columns.push_back(typed_paths.find(path)->second.get());
}

ColumnObject::Ptr ColumnObject::create(
    const UnorderedMapWithMemoryTracking<String, ColumnPtr> & typed_paths_,
    const UnorderedMapWithMemoryTracking<String, ColumnPtr> & dynamic_paths_,
    const ColumnPtr & shared_data_,
    size_t max_dynamic_paths_,
    size_t max_dynamic_paths_upper_bound_,
    size_t global_max_dynamic_paths_,
    size_t max_dynamic_types_,
    const ColumnObject::StatisticsPtr & statistics_)
{
    UnorderedMapWithMemoryTracking<String, MutableColumnPtr> mutable_typed_paths;
    mutable_typed_paths.reserve(typed_paths_.size());
    for (const auto & [path, column] : typed_paths_)
        mutable_typed_paths[path] = typed_paths_.at(path)->assumeMutable();

    UnorderedMapWithMemoryTracking<String, MutableColumnPtr> mutable_dynamic_paths;
    mutable_dynamic_paths.reserve(dynamic_paths_.size());
    for (const auto & [path, column] : dynamic_paths_)
        mutable_dynamic_paths[path] = dynamic_paths_.at(path)->assumeMutable();

    return ColumnObject::create(
        std::move(mutable_typed_paths),
        std::move(mutable_dynamic_paths),
        shared_data_->assumeMutable(),
        max_dynamic_paths_,
        max_dynamic_paths_upper_bound_,
        global_max_dynamic_paths_,
        max_dynamic_types_,
        statistics_);
}

ColumnObject::MutablePtr ColumnObject::create(
    UnorderedMapWithMemoryTracking<String, MutableColumnPtr> typed_paths_,
    UnorderedMapWithMemoryTracking<String, MutableColumnPtr> dynamic_paths_,
    MutableColumnPtr shared_data_,
    size_t max_dynamic_paths_,
    size_t max_dynamic_paths_upper_bound_,
    size_t global_max_dynamic_paths_,
    size_t max_dynamic_types_,
    const ColumnObject::StatisticsPtr & statistics_)
{
    return Base::create(std::move(typed_paths_), std::move(dynamic_paths_), std::move(shared_data_), max_dynamic_paths_, max_dynamic_paths_upper_bound_, global_max_dynamic_paths_, max_dynamic_types_, statistics_);
}

ColumnObject::MutablePtr ColumnObject::create(UnorderedMapWithMemoryTracking<String, MutableColumnPtr> typed_paths_, size_t max_dynamic_paths_, size_t max_dynamic_types_)
{
    return Base::create(std::move(typed_paths_), max_dynamic_paths_, max_dynamic_types_);
}

std::string ColumnObject::getName() const
{
    WriteBufferFromOwnString ss;
    ss << "Object(";
    ss << "max_dynamic_paths=" << global_max_dynamic_paths;
    ss << ", max_dynamic_types=" << max_dynamic_types;
    for (const auto & path : sorted_typed_paths)
        ss << ", " << path << " " << typed_paths.find(path)->second->getName();
    ss << ")";
    return ss.str();
}

MutableColumnPtr ColumnObject::cloneEmpty() const
{
    UnorderedMapWithMemoryTracking<String, MutableColumnPtr> empty_typed_paths;
    empty_typed_paths.reserve(typed_paths.size());
    for (const auto & [path, column] : typed_paths)
        empty_typed_paths[path] = column->cloneEmpty();

    UnorderedMapWithMemoryTracking<String, MutableColumnPtr> empty_dynamic_paths;
    empty_dynamic_paths.reserve(dynamic_paths.size());
    for (const auto & [path, column] : dynamic_paths)
        empty_dynamic_paths[path] = column->cloneEmpty();

    return ColumnObject::create(
        std::move(empty_typed_paths),
        std::move(empty_dynamic_paths),
        shared_data->cloneEmpty(),
        max_dynamic_paths,
        max_dynamic_paths_upper_bound,
        global_max_dynamic_paths,
        max_dynamic_types,
        statistics);
}

MutableColumnPtr ColumnObject::cloneResized(size_t size) const
{
    UnorderedMapWithMemoryTracking<String, MutableColumnPtr> resized_typed_paths;
    resized_typed_paths.reserve(typed_paths.size());
    for (const auto & [path, column] : typed_paths)
        resized_typed_paths[path] = column->cloneResized(size);

    UnorderedMapWithMemoryTracking<String, MutableColumnPtr> resized_dynamic_paths;
    resized_dynamic_paths.reserve(dynamic_paths.size());
    for (const auto & [path, column] : dynamic_paths)
        resized_dynamic_paths[path] = column->cloneResized(size);

    return ColumnObject::create(
        std::move(resized_typed_paths),
        std::move(resized_dynamic_paths),
        shared_data->cloneResized(size),
        max_dynamic_paths,
        max_dynamic_paths_upper_bound,
        global_max_dynamic_paths,
        max_dynamic_types,
        statistics);
}

Field ColumnObject::operator[](size_t n) const
{
    Object object;

    for (const auto & [path, column] : typed_paths)
        object[path] = (*column)[n];
    for (const auto & [path, column] : dynamic_paths_ptrs)
    {
        /// Output only non-null values from dynamic paths. We cannot distinguish cases when
        /// dynamic path has Null value and when it's absent in the row and consider them equivalent.
        if (!column->isNullAt(n))
            object[path] = (*column)[n];
    }

    const auto & shared_data_offsets = getSharedDataOffsets();
    const auto [shared_paths, shared_values] = getSharedDataPathsAndValues();
    size_t start = shared_data_offsets[static_cast<ssize_t>(n) - 1];
    size_t end = shared_data_offsets[n];
    for (size_t i = start; i != end; ++i)
    {
        String path{shared_paths->getDataAt(i)};
        auto value_data = shared_values->getDataAt(i);
        ReadBufferFromMemory buf(value_data);
        Field value;
        getDynamicSerialization()->deserializeBinary(value, buf, getFormatSettings());
        object[path] = value;
    }

    return object;
}

void ColumnObject::get(size_t n, Field & res) const
{
    res = (*this)[n];
}

void ColumnObject::getValueNameImpl(WriteBufferFromOwnString & name_buf, size_t n, const Options & options) const
{
    if (options.notFull(name_buf))
        name_buf << '{';

    bool first = true;

    if (options.notFull(name_buf))
    {
        for (const auto & [path, column] : typed_paths)
        {
            if (!options.notFull(name_buf))
                break;

            if (first)
                first = false;
            else
                name_buf << ", ";
            writeDoubleQuoted(path, name_buf);
            column->getValueNameImpl(name_buf, n, options);
        }
    }

    if (options.notFull(name_buf))
    {
        for (const auto & [path, column] : dynamic_paths_ptrs)
        {
            if (!options.notFull(name_buf))
                break;

            /// Output only non-null values from dynamic paths. We cannot distinguish cases when
            /// dynamic path has Null value and when it's absent in the row and consider them equivalent.
            if (column->isNullAt(n))
                continue;

            if (first)
                first = false;
            else
                name_buf << ", ";
            writeDoubleQuoted(path, name_buf);
            column->getValueNameImpl(name_buf, n, options);
        }
    }

    if (options.notFull(name_buf))
    {
        const auto & shared_data_offsets = getSharedDataOffsets();
        const auto [shared_paths, shared_values] = getSharedDataPathsAndValues();
        size_t start = shared_data_offsets[static_cast<ssize_t>(n) - 1];
        size_t end = shared_data_offsets[n];
        for (size_t i = start; i != end; ++i)
        {
            if (!options.notFull(name_buf))
                break;

            if (first)
                first = false;
            else
                name_buf << ", ";

            String path{shared_paths->getDataAt(i)};
            writeDoubleQuoted(path, name_buf);

            auto value_data = shared_values->getDataAt(i);
            ReadBufferFromMemory buf(value_data);
            auto decoded_type = decodeDataType(buf);

            if (isNothing(decoded_type))
            {
                name_buf << ": NULL";
                continue;
            }

            const auto column = decoded_type->createColumn();
            decoded_type->getDefaultSerialization()->deserializeBinary(*column, buf, getFormatSettings());

            column->getValueNameImpl(name_buf, 0, options);
        }
    }

    if (options.notFull(name_buf))
        name_buf << "}";
}

bool ColumnObject::isDefaultAt(size_t n) const
{
    for (const auto & [path, column] : typed_paths)
    {
        if (!column->isDefaultAt(n))
            return false;
    }

    for (const auto & [path, column] : dynamic_paths_ptrs)
    {
        if (!column->isDefaultAt(n))
            return false;
    }

    if (!shared_data->isDefaultAt(n))
        return false;

    return true;
}

UInt64 ColumnObject::getNumberOfDefaultRows() const
{
    /// Avoid the O(rows * paths) per-row virtual `isDefaultAt` calls of the IColumnHelper
    /// default: query each subcolumn's non-default rows once and union them in a bitmap.
    const size_t num_rows = size();
    if (num_rows == 0)
        return 0;

    PaddedPODArray<UInt8> non_default_anywhere;
    non_default_anywhere.resize_fill(num_rows);  /// zero-initialised via memset
    size_t num_non_default = 0;

    auto add_non_defaults_of = [&](const IColumn & column)
    {
        if (num_non_default == num_rows)
            return;

        const size_t num_defaults_in_column = column.getNumberOfDefaultRows();
        if (num_defaults_in_column == num_rows)
            return;
        if (num_defaults_in_column == 0)
        {
            std::memset(non_default_anywhere.data(), 1, num_rows);
            num_non_default = num_rows;
            return;
        }

        IColumn::Offsets non_default_indices;
        column.getIndicesOfNonDefaultRows(non_default_indices, /*from=*/0, /*limit=*/0);
        for (UInt64 idx : non_default_indices)
        {
            if (!non_default_anywhere[idx])
            {
                non_default_anywhere[idx] = 1;
                ++num_non_default;
            }
        }
    };

    for (const auto & [path, column] : typed_paths)
        add_non_defaults_of(*column);

    for (const auto & [path, column] : dynamic_paths_ptrs)
        add_non_defaults_of(*column);

    add_non_defaults_of(*shared_data);

    return num_rows - num_non_default;
}

bool ColumnObject::hasOnlyTypeDefaults() const
{
    for (const auto & [path, column] : typed_paths)
    {
        if (!column->hasOnlyTypeDefaults())
            return false;
    }

    for (const auto & [path, column] : dynamic_paths_ptrs)
    {
        if (!column->hasOnlyTypeDefaults())
            return false;
    }

    return shared_data->hasOnlyTypeDefaults();
}

std::string_view ColumnObject::getDataAt(size_t) const
{
    throw Exception(ErrorCodes::NOT_IMPLEMENTED, "Method getDataAt is not supported for {}", getName());
}

void ColumnObject::insertData(const char *, size_t)
{
    throw Exception(ErrorCodes::NOT_IMPLEMENTED, "Method insertData is not supported for {}", getName());
}

UInt64 ColumnObject::getNextDynamicPathsVersion()
{
    static std::atomic<UInt64> last_version = 0;
    return last_version.fetch_add(1, std::memory_order_relaxed) + 1;
}

ColumnDynamic * ColumnObject::tryToAddNewDynamicPath(std::string_view path)
{
    if (dynamic_paths.size() == max_dynamic_paths)
        return nullptr;

    auto new_dynamic_column = ColumnDynamic::create(max_dynamic_types);
    new_dynamic_column->reserve(shared_data->capacity());
    new_dynamic_column->insertManyDefaults(size());
    auto it = dynamic_paths.emplace(path, std::move(new_dynamic_column)).first;
    auto it_ptr = dynamic_paths_ptrs.emplace(path, assert_cast<ColumnDynamic *>(it->second.get())).first;
    sorted_dynamic_paths.insert(it->first);
    updateDynamicPathsVersion();
    /// Invalidate statistics because they refer to the old set of dynamic paths.
    statistics.reset();
    return it_ptr->second;
}

void ColumnObject::addNewDynamicPath(std::string_view path, MutableColumnPtr column)
{
    if (dynamic_paths.size() == max_dynamic_paths)
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Cannot add new dynamic path as the limit ({}) on dynamic paths is reached", max_dynamic_paths);

    if (!empty())
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Setting specific column for dynamic path is allowed only for empty object column");

    auto it = dynamic_paths.emplace(path, std::move(column)).first;
    dynamic_paths_ptrs.emplace(path, assert_cast<ColumnDynamic *>(it->second.get()));
    sorted_dynamic_paths.insert(it->first);
    updateDynamicPathsVersion();
}

void ColumnObject::addNewDynamicPath(std::string_view path)
{
    if (!tryToAddNewDynamicPath(path))
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Cannot add new dynamic path as the limit ({}) on dynamic paths is reached", max_dynamic_paths);
}

void ColumnObject::setMaxDynamicPaths(size_t max_dynamic_paths_)
{
    if (!empty())
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Setting specific max_dynamic_paths parameter is allowed only for empty object column");

    max_dynamic_paths = max_dynamic_paths_;
    updateDynamicPathsVersion();
}

void ColumnObject::setMaxDynamicPathsUpperBound(size_t max_dynamic_paths_upper_bound_)
{
    /// Lowering the bound only restricts paths added later, so unlike max_dynamic_paths it doesn't
    /// require an empty column: the paths already present just have to fit under the new bound.
    if (max_dynamic_paths_upper_bound_ < dynamic_paths.size())
        throw Exception(
            ErrorCodes::LOGICAL_ERROR,
            "Cannot set the upper bound on max_dynamic_paths to {}, the column already has {} dynamic paths",
            max_dynamic_paths_upper_bound_,
            dynamic_paths.size());

    /// The bound can only be narrowed: widening it back is exactly what it exists to prevent.
    if (max_dynamic_paths_upper_bound_ > max_dynamic_paths_upper_bound)
        throw Exception(
            ErrorCodes::LOGICAL_ERROR,
            "Cannot raise the upper bound on max_dynamic_paths from {} to {}",
            max_dynamic_paths_upper_bound,
            max_dynamic_paths_upper_bound_);

    max_dynamic_paths_upper_bound = max_dynamic_paths_upper_bound_;
    if (max_dynamic_paths > max_dynamic_paths_upper_bound)
    {
        max_dynamic_paths = max_dynamic_paths_upper_bound;
        updateDynamicPathsVersion();
    }
}

void ColumnObject::takeMaxDynamicPathsUpperBoundFrom(const ColumnObject & src)
{
    /// Paths already added cannot be taken back, so the bound cannot go below their number.
    size_t new_upper_bound = std::max(src.max_dynamic_paths_upper_bound, dynamic_paths.size());
    if (new_upper_bound >= max_dynamic_paths_upper_bound)
        return;

    max_dynamic_paths_upper_bound = new_upper_bound;
    if (max_dynamic_paths > new_upper_bound)
    {
        max_dynamic_paths = new_upper_bound;
        updateDynamicPathsVersion();
    }
}

void ColumnObject::setDynamicPaths(const VectorWithMemoryTracking<String> & paths)
{
    if (!empty())
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Setting specific max_dynamic_paths parameter is allowed only for empty object column");

    if (paths.size() > max_dynamic_paths)
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Cannot set dynamic paths to Object column, the number of paths ({}) exceeds the limit ({})", paths.size(), max_dynamic_paths);

    /// Clear current dynamic structure if any.
    dynamic_paths_ptrs.clear();
    dynamic_paths.clear();
    sorted_dynamic_paths.clear();

    size_t size = this->size();
    for (const auto & path : paths)
    {
        auto new_dynamic_column = ColumnDynamic::create(max_dynamic_types);
        if (size)
            new_dynamic_column->insertManyDefaults(size);
        auto it = dynamic_paths.emplace(path, std::move(new_dynamic_column)).first;
        dynamic_paths_ptrs[path] = assert_cast<ColumnDynamic *>(it->second.get());
        sorted_dynamic_paths.insert(it->first);
    }
    updateDynamicPathsVersion();
}

void ColumnObject::setDynamicPaths(const VectorWithMemoryTracking<std::pair<String, ColumnPtr>> & paths)
{
    if (paths.size() > max_dynamic_paths)
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Cannot set dynamic paths to Object column, the number of paths ({}) exceeds the limit ({})", paths.size(), max_dynamic_paths);

    for (const auto & [path, column] : paths)
    {
        auto it = dynamic_paths.emplace(path, column).first;
        dynamic_paths_ptrs[path] = assert_cast<ColumnDynamic *>(it->second.get());
        sorted_dynamic_paths.insert(it->first);
    }

    /// Invalidate statistics because they refer to the old set of dynamic paths.
    if (!paths.empty())
    {
        statistics.reset();
        updateDynamicPathsVersion();
    }
}

void ColumnObject::insert(const Field & x)
{
    const auto & object = x.safeGet<Object>();
    auto & shared_data_offsets = getSharedDataOffsets();
    auto [shared_data_paths, shared_data_values] = getSharedDataPathsAndValues();
    size_t current_size = size();
    for (const auto & [path, value_field] : object)
    {
        if (auto typed_it = typed_paths.find(path); typed_it != typed_paths.end())
        {
            typed_it->second->insert(value_field);
        }
        else if (auto dynamic_it = dynamic_paths_ptrs.find(path); dynamic_it != dynamic_paths_ptrs.end())
        {
            dynamic_it->second->insert(value_field);
        }
        else if (auto * dynamic_path_column = tryToAddNewDynamicPath(path))
        {
            dynamic_path_column->insert(value_field);
        }
        /// We reached the limit on dynamic paths. Add this path to the common data if the value is not Null.
        /// (we cannot distinguish cases when path has Null value or is absent in the row and consider them equivalent).
        /// Object is actually map, so all paths are already sorted and we can add it right now.
        else if (!value_field.isNull())
        {
            shared_data_paths->insertData(path.data(), path.size());
            auto & shared_data_values_chars = shared_data_values->getChars();
            {
                WriteBufferFromVector<ColumnString::Chars> value_buf(shared_data_values_chars, AppendModeTag());
                getDynamicSerialization()->serializeBinary(value_field, value_buf, getFormatSettings());
            }
            shared_data_values->getOffsets().push_back(shared_data_values_chars.size());
        }
    }

    shared_data_offsets.push_back(shared_data_paths->size());

    /// Fill all remaining typed and dynamic paths with default values.
    for (auto & [_, column] : typed_paths)
    {
        if (column->size() == current_size)
            column->insertDefault();
    }

    for (auto & [_, column] : dynamic_paths_ptrs)
    {
        if (column->size() == current_size)
            column->insertDefault();
    }
}

bool ColumnObject::tryInsert(const Field & x)
{
    if (x.getType() != Field::Types::Which::Object)
        return false;

    const auto & object = x.safeGet<Object>();
    auto & shared_data_offsets = getSharedDataOffsets();
    auto [shared_data_paths, shared_data_values] = getSharedDataPathsAndValues();
    size_t prev_size = size();
    size_t prev_paths_size = shared_data_paths->size();
    size_t prev_values_size = shared_data_values->size();
    /// Save all newly added dynamic paths. In case of failure
    /// we should remove them.
    UnorderedSetWithMemoryTracking<String> new_dynamic_paths;
    auto restore_sizes = [&]()
    {
        for (auto & [_, column] : typed_paths)
        {
            if (column->size() != prev_size)
                column->popBack(column->size() - prev_size);
        }

        /// Remove all newly added dynamic paths.
        for (const auto & path : new_dynamic_paths)
        {
            dynamic_paths_ptrs.erase(path);
            sorted_dynamic_paths.erase(path);
            dynamic_paths.erase(path);
        }
        updateDynamicPathsVersion();

        for (auto & [_, column] : dynamic_paths_ptrs)
        {
            if (column->size() != prev_size)
                column->popBack(column->size() - prev_size);
        }

        if (shared_data_paths->size() != prev_paths_size)  /// NOLINT(clang-analyzer-core.NullDereference)
            shared_data_paths->popBack(shared_data_paths->size() - prev_paths_size);
        if (shared_data_values->size() != prev_values_size)
            shared_data_values->popBack(shared_data_values->size() - prev_values_size);
    };

    for (const auto & [path, value_field] : object)
    {
        if (auto typed_it = typed_paths.find(path); typed_it != typed_paths.end())
        {
            if (!typed_it->second->tryInsert(value_field))
            {
                restore_sizes();
                return false;
            }
        }
        else if (auto dynamic_it = dynamic_paths_ptrs.find(path); dynamic_it != dynamic_paths_ptrs.end())
        {
            if (!dynamic_it->second->tryInsert(value_field))
            {
                restore_sizes();
                return false;
            }
        }
        else if (auto * dynamic_path_column = tryToAddNewDynamicPath(path))
        {
            new_dynamic_paths.insert(String(path));
            if (!dynamic_path_column->tryInsert(value_field))
            {
                restore_sizes();
                return false;
            }
        }
        /// We reached the limit on dynamic paths. Add this path to the common data if the value is not Null.
        /// (we cannot distinguish cases when path has Null value or is absent in the row and consider them equivalent).
        /// Object is actually map, so all paths are already sorted and we can add it right now.
        else if (!value_field.isNull())
        {
            WriteBufferFromOwnString value_buf;
            getDynamicSerialization()->serializeBinary(value_field, value_buf, getFormatSettings());
            shared_data_paths->insertData(path.data(), path.size());
            shared_data_values->insertData(value_buf.str().data(), value_buf.str().size());
        }
    }

    shared_data_offsets.push_back(shared_data_paths->size());

    /// Fill all remaining typed and dynamic paths with default values.
    for (auto & [_, column] : typed_paths)
    {
        if (column->size() == prev_size)
            column->insertDefault();
    }

    for (auto & [_, column] : dynamic_paths_ptrs)
    {
        if (column->size() == prev_size)
            column->insertDefault();
    }

    return true;
}

namespace
{

/// Consecutive rows of a source column.
struct SourceRange
{
    const IColumn * column;
    size_t start;
    size_t length;
};

void insertSourceRanges(IColumn & column, std::span<const SourceRange> ranges);

void insertStringRanges(ColumnString & column, std::span<const SourceRange> ranges)
{
    size_t num_rows = 0;
    size_t num_bytes = 0;
    for (const auto & range : ranges)
    {
        const auto & src_offsets = assert_cast<const ColumnString &>(*range.column).getOffsets();
        num_rows += range.length;
        /// Offsets have a padding element before the first one, which is 0.
        num_bytes += src_offsets[range.start + range.length - 1] - src_offsets[static_cast<ssize_t>(range.start) - 1];
    }

    auto & chars = column.getChars();
    auto & offsets = column.getOffsets();
    chars.reserve(chars.size() + num_bytes);
    offsets.reserve(offsets.size() + num_rows);
    size_t chars_pos = chars.size();
    size_t row = offsets.size();
    chars.resize(chars_pos + num_bytes);
    offsets.resize(row + num_rows);

    for (const auto & range : ranges)
    {
        const auto & src = assert_cast<const ColumnString &>(*range.column);
        const auto & src_offsets = src.getOffsets();
        size_t src_begin = src_offsets[static_cast<ssize_t>(range.start) - 1];
        if (range.length == 1)
        {
            size_t size = src_offsets[range.start] - src_begin;
            memcpySmallAllowReadWriteOverflow15(chars.data() + chars_pos, src.getChars().data() + src_begin, size);
            chars_pos += size;
            offsets[row++] = chars_pos;
        }
        else
        {
            size_t size = src_offsets[range.start + range.length - 1] - src_begin;
            memcpy(chars.data() + chars_pos, src.getChars().data() + src_begin, size);
            for (size_t i = range.start; i != range.start + range.length; ++i)
                offsets[row++] = chars_pos + src_offsets[i] - src_begin;
            chars_pos += size;
        }
    }
}

template <size_t value_size>
void insertFixedSizeRanges(IColumn & column, size_t num_rows, std::span<const SourceRange> ranges)
{
    char * pos = column.insertRawUninitialized(num_rows).data();
    /// The raw data of the sources seen so far. A batch has ranges of a few sources only.
    std::array<std::pair<const IColumn *, const char *>, 16> sources{};
    size_t num_sources = 0;
    for (const auto & range : ranges)
    {
        const char * data = nullptr;
        for (size_t i = 0; i != num_sources; ++i)
        {
            if (sources[i].first == range.column)
            {
                data = sources[i].second;
                break;
            }
        }
        if (!data)
        {
            data = range.column->getRawData().data();
            if (num_sources != sources.size())
                sources[num_sources++] = {range.column, data};
        }

        if (range.length == 1)
            memcpy(pos, data + range.start * value_size, value_size);
        else
            memcpy(pos, data + range.start * value_size, range.length * value_size);
        pos += range.length * value_size;
    }
}

bool tryInsertFixedSizeRanges(IColumn & column, std::span<const SourceRange> ranges)
{
    if (!column.isFixedAndContiguous() || isColumnConst(column))
        return false;

    size_t num_rows = 0;
    for (const auto & range : ranges)
        num_rows += range.length;

    switch (column.sizeOfValueIfFixed())
    {
        case 1: insertFixedSizeRanges<1>(column, num_rows, ranges); return true;
        case 2: insertFixedSizeRanges<2>(column, num_rows, ranges); return true;
        case 4: insertFixedSizeRanges<4>(column, num_rows, ranges); return true;
        case 8: insertFixedSizeRanges<8>(column, num_rows, ranges); return true;
        case 16: insertFixedSizeRanges<16>(column, num_rows, ranges); return true;
        default: return false;
    }
}

void insertNullableRanges(ColumnNullable & column, std::span<const SourceRange> ranges)
{
    VectorWithMemoryTracking<SourceRange> nested_ranges;
    VectorWithMemoryTracking<SourceRange> null_map_ranges;
    nested_ranges.reserve(ranges.size());
    null_map_ranges.reserve(ranges.size());
    for (const auto & range : ranges)
    {
        const auto & src = assert_cast<const ColumnNullable &>(*range.column);
        nested_ranges.push_back({&src.getNestedColumn(), range.start, range.length});
        null_map_ranges.push_back({&src.getNullMapColumn(), range.start, range.length});
    }
    insertSourceRanges(column.getNestedColumn(), nested_ranges);
    insertSourceRanges(column.getNullMapColumn(), null_map_ranges);
}

/// Same result as inserting the ranges in order with insertFrom (ranges of one row) and insertRangeFrom.
/// Columns of strings, of fixed-size values and Nullable of them are copied without a virtual call per range.
/// Like insertFrom, it expects the source columns to have the class of the column.
void insertSourceRanges(IColumn & column, std::span<const SourceRange> ranges)
{
    const IColumn * first_src = ranges.empty() ? nullptr : ranges.front().column;
    if (first_src && typeid(*first_src) == typeid(column))
    {
        if (auto * string_column = typeid_cast<ColumnString *>(&column))
        {
            insertStringRanges(*string_column, ranges);
            return;
        }
        if (auto * nullable_column = typeid_cast<ColumnNullable *>(&column))
        {
            insertNullableRanges(*nullable_column, ranges);
            return;
        }
        if (tryInsertFixedSizeRanges(column, ranges))
            return;
    }

    for (const auto & range : ranges)
    {
        if (range.length == 1)
            column.insertFrom(*range.column, range.start);
        else
            column.insertRangeFrom(*range.column, range.start, range.length);
    }
}

/// A source Variant column with the same variants as the column its rows go to, with what insertVariantRows
/// needs of it resolved once instead of for every row.
struct VariantRowsSource
{
    /// The number of variants of the column the source was resolved for. Variants are only added by inserts.
    size_t num_variants = 0;
    const ColumnVariant::Discriminator * discriminators = nullptr;
    const ColumnVariant::Offset * offsets = nullptr;
    /// Indexed by the local discriminators of the source: the local discriminator in the column, and the variant
    /// of the source.
    VectorWithMemoryTracking<ColumnVariant::Discriminator> local_discriminators;
    VectorWithMemoryTracking<const IColumn *> variants;

    /// Resolves the source for the column, unless it is resolved for the current variants of the column.
    void update(const ColumnVariant & src, const ColumnVariant & column)
    {
        size_t column_num_variants = column.getNumVariants();
        if (num_variants == column_num_variants && discriminators)
            return;

        if (src.getNumVariants() != column_num_variants)
            throw Exception(ErrorCodes::LOGICAL_ERROR, "Cannot insert value of Variant type with different number of types");

        discriminators = src.getLocalDiscriminators().data();
        offsets = src.getOffsets().data();
        local_discriminators.resize(column_num_variants);
        variants.resize(column_num_variants);
        for (size_t src_local_discr = 0; src_local_discr != column_num_variants; ++src_local_discr)
        {
            auto discr = static_cast<ColumnVariant::Discriminator>(src_local_discr);
            local_discriminators[src_local_discr] = column.localDiscriminatorByGlobal(src.globalDiscriminatorByLocal(discr));
            variants[src_local_discr] = &src.getVariantByLocalDiscriminator(src_local_discr);
        }
        num_variants = column_num_variants;
    }
};

/// `length` rows of a source Variant column from `start`, or `length` default values if source is null.
struct VariantRows
{
    const VariantRowsSource * source;
    size_t start;
    size_t length;
};

/// Buffers of insertVariantRows, kept between calls.
struct VariantRowsScratch
{
    /// Size of each variant of the column with the values collected so far, or `unused_variant` if no value
    /// was collected for it yet.
    static constexpr size_t unused_variant = std::numeric_limits<size_t>::max();
    VectorWithMemoryTracking<size_t> variant_sizes;
    VectorWithMemoryTracking<VectorWithMemoryTracking<SourceRange>> variant_ranges;
    /// Local discriminators of the variants that got values, in the order of their first value.
    VectorWithMemoryTracking<ColumnVariant::Discriminator> used_variants;
};

/// Same result as ColumnVariant::insertRangeFrom of each source range (for a source with the same variants, which is
/// insertFrom for a range of one row) and insertManyDefaults, in order: discriminators and offsets are written row by row,
/// and the values of each variant are inserted together, in the order of rows. Consecutive values of a source variant
/// are copied as one range.
/// The sources must have the same variants as the column.
void insertVariantRows(ColumnVariant & column, std::span<const VariantRows> rows, VariantRowsScratch & scratch)
{
    static constexpr auto null_discriminator = ColumnVariant::NULL_DISCRIMINATOR;
    static constexpr auto unused_variant = VariantRowsScratch::unused_variant;

    size_t num_rows = 0;
    for (const auto & row : rows)
        num_rows += row.length;

    auto & local_discriminators = column.getLocalDiscriminators();
    auto & offsets = column.getOffsets();
    size_t prev_size = local_discriminators.size();
    local_discriminators.resize(prev_size + num_rows);
    offsets.resize(prev_size + num_rows);
    auto * discriminators_pos = local_discriminators.data() + prev_size;
    auto * offsets_pos = offsets.data() + prev_size;

    size_t num_variants = column.getNumVariants();
    auto & variant_sizes = scratch.variant_sizes;
    auto & variant_ranges = scratch.variant_ranges;
    auto & used_variants = scratch.used_variants;
    variant_sizes.assign(num_variants, unused_variant);
    if (variant_ranges.size() < num_variants)
        variant_ranges.resize(num_variants);
    used_variants.clear();

    for (const auto & row : rows)
    {
        if (!row.source)
        {
            memset(discriminators_pos, null_discriminator, row.length);
            memset(offsets_pos, 0, row.length * sizeof(*offsets_pos));
            discriminators_pos += row.length;
            offsets_pos += row.length;
            continue;
        }

        const auto & src = *row.source;
        const auto * src_discriminators = src.discriminators;
        const auto * src_offsets = src.offsets;
        const auto * src_local_discriminators = src.local_discriminators.data();
        for (size_t i = row.start; i != row.start + row.length; ++i)
        {
            auto src_local_discr = src_discriminators[i];
            if (src_local_discr == null_discriminator)
            {
                *discriminators_pos++ = null_discriminator;
                *offsets_pos++ = 0;
                continue;
            }

            auto local_discr = src_local_discriminators[src_local_discr];
            *discriminators_pos++ = local_discr;

            auto & variant_size = variant_sizes[local_discr];
            auto & ranges = variant_ranges[local_discr];
            if (variant_size == unused_variant)
            {
                variant_size = column.getVariantByLocalDiscriminator(local_discr).size();
                ranges.clear();
                used_variants.push_back(local_discr);
            }
            *offsets_pos++ = variant_size++;

            const auto * src_variant = src.variants[src_local_discr];
            size_t src_offset = src_offsets[i];
            if (!ranges.empty() && ranges.back().column == src_variant && ranges.back().start + ranges.back().length == src_offset)
                ++ranges.back().length;
            else
                ranges.push_back({src_variant, src_offset, 1});
        }
    }

    for (auto local_discr : used_variants)
        insertSourceRanges(column.getVariantByLocalDiscriminator(local_discr), variant_ranges[local_discr]);
}

}

/// How the values of source dynamic paths that have no dynamic path here are written into our shared data,
/// see `insertFromSharedDataAndFillRemainingDynamicPaths`.
struct ColumnObject::SharedDataSerializationState
{
    /// A cache for each of these paths.
    VectorWithMemoryTracking<SharedDataValueSerializationCache> caches;

    /// The paths that have a value (are not NULL) in source rows [rows_begin, rows_end): those of row r are the
    /// indexes path_indexes[row_offsets[r - rows_begin], row_offsets[r - rows_begin + 1]), ascending.
    /// Most paths are NULL in most rows. Rows are requested a few at a time and in order, so they are
    /// scanned path by path a window of rows at a time instead of reading every path in every row.
    size_t rows_begin = 0;
    size_t rows_end = 0;
    PaddedPODArray<UInt32> row_offsets;
    PaddedPODArray<UInt32> path_indexes;
    PaddedPODArray<UInt32> positions;

    static constexpr size_t min_window_rows = 128;

    std::pair<const UInt32 *, const UInt32 *> getPathsWithValues(const DynamicPathsForSharedData & paths, size_t row, size_t end, size_t num_rows)
    {
        if (row < rows_begin || row >= rows_end)
            scan(paths, row, std::min(num_rows, std::max(end, row + min_window_rows)));
        const UInt32 * data = path_indexes.data();
        return {data + row_offsets[row - rows_begin], data + row_offsets[row - rows_begin + 1]};
    }

private:
    /// The local discriminators of each of the paths, which do not change while the state is used.
    VectorWithMemoryTracking<const UInt8 *> paths_discriminators;

    void scan(const DynamicPathsForSharedData & paths, size_t begin, size_t end)
    {
        if (paths_discriminators.size() != paths.size())
        {
            paths_discriminators.resize(paths.size());
            for (size_t index = 0; index != paths.size(); ++index)
                paths_discriminators[index] = paths[index].second->getVariantColumn().getLocalDiscriminators().data();
        }

        const size_t num = end - begin;
        row_offsets.assign(num + 1, 0U);
        for (const UInt8 * path_discriminators : paths_discriminators)
        {
            const UInt8 * discriminators = path_discriminators + begin;
            for (size_t i = 0; i != num; ++i)
                row_offsets[i + 1] += discriminators[i] != ColumnVariant::NULL_DISCRIMINATOR;
        }
        for (size_t i = 0; i != num; ++i)
            row_offsets[i + 1] += row_offsets[i];

        path_indexes.resize(row_offsets[num]);
        positions.assign(row_offsets.begin(), row_offsets.end() - 1);
        for (size_t index = 0; index != paths.size(); ++index)
        {
            const UInt8 * discriminators = paths_discriminators[index] + begin;
            for (size_t i = 0; i != num; ++i)
            {
                if (discriminators[i] != ColumnVariant::NULL_DISCRIMINATOR)
                    path_indexes[positions[i]++] = static_cast<UInt32>(index);
            }
        }
        rows_begin = begin;
        rows_end = end;
    }
};

/// How rows of one source column are inserted into this column, see `gather`.
struct ColumnObject::GatherSourcePlan
{
    /// The source column. Holding it keeps another column from taking its address while the plan is kept.
    ColumnPtr source;
    bool is_built = false;
    /// The plan stays valid while these two do not change: inserting from other sources can add dynamic paths
    /// to this column or lower its limit on dynamic paths.
    size_t num_dynamic_paths = 0;
    size_t max_dynamic_paths = 0;
    /// Pairs (our column, source column), in the order of our typed paths.
    VectorWithMemoryTracking<std::pair<IColumn *, const IColumn *>> typed_paths;

    struct DynamicPath
    {
        ColumnDynamic * column;
        const ColumnDynamic * src_column;
        std::string_view path;
        ColumnDynamic::InsertFromCache cache;
        /// The Variant column of the source, used while `cache` says its rows go into our Variant column as they are.
        VariantRowsSource variant_rows_source;
    };
    VectorWithMemoryTracking<DynamicPath> dynamic_paths;
    /// For each of GatherState::dynamic_columns, its index in dynamic_paths, or -1 if the source has no such dynamic path.
    VectorWithMemoryTracking<ssize_t> dynamic_path_by_column;
    /// Source dynamic paths we have no dynamic path for, and how their values are written into our shared data.
    DynamicPathsForSharedData dynamic_paths_for_shared_data;
    SharedDataSerializationState shared_data_serialization;
    /// Our dynamic paths are full and equal to the source ones, so shared data is copied as is.
    bool insert_shared_data_directly = false;
};

/// The state of `gather` while it fills one block. The per-source plans hold their source columns, which do not
/// change while they are shared, so a plan stays valid for its source across the calls of `gather` for the block.
/// The cached value types point into the sources without holding them, so they are kept for one call only.
struct ColumnObject::GatherState
{
    UnorderedMapWithMemoryTracking<const ColumnObject *, GatherSourcePlan> plans;
    const ColumnObject * last_source = nullptr;
    GatherSourcePlan * last_plan = nullptr;

    /// Called at the start of each call of `gather`. Between calls the gatherer replaces sources by their next
    /// blocks, so the plans of the sources that only the plans still hold are not needed anymore.
    void startGatherCall()
    {
        std::erase_if(plans, [](const auto & entry) { return entry.second.source->use_count() == 1; });
        last_source = nullptr;
        last_plan = nullptr;
        type_caches.assign(type_caches.size(), SharedDataValueTypeCache{});
        type_cache_num_variants.assign(type_cache_num_variants.size(), 0);
    }

    /// Our dynamic paths in a flat list, for the lookup of paths from source shared data and default filling.
    size_t num_dynamic_paths = std::numeric_limits<size_t>::max();
    VectorWithMemoryTracking<ColumnDynamic *> dynamic_columns;
    /// Looked up for each value in source shared data, so it is a flat hash map. Keys point to the paths in dynamic_paths_ptrs.
    HashMapWithSavedHash<std::string_view, size_t> dynamic_column_index;

    /// Index in dynamic_columns of our dynamic path, or nullopt.
    std::optional<size_t> findDynamicColumn(std::string_view path) const
    {
        if (const auto * it = dynamic_column_index.find(path))
            return it->getMapped();
        return std::nullopt;
    }

    /// The type of the last value read from source shared data into each of dynamic_columns.
    /// A cached global discriminator is valid only while the column has the same number of variants.
    VectorWithMemoryTracking<SharedDataValueTypeCache> type_caches;
    VectorWithMemoryTracking<size_t> type_cache_num_variants;

    /// While a batch of ranges is inserted path by path, the values that source shared data has for our dynamic
    /// paths are collected first, for each of dynamic_columns in the order of rows, and inserted afterwards.
    struct ValueFromSharedData
    {
        /// Our row the value goes to.
        size_t row;
        const ColumnString * src_shared_data_values;
        size_t n;
    };
    bool collect_values_from_shared_data = false;
    VectorWithMemoryTracking<VectorWithMemoryTracking<ValueFromSharedData>> values_from_shared_data;

    /// The plan of each range of the batch.
    VectorWithMemoryTracking<GatherSourcePlan *> range_plans;
    /// The ranges of the batch in the source columns of one path.
    VectorWithMemoryTracking<SourceRange> path_ranges;
    /// Rows for one of dynamic_columns that are not inserted yet, see `insertGatheredRanges`.
    VectorWithMemoryTracking<VariantRows> pending_variant_rows;
    VariantRowsScratch variant_rows_scratch;

    void updateDynamicColumns(const PathToDynamicColumnPtrMap & object_dynamic_paths)
    {
        if (num_dynamic_paths == object_dynamic_paths.size())
            return;

        dynamic_columns.clear();
        dynamic_column_index.clear();
        for (const auto & [path, column] : object_dynamic_paths)
        {
            HashMapWithSavedHash<std::string_view, size_t>::LookupResult it;
            bool inserted;
            dynamic_column_index.emplace(std::string_view(path), it, inserted);
            it->getMapped() = dynamic_columns.size();
            dynamic_columns.push_back(column);
        }
        type_caches.assign(dynamic_columns.size(), SharedDataValueTypeCache{});
        type_cache_num_variants.assign(dynamic_columns.size(), 0);
        values_from_shared_data.resize(dynamic_columns.size());
        num_dynamic_paths = object_dynamic_paths.size();
    }

    void deserializeValue(const ColumnString * src_shared_data_values, size_t n, size_t column_index)
    {
        auto & column = *dynamic_columns[column_index];
        auto & cache = type_caches[column_index];
        if (type_cache_num_variants[column_index] != column.getVariantInfo().variant_names.size())
            cache = {};

        deserializeValueFromSharedData(src_shared_data_values, n, column, cache);
        /// Reading the value could have added a variant to the column, the cache was rebuilt after it then.
        type_cache_num_variants[column_index] = column.getVariantInfo().variant_names.size();
    }
};

void ColumnObject::GatherStateDeleter::operator()(GatherState * state) const
{
    delete state;
}

void ColumnObject::gather(ColumnGathererStream & gatherer)
{
    if (!gather_state_holder)
        gather_state_holder.reset(new GatherState);
    gather_state_holder->startGatherCall();
    gather_state = gather_state_holder.get();
    SCOPE_EXIT({
        gather_state = nullptr;
        /// Unless the gatherer continues this block after the next block of a source, release the sources.
        if (!gatherer.waitsForSourceBlock())
            gather_state_holder.reset();
    });

    /// When no dynamic paths can be added, as in merges, where the structure of the result is chosen in advance,
    /// rows from all sources can be inserted path by path: each path column still gets the same values in the
    /// same order, and popBack of the last inserted rows restores the previous state.
    if (canAddNewDynamicPath())
        gatherer.gather(*this);
    else
        gatherer.gatherInBatches(*this, [this](const auto & ranges) { insertGatheredRanges(ranges); });
}

ColumnObject::GatherSourcePlan & ColumnObject::getGatherSourcePlan(const ColumnObject & src)
{
    auto & state = *gather_state;
    if (state.last_source != &src)
    {
        state.last_plan = &state.plans[&src];
        state.last_source = &src;
    }

    auto & plan = *state.last_plan;
    if (!plan.source)
        plan.source = src.getPtr();
    if (plan.is_built && plan.num_dynamic_paths == dynamic_paths.size() && plan.max_dynamic_paths == max_dynamic_paths)
        return plan;

    /// Resolve paths the same way insertFrom does without a plan, adding new dynamic paths while we can.
    /// Typed paths are the same in both columns. They are listed in our order, so that the plans of all sources agree.
    if (src.typed_paths.size() != typed_paths.size())
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Different number of typed paths in the source and destination Object columns: {} != {}", src.typed_paths.size(), typed_paths.size());
    plan.typed_paths.clear();
    for (auto & [path, column] : typed_paths)
    {
        auto it = src.typed_paths.find(path);
        if (it == src.typed_paths.end())
            throw Exception(ErrorCodes::LOGICAL_ERROR, "Typed path {} is missing in the source Object column", path);
        plan.typed_paths.emplace_back(column.get(), it->second.get());
    }

    plan.dynamic_paths.clear();
    plan.dynamic_paths_for_shared_data.clear();
    for (const auto & [path, column] : src.dynamic_paths)
    {
        const auto * src_dynamic_column = assert_cast<const ColumnDynamic *>(column.get());
        if (auto it = dynamic_paths_ptrs.find(path); it != dynamic_paths_ptrs.end())
            plan.dynamic_paths.push_back({it->second, src_dynamic_column, path, {}, {}});
        else if (auto * dynamic_path_column = tryToAddNewDynamicPath(path))
            plan.dynamic_paths.push_back({dynamic_path_column, src_dynamic_column, path, {}, {}});
        else
            plan.dynamic_paths_for_shared_data.emplace_back(path, src_dynamic_column);
    }
    sortDynamicPathsForSharedData(plan.dynamic_paths_for_shared_data);
    plan.shared_data_serialization = {};
    plan.shared_data_serialization.caches.assign(plan.dynamic_paths_for_shared_data.size(), SharedDataValueSerializationCache{});

    state.updateDynamicColumns(dynamic_paths_ptrs);
    plan.dynamic_path_by_column.assign(state.dynamic_columns.size(), -1);
    for (size_t i = 0; i != plan.dynamic_paths.size(); ++i)
        plan.dynamic_path_by_column[state.findDynamicColumn(plan.dynamic_paths[i].path).value()] = static_cast<ssize_t>(i);

    plan.insert_shared_data_directly = !canAddNewDynamicPath() && sorted_dynamic_paths == src.sorted_dynamic_paths;
    plan.num_dynamic_paths = dynamic_paths.size();
    plan.max_dynamic_paths = max_dynamic_paths;
    plan.is_built = true;
    return plan;
}

void ColumnObject::insertRangeFromWithPlan(GatherSourcePlan & plan, const ColumnObject & src, size_t start, size_t length)
{
    if (length == 1)
    {
        for (const auto & [column, src_column] : plan.typed_paths)
            column->insertFrom(*src_column, start);
        for (auto & dynamic_path : plan.dynamic_paths)
            dynamic_path.column->insertFromWithCache(*dynamic_path.src_column, start, dynamic_path.cache);
        if (plan.insert_shared_data_directly)
            shared_data->insertFrom(*src.shared_data, start);
    }
    else
    {
        for (const auto & [column, src_column] : plan.typed_paths)
            column->insertRangeFrom(*src_column, start, length);
        for (const auto & dynamic_path : plan.dynamic_paths)
            dynamic_path.column->insertRangeFrom(*dynamic_path.src_column, start, length);
        if (plan.insert_shared_data_directly)
            shared_data->insertRangeFrom(*src.shared_data, start, length);
    }

    if (!plan.insert_shared_data_directly)
        insertFromSharedDataAndFillRemainingDynamicPaths(src, plan.dynamic_paths_for_shared_data, start, length, &plan.shared_data_serialization);
}

template <typename Ranges>
void ColumnObject::insertGatheredRanges(const Ranges & ranges)
{
    auto & state = *gather_state;
    auto & plans = state.range_plans;
    plans.clear();
    for (const auto & range : ranges)
    {
        const auto & src = assert_cast<const ColumnObject &>(*range.column);
        takeMaxDynamicPathsUpperBoundFrom(src);
        plans.push_back(&getGatherSourcePlan(src));
    }

    /// Typed paths, one at a time.
    auto & path_ranges = state.path_ranges;
    for (size_t i = 0; i != typed_paths.size(); ++i)
    {
        path_ranges.clear();
        for (size_t r = 0; r != ranges.size(); ++r)
            path_ranges.push_back({plans[r]->typed_paths[i].second, ranges[r].start, ranges[r].length});
        insertSourceRanges(*plans.front()->typed_paths[i].first, path_ranges);
    }

    /// Shared data, row by row. Values for our dynamic paths found in source shared data are collected.
    state.updateDynamicColumns(dynamic_paths_ptrs);
    for (auto & values : state.values_from_shared_data)
        values.clear();

    size_t start_row = shared_data->size();
    state.collect_values_from_shared_data = true;
    for (size_t r = 0; r != ranges.size(); ++r)
    {
        const auto & range = ranges[r];
        auto & plan = *plans[r];
        const auto & src = assert_cast<const ColumnObject &>(*range.column);
        if (!plan.insert_shared_data_directly)
            insertFromSharedDataAndFillRemainingDynamicPaths(src, plan.dynamic_paths_for_shared_data, range.start, range.length, &plan.shared_data_serialization);
        else if (range.length == 1)
            shared_data->insertFrom(*src.shared_data, range.start);
        else
            shared_data->insertRangeFrom(*src.shared_data, range.start, range.length);
    }
    state.collect_values_from_shared_data = false;
    size_t end_row = shared_data->size();

    /// Dynamic paths, one at a time: values from source dynamic paths and from source shared data in the order
    /// of rows, and defaults for the rows without a value.
    /// Defaults and ranges of values that go into the Variant column as they are wait in pending_rows, and are
    /// inserted together before any other insert into the column, which can change its variants.
    auto & pending_rows = state.pending_variant_rows;
    static constexpr size_t offsets_prefetch_distance = 16;
    static constexpr size_t values_prefetch_distance = 8;
    for (size_t i = 0; i != state.dynamic_columns.size(); ++i)
    {
        ColumnDynamic & column = *state.dynamic_columns[i];
        /// The size of the column with the pending rows.
        size_t column_size = column.size();
        pending_rows.clear();
        auto insert_defaults_up_to = [&](size_t new_size)
        {
            if (column_size < new_size)
            {
                pending_rows.push_back({nullptr, 0, new_size - column_size});
                column_size = new_size;
            }
        };
        auto insert_pending_rows = [&]
        {
            if (!pending_rows.empty())
            {
                insertVariantRows(column.getVariantColumn(), pending_rows, state.variant_rows_scratch);
                pending_rows.clear();
            }
        };

        const auto & values = state.values_from_shared_data[i];
        auto value_it = values.begin();
        size_t row = start_row;
        for (size_t r = 0; r != ranges.size(); ++r)
        {
            const auto & range = ranges[r];
            size_t range_end_row = row + range.length;
            if (ssize_t index = plans[r]->dynamic_path_by_column[i]; index != -1)
            {
                if (value_it != values.end() && value_it->row < range_end_row)
                    throw Exception(ErrorCodes::LOGICAL_ERROR, "Path {} is both a dynamic path and in shared data of the source Object column", plans[r]->dynamic_paths[index].path);

                auto & dynamic_path = plans[r]->dynamic_paths[index];
                insert_defaults_up_to(row);
                if (column.insertsVariantDirectly(*dynamic_path.src_column, dynamic_path.cache))
                {
                    dynamic_path.variant_rows_source.update(dynamic_path.src_column->getVariantColumn(), column.getVariantColumn());
                    pending_rows.push_back({&dynamic_path.variant_rows_source, range.start, range.length});
                    column_size += range.length;
                }
                else
                {
                    insert_pending_rows();
                    if (range.length == 1)
                        column.insertFromWithCache(*dynamic_path.src_column, range.start, dynamic_path.cache);
                    else
                        column.insertRangeFrom(*dynamic_path.src_column, range.start, range.length);
                    column_size = column.size();
                }
            }
            else
            {
                for (; value_it != values.end() && value_it->row < range_end_row; ++value_it)
                {
                    /// The values of one path are spread over the shared data of the source, so the offsets and then
                    /// the bytes of the values a few iterations ahead are prefetched.
                    size_t values_left = static_cast<size_t>(values.end() - value_it);
                    if (values_left > offsets_prefetch_distance)
                    {
                        const auto & ahead = value_it[offsets_prefetch_distance];
                        __builtin_prefetch(&ahead.src_shared_data_values->getOffsets()[static_cast<ssize_t>(ahead.n) - 1]);
                    }
                    if (values_left > values_prefetch_distance)
                    {
                        const auto & ahead = value_it[values_prefetch_distance];
                        __builtin_prefetch(ahead.src_shared_data_values->getChars().data() + ahead.src_shared_data_values->getOffsets()[static_cast<ssize_t>(ahead.n) - 1]);
                    }

                    insert_defaults_up_to(value_it->row);
                    insert_pending_rows();
                    state.deserializeValue(value_it->src_shared_data_values, value_it->n, i);
                    column_size = column.size();
                }
            }
            row = range_end_row;
        }

        insert_defaults_up_to(end_row);
        insert_pending_rows();
        if (column.size() != end_row)
            throw Exception(ErrorCodes::LOGICAL_ERROR, "Unexpected size of dynamic path column: {} != {}", column.size(), end_row);
    }
}

void ColumnObject::sortDynamicPathsForSharedData(DynamicPathsForSharedData & paths)
{
    std::sort(paths.begin(), paths.end(), [](const auto & lhs, const auto & rhs) { return lhs.first < rhs.first; });
}

#if !defined(DEBUG_OR_SANITIZER_BUILD)
void ColumnObject::insertFrom(const IColumn & src, size_t n)
#else
void ColumnObject::doInsertFrom(const IColumn & src, size_t n)
#endif
{
    const auto & src_object_column = assert_cast<const ColumnObject &>(src);

    /// A limit that parsing settings put on the source instance rather than on the type has to
    /// travel with the data, so that aggregating parsed data cannot widen it back.
    takeMaxDynamicPathsUpperBoundFrom(src_object_column);

    if (gather_state)
    {
        insertRangeFromWithPlan(getGatherSourcePlan(src_object_column), src_object_column, n, 1);
        return;
    }

    /// First, insert typed paths, they must be the same for both columns.
    for (const auto & [path, column] : src_object_column.typed_paths)
        typed_paths[path]->insertFrom(*column, n);

    /// Second, insert dynamic paths and extend them if needed.
    /// We can reach the limit of dynamic paths, and in this case
    /// the rest of dynamic paths will be inserted into shared data.
    DynamicPathsForSharedData src_dynamic_paths_for_shared_data;
    for (const auto & [path, column] : src_object_column.dynamic_paths)
    {
        /// Check if we already have such dynamic path.
        if (auto it = dynamic_paths_ptrs.find(path); it != dynamic_paths_ptrs.end())
            it->second->insertFrom(*column, n);
        /// Try to add a new dynamic path.
        else if (auto * dynamic_path_column = tryToAddNewDynamicPath(path))
            dynamic_path_column->insertFrom(*column, n);
        /// Limit on dynamic paths is reached, add path to shared data later.
        else
            src_dynamic_paths_for_shared_data.emplace_back(path, assert_cast<const ColumnDynamic *>(column.get()));
    }

    /// Finally, insert paths from shared data.
    /// If limit on dynamic paths is reached and set of dynamic paths is the same for both source
    /// and destination columns, we can insert into shared data from source shared data directly.
    if (!canAddNewDynamicPath() && sorted_dynamic_paths == src_object_column.sorted_dynamic_paths)
    {
        shared_data->insertFrom(*src_object_column.shared_data, n);
    }
    /// Otherwise we might need to insert dynamic paths into shared data and vice versa.
    else
    {
        sortDynamicPathsForSharedData(src_dynamic_paths_for_shared_data);
        insertFromSharedDataAndFillRemainingDynamicPaths(src_object_column, src_dynamic_paths_for_shared_data, n, 1);
    }
}

#if !defined(DEBUG_OR_SANITIZER_BUILD)
void ColumnObject::insertRangeFrom(const IColumn & src, size_t start, size_t length)
#else
void ColumnObject::doInsertRangeFrom(const IColumn & src, size_t start, size_t length)
#endif
{
    if (length == 0)
        return;

    if (start + length > src.size())
        throw Exception(ErrorCodes::PARAMETER_OUT_OF_BOUND, "Parameter out of bound in ColumnObject::insertRangeFrom method.");

    /// TODO: try to parallelize doInsertRangeFrom over typed/dynamic paths if it makes sense.
    const auto & src_object_column = assert_cast<const ColumnObject &>(src);

    /// See the comment in `insertFrom`.
    takeMaxDynamicPathsUpperBoundFrom(src_object_column);

    if (gather_state)
    {
        insertRangeFromWithPlan(getGatherSourcePlan(src_object_column), src_object_column, start, length);
        return;
    }

    /// First, insert typed paths, they must be the same for both columns.
    for (const auto & [path, column] : src_object_column.typed_paths)
        typed_paths[path]->insertRangeFrom(*column, start, length);

    /// Second, insert dynamic paths and extend them if needed.
    /// We can reach the limit of dynamic paths, and in this case
    /// the rest of dynamic paths will be inserted into shared data.
    DynamicPathsForSharedData src_dynamic_paths_for_shared_data;
    for (const auto & [path, column] : src_object_column.dynamic_paths)
    {
        /// Check if we already have such dynamic path.
        if (auto it = dynamic_paths_ptrs.find(path); it != dynamic_paths_ptrs.end())
            it->second->insertRangeFrom(*column, start, length);
        /// Try to add a new dynamic path.
        else if (auto * dynamic_path_column = tryToAddNewDynamicPath(path))
            dynamic_path_column->insertRangeFrom(*column, start, length);
        /// Limit on dynamic paths is reached, add path to shared data later.
        else
            src_dynamic_paths_for_shared_data.emplace_back(path, assert_cast<const ColumnDynamic *>(column.get()));
    }

    /// Finally, insert paths from shared data.
    /// If limit on dynamic paths is reached and set of dynamic paths is the same for both source
    /// and destination columns, we can insert into shared data from source shared data directly.
    if (!canAddNewDynamicPath() && sorted_dynamic_paths == src_object_column.sorted_dynamic_paths)
    {
        shared_data->insertRangeFrom(*src_object_column.shared_data, start, length);
    }
    /// Otherwise we might need to insert dynamic paths into shared data and vice versa.
    else
    {
        sortDynamicPathsForSharedData(src_dynamic_paths_for_shared_data);
        insertFromSharedDataAndFillRemainingDynamicPaths(src_object_column, src_dynamic_paths_for_shared_data, start, length);
    }
}

void ColumnObject::insertFromSharedDataAndFillRemainingDynamicPaths(const DB::ColumnObject & src_object_column, const DynamicPathsForSharedData & src_dynamic_paths_for_shared_data, size_t start, size_t length, SharedDataSerializationState * serialization_state)
{
    /// Writes the value of src_dynamic_paths_for_shared_data[index] in row n into our shared data.
    auto serialize_path_and_value = [&](ColumnString * shared_data_paths, ColumnString * shared_data_values, size_t index, size_t n)
    {
        const auto & [path, src_column] = src_dynamic_paths_for_shared_data[index];
        if (serialization_state)
            serializePathAndValueIntoSharedData(shared_data_paths, shared_data_values, path, *src_column, n, serialization_state->caches[index]);
        else
            serializePathAndValueIntoSharedData(shared_data_paths, shared_data_values, path, *src_column, n);
    };

    /// The indexes in src_dynamic_paths_for_shared_data of the paths that can have a value in a row: with a state,
    /// only the paths that have one, otherwise all of them.
    PODArrayWithStackMemory<UInt32, 256> all_paths;
    if (!serialization_state)
    {
        all_paths.resize(src_dynamic_paths_for_shared_data.size());
        for (size_t index = 0; index != all_paths.size(); ++index)
            all_paths[index] = static_cast<UInt32>(index);
    }
    auto get_row_paths = [&](size_t row) -> std::pair<const UInt32 *, const UInt32 *>
    {
        if (serialization_state)
            return serialization_state->getPathsWithValues(src_dynamic_paths_for_shared_data, row, start + length, src_object_column.size());
        return {all_paths.data(), all_paths.data() + all_paths.size()};
    };

    /// Paths in shared data are sorted, and src_dynamic_paths_for_shared_data is sorted by path,
    /// so these paths can be merged into each row in order.

    /// While gathering, our dynamic paths are looked up in a flat list that also caches value types.
    if (gather_state)
        gather_state->updateDynamicColumns(dynamic_paths_ptrs);

    /// Check if src object doesn't have any paths in shared data in specified range.
    const auto & src_shared_data_offsets = src_object_column.getSharedDataOffsets();
    if (src_shared_data_offsets[static_cast<ssize_t>(start) - 1] == src_shared_data_offsets[static_cast<ssize_t>(start) + length - 1])
    {
        size_t current_size = size();

        /// If no src dynamic columns should be inserted into shared data, insert defaults.
        if (src_dynamic_paths_for_shared_data.empty())
        {
            shared_data->insertManyDefaults(length);
        }
        /// Otherwise insert required src dynamic columns into shared data.
        else
        {
            const auto [shared_data_paths, shared_data_values] = getSharedDataPathsAndValues();
            auto & shared_data_offsets = getSharedDataOffsets();
            for (size_t i = start; i != start + length; ++i)
            {
                /// Paths in src_dynamic_paths_for_shared_data are already sorted.
                auto [row_paths_it, row_paths_end] = get_row_paths(i);
                for (; row_paths_it != row_paths_end; ++row_paths_it)
                    serialize_path_and_value(shared_data_paths, shared_data_values, *row_paths_it, i);
                shared_data_offsets.push_back(shared_data_paths->size());
            }
        }

        /// Insert default values in all remaining dynamic paths.
        if (gather_state)
        {
            if (!gather_state->collect_values_from_shared_data)
            {
                for (auto * column : gather_state->dynamic_columns)
                {
                    if (column->size() == current_size)
                        column->insertManyDefaults(length);
                }
            }
        }
        else
        {
            for (auto & [_, column] : dynamic_paths_ptrs)
            {
                if (column->size() == current_size)
                    column->insertManyDefaults(length);
            }
        }
        return;
    }

    /// Src object column contains some paths in shared data in specified range.
    /// Iterate over this range and insert all required paths into shared data or dynamic paths.
    const auto [src_shared_data_paths, src_shared_data_values] = src_object_column.getSharedDataPathsAndValues();
    const auto [shared_data_paths, shared_data_values] = getSharedDataPathsAndValues();
    auto & shared_data_offsets = getSharedDataOffsets();

    /// Source occurrences that are copied as they are form runs, also across rows. A run [copy_begin, copy_end)
    /// is copied at once when a value from elsewhere has to be written after it, or at the end.
    size_t copy_begin = 0;
    size_t copy_end = 0;
    auto flush_copied = [&]
    {
        if (copy_begin != copy_end)
        {
            shared_data_paths->insertRangeFrom(*src_shared_data_paths, copy_begin, copy_end - copy_begin);
            shared_data_values->insertRangeFrom(*src_shared_data_values, copy_begin, copy_end - copy_begin);
        }
        copy_begin = copy_end = 0;
    };

    for (size_t row = start; row != start + length; ++row)
    {
        size_t current_size = shared_data_offsets.size();
        /// Iterate separately over the paths of sorted src_dynamic_paths_for_shared_data that can have a value in this row.
        auto [row_paths_it, row_paths_end] = get_row_paths(row);
        size_t offset = src_shared_data_offsets[static_cast<ssize_t>(row) - 1];
        size_t end = src_shared_data_offsets[row];
        for (size_t i = offset; i != end; ++i)
        {
            auto path = src_shared_data_paths->getDataAt(i);
            /// Check if we have this path in dynamic paths.
            if (gather_state)
            {
                if (auto column_index = gather_state->findDynamicColumn(path))
                {
                    if (gather_state->collect_values_from_shared_data)
                    {
                        gather_state->values_from_shared_data[*column_index].push_back({current_size, src_shared_data_values, i});
                        continue;
                    }

                    /// Dynamic paths are filled with defaults lazily while gathering, see below.
                    auto * column = gather_state->dynamic_columns[*column_index];
                    if (column->size() > current_size)
                        throw Exception(ErrorCodes::LOGICAL_ERROR, "Unexpected size of dynamic path {}: {} != {}", path, column->size(), current_size);
                    if (column->size() < current_size)
                        column->insertManyDefaults(current_size - column->size());

                    /// Deserialize binary value into dynamic column from shared data.
                    gather_state->deserializeValue(src_shared_data_values, i, *column_index);
                    continue;
                }
            }
            else if (auto it = dynamic_paths_ptrs.find(path); it != dynamic_paths_ptrs.end())
            {
                if (it->second->size() != current_size)
                    throw Exception(ErrorCodes::LOGICAL_ERROR, "Unexpected size of dynamic path {}: {} != {}", path, it->second->size(), current_size);

                /// Deserialize binary value into dynamic column from shared data.
                deserializeValueFromSharedData(src_shared_data_values, i, *it->second);
                continue;
            }

            if (auto * dynamic_path_column = tryToAddNewDynamicPath(path))
            {
                deserializeValueFromSharedData(src_shared_data_values, i, *dynamic_path_column);
                if (gather_state)
                    gather_state->updateDynamicColumns(dynamic_paths_ptrs);
            }
            else
            {
                /// Before inserting this path into shared data check if we need to
                /// insert dynamic paths from src_dynamic_paths_for_shared_data before.
                while (row_paths_it != row_paths_end && src_dynamic_paths_for_shared_data[*row_paths_it].first < path)
                {
                    flush_copied();
                    serialize_path_and_value(shared_data_paths, shared_data_values, *row_paths_it, row);
                    ++row_paths_it;
                }

                /// Insert path and value from src shared data to our shared data.
                if (copy_end != i)
                {
                    flush_copied();
                    copy_begin = i;
                }
                copy_end = i + 1;
            }
        }

        /// Insert remaining dynamic paths from src_dynamic_paths_for_shared_data.
        if (row_paths_it != row_paths_end)
            flush_copied();
        for (; row_paths_it != row_paths_end; ++row_paths_it)
            serialize_path_and_value(shared_data_paths, shared_data_values, *row_paths_it, row);

        shared_data_offsets.push_back(shared_data_paths->size() + (copy_end - copy_begin));

        /// Insert default value in all remaining dynamic paths.
        /// While gathering, a dynamic path is filled with defaults only before its next value and after the range.
        if (!gather_state)
        {
            for (auto & [_, column] : dynamic_paths_ptrs)
            {
                if (column->size() == current_size)
                    column->insertDefault();
            }
        }
    }
    flush_copied();

    if (gather_state && !gather_state->collect_values_from_shared_data)
    {
        size_t new_size = shared_data_offsets.size();
        for (auto * column : gather_state->dynamic_columns)
        {
            if (column->size() < new_size)
                column->insertManyDefaults(new_size - column->size());
        }
    }
}

void ColumnObject::serializePathAndValueIntoSharedData(ColumnString * shared_data_paths, ColumnString * shared_data_values, std::string_view path, const ColumnDynamic & column, size_t n)
{
    /// Don't store Null values in shared data. We consider Null value equivalent to the absence
    /// of this path in the row because we cannot distinguish these 2 cases for dynamic paths.
    if (column.isNullAt(n))
        return;

    shared_data_paths->insertData(path.data(), path.size());
    auto & shared_data_values_chars = shared_data_values->getChars();
    {
        WriteBufferFromVector<ColumnString::Chars> value_buf(shared_data_values_chars, AppendModeTag());
        getDynamicSerialization()->serializeBinary(column, n, value_buf, getFormatSettings());
    }
    shared_data_values->getOffsets().push_back(shared_data_values_chars.size());
}

void ColumnObject::serializePathAndValueIntoSharedData(ColumnString * shared_data_paths, ColumnString * shared_data_values, std::string_view path, const ColumnDynamic & column, size_t n, SharedDataValueSerializationCache & cache)
{
    const auto & variant_column = column.getVariantColumn();
    auto global_discr = variant_column.globalDiscriminatorAt(n);
    /// Null values are not stored, see the overload above.
    if (global_discr == ColumnVariant::NULL_DISCRIMINATOR)
        return;

    if (!cache.is_initialized)
    {
        cache.shared_variant_discriminator = column.getSharedVariantDiscriminator();
        cache.max_string_size = getFormatSettings().binary.max_binary_string_size;
        cache.encoded_types.resize(column.getVariantInfo().variant_names.size());
        cache.serializations.resize(column.getVariantInfo().variant_names.size());
        cache.value_formats.resize(column.getVariantInfo().variant_names.size());
        cache.is_initialized = true;
    }

    shared_data_paths->insertData(path.data(), path.size());
    auto & shared_data_values_chars = shared_data_values->getChars();
    const auto & variant = variant_column.getVariantByGlobalDiscriminator(global_discr);
    const size_t variant_row = variant_column.offsetAt(n);
    /// The same bytes as SerializationDynamic::serializeBinary writes: a value of the shared variant is already
    /// a binary-encoded type and value, other values are written as the encoded variant type and the value.
    if (global_discr == cache.shared_variant_discriminator)
    {
        auto value = assert_cast<const ColumnString &>(variant).getDataAt(variant_row);
        shared_data_values_chars.insert(value.data(), value.data() + value.size());
    }
    else
    {
        using ValueFormat = SharedDataValueSerializationCache::ValueFormat;
        auto & serialization = cache.serializations[global_discr];
        if (!serialization)
        {
            const auto & variant_info = column.getVariantInfo();
            const auto & variant_type = assert_cast<const DataTypeVariant &>(*variant_info.variant_type).getVariant(global_discr);
            WriteBufferFromString type_buf(cache.encoded_types[global_discr]);
            encodeDataType(variant_type, type_buf);
            type_buf.finalize();
            serialization = getDataTypesCache().getSerialization(variant_info.variant_names[global_discr]);

            /// SerializationString::serializeBinary and SerializationNumber::serializeBinary (little-endian) write these.
            if (typeid_cast<const SerializationString *>(serialization.get()))
                cache.value_formats[global_discr] = ValueFormat::String;
            else if (std::endian::native == std::endian::little && WhichDataType(variant_type).isNativeNumber())
                cache.value_formats[global_discr] = ValueFormat::FixedSize;
            else
                cache.value_formats[global_discr] = ValueFormat::Serialization;
        }

        const auto & encoded_type = cache.encoded_types[global_discr];
        shared_data_values_chars.insert(encoded_type.data(), encoded_type.data() + encoded_type.size());
        auto value_format = cache.value_formats[global_discr];
        std::string_view value;
        if (value_format != ValueFormat::Serialization)
        {
            value = variant.getDataAt(variant_row);
            if (value_format == ValueFormat::String && cache.max_string_size && value.size() > cache.max_string_size)
                value_format = ValueFormat::Serialization;
        }

        if (value_format == ValueFormat::Serialization)
        {
            WriteBufferFromVector<ColumnString::Chars> value_buf(shared_data_values_chars, AppendModeTag());
            serialization->serializeBinary(variant, variant_row, value_buf, getFormatSettings());
            value_buf.finalize();
        }
        else
        {
            if (value_format == ValueFormat::String)
            {
                char size_buf[16];
                const char * size_end = writeVarUInt(value.size(), size_buf);
                shared_data_values_chars.insert(size_buf, size_end);
            }
            shared_data_values_chars.insert(value.data(), value.data() + value.size());
        }
    }
    shared_data_values->getOffsets().push_back(shared_data_values_chars.size());
}

void ColumnObject::deserializeValueFromSharedData(const ColumnString * shared_data_values, size_t n, IColumn & column)
{
    auto value_data = shared_data_values->getDataAt(n);
    ReadBufferFromMemory buf(value_data);
    getDynamicSerialization()->deserializeBinary(column, buf, getFormatSettings());
}

void ColumnObject::deserializeValueFromSharedData(const ColumnString * shared_data_values, size_t n, ColumnDynamic & column, SharedDataValueTypeCache & cache)
{
    auto value_data = shared_data_values->getDataAt(n);
    auto & variant_column = column.getVariantColumn();
    /// The binary type encoding is read byte by byte without lookahead, so equal leading bytes decode to
    /// the same type: this is what the full path below would do for this value.
    /// Most types are encoded by one byte, which is compared without a call to memcmp.
    const auto & encoded_type = cache.encoded_type;
    if (cache.serialization && value_data.size() >= encoded_type.size() && value_data.front() == encoded_type.front()
        && (encoded_type.size() == 1 || memcmp(value_data.data() + 1, encoded_type.data() + 1, encoded_type.size() - 1) == 0))
    {
        auto & variant = variant_column.getVariantByGlobalDiscriminator(cache.global_discriminator);
        auto value = value_data.substr(encoded_type.size());
        /// The same as SerializationString::deserializeBinary and SerializationNumber::deserializeBinary (little-endian)
        /// read. Values they would reject are left to them, so they throw the same exceptions.
        using ValueFormat = SharedDataValueSerializationCache::ValueFormat;
        bool inserted = false;
        if (cache.value_format == ValueFormat::String)
        {
            UInt64 size = 0;
            const char * data = readVarUInt(size, value.data(), value.size());
            const UInt64 max_size = getFormatSettings().binary.max_binary_string_size;
            if (size <= static_cast<UInt64>(value.data() + value.size() - data) && size <= SerializationString::MAX_STRING_SIZE
                && (!max_size || size <= max_size))
            {
                variant.insertData(data, size);
                inserted = true;
            }
        }
        else if (cache.value_format == ValueFormat::FixedSize)
        {
            const size_t size = variant.sizeOfValueIfFixed();
            if (value.size() >= size)
            {
                variant.insertData(value.data(), size);
                inserted = true;
            }
        }

        if (!inserted)
        {
            ReadBufferFromMemory buf(value);
            cache.serialization->deserializeBinary(variant, buf, getFormatSettings());
        }
        variant_column.getLocalDiscriminators().push_back(variant_column.localDiscriminatorByGlobal(cache.global_discriminator));
        variant_column.getOffsets().push_back(variant.size() - 1);
        return;
    }

    deserializeValueFromSharedData(shared_data_values, n, column);

    /// Adding a variant can renumber the global discriminators, so the cache is rebuilt after every full read.
    /// NULL and values kept in the shared variant are not cached.
    cache = {};
    auto global_discriminator = variant_column.globalDiscriminatorAt(variant_column.size() - 1);
    if (global_discriminator == ColumnVariant::NULL_DISCRIMINATOR || global_discriminator == column.getSharedVariantDiscriminator())
        return;

    ReadBufferFromMemory buf(value_data);
    auto type = decodeDataType(buf, getFormatSettings().binary.max_binary_type_complexity);
    cache.encoded_type = value_data.substr(0, buf.position() - value_data.data());
    cache.global_discriminator = global_discriminator;
    cache.serialization = column.getVariantSerialization(type);
    if (typeid_cast<const SerializationString *>(cache.serialization.get()))
        cache.value_format = SharedDataValueSerializationCache::ValueFormat::String;
    else if (std::endian::native == std::endian::little && WhichDataType(type).isNativeNumber())
        cache.value_format = SharedDataValueSerializationCache::ValueFormat::FixedSize;
}

void ColumnObject::insertDefault()
{
    /// Exception-safe: if some sub-column's insertDefault throws (e.g. on a memory limit),
    /// roll back the sub-columns that were already modified, otherwise the object is left
    /// with sub-columns of different sizes and popBack would over-pop the shorter ones.
    size_t prev_size = size();
    try
    {
        for (auto & [_, column] : typed_paths)
            column->insertDefault();
        for (auto & [_, column] : dynamic_paths_ptrs)
            column->insertDefault();
        shared_data->insertDefault();
    }
    catch (...)
    {
        for (auto & [_, column] : typed_paths)
            if (column->size() > prev_size)
                column->popBack(column->size() - prev_size);
        for (auto & [_, column] : dynamic_paths_ptrs)
            if (column->size() > prev_size)
                column->popBack(column->size() - prev_size);
        if (shared_data->size() > prev_size)
            shared_data->popBack(shared_data->size() - prev_size);
        throw;
    }
}

void ColumnObject::insertManyDefaults(size_t length)
{
    size_t prev_size = size();
    try
    {
        for (auto & [_, column] : typed_paths)
            column->insertManyDefaults(length);
        for (auto & [_, column] : dynamic_paths_ptrs)
            column->insertManyDefaults(length);
        shared_data->insertManyDefaults(length);
    }
    catch (...)
    {
        for (auto & [_, column] : typed_paths)
            if (column->size() > prev_size)
                column->popBack(column->size() - prev_size);
        for (auto & [_, column] : dynamic_paths_ptrs)
            if (column->size() > prev_size)
                column->popBack(column->size() - prev_size);
        if (shared_data->size() > prev_size)
            shared_data->popBack(shared_data->size() - prev_size);
        throw;
    }
}

void ColumnObject::popBack(size_t n)
{
    for (auto & [_, column] : typed_paths)
        column->popBack(n);
    for (auto & [_, column] : dynamic_paths_ptrs)
        column->popBack(n);
    shared_data->popBack(n);
}

ColumnCheckpointPtr ColumnObject::getCheckpoint() const
{
    auto get_checkpoints = [](const auto & columns)
    {
        ColumnObjectCheckpoint::CheckpointsMap checkpoints;
        for (const auto & [name, column] : columns)
            checkpoints[name] = column->getCheckpoint();

        return checkpoints;
    };

    return std::make_shared<ColumnObjectCheckpoint>(size(), get_checkpoints(typed_paths), get_checkpoints(dynamic_paths_ptrs), shared_data->getCheckpoint());
}

void ColumnObject::updateCheckpoint(ColumnCheckpoint & checkpoint) const
{
    auto & object_checkpoint = assert_cast<ColumnObjectCheckpoint &>(checkpoint);

    auto update_checkpoints = [&](const auto & columns_map, auto & checkpoints_map)
    {
        for (const auto & [name, column] : columns_map)
        {
            auto & nested = checkpoints_map[name];
            if (!nested)
                nested = column->getCheckpoint();
            else
                column->updateCheckpoint(*nested);
        }
    };

    checkpoint.size = size();
    update_checkpoints(typed_paths, object_checkpoint.typed_paths);
    update_checkpoints(dynamic_paths, object_checkpoint.dynamic_paths);
    shared_data->updateCheckpoint(*object_checkpoint.shared_data);
}

void ColumnObject::rollback(const ColumnCheckpoint & checkpoint)
{
    const auto & object_checkpoint = assert_cast<const ColumnObjectCheckpoint &>(checkpoint);

    auto rollback_columns = [&](auto & columns_map, const auto & checkpoints_map, bool is_dynamic_paths)
    {
        NameSet names_to_remove;

        /// Rollback subcolumns and remove paths that were not in checkpoint.
        for (auto & [name, column] : columns_map)
        {
            auto it = checkpoints_map.find(name);
            if (it == checkpoints_map.end())
                names_to_remove.insert(name);
            else
                column->rollback(*it->second);
        }

        for (const auto & name : names_to_remove)
        {
            if (is_dynamic_paths)
            {
                dynamic_paths_ptrs.erase(name);
                sorted_dynamic_paths.erase(name);
                updateDynamicPathsVersion();
            }

            columns_map.erase(name);
        }
    };

    rollback_columns(typed_paths, object_checkpoint.typed_paths, false);
    rollback_columns(dynamic_paths, object_checkpoint.dynamic_paths, true);
    shared_data->rollback(*object_checkpoint.shared_data);
}

std::string_view ColumnObject::serializeValueIntoArena(size_t n, Arena & arena, const char *& begin, const IColumn::SerializationSettings * settings) const
{
    std::string_view res;
    /// First serialize values from typed paths in sorted order. They are the same for all instances of this column.
    for (auto path : sorted_typed_paths)
    {
        auto data_ref = typed_paths.find(path)->second->serializeValueIntoArena(n, arena, begin, settings);
        res = std::string_view{data_ref.data() - res.size(), res.size() + data_ref.size()};
    }

    /// Second, serialize paths and values in binary format from dynamic paths and shared data in sorted by path order.
    serializeDynamicPathsAndSharedDataIntoArena(n, arena, begin, res);
    return res;
}

void ColumnObject::serializeDynamicPathsAndSharedDataIntoArena(size_t n, Arena & arena, const char *& begin, std::string_view & res) const
{
    /// Calculate total number of paths to serialize and write it.
    const auto & shared_data_offsets = getSharedDataOffsets();
    size_t offset = shared_data_offsets[static_cast<ssize_t>(n) - 1];
    size_t end = shared_data_offsets[static_cast<ssize_t>(n)];
    size_t num_paths = (end - offset);
    /// Don't serialize Nulls from dynamic paths.
    for (const auto & [_, column] : dynamic_paths)
        num_paths += !column->isNullAt(n);

    char * pos = arena.allocContinue(sizeof(size_t), begin);
    memcpy(pos, &num_paths, sizeof(size_t));
    res = std::string_view{pos - res.size(), res.size() + sizeof(size_t)};

    auto dynamic_paths_it = sorted_dynamic_paths.begin();
    auto [shared_data_paths, shared_data_values] = getSharedDataPathsAndValues();
    for (size_t i = offset; i != end; ++i)
    {
        auto path = shared_data_paths->getDataAt(i);
        /// Paths in shared data are sorted. Serialize all paths from dynamic paths that go before this path in sorted order.
        while (dynamic_paths_it != sorted_dynamic_paths.end() && *dynamic_paths_it < path)
        {
            const auto * dynamic_column = dynamic_paths_ptrs.find(*dynamic_paths_it)->second;
            /// Don't serialize Nulls.
            if (!dynamic_column->isNullAt(n))
            {
                WriteBufferFromOwnString buf;
                getDynamicSerialization()->serializeBinary(*dynamic_column, n, buf, getFormatSettings());
                serializePathAndValueIntoArena(arena, begin, std::string_view(*dynamic_paths_it), buf.str(), res);
            }
            ++dynamic_paths_it;
        }
        serializePathAndValueIntoArena(arena, begin, std::string_view(path), shared_data_values->getDataAt(i), res);
    }

    /// Serialize all remaining paths in dynamic paths.
    for (; dynamic_paths_it != sorted_dynamic_paths.end(); ++dynamic_paths_it)
    {
        const auto * dynamic_column = dynamic_paths_ptrs.find(*dynamic_paths_it)->second;
        if (!dynamic_column->isNullAt(n))
        {
            WriteBufferFromOwnString buf;
            getDynamicSerialization()->serializeBinary(*dynamic_column, n, buf, getFormatSettings());
            serializePathAndValueIntoArena(arena, begin, std::string_view(*dynamic_paths_it), buf.str(), res);
        }
    }
}

void ColumnObject::serializePathAndValueIntoArena(DB::Arena & arena, const char *& begin, std::string_view path, std::string_view value, std::string_view & res) const
{
    size_t value_size = value.size();
    size_t path_size = path.size();
    char * pos = arena.allocContinue(sizeof(size_t) + path_size + sizeof(size_t) + value_size, begin);
    memcpy(pos, &path_size, sizeof(size_t));
    memcpy(pos + sizeof(size_t), path.data(), path_size);
    memcpy(pos + sizeof(size_t) + path_size, &value_size, sizeof(size_t));
    memcpy(pos + sizeof(size_t) + path_size + sizeof(size_t), value.data(), value_size);
    res = std::string_view{pos - res.size(), res.size() + sizeof(size_t) + path_size + sizeof(size_t) + value_size};
}

void ColumnObject::deserializeAndInsertFromArena(ReadBuffer & in, const IColumn::SerializationSettings * settings)
{
    /// First deserialize typed paths. They come first.
    for (auto path : sorted_typed_paths)
        typed_paths.find(path)->second->deserializeAndInsertFromArena(in, settings);

    /// Second deserialize all other paths and values and insert them into dynamic paths or shared data.
    deserializeDynamicPathsAndSharedDataFromArena(in);
}

void ColumnObject::deserializeDynamicPathsAndSharedDataFromArena(ReadBuffer & in)
{
    size_t current_size = size();
    size_t num_paths = 0;
    readBinaryLittleEndian<size_t>(num_paths, in);

    const auto [shared_data_paths, shared_data_values] = getSharedDataPathsAndValues();
    for (size_t i = 0; i != num_paths; ++i)
    {
        size_t path_size = 0;
        readBinaryLittleEndian<size_t>(path_size, in);

        if (in.available() < path_size)
            throw Exception(
                ErrorCodes::ATTEMPT_TO_READ_AFTER_EOF,
                "Attempt to read {} bytes for the path size, but only {} bytes are available",
                path_size,
                in.available());
        std::string_view path(in.position(), path_size);
        in.ignore(path_size);

        /// Deserialize binary value and try to insert it to dynamic paths or shared data.
        size_t value_size = 0;
        readBinaryLittleEndian<size_t>(value_size, in);

        /// Check if we have this path in dynamic paths.
        if (auto dynamic_it = dynamic_paths.find(path); dynamic_it != dynamic_paths.end())
        {
            getDynamicSerialization()->deserializeBinary(*dynamic_it->second, in, getFormatSettings());
        }
        /// Try to add a new dynamic path.
        else if (auto * dynamic_path_column = tryToAddNewDynamicPath(path))
        {
            getDynamicSerialization()->deserializeBinary(*dynamic_path_column, in, getFormatSettings());
        }
        /// Limit on dynamic paths is reached, add this path to shared data.
        /// Serialized paths are sorted, so we can insert right away.
        else
        {
            if (in.available() < value_size)
                throw Exception(
                    ErrorCodes::ATTEMPT_TO_READ_AFTER_EOF,
                    "Attempt to read {} bytes for the value size, but only {} bytes are available",
                    value_size,
                    in.available());
            std::string_view value(in.position(), value_size);
            in.ignore(value_size);
            shared_data_paths->insertData(path.data(), path.size());
            shared_data_values->insertData(value.data(), value.size());
        }
    }

    getSharedDataOffsets().push_back(shared_data_paths->size());

    /// Insert default value in all remaining  dynamic paths.
    for (auto & [_, column] : dynamic_paths_ptrs)
    {
        if (column->size() == current_size)
            column->insertDefault();
    }
}

void ColumnObject::updateHashWithValue(size_t n, SipHash & hash) const
{
    for (auto path : sorted_typed_paths)
        typed_paths.find(path)->second->updateHashWithValue(n, hash);

    /// The hash of the object in row should not depend on the way we store paths (in dynamic paths or in shared data)
    /// and should be the same for the same objects. To support it we update hash with path and its value (if not null) in
    /// sorted by path order from both dynamic paths and shared data.
    const auto [shared_data_paths, shared_data_values] = getSharedDataPathsAndValues();
    const auto & shared_data_offsets = getSharedDataOffsets();
    size_t start = shared_data_offsets[static_cast<ssize_t>(n) - 1];
    size_t end = shared_data_offsets[static_cast<ssize_t>(n)];
    auto dynamic_paths_it = sorted_dynamic_paths.begin();
    for (size_t i = start; i != end; ++i)
    {
        auto path = shared_data_paths->getDataAt(i);
        /// Paths in shared data are sorted. Update hash with all paths from dynamic paths that go before this path in sorted order.
        while (dynamic_paths_it != sorted_dynamic_paths.end() && *dynamic_paths_it < path)
        {
            const auto * dynamic_column = dynamic_paths_ptrs.find(*dynamic_paths_it)->second;
            if (!dynamic_column->isNullAt(n))
            {
                hash.update(*dynamic_paths_it);
                dynamic_column->updateHashWithValue(n, hash);
            }
            ++dynamic_paths_it;
        }

        /// Hash the value the same way ColumnDynamic hashes a value in its shared variant, so the hash is layout-independent.
        auto value = shared_data_values->getDataAt(i);
        ReadBufferFromMemory buf(value);
        auto value_type = decodeDataType(buf);
        hash.update(path);

        /// A shared_data entry can be encoded as Nothing (a serialized NULL). Nothing has no usable
        /// default serialization (SerializationNothing::deserializeBinary always throws), so it must be
        /// special-cased here just like SerializationDynamic::deserializeBinary does for ColumnDynamic:
        /// treat it as the null row and hash the same NULL_DISCRIMINATOR that ColumnDynamic::updateHashWithValue
        /// hashes for a null value, instead of hashing a type name and deserialized value.
        if (isNothing(value_type))
        {
            hash.update(ColumnVariant::NULL_DISCRIMINATOR);
            continue;
        }

        auto type_name = value_type->getName();
        hash.update(type_name);
        auto tmp_column = value_type->createColumn();
        getDataTypesCache().getSerialization(type_name)->deserializeBinary(*tmp_column, buf, getFormatSettings());
        tmp_column->updateHashWithValue(0, hash);
    }

    /// Iterate over all remaining paths in dynamic paths.
    for (; dynamic_paths_it != sorted_dynamic_paths.end(); ++dynamic_paths_it)
    {
        const auto * dynamic_column = dynamic_paths_ptrs.find(*dynamic_paths_it)->second;
        if (!dynamic_column->isNullAt(n))
        {
            hash.update(*dynamic_paths_it);
            dynamic_column->updateHashWithValue(n, hash);
        }
    }
}

void ColumnObject::updateHashWithValueRange(size_t begin, size_t end, SipHash & hash) const
{
    /// Typed paths are always in the same order for all instances of the same Object type,
    /// so there is no need to hash the paths themselves.
    for (const auto & path : sorted_typed_paths)
        typed_paths.find(path)->second->updateHashWithValueRange(begin, end, hash);

    /// Dynamic paths may differ, so we hash the paths together with values.
    for (const auto & path : sorted_dynamic_paths)
    {
        hash.update(path.size());
        hash.update(path);
        dynamic_paths.find(path)->second->updateHashWithValueRange(begin, end, hash);
    }

    shared_data->updateHashWithValueRange(begin, end, hash);
}

void ColumnObject::computeHashInto(size_t row_begin, size_t row_end, UInt32 * hash_out, bool initial) const
{
    /// A logically equal object must hash the same regardless of how its paths are split between
    /// dynamic sub-columns and `shared_data` (the split varies across blocks and temp-file round-trips).
    /// Typed paths can never move between sections, so they are chained in a fixed order. Dynamic paths
    /// and `shared_data` can hold the same path, so each `(path, value)` is folded commutatively (`+`)
    /// and a `shared_data` value is decoded to the leaf hash it would have as a typed variant.
    const size_t n = row_end - row_begin;
    PaddedPODArray<UInt32> object_hash(n, WEAK_HASH32_INITIAL_VALUE);

    for (const auto & path : sorted_typed_paths)
        typed_paths.find(path)->second->computeHashInto(row_begin, row_end, object_hash.data(), /*initial=*/false);

    if (global_max_dynamic_paths == 0)
    {
        /// No path can ever be dynamic, so `shared_data` holds every non-typed path in a canonical
        /// layout and its bulk hash is already split-invariant (no per-value decode needed).
        shared_data->computeHashInto(row_begin, row_end, object_hash.data(), /*initial=*/false);
    }
    else
    {
        PaddedPODArray<UInt32> value_hash(n);
        for (const auto & [path, column] : dynamic_paths_ptrs)
        {
            column->computeHashInto(row_begin, row_end, value_hash.data(), /*initial=*/true);
            const UInt32 path_hash = updateWeakHash32(
                reinterpret_cast<const UInt8 *>(path.data()), path.size(), WEAK_HASH32_INITIAL_VALUE);
            for (size_t i = 0; i < n; ++i)
            {
                /// An absent/NULL path contributes nothing, so `{"a":1}` and `{"a":1,"b":null}` agree.
                if (!column->isNullAt(row_begin + i))
                    object_hash[i] += combineWeakHash32(value_hash[i], path_hash);
            }
        }

        const auto [shared_paths, shared_values] = getSharedDataPathsAndValues();
        const auto & shared_offsets = getSharedDataOffsets();
        const size_t entries_begin = shared_offsets[static_cast<ssize_t>(row_begin) - 1];
        const size_t num_entries = shared_offsets[static_cast<ssize_t>(row_end) - 1] - entries_begin;
        if (num_entries)
        {
            /// The whole range is hashed in one call so the deserialization can be batched by type.
            PODArray<UInt32> entry_hash(num_entries);
            ColumnDynamic::hashSharedValues(*shared_values, entries_begin, num_entries, entry_hash.data());

            for (size_t i = 0; i < n; ++i)
            {
                for (size_t j = shared_offsets[static_cast<ssize_t>(row_begin + i) - 1]; j < shared_offsets[row_begin + i]; ++j)
                {
                    const auto path = shared_paths->getDataAt(j);
                    const UInt32 path_hash = updateWeakHash32(
                        reinterpret_cast<const UInt8 *>(path.data()), path.size(), WEAK_HASH32_INITIAL_VALUE);
                    object_hash[i] += combineWeakHash32(entry_hash[j - entries_begin], path_hash);
                }
            }
        }
    }

    if (initial)
    {
        memcpy(hash_out, object_hash.data(), n * sizeof(UInt32));
    }
    else
    {
        for (size_t i = 0; i < n; ++i)
            hash_out[i] = combineWeakHash32(object_hash[i], hash_out[i]);
    }
}

void ColumnObject::updateHashFast(SipHash & hash) const
{
    for (const auto & [_, column] : typed_paths)
        column->updateHashFast(hash);
    for (const auto & [_, column] : dynamic_paths_ptrs)
        column->updateHashFast(hash);
    shared_data->updateHashFast(hash);
}

ColumnPtr ColumnObject::filter(const Filter & filt, ssize_t result_size_hint) const
{
    UnorderedMapWithMemoryTracking<String, ColumnPtr> filtered_typed_paths;
    filtered_typed_paths.reserve(typed_paths.size());
    for (const auto & [path, column] : typed_paths)
        filtered_typed_paths[path] = column->filter(filt, result_size_hint);

    UnorderedMapWithMemoryTracking<String, ColumnPtr> filtered_dynamic_paths;
    filtered_dynamic_paths.reserve(dynamic_paths_ptrs.size());
    for (const auto & [path, column] : dynamic_paths_ptrs)
        filtered_dynamic_paths[path] = column->filter(filt, result_size_hint);

    auto filtered_shared_data = shared_data->filter(filt, result_size_hint);
    return ColumnObject::create(filtered_typed_paths, filtered_dynamic_paths, filtered_shared_data, max_dynamic_paths, max_dynamic_paths_upper_bound, global_max_dynamic_paths, max_dynamic_types, statistics);
}

void ColumnObject::filter(const Filter & filt)
{
    for (const auto & [path, column] : typed_paths)
        column->assumeMutable()->filter(filt);

    for (const auto & [path, column] : dynamic_paths_ptrs)
        column->filter(filt);

    shared_data->filter(filt);

    statistics.reset();
}

void ColumnObject::expand(const Filter & mask, bool inverted)
{
    for (auto & [_, column] : typed_paths)
        column->expand(mask, inverted);
    for (auto & [_, column] : dynamic_paths_ptrs)
        column->expand(mask, inverted);
    shared_data->expand(mask, inverted);
}

ColumnPtr ColumnObject::permute(const Permutation & perm, size_t limit) const
{
    UnorderedMapWithMemoryTracking<String, ColumnPtr> permuted_typed_paths;
    permuted_typed_paths.reserve(typed_paths.size());
    for (const auto & [path, column] : typed_paths)
        permuted_typed_paths[path] = column->permute(perm, limit);

    UnorderedMapWithMemoryTracking<String, ColumnPtr> permuted_dynamic_paths;
    permuted_dynamic_paths.reserve(dynamic_paths_ptrs.size());
    for (const auto & [path, column] : dynamic_paths_ptrs)
        permuted_dynamic_paths[path] = column->permute(perm, limit);

    auto permuted_shared_data = shared_data->permute(perm, limit);
    return ColumnObject::create(permuted_typed_paths, permuted_dynamic_paths, permuted_shared_data, max_dynamic_paths, max_dynamic_paths_upper_bound, global_max_dynamic_paths, max_dynamic_types, statistics);
}

ColumnPtr ColumnObject::index(const IColumn & indexes, size_t limit) const
{
    UnorderedMapWithMemoryTracking<String, ColumnPtr> indexed_typed_paths;
    indexed_typed_paths.reserve(typed_paths.size());
    for (const auto & [path, column] : typed_paths)
        indexed_typed_paths[path] = column->index(indexes, limit);

    UnorderedMapWithMemoryTracking<String, ColumnPtr> indexed_dynamic_paths;
    indexed_dynamic_paths.reserve(dynamic_paths_ptrs.size());
    for (const auto & [path, column] : dynamic_paths_ptrs)
        indexed_dynamic_paths[path] = column->index(indexes, limit);

    auto indexed_shared_data = shared_data->index(indexes, limit);
    return ColumnObject::create(indexed_typed_paths, indexed_dynamic_paths, indexed_shared_data, max_dynamic_paths, max_dynamic_paths_upper_bound, global_max_dynamic_paths, max_dynamic_types, statistics);
}

ColumnPtr ColumnObject::replicate(const Offsets & replicate_offsets) const
{
    UnorderedMapWithMemoryTracking<String, ColumnPtr> replicated_typed_paths;
    replicated_typed_paths.reserve(typed_paths.size());
    for (const auto & [path, column] : typed_paths)
        replicated_typed_paths[path] = column->replicate(replicate_offsets);

    UnorderedMapWithMemoryTracking<String, ColumnPtr> replicated_dynamic_paths;
    replicated_dynamic_paths.reserve(dynamic_paths_ptrs.size());
    for (const auto & [path, column] : dynamic_paths_ptrs)
        replicated_dynamic_paths[path] = column->replicate(replicate_offsets);

    auto replicated_shared_data = shared_data->replicate(replicate_offsets);
    return ColumnObject::create(replicated_typed_paths, replicated_dynamic_paths, replicated_shared_data, max_dynamic_paths, max_dynamic_paths_upper_bound, global_max_dynamic_paths, max_dynamic_types, statistics);
}

VectorWithMemoryTracking<MutableColumnPtr> ColumnObject::scatter(size_t num_columns, const Selector & selector) const
{
    VectorWithMemoryTracking<UnorderedMapWithMemoryTracking<String, MutableColumnPtr>> scattered_typed_paths(num_columns);
    for (auto & typed_paths_ : scattered_typed_paths)
        typed_paths_.reserve(typed_paths.size());

    for (const auto & [path, column] : typed_paths)
    {
        auto scattered_columns = column->scatter(num_columns, selector);
        for (size_t i = 0; i != num_columns; ++i)
            scattered_typed_paths[i][path] = std::move(scattered_columns[i]);
    }

    VectorWithMemoryTracking<UnorderedMapWithMemoryTracking<String, MutableColumnPtr>> scattered_dynamic_paths(num_columns);
    for (auto & dynamic_paths_ : scattered_dynamic_paths)
        dynamic_paths_.reserve(dynamic_paths_ptrs.size());

    for (const auto & [path, column] : dynamic_paths_ptrs)
    {
        auto scattered_columns = column->scatter(num_columns, selector);
        for (size_t i = 0; i != num_columns; ++i)
            scattered_dynamic_paths[i][path] = std::move(scattered_columns[i]);
    }

    auto scattered_shared_data_columns = shared_data->scatter(num_columns, selector);
    VectorWithMemoryTracking<MutableColumnPtr> result_columns;
    result_columns.reserve(num_columns);
    for (size_t i = 0; i != num_columns; ++i)
        result_columns.emplace_back(ColumnObject::create(std::move(scattered_typed_paths[i]), std::move(scattered_dynamic_paths[i]), std::move(scattered_shared_data_columns[i]), max_dynamic_paths, max_dynamic_paths_upper_bound, global_max_dynamic_paths, max_dynamic_types, statistics));
    return result_columns;
}

struct ColumnObject::ComparatorBase
{
    const ColumnObject & parent;
    int nan_direction_hint;

    ComparatorBase(const ColumnObject & parent_, int nan_direction_hint_)
        : parent(parent_), nan_direction_hint(nan_direction_hint_)
    {
    }

    ALWAYS_INLINE int compare(size_t lhs, size_t rhs) const
    {
        int res = parent.compareAt(lhs, rhs, parent, nan_direction_hint);

        return res;
    }
};

void ColumnObject::getPermutation(PermutationSortDirection direction, PermutationSortStability stability,
                                  size_t limit, int nan_direction_hint, Permutation & res) const
{
    if (direction == IColumn::PermutationSortDirection::Ascending && stability == IColumn::PermutationSortStability::Unstable)
        getPermutationImpl(limit, res, ComparatorAscendingUnstable(*this, nan_direction_hint), DefaultSort(), DefaultPartialSort());
    else if (direction == IColumn::PermutationSortDirection::Ascending && stability == IColumn::PermutationSortStability::Stable)
        getPermutationImpl(limit, res, ComparatorAscendingStable(*this, nan_direction_hint), DefaultSort(), DefaultPartialSort());
    else if (direction == IColumn::PermutationSortDirection::Descending && stability == IColumn::PermutationSortStability::Unstable)
        getPermutationImpl(limit, res, ComparatorDescendingUnstable(*this, nan_direction_hint), DefaultSort(), DefaultPartialSort());
    else if (direction == IColumn::PermutationSortDirection::Descending && stability == IColumn::PermutationSortStability::Stable)
        getPermutationImpl(limit, res, ComparatorDescendingStable(*this, nan_direction_hint), DefaultSort(), DefaultPartialSort());
}

void ColumnObject::updatePermutation(PermutationSortDirection direction, PermutationSortStability stability,
                                     size_t limit, int nan_direction_hint, Permutation & res, EqualRanges & equal_ranges) const
{
    auto comparator_equal = ComparatorEqual(*this, nan_direction_hint);

    if (direction == IColumn::PermutationSortDirection::Ascending && stability == IColumn::PermutationSortStability::Unstable)
        updatePermutationImpl(limit, res, equal_ranges, ComparatorAscendingUnstable(*this, nan_direction_hint), comparator_equal, DefaultSort(), DefaultPartialSort());
    else if (direction == IColumn::PermutationSortDirection::Ascending && stability == IColumn::PermutationSortStability::Stable)
        updatePermutationImpl(limit, res, equal_ranges, ComparatorAscendingStable(*this, nan_direction_hint), comparator_equal, DefaultSort(), DefaultPartialSort());
    else if (direction == IColumn::PermutationSortDirection::Descending && stability == IColumn::PermutationSortStability::Unstable)
        updatePermutationImpl(limit, res, equal_ranges, ComparatorDescendingUnstable(*this, nan_direction_hint), comparator_equal, DefaultSort(), DefaultPartialSort());
    else if (direction == IColumn::PermutationSortDirection::Descending && stability == IColumn::PermutationSortStability::Stable)
        updatePermutationImpl(limit, res, equal_ranges, ComparatorDescendingStable(*this, nan_direction_hint), comparator_equal, DefaultSort(), DefaultPartialSort());
}

void ColumnObject::reserve(size_t n)
{
    for (auto & [_, column] : typed_paths)
        column->reserve(n);
    for (auto & [_, column] : dynamic_paths_ptrs)
        column->reserve(n);
    shared_data->reserve(n);
}

size_t ColumnObject::capacity() const
{
    return shared_data->capacity();
}

void ColumnObject::shrinkToFit()
{
    for (auto & [_, column] : typed_paths)
        column->shrinkToFit();
    for (auto & [_, column] : dynamic_paths_ptrs)
        column->shrinkToFit();
    shared_data->shrinkToFit();
}

void ColumnObject::ensureOwnership()
{
    for (auto & [_, column] : typed_paths)
        column->ensureOwnership();
    for (auto & [_, column] : dynamic_paths_ptrs)
        column->ensureOwnership();
    shared_data->ensureOwnership();
}

size_t ColumnObject::byteSize() const
{
    size_t size = 0;
    for (const auto & [_, column] : typed_paths)
        size += column->byteSize();
    for (const auto & [_, column] : dynamic_paths_ptrs)
        size += column->byteSize();
    size += shared_data->byteSize();
    return size;
}

size_t ColumnObject::byteSizeAt(size_t n) const
{
    size_t size = 0;
    for (const auto & [_, column] : typed_paths)
        size += column->byteSizeAt(n);
    for (const auto & [_, column] : dynamic_paths_ptrs)
        size += column->byteSizeAt(n);
    size += shared_data->byteSizeAt(n);
    return size;
}

size_t ColumnObject::allocatedBytes() const
{
    size_t size = 0;
    for (const auto & [_, column] : typed_paths)
        size += column->allocatedBytes();
    for (const auto & [_, column] : dynamic_paths_ptrs)
        size += column->allocatedBytes();
    size += shared_data->allocatedBytes();
    return size;
}

void ColumnObject::protect()
{
    for (auto & [_, column] : typed_paths)
        column->protect();
    for (auto & [_, column] : dynamic_paths_ptrs)
        column->protect();
    shared_data->protect();
}

void ColumnObject::forEachMutableSubcolumn(DB::IColumn::MutableColumnCallback callback)
{
    for (const auto & path : sorted_typed_paths)
        callback(typed_paths.find(path)->second);
    rebuildSortedTypedPathColumns();
    for (const auto & path : sorted_dynamic_paths)
    {
        auto it = dynamic_paths.find(path);
        callback(it->second);
        dynamic_paths_ptrs[it->first] = assert_cast<ColumnDynamic *>(it->second.get());
    }
    updateDynamicPathsVersion();
    callback(shared_data);
}

void ColumnObject::forEachMutableSubcolumnRecursively(DB::IColumn::RecursiveMutableColumnCallback callback)
{
    for (const auto & path : sorted_typed_paths)
    {
        auto & column = typed_paths.find(path)->second;
        callback(*column);
        column->forEachMutableSubcolumnRecursively(callback);
    }

    rebuildSortedTypedPathColumns();

    for (const auto & path : sorted_dynamic_paths)
    {
        auto it = dynamic_paths.find(path);
        callback(*it->second);
        it->second->forEachMutableSubcolumnRecursively(callback);
        dynamic_paths_ptrs[it->first] = assert_cast<ColumnDynamic *>(it->second.get());
    }
    updateDynamicPathsVersion();
    callback(*shared_data);
    shared_data->forEachMutableSubcolumnRecursively(callback);
}

void ColumnObject::forEachSubcolumn(DB::IColumn::ColumnCallback callback) const
{
    for (const auto & path : sorted_typed_paths)
        callback(typed_paths.find(path)->second);
    for (const auto & path : sorted_dynamic_paths)
        callback(dynamic_paths.find(path)->second);

    callback(shared_data);
}

void ColumnObject::forEachSubcolumnRecursively(DB::IColumn::RecursiveColumnCallback callback) const
{
    for (const auto & path : sorted_typed_paths)
    {
        const auto & column = typed_paths.find(path)->second;
        callback(*column);
        column->forEachSubcolumnRecursively(callback);
    }
    for (const auto & path : sorted_dynamic_paths)
    {
        const auto & column = dynamic_paths.find(path)->second;
        callback(*column);
        column->forEachSubcolumnRecursively(callback);
    }
    callback(*shared_data);
    shared_data->forEachSubcolumnRecursively(callback);
}

bool ColumnObject::structureEquals(const IColumn & rhs) const
{
    /// 2 Object columns have equal structure if they have the same typed paths and global_max_dynamic_paths/max_dynamic_types.
    const auto * rhs_object = typeid_cast<const ColumnObject *>(&rhs);
    if (!rhs_object || typed_paths.size() != rhs_object->typed_paths.size() || global_max_dynamic_paths != rhs_object->global_max_dynamic_paths || max_dynamic_types != rhs_object->max_dynamic_types)
        return false;

    for (const auto & [path, column] : typed_paths)
    {
        auto it = rhs_object->typed_paths.find(path);
        if (it == rhs_object->typed_paths.end() || !it->second->structureEquals(*column))
            return false;
    }

    return true;
}

ColumnPtr ColumnObject::compress(bool force_compression) const
{
    UnorderedMapWithMemoryTracking<String, ColumnPtr> compressed_typed_paths;
    compressed_typed_paths.reserve(typed_paths.size());
    size_t byte_size = 0;
    for (const auto & [path, column] : typed_paths)
    {
        auto compressed_column = column->compress(force_compression);
        byte_size += compressed_column->byteSize();
        compressed_typed_paths[path] = std::move(compressed_column);
    }

    UnorderedMapWithMemoryTracking<String, ColumnPtr> compressed_dynamic_paths;
    compressed_dynamic_paths.reserve(dynamic_paths_ptrs.size());
    for (const auto & [path, column] : dynamic_paths_ptrs)
    {
        auto compressed_column = column->compress(force_compression);
        byte_size += compressed_column->byteSize();
        compressed_dynamic_paths[path] = std::move(compressed_column);
    }

    auto compressed_shared_data = shared_data->compress(force_compression);
    byte_size += compressed_shared_data->byteSize();

    auto decompress =
        [my_compressed_typed_paths = std::move(compressed_typed_paths),
         my_compressed_dynamic_paths = std::move(compressed_dynamic_paths),
         my_compressed_shared_data = std::move(compressed_shared_data),
         my_max_dynamic_paths = max_dynamic_paths,
         my_max_dynamic_paths_upper_bound = max_dynamic_paths_upper_bound,
         my_global_max_dynamic_paths = global_max_dynamic_paths,
         my_max_dynamic_types = max_dynamic_types,
         my_statistics = statistics]() mutable
    {
        UnorderedMapWithMemoryTracking<String, ColumnPtr> decompressed_typed_paths;
        decompressed_typed_paths.reserve(my_compressed_typed_paths.size());
        for (const auto & [path, column] : my_compressed_typed_paths)
            decompressed_typed_paths[path] = column->decompress();

        UnorderedMapWithMemoryTracking<String, ColumnPtr> decompressed_dynamic_paths;
        decompressed_dynamic_paths.reserve(my_compressed_dynamic_paths.size());
        for (const auto & [path, column] : my_compressed_dynamic_paths)
            decompressed_dynamic_paths[path] = column->decompress();

        auto decompressed_shared_data = my_compressed_shared_data->decompress();
        return ColumnObject::create(decompressed_typed_paths, decompressed_dynamic_paths, decompressed_shared_data, my_max_dynamic_paths, my_max_dynamic_paths_upper_bound, my_global_max_dynamic_paths, my_max_dynamic_types, my_statistics);
    };

    return ColumnCompressed::create(size(), byte_size, decompress);
}

void ColumnObject::finalize()
{
    for (auto & [_, column] : typed_paths)
        column->finalize();
    for (auto & [_, column] : dynamic_paths_ptrs)
        column->finalize();
    shared_data->finalize();
}

bool ColumnObject::isFinalized() const
{
    bool finalized = true;
    for (const auto & [_, column] : typed_paths)
        finalized &= column->isFinalized();
    for (const auto & [_, column] : dynamic_paths_ptrs)
        finalized &= column->isFinalized();
    finalized &= shared_data->isFinalized();
    return finalized;
}

void ColumnObject::getExtremes(Field & min, Field & max, size_t start, size_t end) const
{
    min = Object();
    max = Object();

    if (start >= end)
        return;

    size_t min_idx = start;
    size_t max_idx = start;

    for (size_t i = start + 1; i < end; ++i)
    {
        if (compareAt(i, min_idx, *this, /* nan_direction_hint = */ 1) < 0)
            min_idx = i;
        else if (compareAt(i, max_idx, *this, /* nan_direction_hint = */ -1) > 0)
            max_idx = i;
    }

    get(min_idx, min);
    get(max_idx, max);
}

void ColumnObject::prepareForSquashing(const VectorWithMemoryTracking<ColumnPtr> & source_columns, size_t factor)
{
    if (source_columns.empty())
        return;

    /// Dynamic paths of source Object columns may differ.
    /// We want to preallocate memory for all dynamic paths we will have after squashing.
    /// It may happen that the total number of dynamic paths in source columns will
    /// exceed the limit, in this case we will choose the most frequent paths.
    UnorderedMapWithMemoryTracking<String, size_t> path_to_total_number_of_non_null_values;

    auto add_dynamic_paths = [&](const ColumnObject & source_object)
    {
        for (const auto & [path, dynamic_column_ptr] : source_object.dynamic_paths_ptrs)
        {
            auto it = path_to_total_number_of_non_null_values.find(path);
            if (it == path_to_total_number_of_non_null_values.end())
                it = path_to_total_number_of_non_null_values.emplace(path, 0).first;
            it->second += (dynamic_column_ptr->size() - dynamic_column_ptr->getNumberOfDefaultRows());
        }
    };

    for (const auto & source_column : source_columns)
        add_dynamic_paths(assert_cast<const ColumnObject &>(*source_column));

    /// Add dynamic paths from this object column.
    add_dynamic_paths(*this);

    /// It might happen that current max_dynamic_paths is less then its upper bound
    /// but the shared data is empty. For example if this block was deserialized from Native format.
    /// In this case we should set max_dynamic_paths to the upper bound, so during squashing we
    /// will insert new types to SharedVariant only when that limit is reached.
    /// Raising the limit is only safe while nothing has been spilled yet: otherwise a path could be
    /// promoted to a dynamic path while the earlier rows still keep it in shared data.
    if (getSharedDataPathsAndValues().first->empty() && max_dynamic_paths != max_dynamic_paths_upper_bound)
    {
        max_dynamic_paths = max_dynamic_paths_upper_bound;
        updateDynamicPathsVersion();
    }

    /// Check if the number of all dynamic paths exceeds the limit.
    if (path_to_total_number_of_non_null_values.size() > max_dynamic_paths)
    {
        /// We want to keep the most frequent paths in the resulting object column.
        /// Sort paths by total number of non null values.
        /// Don't include paths from current column as we cannot change them.
        VectorWithMemoryTracking<std::pair<size_t, std::string_view>> paths_with_sizes;
        paths_with_sizes.reserve(path_to_total_number_of_non_null_values.size() - dynamic_paths.size());
        for (const auto & [path, size] : path_to_total_number_of_non_null_values)
        {
            if (!dynamic_paths.contains(path))
                paths_with_sizes.emplace_back(size, path);
        }

        /// If sizes are equal, sort by path names in ascending order (for easier testing purposes).
        const auto compare_paths = [](const auto & left, const auto & right)
        {
            return std::tie(left.first, right.second) < std::tie(right.first, left.second);
        };

        /// Fill dynamic_paths with first paths in sorted list until we reach the limit.
        size_t paths_to_add = max_dynamic_paths - dynamic_paths.size();
        sortAndKeepTop(paths_with_sizes, paths_to_add, compare_paths);
        for (const auto & [_, path] : paths_with_sizes)
            addNewDynamicPath(path);
    }
    /// Otherwise keep all paths.
    else
    {
        /// Create columns for new dynamic paths.
        for (const auto & [path, _] : path_to_total_number_of_non_null_values)
        {
            if (!dynamic_paths.contains(path))
                addNewDynamicPath(path);
        }
    }

    /// Now current object column has all resulting dynamic paths and we can call
    /// prepareForSquashing on them to preallocate the memory.
    /// Also we can preallocate memory for dynamic paths and shared data.
    VectorWithMemoryTracking<ColumnPtr> shared_data_source_columns;
    shared_data_source_columns.reserve(source_columns.size());
    UnorderedMapWithMemoryTracking<String, VectorWithMemoryTracking<ColumnPtr>> typed_paths_source_columns;
    typed_paths_source_columns.reserve(typed_paths.size());
    UnorderedMapWithMemoryTracking<String, VectorWithMemoryTracking<ColumnPtr>> dynamic_paths_source_columns;
    dynamic_paths_source_columns.reserve(dynamic_paths.size());

    for (const auto & [path, column] : typed_paths)
        typed_paths_source_columns[path].reserve(source_columns.size());

    for (const auto & [path, column] : dynamic_paths)
        dynamic_paths_source_columns[path].reserve(source_columns.size());

    size_t total_size = 0;
    for (const auto & source_column : source_columns)
    {
        const auto & source_object_column = assert_cast<const ColumnObject &>(*source_column);
        total_size += source_object_column.size();
        shared_data_source_columns.push_back(source_object_column.shared_data);

        for (const auto & [path, column] : source_object_column.typed_paths)
            typed_paths_source_columns.at(path).push_back(column);

        for (const auto & [path, column] : source_object_column.dynamic_paths)
        {
            if (dynamic_paths.contains(path))
                dynamic_paths_source_columns.at(path).push_back(column);
        }
    }

    shared_data->prepareForSquashing(shared_data_source_columns, factor);

    for (const auto & [path, source_typed_columns] : typed_paths_source_columns)
        typed_paths[path]->prepareForSquashing(source_typed_columns, factor);

    for (const auto & [path, source_dynamic_columns] : dynamic_paths_source_columns)
    {
        /// ColumnDynamic::prepareForSquashing may not preallocate enough memory for discriminators and offsets
        /// because source columns may not have this dynamic path (and so dynamic columns filled with nulls).
        /// For this reason we first call ColumnDynamic::reserve with resulting size to preallocate memory for
        /// discriminators and offsets and ColumnDynamic::prepareVariantsForSquashing to preallocate memory
        /// for all variants inside Dynamic.
        dynamic_paths_ptrs[path]->reserve(total_size * factor);
        dynamic_paths_ptrs[path]->prepareVariantsForSquashing(source_dynamic_columns, factor);
    }
}

bool ColumnObject::dynamicStructureEquals(const IColumn & rhs) const
{
    const auto * rhs_object = typeid_cast<const ColumnObject *>(&rhs);
    if (!rhs_object || typed_paths.size() != rhs_object->typed_paths.size()
        || global_max_dynamic_paths != rhs_object->global_max_dynamic_paths || max_dynamic_types != rhs_object->max_dynamic_types
        || dynamic_paths.size() != rhs_object->dynamic_paths.size())
        return false;

    for (const auto & [path, column] : typed_paths)
    {
        auto it = rhs_object->typed_paths.find(path);
        if (it == rhs_object->typed_paths.end() || !it->second->dynamicStructureEquals(*column))
            return false;
    }

    for (const auto & [path, column] : dynamic_paths)
    {
        auto it = rhs_object->dynamic_paths.find(path);
        if (it == rhs_object->dynamic_paths.end() || !it->second->dynamicStructureEquals(*column))
            return false;
    }

    return true;
}

void ColumnObject::chooseDynamicStructureForMerge(const VectorWithMemoryTracking<ColumnPtr> & source_columns, std::optional<size_t> max_dynamic_subcolumns)
{
    if (!empty())
        throw Exception(ErrorCodes::LOGICAL_ERROR, "chooseDynamicStructureForMerge should be called only on empty Object column");

    /// During serialization of Object column in MergeTree all Object columns
    /// in single part must have the same structure (the same dynamic paths). During merge
    /// resulting column is constructed by inserting from source columns,
    /// but it may happen that resulting column doesn't have rows from all source parts
    /// but only from subset of them, and as a result some dynamic paths could be missing
    /// and structures of resulting column may differ.
    /// To solve this problem, before merge we create empty resulting column and use this method
    /// to take dynamic structure from all source columns even if we won't insert
    /// rows from some of them.

    /// We want to construct resulting set of dynamic paths with paths that have least number of null values in source columns
    /// and insert the rest paths into shared data if we exceed the limit of dynamic paths.
    /// First, collect all dynamic paths from all source columns and calculate total number of non-null values.
    /// We read source statistics to make path selection decisions, but do not update statistics in the result.
    UnorderedMapWithMemoryTracking<String, size_t> path_to_total_number_of_non_null_values;
    for (const auto & source_column : source_columns)
    {
        const auto & source_object = assert_cast<const ColumnObject &>(*source_column);
        /// During deserialization from MergeTree we will have statistics from the whole
        /// data part with number of non null values for each dynamic path.
        const auto & source_statistics = source_object.getOrCalculateStatistics();
        for (const auto & [path, column_ptr] : source_object.dynamic_paths_ptrs)
        {
            auto it = path_to_total_number_of_non_null_values.find(path);
            if (it == path_to_total_number_of_non_null_values.end())
                it = path_to_total_number_of_non_null_values.emplace(path, 0).first;
            size_t size = column_ptr->size() - column_ptr->getNumberOfDefaultRows();
            auto statistics_it = source_statistics->dynamic_paths_statistics.find(path);
            if (statistics_it != source_statistics->dynamic_paths_statistics.end())
                size = statistics_it->second;
            it->second += size;
        }

        /// Add paths from shared data statistics. It can help extracting frequent paths
        /// from shared data to dynamic paths.
        for (const auto & [path, size] : source_statistics->shared_data_paths_statistics)
        {
            auto it = path_to_total_number_of_non_null_values.find(path);
            if (it == path_to_total_number_of_non_null_values.end())
                it = path_to_total_number_of_non_null_values.emplace(path, 0).first;
            it->second += size;
        }
    }

    /// Reset current state.
    dynamic_paths.clear();
    dynamic_paths_ptrs.clear();
    sorted_dynamic_paths.clear();
    /// If max_dynamic_subcolumns is set, use it as max number of paths.
    max_dynamic_paths
        = max_dynamic_subcolumns ? std::min(*max_dynamic_subcolumns, max_dynamic_paths_upper_bound) : max_dynamic_paths_upper_bound;

    /// Check if the number of all dynamic paths exceeds the limit.
    if (path_to_total_number_of_non_null_values.size() > max_dynamic_paths)
    {
        /// Sort paths by total number of non null values.
        VectorWithMemoryTracking<std::pair<size_t, std::string_view>> paths_with_sizes;
        paths_with_sizes.reserve(path_to_total_number_of_non_null_values.size());
        for (const auto & [path, size] : path_to_total_number_of_non_null_values)
            paths_with_sizes.emplace_back(size, path);

        /// If sizes are equal, sort by path names in ascending order (for easier testing purposes).
        const auto compare_paths = [](const auto & left, const auto & right)
        {
            return std::tuple(right.first, left.second) < std::tuple(left.first, right.second);
        };
        sortAndKeepTop(paths_with_sizes, max_dynamic_paths, compare_paths);

        /// Fill dynamic_paths with first max_dynamic_paths paths in sorted list.
        for (const auto & [_, path] : paths_with_sizes)
        {
            auto it = dynamic_paths.emplace(path, ColumnDynamic::create(max_dynamic_types)).first;
            dynamic_paths_ptrs.emplace(path, assert_cast<ColumnDynamic *>(it->second.get()));
            sorted_dynamic_paths.insert(it->first);
        }
    }
    /// Use all dynamic paths from all source columns.
    else
    {
        for (const auto & [path, _] : path_to_total_number_of_non_null_values)
        {
            auto it = dynamic_paths.emplace(path, ColumnDynamic::create(max_dynamic_types)).first;
            dynamic_paths_ptrs[path] = assert_cast<ColumnDynamic *>(it->second.get());
            sorted_dynamic_paths.insert(it->first);
        }
    }

    /// Set max_dynamic_paths to the number of selected dynamic paths.
    /// It's needed to avoid adding new unexpected dynamic paths during inserts into this column during merge.
    max_dynamic_paths = dynamic_paths.size();
    updateDynamicPathsVersion();

    /// Now we have the resulting set of dynamic paths that will be used in all merged columns.
    /// As we use Dynamic column for dynamic paths, we should call `chooseDynamicStructureForMerge`
    /// on all resulting dynamic columns.
    for (auto & [path, column] : dynamic_paths)
    {
        VectorWithMemoryTracking<ColumnPtr> dynamic_path_source_columns;
        for (const auto & source_column : source_columns)
        {
            const auto & source_object = assert_cast<const ColumnObject &>(*source_column);
            auto it = source_object.dynamic_paths.find(path);
            if (it != source_object.dynamic_paths.end())
                dynamic_path_source_columns.push_back(it->second);
        }
        column->chooseDynamicStructureForMerge(dynamic_path_source_columns, max_dynamic_subcolumns);
    }

    /// Typed paths also can contain types with dynamic structure.
    for (auto & [path, column] : typed_paths)
    {
        VectorWithMemoryTracking<ColumnPtr> typed_path_source_columns;
        typed_path_source_columns.reserve(source_columns.size());
        for (const auto & source_column : source_columns)
            typed_path_source_columns.push_back(assert_cast<const ColumnObject &>(*source_column).typed_paths.at(path));
        column->chooseDynamicStructureForMerge(typed_path_source_columns, max_dynamic_subcolumns);
    }
}

void ColumnObject::takeExactDynamicStructureFrom(const IColumn & source)
{
    if (!empty())
        throw Exception(ErrorCodes::LOGICAL_ERROR, "takeExactDynamicStructureFrom should be called only on empty Object column");

    const auto & source_object = assert_cast<const ColumnObject &>(source);

    for (auto & [path, column] : typed_paths)
        column->takeExactDynamicStructureFrom(*source_object.typed_paths.at(path));

    dynamic_paths.clear();
    dynamic_paths_ptrs.clear();
    sorted_dynamic_paths.clear();
    for (const auto & [path, column] : source_object.getDynamicPaths())
    {
        auto it = dynamic_paths.emplace(path, ColumnDynamic::create(max_dynamic_types)).first;
        it->second->takeExactDynamicStructureFrom(*column);
        dynamic_paths_ptrs.emplace(path, assert_cast<ColumnDynamic *>(it->second.get()));
        sorted_dynamic_paths.insert(it->first);
    }

    /// Set max_dynamic_paths to the number of dynamic paths.
    /// It's needed to avoid adding new unexpected dynamic paths during later inserts into this column.
    /// max_dynamic_paths_upper_bound is deliberately left alone: lowering it to the same value would
    /// make `prepareForSquashing` restore max_dynamic_paths to it and so undo this freeze.
    max_dynamic_paths = dynamic_paths.size();
    updateDynamicPathsVersion();
}

void ColumnObject::fixDynamicStructure()
{
    /// Set max_dynamic_paths to the number of dynamic paths.
    /// It's needed to avoid adding new unexpected dynamic paths during later inserts into this column.
    max_dynamic_paths = dynamic_paths.size();
    updateDynamicPathsVersion();
}

ColumnObject::StatisticsPtr ColumnObject::getOrCalculateStatistics() const
{
    if (statistics)
        return statistics;

    auto calculated_statistics = std::make_shared<Statistics>();
    for (const auto & [path, column] : dynamic_paths)
        calculated_statistics->dynamic_paths_statistics[path] = column->size() - column->getNumberOfDefaultRows();

    const auto [shared_data_paths, _] = getSharedDataPathsAndValues();
    calculated_statistics->addSharedDataPaths(*shared_data_paths, 0, shared_data_paths->size());
    return calculated_statistics;
}

void ColumnObject::Statistics::addSharedDataPaths(const ColumnString & shared_data_paths, size_t start, size_t end)
{
    /// The same paths repeat in many rows, so they are counted in a flat hash map first, and the statistics are
    /// updated once per distinct path. Doing it in the order of the first occurrence of each path adds the same
    /// paths in the same order as counting the paths one by one, so the iteration order of the statistics,
    /// in which they are written, stays the same.
    HashMapWithSavedHash<std::string_view, size_t> path_to_index;
    std::vector<std::pair<std::string_view, size_t>> paths_and_counts;
    for (size_t i = start; i != end; ++i)
    {
        auto path = shared_data_paths.getDataAt(i);
        HashMapWithSavedHash<std::string_view, size_t>::LookupResult it;
        bool inserted;
        path_to_index.emplace(path, it, inserted);
        if (inserted)
        {
            it->getMapped() = paths_and_counts.size();
            paths_and_counts.emplace_back(path, 1);
        }
        else
        {
            ++paths_and_counts[it->getMapped()].second;
        }
    }

    for (const auto & [path, count] : paths_and_counts)
    {
        if (auto it = shared_data_paths_statistics.find(path); it != shared_data_paths_statistics.end())
            it->second += count;
        else if (shared_data_paths_statistics.size() < MAX_SHARED_DATA_STATISTICS_SIZE)
            shared_data_paths_statistics.emplace(path, count);
    }
}

void ColumnObject::takeOrCalculateStatisticsFrom(const VectorWithMemoryTracking<ColumnPtr> & source_columns)
{
    /// Assumes dynamic structure has already been set by `takeExactDynamicStructureFrom` or `chooseDynamicStructureForMerge`.
    Statistics new_statistics;
    /// Collect total sizes for paths that are not in our dynamic_paths (candidates for shared data statistics).
    UnorderedMapWithMemoryTracking<String, size_t> shared_data_candidates;
    for (const auto & source_column : source_columns)
    {
        const auto & source_object = assert_cast<const ColumnObject &>(*source_column);
        const auto & source_statistics = source_object.getOrCalculateStatistics();

        /// For dynamic paths in source statistics: if the path is in our dynamic structure, add directly;
        /// otherwise accumulate in shared data candidates.
        for (const auto & [path, size] : source_statistics->dynamic_paths_statistics)
        {
            if (dynamic_paths.contains(path))
                new_statistics.dynamic_paths_statistics[path] += size;
            else
                shared_data_candidates[path] += size;
        }

        /// For shared data paths in source statistics: if the path got promoted to a dynamic path
        /// in the merged structure, add to dynamic_paths_statistics; otherwise accumulate in shared data candidates.
        for (const auto & [path, size] : source_statistics->shared_data_paths_statistics)
        {
            if (dynamic_paths.contains(path))
                new_statistics.dynamic_paths_statistics[path] += size;
            else
                shared_data_candidates[path] += size;
        }
    }

    /// Select top MAX_SHARED_DATA_STATISTICS_SIZE paths by total size for shared data statistics.
    if (shared_data_candidates.size() <= Statistics::MAX_SHARED_DATA_STATISTICS_SIZE)
    {
        for (auto & [path, size] : shared_data_candidates)
            new_statistics.shared_data_paths_statistics.emplace(path, size);
    }
    else
    {
        VectorWithMemoryTracking<std::pair<size_t, std::string_view>> candidates_with_sizes;
        candidates_with_sizes.reserve(shared_data_candidates.size());
        for (const auto & [path, size] : shared_data_candidates)
            candidates_with_sizes.emplace_back(size, path);
        sortAndKeepTop(candidates_with_sizes, Statistics::MAX_SHARED_DATA_STATISTICS_SIZE, std::greater<>());
        for (const auto & [size, path] : candidates_with_sizes)
            new_statistics.shared_data_paths_statistics.emplace(path, size);
    }

    statistics = std::make_shared<const Statistics>(std::move(new_statistics));

    /// Recursively update statistics for nested dynamic paths.
    for (auto & [path, column] : dynamic_paths)
    {
        VectorWithMemoryTracking<ColumnPtr> dynamic_path_source_columns;
        for (const auto & source_column : source_columns)
        {
            const auto & source_object = assert_cast<const ColumnObject &>(*source_column);
            auto it = source_object.dynamic_paths.find(path);
            if (it != source_object.dynamic_paths.end())
                dynamic_path_source_columns.push_back(it->second);
        }
        if (!dynamic_path_source_columns.empty())
            column->takeOrCalculateStatisticsFrom(dynamic_path_source_columns);
    }

    /// Recursively update statistics for typed paths.
    for (auto & [path, column] : typed_paths)
    {
        VectorWithMemoryTracking<ColumnPtr> typed_path_source_columns;
        typed_path_source_columns.reserve(source_columns.size());
        for (const auto & source_column : source_columns)
            typed_path_source_columns.push_back(assert_cast<const ColumnObject &>(*source_column).typed_paths.at(path));
        column->takeOrCalculateStatisticsFrom(typed_path_source_columns);
    }
}

size_t ColumnObject::findPathLowerBoundInSharedData(std::string_view path, const ColumnString & shared_data_paths, size_t start, size_t end)
{
    /// Simple random access iterator over values in ColumnString in specified range.
    class Iterator
    {
    public:
        using difference_type = size_t;
        using value_type = std::string_view;
        using iterator_category = std::random_access_iterator_tag;
        using pointer = std::string_view*;
        using reference = std::string_view&;

        Iterator() = delete;
        Iterator(const ColumnString * data_, size_t index_) : data(data_), index(index_) {}
        Iterator(const Iterator & rhs) = default;
        Iterator & operator=(const Iterator & rhs) = default;
        inline Iterator& operator+=(difference_type rhs) { index += rhs; return *this;}
        inline std::string_view operator*() const {return data->getDataAt(index);}

        inline Iterator& operator++() { ++index; return *this; }
        inline difference_type operator-(const Iterator & rhs) const {return index - rhs.index; }

        const ColumnString * data;
        size_t index;
    };

    Iterator start_it(&shared_data_paths, start);
    Iterator end_it(&shared_data_paths, end);
    auto it = std::lower_bound(start_it, end_it, path);
    return it.index;
}

void ColumnObject::fillPathColumnFromSharedData(IColumn & path_column, std::string_view path, const ColumnPtr & shared_data_column, size_t start, size_t end)
{
    const auto & shared_data_array = assert_cast<const ColumnArray &>(*shared_data_column);
    const auto & shared_data_offsets = shared_data_array.getOffsets();
    size_t first_offset = shared_data_offsets[static_cast<ssize_t>(start) - 1];
    size_t last_offset = shared_data_offsets[static_cast<ssize_t>(end) - 1];
    /// Check if we have at least one row with data.
    if (first_offset == last_offset)
    {
        path_column.insertManyDefaults(end - start);
        return;
    }

    const auto & shared_data_tuple = assert_cast<const ColumnTuple &>(shared_data_array.getData());
    const auto & shared_data_paths = assert_cast<const ColumnString &>(shared_data_tuple.getColumn(0));
    const auto & shared_data_values = assert_cast<const ColumnString &>(shared_data_tuple.getColumn(1));
    const auto & dynamic_serialization = getDynamicSerialization();
    for (size_t i = start; i != end; ++i)
    {
        size_t paths_start = shared_data_offsets[static_cast<ssize_t>(i) - 1];
        size_t paths_end = shared_data_offsets[static_cast<ssize_t>(i)];
        auto lower_bound_path_index = ColumnObject::findPathLowerBoundInSharedData(path, shared_data_paths, paths_start, paths_end);
        if (lower_bound_path_index != paths_end && shared_data_paths.getDataAt(lower_bound_path_index) == path)
        {
            auto value_data = shared_data_values.getDataAt(lower_bound_path_index);
            ReadBufferFromMemory buf(value_data);
            dynamic_serialization->deserializeBinary(path_column, buf, getFormatSettings());
        }
        else
        {
            path_column.insertDefault();
        }
    }
}

ColumnObject::SortedPathsIterator::SortedPathsIterator(const ColumnObject & column_object_, size_t row_, bool skip_typed_nulls_)
    : column_object(column_object_)
    , typed_paths_it(column_object.sorted_typed_paths.begin())
    , typed_paths_end(column_object.sorted_typed_paths.end())
    , dynamic_paths_it(column_object.sorted_dynamic_paths.begin())
    , dynamic_paths_end(column_object.sorted_dynamic_paths.end())
    , row(row_)
    , skip_typed_nulls(skip_typed_nulls_)
{
    std::tie(shared_data_paths, shared_data_values) = column_object.getSharedDataPathsAndValues();
    const auto & shared_data_offsets = column_object.getSharedDataOffsets();
    shared_data_it = shared_data_offsets[row - 1];
    shared_data_end = shared_data_offsets[row];
    setCurrentPath();
}

void ColumnObject::SortedPathsIterator::next()
{
    switch (current_path_type)
    {
        case PathType::DYNAMIC:
            ++dynamic_paths_it;
            break;
        case PathType::TYPED:
            ++typed_paths_it;
            break;
        case PathType::SHARED_DATA:
            ++shared_data_it;
            break;
    }

    setCurrentPath();
}

int ColumnObject::SortedPathsIterator::compare(const SortedPathsIterator & rhs, int nan_direction_hint) const
{
    /// First, compare paths as strings.
    auto path = getCurrentPath();
    auto rhs_path = rhs.getCurrentPath();
    if (path != rhs_path)
        return path < rhs_path ? -1 : 1;

    /// If paths are equal, compare their values. When both values live in shared data they are
    /// already serialized in Dynamic binary form, so compare them directly via
    /// ColumnDynamic::compareSerializedValues (same order as the materializing path). Any other
    /// combination keeps the materializing path unchanged.
    if (current_path_type == PathType::SHARED_DATA && rhs.current_path_type == PathType::SHARED_DATA)
        return ColumnDynamic::compareSerializedValues(getCurrentSharedDataValue(), rhs.getCurrentSharedDataValue(), nan_direction_hint);

    auto [column, n] = getCurrentPathColumnAndRow();
    auto [rhs_column, rhs_n] = rhs.getCurrentPathColumnAndRow();
    return column->compareAt(n, rhs_n, *rhs_column, nan_direction_hint);
}

bool ColumnObject::SortedPathsIterator::end()
{
    return typed_paths_it == typed_paths_end && dynamic_paths_it == dynamic_paths_end && shared_data_it == shared_data_end;
}

void ColumnObject::SortedPathsIterator::setCurrentPath()
{
    /// We have 3 sorted lists of paths - typed paths, dynamic paths and paths in shared data.
    /// We store iterators for each of these lists. Here we try to find the iterator with the lexicographically smallest path.

    /// Null in dynamic path is considered as absence of this path.
    while (dynamic_paths_it != dynamic_paths_end && column_object.dynamic_paths.find(*dynamic_paths_it)->second->isNullAt(row))
        ++dynamic_paths_it;

    /// If requested, skip typed paths whose value is null (treat them as absent).
    if (skip_typed_nulls)
        while (typed_paths_it != typed_paths_end && column_object.typed_paths.find(*typed_paths_it)->second->isNullAt(row))
            ++typed_paths_it;

    std::array<std::pair<PathType, std::optional<std::string_view>>, 3> paths{
        std::pair{PathType::TYPED, typed_paths_it == typed_paths_end ? std::nullopt : std::optional<std::string_view>(*typed_paths_it)},
        std::pair{
            PathType::DYNAMIC, dynamic_paths_it == dynamic_paths_end ? std::nullopt : std::optional<std::string_view>(*dynamic_paths_it)},
        std::pair{
            PathType::SHARED_DATA,
            shared_data_it == shared_data_end ? std::nullopt
                                              : std::optional<std::string_view>(shared_data_paths->getDataAt(shared_data_it))},
    };

    auto min_path = std::ranges::min(
        paths,
        [](auto first_path, auto second_path)
        {
            if (!second_path.second)
                return true;

            if (!first_path.second)
                return false;

            return first_path.second < second_path.second;
        });

    if (min_path.second)
        current_path_type = min_path.first;
}

std::string_view ColumnObject::SortedPathsIterator::getCurrentPath() const
{
    switch (current_path_type)
    {
        case PathType::DYNAMIC:
            return *dynamic_paths_it;
        case PathType::TYPED:
            return *typed_paths_it;
        case PathType::SHARED_DATA:
            return shared_data_paths->getDataAt(shared_data_it);
    }
}

std::pair<ColumnPtr, size_t> ColumnObject::SortedPathsIterator::getCurrentPathColumnAndRow() const
{
    switch (current_path_type)
    {
        case PathType::DYNAMIC:
            return {column_object.dynamic_paths.find(*dynamic_paths_it)->second, row};
        case PathType::TYPED:
            return {column_object.typed_paths.find(*typed_paths_it)->second, row};
        case PathType::SHARED_DATA:
        {
            auto tmp_column = ColumnDynamic::create();
            tmp_column->reserve(1);
            ColumnObject::deserializeValueFromSharedData(shared_data_values, shared_data_it, *tmp_column);
            return {std::move(tmp_column), 0};
        }
    }
};

std::string_view ColumnObject::SortedPathsIterator::getCurrentSharedDataValue() const
{
    return shared_data_values->getDataAt(shared_data_it);
}

ColumnObject::SortedPathsIterator::PathInfo ColumnObject::SortedPathsIterator::getCurrentPathInfo() const
{
    PathInfo path_info;
    path_info.type = current_path_type;
    path_info.path = getCurrentPath();
    std::tie(path_info.column, path_info.row) = getCurrentPathColumnAndRow();
    return path_info;
}

void ColumnObject::SortedPathsIterator::serializeCurrentValueBinary(
    const UnorderedMapWithMemoryTracking<String, SerializationPtr> & typed_path_serializations,
    WriteBuffer & buf) const
{
    if (current_path_type == PathType::SHARED_DATA)
    {
        auto value_data = shared_data_values->getDataAt(shared_data_it);
        buf.write(value_data.data(), value_data.size());
        return;
    }

    if (current_path_type == PathType::DYNAMIC)
    {
        const auto & dynamic_col = assert_cast<const ColumnDynamic &>(
            *column_object.dynamic_paths.find(*dynamic_paths_it)->second);
        getDynamicSerialization()->serializeBinary(dynamic_col, row, buf, getFormatSettings());
        return;
    }

    chassert(current_path_type == PathType::TYPED);
    const IColumn & col = *column_object.typed_paths.find(*typed_paths_it)->second;
    auto ser_it = typed_path_serializations.find(String(*typed_paths_it));
    if (ser_it == typed_path_serializations.end())
        throw Exception(
            ErrorCodes::LOGICAL_ERROR,
            "No serialization found for typed path '{}' in serializeCurrentValueBinary",
            *typed_paths_it);

    /// Write the value bare — no type tag — so the blob can be deserialized
    /// directly with the same serialization.
    ser_it->second->serializeBinary(col, row, buf, getFormatSettings());
}

#if !defined(DEBUG_OR_SANITIZER_BUILD)
int ColumnObject::compareAt(size_t n, size_t m, const IColumn & rhs, int nan_direction_hint) const
#else
int ColumnObject::doCompareAt(size_t n, size_t m, const IColumn & rhs, int nan_direction_hint) const
#endif
{
    /// We compare objects lexicographically like maps.
    const ColumnObject & rhs_object = assert_cast<const ColumnObject &>(rhs);
    /// Iterate over paths in both columns in sorted order.
    SortedPathsIterator it(*this, n);
    SortedPathsIterator rhs_it(rhs_object, m);

    while (!it.end() && !rhs_it.end())
    {
        auto cmp = it.compare(rhs_it, nan_direction_hint);
        if (cmp)
            return cmp;
        it.next();
        rhs_it.next();
    }

    if (it.end() && rhs_it.end())
        return 0;

    if (it.end())
        return -1;
    return 1;
}

void ColumnObject::repairDuplicatesInDynamicPathsAndSharedData(size_t offset)
{
    if (dynamic_paths.empty())
        return;

    /// First, check if all dynamic paths have correct sizes, just in case.
    size_t expected_size = shared_data->size();
    for (const auto & [path, column] : dynamic_paths)
    {
        if (column->size() != expected_size)
            throw Exception(ErrorCodes::LOGICAL_ERROR, "Unexpected size of dynamic path {}: {} != {}", path, column->size(), expected_size);
    }

    /// Second, iterate over paths in shared data and check if we have any path that is also present in dynamic paths.
    const auto & shared_data_offsets = getSharedDataOffsets();
    const auto [shared_data_paths, shared_data_values] = getSharedDataPathsAndValues();
    /// Remember the first row with duplicates if any. We will start repair from this row.
    std::optional<size_t> first_row_with_duplicates = std::nullopt;
    size_t size = shared_data_offsets.size();
    /// Every path in shared data is looked up, usually without a match, so dynamic paths are put in a flat hash set.
    HashSetWithSavedHash<std::string_view> dynamic_paths_set;
    for (const auto & [path, _] : dynamic_paths)
        dynamic_paths_set.insert(std::string_view(path));
    for (size_t j = shared_data_offsets[static_cast<ssize_t>(offset) - 1]; j < shared_data_offsets[static_cast<ssize_t>(size) - 1]; ++j)
    {
        if (dynamic_paths_set.has(shared_data_paths->getDataAt(j)))
        {
            /// Duplicate is found, no need to iterate further, we need to start repair from its row.
            first_row_with_duplicates = std::upper_bound(shared_data_offsets.begin() + offset, shared_data_offsets.end(), j) - shared_data_offsets.begin();
            break;
        }
    }

    if (!first_row_with_duplicates)
        return;

    LOG_TRACE(getLogger("ColumnObject"), "Repair duplicates in Object column starting from row {}", *first_row_with_duplicates);

    /// During repair we create new shared data without duplicated dynamic paths
    /// update corresponding dynamic paths with values from shared data.
    auto new_shared_data = shared_data->cloneResized(*first_row_with_duplicates);
    const auto [new_shared_data_paths, new_shared_data_values, new_shared_data_offsets] = getSharedDataPathsValuesAndOffsets(*new_shared_data);
    new_shared_data_offsets->reserve(size);
    PathToColumnMap new_dynamic_paths;
    for (size_t i = *first_row_with_duplicates; i < size; ++i)
    {
        size_t shared_data_start = shared_data_offsets[i - 1];
        size_t shared_data_end = shared_data_offsets[i];
        for (size_t j = shared_data_start; j < shared_data_end; ++j)
        {
            auto path = shared_data_paths->getDataAt(j);
            auto it = dynamic_paths.find(path);
            if (it == dynamic_paths.end())
            {
                new_shared_data_paths->insertFrom(*shared_data_paths, j);
                new_shared_data_values->insertFrom(*shared_data_values, j);
            }
            /// We update dynamic path with value from shared data only if dynamic path has NULL at this row.
            else if (it->second->isNullAt(i))
            {
                auto new_it = new_dynamic_paths.find(path);
                if (new_it == new_dynamic_paths.end())
                {
                    new_it = new_dynamic_paths.emplace(path, it->second->cloneResized(i)).first;
                    new_it->second->reserve(size);
                }

                deserializeValueFromSharedData(shared_data_values, j, *new_it->second);
            }
            /// Situation when both values in dynamic path and shared data are non-NULL should not be possible
            /// and we cannot repair it anyhow. Throw logical error exception in this case.
            else
            {
                auto value = shared_data_values->getDataAt(j);
                ReadBufferFromMemory buf(value);
                auto type_from_shared_data = decodeDataType(buf);
                if (!isNothing(type_from_shared_data))
                {
                    auto type_from_dynamic_path = dynamic_paths_ptrs.find(path)->second->getTypeAt(i);
                    throw Exception(
                        ErrorCodes::LOGICAL_ERROR,
                        "Path {} is present both in dynamic paths and shared data and has two non-null values at the row {}. "
                        "Value type in dynamic paths: {}. Value type in shared data: {}",
                        path,
                        i,
                        type_from_dynamic_path->getName(),
                        type_from_shared_data->getName());
                }
            }
        }

        new_shared_data_offsets->push_back(new_shared_data_paths->size());
        /// Update new dynamic paths that were not updated with value from shared data in this row.
        for (auto & [path, column] : new_dynamic_paths)
        {
            if (column->size() == i)
                column->insertFrom(*dynamic_paths.at(path), i);
        }
    }

    for (auto & [path, column] : new_dynamic_paths)
    {
        if (column->size() != size)
            throw Exception(ErrorCodes::LOGICAL_ERROR, "Unexpected size of new dynamic path {}: {} != {}", path, column->size(), size);
        dynamic_paths_ptrs[path] = assert_cast<ColumnDynamic *>(column.get());
        dynamic_paths[path] = std::move(column);
    }
    updateDynamicPathsVersion();

    if (new_shared_data->size() != size)
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Unexpected size of new shared data: {} != {}", new_shared_data->size(), size);
    shared_data = std::move(new_shared_data);
    /// Invalidate statistics because dynamic paths content changed.
    statistics.reset();
}

void ColumnObject::validateDynamicPathsSizes() const
{
    size_t expected_size = shared_data->size();
    for (const auto & [path, column] : dynamic_paths)
    {
        if (column->size() != expected_size)
            throw Exception(ErrorCodes::LOGICAL_ERROR, "Unexpected size of dynamic path {}: {} != {}", path, column->size(), expected_size);
    }
}

bool ColumnObject::isEmptyAt(size_t n, bool skip_null_typed_paths) const
{
    if (!typed_paths.empty())
    {
        if (!skip_null_typed_paths)
            /// If object column has at least 1 typed path, it will never be empty, because these paths always have values.
            return false;

        /// When skip_null_typed_paths is true, check each typed path individually:
        /// only non-NULL values count as present.
        for (const auto & [path, column] : typed_paths)
        {
            if (!column->isNullAt(n))
                return false;
        }
    }

    /// Check if all dynamic paths have NULL at this row.
    for (const auto & [path, column] : dynamic_paths_ptrs)
    {
        if (!column->isNullAt(n))
            return false;
    }

    /// Check if there are no paths in shared data.
    return shared_data->isDefaultAt(n);
}

bool ColumnObject::hasNonEmptyRows(bool skip_null_typed_paths) const
{
    /// If object column has at least 1 typed path, it will never be empty, because these paths always have values.
    if (!skip_null_typed_paths && !typed_paths.empty())
        return true;

    for (size_t i = 0; i != size(); ++i)
    {
        if (!isEmptyAt(i, skip_null_typed_paths))
            return true;
    }

    return false;
}

}
