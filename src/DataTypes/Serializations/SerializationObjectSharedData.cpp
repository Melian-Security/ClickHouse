#include <Common/SipHash.h>
#include <DataTypes/Serializations/SerializationObjectSharedData.h>
#include <DataTypes/Serializations/SerializationObjectHelpers.h>
#include <DataTypes/Serializations/SerializationArray.h>
#include <DataTypes/Serializations/SerializationString.h>
#include <DataTypes/Serializations/SerializationDynamic.h>
#include <DataTypes/Serializations/SubstreamPathMap.h>
#include <DataTypes/DataTypesBinaryEncoding.h>
#include <DataTypes/DataTypeDynamic.h>
#include <DataTypes/DataTypeVariant.h>
#include <DataTypes/Serializations/getSubcolumnsDeserializationOrder.h>
#include <DataTypes/DataTypeObject.h>
#include <DataTypes/DataTypesNumber.h>
#include <Columns/ColumnMap.h>
#include <Columns/ColumnArray.h>
#include <Columns/ColumnTuple.h>
#include <Columns/ColumnDynamic.h>
#include <Columns/ColumnVariant.h>
#include <Core/Defines.h>
#include <Core/NamesAndTypes.h>
#include <Formats/FormatSettings.h>
#include <IO/ReadBufferFromMemory.h>
#include <IO/ReadHelpers.h>
#include <IO/VarInt.h>
#include <base/StringViewHash.h>
#include <city.h>
#include <algorithm>
#include <numeric>

namespace DB
{

namespace ErrorCodes
{
    extern const int CANNOT_READ_ALL_DATA;
    extern const int LOGICAL_ERROR;
    extern const int INCORRECT_DATA;
    extern const int NOT_IMPLEMENTED;
}

namespace
{

/// The count is untrusted, so use it only as a capped hint; the caller appends items as it reads them.
template <typename Container>
void reserveOrThrowTooMany(Container & container, size_t count, const char * what)
{
    if (count > container.max_size())
        throw Exception(ErrorCodes::INCORRECT_DATA, "JSON/Object column has too many {}: {}", what, count);
    container.reserve(std::min(count, DEFAULT_NATIVE_BINARY_MAX_NUM_COLUMNS));
}

}

SerializationObjectSharedData::SerializationObjectSharedData(SerializationVersion serialization_version_, const DataTypePtr & dynamic_type_, const SerializationPtr & dynamic_serialization_, size_t buckets_)
    : serialization_version(serialization_version_)
    , dynamic_type(dynamic_type_)
    , dynamic_serialization(dynamic_serialization_)
    , buckets(buckets_)
    , serialization_map(DataTypeObject::getTypeOfSharedData()->getDefaultSerialization())
{
}

UInt128 SerializationObjectSharedData::getHash(SerializationVersion serialization_version_, const DataTypePtr & dynamic_type_, const SerializationPtr & dynamic_serialization_, size_t buckets_)
{
    SipHash hash;
    hash.update("ObjectSharedData");
    hash.update(static_cast<int>(serialization_version_.value));
    auto dynamic_type_name = dynamic_type_->getName();
    hash.update(dynamic_type_name.size());
    hash.update(dynamic_type_name);
    hash.update(dynamic_serialization_->getHash());
    hash.update(buckets_);
    return hash.get128();
}

SerializationPtr SerializationObjectSharedData::create(SerializationVersion serialization_version_, const DataTypePtr & dynamic_type_, const SerializationPtr & dynamic_serialization_, size_t buckets_)
{
    if (!dynamic_serialization_->supportsPooling())
        return std::shared_ptr<ISerialization>(new SerializationObjectSharedData(serialization_version_, dynamic_type_, dynamic_serialization_, buckets_));
    return ISerialization::pooled(getHash(serialization_version_, dynamic_type_, dynamic_serialization_, buckets_), [&] { return new SerializationObjectSharedData(serialization_version_, dynamic_type_, dynamic_serialization_, buckets_); });
}

SerializationObjectSharedData::SerializationVersion::SerializationVersion(UInt64 version) : value(static_cast<Value>(version))
{
    checkVersion(version);
}

SerializationObjectSharedData::SerializationVersion::SerializationVersion(DB::MergeTreeObjectSharedDataSerializationVersion version)
{
    switch (version)
    {
        case MergeTreeObjectSharedDataSerializationVersion::MAP:
            value = MAP;
            break;
        case MergeTreeObjectSharedDataSerializationVersion::MAP_WITH_BUCKETS:
            value = MAP_WITH_BUCKETS;
            break;
        case MergeTreeObjectSharedDataSerializationVersion::ADVANCED:
            value = ADVANCED;
            break;
        case MergeTreeObjectSharedDataSerializationVersion::ADVANCED_CHUNKED:
            value = ADVANCED_CHUNKED;
            break;
    }
}

void SerializationObjectSharedData::SerializationVersion::checkVersion(UInt64 version)
{
    if (version != MAP && version != MAP_WITH_BUCKETS && version != ADVANCED && version != ADVANCED_CHUNKED)
        throw Exception(ErrorCodes::INCORRECT_DATA, "Invalid version for Object shared data serialization: {}", version);
}

namespace
{

/// A value in shared data is the binary encoding of its type followed by the value in the binary format of
/// that type. For the types below the encoding is a single byte, and the binary format of a value is what
/// the column of the type holds for it (the bytes of a number, or the size and the bytes of a string). So
/// when all values of a path in a chunk have one such type, they are copied into a single column of that
/// type instead of being read one by one into a Dynamic column, and the Dynamic structure of the path, which
/// only depends on the type, is written directly.
class SharedDataValueTypes
{
public:
    struct Type
    {
        DataTypePtr type;
        UInt8 encoded_type = 0;
        /// The size of every value, or 0 for String.
        size_t value_size = 0;
        /// Serialization of the variant type of a Dynamic column holding only values of this type, created
        /// the same way as the Dynamic serialization creates it.
        SerializationPtr variant_serialization;
        ColumnVariant::Discriminator discriminator = 0;
        ColumnVariant::Discriminator shared_variant_discriminator = 0;
    };

    SharedDataValueTypes(const DataTypePtr & dynamic_type, const SerializationPtr & dynamic_serialization_)
        : dynamic_serialization(typeid_cast<const SerializationDynamic *>(dynamic_serialization_.get()))
    {
        /// A Dynamic column that cannot hold any variant keeps every value in the shared variant.
        const auto * dynamic_data_type = typeid_cast<const DataTypeDynamic *>(dynamic_type.get());
        enabled = dynamic_serialization && dynamic_data_type && dynamic_data_type->getMaxDynamicTypes() > 0;

        /// Reading a longer string into a Dynamic column throws, so such values are left to that path.
        FormatSettings format_settings;
        max_string_size = SerializationString::MAX_STRING_SIZE;
        if (format_settings.binary.max_binary_string_size)
            max_string_size = std::min<UInt64>(max_string_size, format_settings.binary.max_binary_string_size);
    }

    /// Build the Variant column of the Dynamic column of path `path_index`, or return nullptr if its values
    /// cannot be copied: their types differ or are not supported, or a value is not exactly one value.
    ColumnPtr tryCopyValues(
        const SharedDataBucketsSplitter & buckets_splitter,
        const SharedDataBucketsSplitter::BucketPaths & bucket_paths,
        size_t path_index,
        const Type *& result_type)
    {
        if (!enabled)
            return nullptr;

        const auto & values = buckets_splitter.getValuesColumn();
        size_t begin = bucket_paths.occurrences_begin[path_index];
        size_t end = bucket_paths.occurrences_begin[path_index + 1];
        auto first_value = values.getDataAt(bucket_paths.values[begin]);
        const Type * type = first_value.empty() ? nullptr : getType(static_cast<UInt8>(first_value[0]));
        if (!type)
            return nullptr;

        /// The values of one path are spread over the values column, so the ones a few iterations ahead are prefetched.
        static constexpr size_t prefetch_distance = 8;
        const auto & values_offsets = values.getOffsets();
        const auto * values_chars = values.getChars().data();
        auto prefetch_value = [&](size_t i)
        {
            if (i + prefetch_distance < end)
                __builtin_prefetch(values_chars + values_offsets[ssize_t(bucket_paths.values[i + prefetch_distance]) - 1]);
        };

        auto column = type->type->createColumn();
        column->reserve(end - begin);
        if (type->value_size)
        {
            for (size_t i = begin; i != end; ++i)
            {
                prefetch_value(i);
                auto value = values.getDataAt(bucket_paths.values[i]);
                if (value.size() != 1 + type->value_size || static_cast<UInt8>(value[0]) != type->encoded_type)
                    return nullptr;
                column->insertData(value.data() + 1, type->value_size);
            }
        }
        else
        {
            auto & column_string = assert_cast<ColumnString &>(*column);
            for (size_t i = begin; i != end; ++i)
            {
                prefetch_value(i);
                auto value = values.getDataAt(bucket_paths.values[i]);
                if (value.empty() || static_cast<UInt8>(value[0]) != type->encoded_type)
                    return nullptr;
                const char * pos = value.data() + 1;
                const char * value_end = value.data() + value.size();
                UInt64 size = 0;
                pos = readVarUInt(size, pos, value_end - pos);
                if (size > max_string_size || size != static_cast<UInt64>(value_end - pos))
                    return nullptr;
                column_string.insertData(pos, size);
            }
        }

        /// The values become variant `discriminator`; the rows where the path is absent are NULL.
        size_t num_rows = buckets_splitter.getNumRows();
        auto discriminators = ColumnVariant::ColumnDiscriminators::create(num_rows, ColumnVariant::NULL_DISCRIMINATOR);
        auto offsets = ColumnVariant::ColumnOffsets::create(num_rows, 0);
        auto & discriminators_data = discriminators->getData();
        auto & offsets_data = offsets->getData();
        for (size_t i = begin; i != end; ++i)
        {
            size_t row = bucket_paths.rows[i];
            discriminators_data[row] = type->discriminator;
            offsets_data[row] = i - begin;
        }

        MutableColumns variants(2);
        variants[type->discriminator] = std::move(column);
        variants[type->shared_variant_discriminator] = ColumnDynamic::getSharedVariantDataType()->createColumn();
        result_type = type;
        return ColumnVariant::create(std::move(discriminators), std::move(offsets), std::move(variants));
    }

private:
    const Type * getType(UInt8 encoded_type)
    {
        if (!checked[encoded_type])
        {
            types[encoded_type] = createType(encoded_type);
            checked[encoded_type] = true;
        }
        return types[encoded_type].get();
    }

    std::unique_ptr<Type> createType(UInt8 encoded_type) const
    {
        switch (static_cast<BinaryTypeIndex>(encoded_type))
        {
            case BinaryTypeIndex::UInt8:
            case BinaryTypeIndex::UInt16:
            case BinaryTypeIndex::UInt32:
            case BinaryTypeIndex::UInt64:
            case BinaryTypeIndex::Int8:
            case BinaryTypeIndex::Int16:
            case BinaryTypeIndex::Int32:
            case BinaryTypeIndex::Int64:
            case BinaryTypeIndex::Float32:
            case BinaryTypeIndex::Float64:
            case BinaryTypeIndex::Bool:
            case BinaryTypeIndex::String:
                break;
            default:
                return nullptr;
        }

        const char encoded_type_char = static_cast<char>(encoded_type);
        ReadBufferFromMemory buf(&encoded_type_char, 1);
        auto result = std::make_unique<Type>();
        result->type = decodeDataType(buf);
        result->encoded_type = encoded_type;
        result->value_size = isString(result->type) ? 0 : result->type->getSizeOfValueInMemory();
        /// ColumnDynamic::addNewVariant builds the variant type from the same two types.
        auto variant_type = std::make_shared<DataTypeVariant>(DataTypes{result->type, ColumnDynamic::getSharedVariantDataType()});
        result->variant_serialization = dynamic_serialization->createSerializationForType(variant_type);
        result->discriminator = *variant_type->tryGetVariantDiscriminator(result->type->getName());
        result->shared_variant_discriminator = *variant_type->tryGetVariantDiscriminator(ColumnDynamic::getSharedVariantTypeName());
        return result;
    }

    const SerializationDynamic * dynamic_serialization;
    bool enabled = false;
    UInt64 max_string_size = 0;
    /// Indexed by the encoded type; a null pointer means that values of this type are not copied.
    std::array<std::unique_ptr<Type>, 256> types;
    std::array<bool, 256> checked{};
};

/// The file names of the substreams of path columns, which `serializeChunkBucketData` lists for every path. A name
/// depends only on the fields of the substream path that `SubstreamPathMap` compares, and the same few substream paths
/// are written for every path of every granule, so each name is built once per part instead of once per substream.
/// The returned references stay valid as long as this object.
class SubstreamFileNames
{
public:
    const String & get(const ISerialization::SubstreamPath & path, const ISerialization::StreamFileNameSettings & settings)
    {
        if (const auto * name = names.find(path))
            return *name;
        return names.insert(path, ISerialization::getFileNameForStream(String{}, path, settings));
    }

private:
    SubstreamPathMap<String> names;
};

}

struct SerializeBinaryBulkStateObjectSharedData : public ISerialization::SerializeBinaryBulkState
{
    /// Kept for the whole part, so the types of shared data values are resolved once per part.
    std::unique_ptr<SharedDataValueTypes> value_types;
    SubstreamFileNames substream_file_names;
    ISerialization::SerializeBinaryBulkStatePtr map_state;
    std::vector<ISerialization::SerializeBinaryBulkStatePtr> bucket_map_states;
};

struct DeserializeBinaryBulkStateObjectSharedData : public ISerialization::DeserializeBinaryBulkState
{
    ISerialization::DeserializeBinaryBulkStatePtr map_state;
    std::vector<ISerialization::DeserializeBinaryBulkStatePtr> bucket_map_states;
    std::vector<ISerialization::DeserializeBinaryBulkStatePtr> bucket_structure_states;

    ISerialization::DeserializeBinaryBulkStatePtr clone() const override
    {
        auto new_state = std::make_shared<DeserializeBinaryBulkStateObjectSharedData>(*this);
        new_state->map_state = map_state ? map_state->clone() : nullptr;
        for (size_t bucket = 0; bucket != bucket_map_states.size(); ++bucket)
            new_state->bucket_map_states[bucket] = bucket_map_states[bucket] ? bucket_map_states[bucket]->clone() : nullptr;
        for (size_t bucket = 0; bucket != bucket_structure_states.size(); ++bucket)
            new_state->bucket_structure_states[bucket] = bucket_structure_states[bucket] ? bucket_structure_states[bucket]->clone() : nullptr;
        return new_state;
    }
};

void SerializationObjectSharedData::enumerateStreams(
    ISerialization::EnumerateStreamsSettings & settings,
    const ISerialization::StreamCallback & callback,
    const ISerialization::SubstreamData & data) const
{
    const auto * shared_data_state = data.deserialize_state ? checkAndGetState<DeserializeBinaryBulkStateObjectSharedData>(data.deserialize_state) : nullptr;

    if (serialization_version.value == SerializationVersion::MAP)
    {
        auto map_data = SubstreamData(serialization_map)
                            .withColumn(data.column)
                            .withType(data.type)
                            .withSerializationInfo(data.serialization_info)
                            .withDeserializeState(shared_data_state ? shared_data_state->map_state : nullptr);

        serialization_map->enumerateStreams(settings, callback, map_data);
        return;
    }

    /// Other 3 serializations MAP_WITH_BUCKETS, ADVANCED and ADVANCED_CHUNKED support buckets.
    for (size_t bucket = 0; bucket != buckets; ++bucket)
    {
        settings.path.push_back(Substream::Bucket);
        settings.path.back().bucket = bucket;
        if (serialization_version.value == SerializationVersion::MAP_WITH_BUCKETS)
        {
            auto map_data = SubstreamData(serialization_map)
                                .withColumn(data.column)
                                .withType(data.type)
                                .withSerializationInfo(data.serialization_info)
                                .withDeserializeState(shared_data_state ? shared_data_state->bucket_map_states[bucket] : nullptr);
            serialization_map->enumerateStreams(settings, callback, map_data);
        }
        else if (serialization_version.value == SerializationObjectSharedData::SerializationVersion::ADVANCED
                 || serialization_version.value == SerializationObjectSharedData::SerializationVersion::ADVANCED_CHUNKED)
        {
            if (settings.use_specialized_prefixes_and_suffixes_substreams)
                addSubstreamAndCallCallback(settings.path, callback, Substream::ObjectSharedDataStructurePrefix);
            else
                addSubstreamAndCallCallback(settings.path, callback, Substream::ObjectSharedDataStructure);

            /// When deserialize state is present, it means the whole shared data will be read
            /// via deserializeBinaryBulkWithMultipleStreams, which only uses Structure + Copy streams.
            /// Per-bucket Data/PathsMarks/Substreams/SubstreamsMarks/PathsSubstreamsMetadata are only
            /// needed when writing or reading individual paths via SerializationObjectSharedDataPath (separate class).
            /// Skip them to avoid unnecessary mark file loads and file opens during prefetching.
            if (!shared_data_state)
            {
                addSubstreamAndCallCallback(settings.path, callback, Substream::ObjectSharedDataData);
                addSubstreamAndCallCallback(settings.path, callback, Substream::ObjectSharedDataPathsMarks);
                addSubstreamAndCallCallback(settings.path, callback, Substream::ObjectSharedDataSubstreams);
                addSubstreamAndCallCallback(settings.path, callback, Substream::ObjectSharedDataSubstreamsMarks);
                addSubstreamAndCallCallback(settings.path, callback, Substream::ObjectSharedDataPathsSubstreamsMetadata);
            }

            if (settings.use_specialized_prefixes_and_suffixes_substreams)
                addSubstreamAndCallCallback(settings.path, callback, Substream::ObjectSharedDataStructureSuffix);
        }
        else
        {
            /// If we add new serialization version in future and forget to implement something, better to get an exception instead of doing nothing.
            throw Exception(ErrorCodes::NOT_IMPLEMENTED, "enumerateStreams is not implemented for shared data serialization version {}", serialization_version.value);
        }

        settings.path.pop_back();
    }

    /// Streams related to shared data copy in ADVANCED/ADVANCED_CHUNKED serialization.
    if (serialization_version.value == SerializationVersion::ADVANCED
        || serialization_version.value == SerializationVersion::ADVANCED_CHUNKED)
    {
        settings.path.push_back(Substream::ObjectSharedDataCopy);

        addSubstreamAndCallCallback(settings.path, callback, Substream::ObjectSharedDataCopySizes);
        addSubstreamAndCallCallback(settings.path, callback, Substream::ObjectSharedDataCopyPathsIndexes);
        addSubstreamAndCallCallback(settings.path, callback, Substream::ObjectSharedDataCopyValues);

        settings.path.pop_back();
    }
}

void SerializationObjectSharedData::serializeBinaryBulkStatePrefix(
    const IColumn & column,
    ISerialization::SerializeBinaryBulkSettings & settings,
    ISerialization::SerializeBinaryBulkStatePtr & state) const
{
    auto shared_data_state = std::make_shared<SerializeBinaryBulkStateObjectSharedData>();

    if (serialization_version.value == SerializationVersion::MAP)
    {
        serialization_map->serializeBinaryBulkStatePrefix(column, settings, shared_data_state->map_state);
    }
    else if (serialization_version.value == SerializationVersion::MAP_WITH_BUCKETS)
    {
        shared_data_state->bucket_map_states.resize(buckets);
        for (size_t bucket = 0; bucket != buckets; ++bucket)
        {
            settings.path.push_back(Substream::Bucket);
            settings.path.back().bucket = bucket;
            serialization_map->serializeBinaryBulkStatePrefix(column, settings, shared_data_state->bucket_map_states[bucket]);
            settings.path.pop_back();
        }
    }
    else if (serialization_version.value == SerializationVersion::ADVANCED
             || serialization_version.value == SerializationVersion::ADVANCED_CHUNKED)
    {
        /// ADVANCED/ADVANCED_CHUNKED serialization doesn't have serialization prefix.
    }
    else
    {
        /// If we add new serialization version in future and forget to implement something, better to get an exception instead of doing nothing.
        throw Exception(ErrorCodes::NOT_IMPLEMENTED, "serializeBinaryBulkStatePrefix is not implemented for shared data serialization version {}", serialization_version.value);
    }

    state = std::move(shared_data_state);
}

namespace
{

/// Metadata collected during serialization of one chunk+bucket's data in ADVANCED/ADVANCED_CHUNKED serialization.
/// Used to write metadata substreams (PathsMarks, Substreams, SubstreamsMarks, PathsSubstreamsMetadata, StructureSuffix).
struct ChunkBucketSerializationMetadata
{
    MarkInCompressedFile data_stream_mark{};
    std::vector<MarkInCompressedFile> paths_marks;
    /// The names and marks of the substreams of all paths in order. The substreams of path `i` are
    /// [paths_substreams_ends[i - 1], paths_substreams_ends[i]). The names are owned by `SubstreamFileNames`.
    std::vector<const String *> substreams_names;
    std::vector<MarkInCompressedFile> substreams_marks;
    std::vector<size_t> paths_substreams_ends;

    size_t numPaths() const { return paths_substreams_ends.size(); }
    size_t substreamsBegin(size_t path) const { return path ? paths_substreams_ends[path - 1] : 0; }
    size_t substreamsEnd(size_t path) const { return paths_substreams_ends[path]; }
};

/// Decompose a shared data column (Array(Tuple(String, String))) into its parts.
struct SharedDataColumns
{
    const IColumn & keys_column;
    const IColumn & values_column;
    const ColumnArray::Offsets & offsets;
    const IColumn & offsets_column;
};

SharedDataColumns extractSharedDataColumns(const IColumn & column)
{
    const auto & array_column = assert_cast<const ColumnArray &>(column);
    const auto & tuple_column = assert_cast<const ColumnTuple &>(array_column.getData());
    return {
        .keys_column = tuple_column.getColumn(0),
        .values_column = tuple_column.getColumn(1),
        .offsets = array_column.getOffsets(),
        .offsets_column = array_column.getOffsetsColumn(),
    };
}

/// Per-substream stream getter helpers. Each pushes the substream type onto settings.path,
/// calls settings.getter, checks for nullptr, and returns the stream.
/// The caller must pop settings.path after it is done writing to the stream.
WriteBuffer & getDataStream(ISerialization::SerializeBinaryBulkSettings & settings)
{
    settings.path.push_back(ISerialization::Substream::ObjectSharedDataData);
    auto * stream = settings.getter(settings.path);
    if (!stream)
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for shared data data");
    return *stream;
}

WriteBuffer & getPathsMarksStream(ISerialization::SerializeBinaryBulkSettings & settings)
{
    settings.path.push_back(ISerialization::Substream::ObjectSharedDataPathsMarks);
    auto * stream = settings.getter(settings.path);
    if (!stream)
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for shared data paths marks");
    return *stream;
}

WriteBuffer & getSubstreamsStream(ISerialization::SerializeBinaryBulkSettings & settings)
{
    settings.path.push_back(ISerialization::Substream::ObjectSharedDataSubstreams);
    auto * stream = settings.getter(settings.path);
    if (!stream)
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for shared data paths substreams");
    return *stream;
}

WriteBuffer & getSubstreamsMarksStream(ISerialization::SerializeBinaryBulkSettings & settings)
{
    settings.path.push_back(ISerialization::Substream::ObjectSharedDataSubstreamsMarks);
    auto * stream = settings.getter(settings.path);
    if (!stream)
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for shared data substreams marks");
    return *stream;
}

WriteBuffer & getPathsSubstreamsMetadataStream(ISerialization::SerializeBinaryBulkSettings & settings)
{
    settings.path.push_back(ISerialization::Substream::ObjectSharedDataPathsSubstreamsMetadata);
    auto * stream = settings.getter(settings.path);
    if (!stream)
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for shared data paths substreams metadata");
    return *stream;
}

WriteBuffer & getStructureSuffixStream(ISerialization::SerializeBinaryBulkSettings & settings)
{
    ISerialization::Substream structure_stream_type = settings.use_specialized_prefixes_and_suffixes_substreams
        ? ISerialization::Substream::ObjectSharedDataStructureSuffix
        : ISerialization::Substream::ObjectSharedDataStructure;
    settings.path.push_back(structure_stream_type);
    auto * stream = settings.getter(settings.path);
    if (!stream)
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for shared data structure suffix");
    return *stream;
}

WriteBuffer & getCopyPathsIndexesStream(ISerialization::SerializeBinaryBulkSettings & settings)
{
    settings.path.push_back(ISerialization::Substream::ObjectSharedDataCopyPathsIndexes);
    auto * stream = settings.getter(settings.path);
    if (!stream)
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for shared data copy indexes");
    return *stream;
}

WriteBuffer & getCopyValuesStream(ISerialization::SerializeBinaryBulkSettings & settings)
{
    settings.path.push_back(ISerialization::Substream::ObjectSharedDataCopyValues);
    auto * stream = settings.getter(settings.path);
    if (!stream)
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for shared data copy values");
    return *stream;
}

/// The marks of one stream while only this stream is written and `settings.path` is its path. A mark is the position of
/// the current compressed block of the stream in the file and the offset in that block, which is the offset in the
/// stream's buffer. The position only changes when the stream writes the block, which changes
/// `stream.count() - stream.offset()`, so the mark getter, which finds the stream by its name, is only called after that.
class StreamMarks
{
public:
    StreamMarks(WriteBuffer & stream_, const ISerialization::SerializeBinaryBulkSettings & settings_)
        : stream(stream_), settings(settings_)
    {
    }

    MarkInCompressedFile get()
    {
        size_t current_block_start = stream.count() - stream.offset();
        if (current_block_start != block_start)
        {
            block_mark = settings.stream_mark_getter(settings.path);
            block_start = current_block_start;
            return block_mark;
        }
        return {block_mark.offset_in_compressed_file, stream.offset()};
    }

private:
    WriteBuffer & stream;
    const ISerialization::SerializeBinaryBulkSettings & settings;
    MarkInCompressedFile block_mark;
    size_t block_start = std::numeric_limits<size_t>::max();
};

/// Write what SerializationDynamic writes, with the settings of `serializeChunkBucketData`, for a Dynamic
/// column whose only variant besides the shared variant is `type`.
void serializeSingleTypeDynamicColumn(
    const SharedDataValueTypes::Type & type,
    const IColumn & variant_column,
    ISerialization::SerializeBinaryBulkSettings & settings)
{
    settings.path.push_back(ISerialization::Substream::DynamicStructure);
    auto * structure_stream = settings.getter(settings.path);
    settings.path.pop_back();
    if (!structure_stream)
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Missing stream for Dynamic column structure");

    writeBinaryLittleEndian(static_cast<UInt64>(SerializationDynamic::SerializationVersion::V3), *structure_stream);
    /// The number of dynamic types and the list of them; the shared variant is not listed.
    writeVarUInt(1, *structure_stream);
    encodeDataType(type.type, *structure_stream);

    settings.path.push_back(ISerialization::Substream::DynamicData);
    ISerialization::SerializeBinaryBulkStatePtr variant_state;
    type.variant_serialization->serializeBinaryBulkStatePrefix(variant_column, settings, variant_state);
    type.variant_serialization->serializeBinaryBulkWithMultipleStreams(variant_column, 0, 0, settings, variant_state);
    type.variant_serialization->serializeBinaryBulkStateSuffix(settings, variant_state);
    settings.path.pop_back();
}

ChunkBucketSerializationMetadata serializeChunkBucketData(
    const SharedDataBucketsSplitter & buckets_splitter,
    const SharedDataBucketsSplitter::BucketPaths & bucket_paths,
    WriteBuffer & data_stream,
    ISerialization::SerializeBinaryBulkSettings & settings,
    const DataTypePtr & dynamic_type_,
    const SerializationPtr & dynamic_serialization_,
    SharedDataValueTypes & value_types,
    SubstreamFileNames & substream_file_names,
    MergeTreeObjectSharedDataSerializationVersion nested_shared_data_version)
{
    ChunkBucketSerializationMetadata metadata;

    if (!settings.stream_mark_getter)
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Mark getter is not set for ADVANCED shared data serialization");

    /// Everything below, also the data of nested serializations, is written into the ObjectSharedDataData stream.
    StreamMarks data_stream_marks(data_stream, settings);
    auto get_data_stream_mark = [&] { return data_stream_marks.get(); };

    /// Remember the mark of the ObjectSharedDataData stream.
    metadata.data_stream_mark = get_data_stream_mark();

    const size_t num_paths = bucket_paths.paths.size();
    metadata.paths_marks.reserve(num_paths);
    metadata.paths_substreams_ends.reserve(num_paths);

    /// Configure serialization settings as in Compact part.
    /// `serializeSingleTypeDynamicColumn` writes the Dynamic structure for exactly these settings.
    ISerialization::SerializeBinaryBulkSettings data_serialization_settings;
    data_serialization_settings.data_part_type = MergeTreeDataPartType::Compact;
    data_serialization_settings.position_independent_encoding = true;
    data_serialization_settings.low_cardinality_max_dictionary_size = 0;
    data_serialization_settings.use_specialized_prefixes_and_suffixes_substreams = true;
    data_serialization_settings.use_compact_variant_discriminators_serialization = true;
    data_serialization_settings.dynamic_serialization_version = MergeTreeDynamicSerializationVersion::V3;
    data_serialization_settings.object_serialization_version = MergeTreeObjectSerializationVersion::V3;
    /// Also use the same serialization version for nested Object types
    data_serialization_settings.object_shared_data_serialization_version = nested_shared_data_version;
    data_serialization_settings.object_shared_data_target_chunk_rows = settings.object_shared_data_target_chunk_rows;
    /// Don't write any dynamic statistics.
    data_serialization_settings.write_statistics = ISerialization::SerializeBinaryBulkSettings::StatisticsMode::NONE;
    data_serialization_settings.stream_mark_getter = [&](const ISerialization::SubstreamPath &) -> MarkInCompressedFile { return get_data_stream_mark(); };
    /// Inherit the min_compress_block_size setting.
    data_serialization_settings.min_compress_block_size = settings.min_compress_block_size;

    /// Substream names of a path are stored without the column name.
    ISerialization::StreamFileNameSettings stream_file_name_settings;
    stream_file_name_settings.escape_variant_substreams = false;

    data_serialization_settings.getter = [&](const ISerialization::SubstreamPath & substream_path) -> WriteBuffer *
    {
        /// New block per substream only once it's worth it: bounds a selective read's over-read
        /// to min_compress_block_size while small substreams still share a block (good compression).
        if (data_stream.offset() >= settings.min_compress_block_size)
            data_stream.next();
        /// Add new substream and its mark for current path.
        metadata.substreams_names.push_back(&substream_file_names.get(substream_path, stream_file_name_settings));
        metadata.substreams_marks.push_back(get_data_stream_mark());
        return &data_stream;
    };

    for (size_t path_index = 0; path_index != num_paths; ++path_index)
    {
        /// Same at the path boundary.
        if (data_stream.offset() >= settings.min_compress_block_size)
            data_stream.next();
        /// Remember the mark of ObjectSharedDataData stream for this path before writing any data.
        metadata.paths_marks.push_back(get_data_stream_mark());

        const SharedDataValueTypes::Type * type = nullptr;
        if (auto variant_column = value_types.tryCopyValues(buckets_splitter, bucket_paths, path_index, type))
        {
            serializeSingleTypeDynamicColumn(*type, *variant_column, data_serialization_settings);
        }
        else
        {
            auto path_column = buckets_splitter.flattenPath(bucket_paths, path_index, dynamic_type_);
            ISerialization::SerializeBinaryBulkStatePtr path_state;
            dynamic_serialization_->serializeBinaryBulkStatePrefix(*path_column, data_serialization_settings, path_state);
            dynamic_serialization_->serializeBinaryBulkWithMultipleStreams(*path_column, 0, 0, data_serialization_settings, path_state);
            dynamic_serialization_->serializeBinaryBulkStateSuffix(data_serialization_settings, path_state);
        }

        metadata.paths_substreams_ends.push_back(metadata.substreams_names.size());
    }

    return metadata;
}

MarkInCompressedFile writePathsMarks(
    const ChunkBucketSerializationMetadata & metadata,
    WriteBuffer & stream,
    ISerialization::SerializeBinaryBulkSettings & settings)
{
    /// Remember the mark of the ObjectSharedDataPathsMarks stream for the structure suffix.
    MarkInCompressedFile paths_marks_stream_mark = settings.stream_mark_getter(settings.path);

    for (const auto & mark : metadata.paths_marks)
    {
        writeBinaryLittleEndian(mark.offset_in_compressed_file, stream);
        writeBinaryLittleEndian(mark.offset_in_decompressed_block, stream);
    }

    return paths_marks_stream_mark;
}

std::vector<MarkInCompressedFile> writePathsSubstreams(
    const ChunkBucketSerializationMetadata & metadata,
    WriteBuffer & stream,
    ISerialization::SerializeBinaryBulkSettings & settings)
{
    std::vector<MarkInCompressedFile> marks_of_paths_substreams;
    marks_of_paths_substreams.reserve(metadata.numPaths());
    StreamMarks stream_marks(stream, settings);
    for (size_t path = 0; path != metadata.numPaths(); ++path)
    {
        marks_of_paths_substreams.push_back(stream_marks.get());
        size_t begin = metadata.substreamsBegin(path);
        size_t end = metadata.substreamsEnd(path);
        writeVarUInt(end - begin, stream);
        for (size_t i = begin; i != end; ++i)
            writeStringBinary(*metadata.substreams_names[i], stream);
    }
    return marks_of_paths_substreams;
}

std::vector<MarkInCompressedFile> writeSubstreamsMarks(
    const ChunkBucketSerializationMetadata & metadata,
    WriteBuffer & stream,
    ISerialization::SerializeBinaryBulkSettings & settings)
{
    std::vector<MarkInCompressedFile> marks_of_paths_substreams_marks;
    marks_of_paths_substreams_marks.reserve(metadata.numPaths());
    StreamMarks stream_marks(stream, settings);
    for (size_t path = 0; path != metadata.numPaths(); ++path)
    {
        marks_of_paths_substreams_marks.push_back(stream_marks.get());
        for (size_t i = metadata.substreamsBegin(path); i != metadata.substreamsEnd(path); ++i)
        {
            writeBinaryLittleEndian(metadata.substreams_marks[i].offset_in_compressed_file, stream);
            writeBinaryLittleEndian(metadata.substreams_marks[i].offset_in_decompressed_block, stream);
        }
    }
    return marks_of_paths_substreams_marks;
}

MarkInCompressedFile writePathsSubstreamsMetadata(
    const std::vector<MarkInCompressedFile> & marks_of_paths_substreams,
    const std::vector<MarkInCompressedFile> & marks_of_paths_substreams_marks,
    WriteBuffer & stream,
    ISerialization::SerializeBinaryBulkSettings & settings)
{
    MarkInCompressedFile paths_substreams_metadata_stream_mark = settings.stream_mark_getter(settings.path);
    for (size_t i = 0; i != marks_of_paths_substreams.size(); ++i)
    {
        writeBinaryLittleEndian(marks_of_paths_substreams[i].offset_in_compressed_file, stream);
        writeBinaryLittleEndian(marks_of_paths_substreams[i].offset_in_decompressed_block, stream);
        writeBinaryLittleEndian(marks_of_paths_substreams_marks[i].offset_in_compressed_file, stream);
        writeBinaryLittleEndian(marks_of_paths_substreams_marks[i].offset_in_decompressed_block, stream);
    }
    return paths_substreams_metadata_stream_mark;
}

void writeStructureSuffix(
    MarkInCompressedFile data_stream_mark,
    MarkInCompressedFile paths_marks_stream_mark,
    MarkInCompressedFile paths_substreams_metadata_stream_mark,
    WriteBuffer & stream)
{
    writeBinaryLittleEndian(data_stream_mark.offset_in_compressed_file, stream);
    writeBinaryLittleEndian(data_stream_mark.offset_in_decompressed_block, stream);
    writeBinaryLittleEndian(paths_marks_stream_mark.offset_in_compressed_file, stream);
    writeBinaryLittleEndian(paths_marks_stream_mark.offset_in_decompressed_block, stream);
    writeBinaryLittleEndian(paths_substreams_metadata_stream_mark.offset_in_compressed_file, stream);
    writeBinaryLittleEndian(paths_substreams_metadata_stream_mark.offset_in_decompressed_block, stream);
}

void writeAllChunkBucketMetadata(
    const ChunkBucketSerializationMetadata & metadata,
    ISerialization::SerializeBinaryBulkSettings & settings)
{
    auto & paths_marks_stream = getPathsMarksStream(settings);
    auto paths_marks_stream_mark = writePathsMarks(metadata, paths_marks_stream, settings);
    settings.path.pop_back();

    auto & substreams_stream = getSubstreamsStream(settings);
    auto marks_of_paths_substreams = writePathsSubstreams(metadata, substreams_stream, settings);
    settings.path.pop_back();

    auto & substreams_marks_stream = getSubstreamsMarksStream(settings);
    auto marks_of_paths_substreams_marks = writeSubstreamsMarks(metadata, substreams_marks_stream, settings);
    settings.path.pop_back();

    auto & metadata_stream = getPathsSubstreamsMetadataStream(settings);
    auto paths_substreams_metadata_stream_mark = writePathsSubstreamsMetadata(
        marks_of_paths_substreams, marks_of_paths_substreams_marks, metadata_stream, settings);
    settings.path.pop_back();

    auto & structure_suffix_stream = getStructureSuffixStream(settings);
    writeStructureSuffix(metadata.data_stream_mark, paths_marks_stream_mark, paths_substreams_metadata_stream_mark, structure_suffix_stream);
    settings.path.pop_back();
}

void writeCopyIndexesForChunk(const SharedDataBucketsSplitter & buckets_splitter, size_t num_paths_occurrences, WriteBuffer & stream)
{
    auto [indexes_column, indexes_type] = buckets_splitter.createPathsIndexes();
    indexes_type->getDefaultSerialization()->serializeBinaryBulk(*indexes_column, stream, 0, num_paths_occurrences);
}

void writeChunkCopySection(
    const IColumn & column,
    size_t offset, size_t end,
    const SharedDataBucketsSplitter & buckets_splitter,
    ISerialization::SerializeBinaryBulkSettings & settings)
{
    settings.path.push_back(ISerialization::Substream::ObjectSharedDataCopy);

    auto cols = extractSharedDataColumns(column);
    size_t limit = end - offset;

    /// Write array sizes.
    settings.path.push_back(ISerialization::Substream::ObjectSharedDataCopySizes);
    SerializationArray::serializeOffsetsBinaryBulk(cols.offsets_column, offset, limit, settings);
    settings.path.pop_back();

    size_t nested_offset = offset ? cols.offsets[offset - 1] : 0;
    size_t nested_end = cols.offsets[end - 1];
    size_t nested_limit = nested_end - nested_offset;

    auto & copy_indexes_stream = getCopyPathsIndexesStream(settings);
    writeCopyIndexesForChunk(buckets_splitter, nested_limit, copy_indexes_stream);
    settings.path.pop_back();

    auto & copy_values_stream = getCopyValuesStream(settings);
    if (nested_limit)
        SerializationString::create()->serializeBinaryBulk(cols.values_column, copy_values_stream, nested_offset, nested_limit);
    settings.path.pop_back();

    settings.path.pop_back();
}

} /// anonymous namespace

/// Deserialize prefix of the chunk in ObjectSharedDataStructure(Prefix) stream.
void SerializationObjectSharedData::deserializeChunkStructurePrefix(
    ReadBuffer & buf,
    ChunkStructure & chunk_structure,
    const DeserializeBinaryBulkStateObjectSharedDataStructure & structure_state)
{
    /// Read number of rows in this chunk.
    readVarUInt(chunk_structure.num_rows, buf);
    String path;
    /// Read number of paths stored in this chunk.
    readVarUInt(chunk_structure.num_paths, buf);

    if (structure_state.need_all_paths)
        reserveOrThrowTooMany(chunk_structure.all_paths, chunk_structure.num_paths, "paths");

    /// Read list of paths.
    for (size_t i = 0; i != chunk_structure.num_paths; ++i)
    {
        readStringBinary(path, buf);
        if (structure_state.requested_paths.contains(path) || structure_state.requested_paths_subcolumns.contains(path) || structure_state.checkIfPathMatchesAnyRequestedPrefix(path))
            chunk_structure.position_to_requested_path[i] = path;

        if (structure_state.need_all_paths)
            chunk_structure.all_paths.push_back(path);
    }
}

/// Deserialize suffix of the chunk in ObjectSharedDataStructure(Suffix) stream.
void SerializationObjectSharedData::deserializeChunkStructureSuffix(ReadBuffer & buf, ChunkStructure & chunk_structure)
{
    readBinaryLittleEndian(chunk_structure.data_stream_mark.offset_in_compressed_file, buf);
    readBinaryLittleEndian(chunk_structure.data_stream_mark.offset_in_decompressed_block, buf);
    readBinaryLittleEndian(chunk_structure.paths_marks_stream_mark.offset_in_compressed_file, buf);
    readBinaryLittleEndian(chunk_structure.paths_marks_stream_mark.offset_in_decompressed_block, buf);
    readBinaryLittleEndian(chunk_structure.paths_substreams_metadata_stream_mark.offset_in_compressed_file, buf);
    readBinaryLittleEndian(chunk_structure.paths_substreams_metadata_stream_mark.offset_in_decompressed_block, buf);
}

void SerializationObjectSharedData::serializeBinaryBulkWithMultipleStreams(
    const IColumn & column,
    size_t offset,
    size_t limit,
    ISerialization::SerializeBinaryBulkSettings & settings,
    ISerialization::SerializeBinaryBulkStatePtr & state) const
{
    auto * shared_data_state = checkAndGetState<SerializeBinaryBulkStateObjectSharedData>(state);
    if ((serialization_version.value == SerializationVersion::ADVANCED || serialization_version.value == SerializationVersion::ADVANCED_CHUNKED)
        && !shared_data_state->value_types)
        shared_data_state->value_types = std::make_unique<SharedDataValueTypes>(dynamic_type, dynamic_serialization);

    if (serialization_version.value == SerializationVersion::MAP)
    {
        serialization_map->serializeBinaryBulkWithMultipleStreams(column, offset, limit, settings, shared_data_state->map_state);
    }
    else if (serialization_version.value == SerializationVersion::MAP_WITH_BUCKETS)
    {
        size_t end = limit && offset + limit < column.size() ? offset + limit : column.size();
        /// Build one bucket at a time (and free it before building the next) to reduce peak memory,
        /// instead of materializing all bucket columns simultaneously.
        SharedDataBucketsSplitter buckets_splitter(column, offset, end, buckets);
        for (size_t bucket = 0; bucket != buckets; ++bucket)
        {
            auto bucket_column = buckets_splitter.extractBucket(bucket);
            settings.path.push_back(Substream::Bucket);
            settings.path.back().bucket = bucket;
            serialization_map->serializeBinaryBulkWithMultipleStreams(*bucket_column, 0, 0, settings, shared_data_state->bucket_map_states[bucket]);
            settings.path.pop_back();
        }
    }
    else if (serialization_version.value == SerializationVersion::ADVANCED)
    {
        size_t end = limit && offset + limit < column.size() ? offset + limit : column.size();

        /// Process each bucket separately to limit peak memory —
        /// only the column of one path is alive at a time.
        /// The splitter hashes each distinct path once instead of once per bucket.
        SharedDataBucketsSplitter buckets_splitter(column, offset, end, buckets);
                for (size_t bucket = 0; bucket != buckets; ++bucket)
        {
            auto bucket_paths = buckets_splitter.getBucketPaths(bucket);

            settings.path.push_back(Substream::Bucket);
            settings.path.back().bucket = bucket;

            /// Write structure prefix: number of rows and list of paths.
            Substream structure_stream_type = settings.use_specialized_prefixes_and_suffixes_substreams ? Substream::ObjectSharedDataStructurePrefix
                                                                                           : Substream::ObjectSharedDataStructure;
            settings.path.push_back(structure_stream_type);
            auto * structure_stream = settings.getter(settings.path);
            settings.path.pop_back();

            if (!structure_stream)
                throw Exception(
                    ErrorCodes::LOGICAL_ERROR,
                    "Got empty stream for shared data structure in SerializationObjectSharedData::serializeBinaryBulkWithMultipleStreams");

            writeVarUInt(end - offset, *structure_stream);
            writeVarUInt(bucket_paths.paths.size(), *structure_stream);
            for (const auto & path : bucket_paths.paths)
                writeStringBinary(path, *structure_stream);

            /// Serialize data and collect metadata, then write metadata substreams + structure suffix.
            auto & data_stream = getDataStream(settings);
            auto metadata = serializeChunkBucketData(
                buckets_splitter, bucket_paths, data_stream, settings, dynamic_type, dynamic_serialization, *shared_data_state->value_types, shared_data_state->substream_file_names,
                MergeTreeObjectSharedDataSerializationVersion::ADVANCED);
            settings.path.pop_back();
            writeAllChunkBucketMetadata(metadata, settings);

            settings.path.pop_back();
        }

        /// Write Copy section.
        writeChunkCopySection(column, offset, end, buckets_splitter, settings);
    }
    else if (serialization_version.value == SerializationVersion::ADVANCED_CHUNKED)
    {
        size_t end = limit && offset + limit < column.size() ? offset + limit : column.size();
        size_t total_rows = end - offset;
        size_t target_chunk_rows = settings.object_shared_data_target_chunk_rows;

        /// All chunks except the last are exactly target_chunk_rows.
        /// If the last chunk would be smaller than half the target, it is merged with the
        /// previous chunk to avoid a wastefully small trailing chunk. This means the last
        /// chunk can be up to 1.5 * target_chunk_rows. For example with target=10000:
        ///   25000 rows → 10000, 10000, 5000  (5000 >= 5000, keep separate)
        ///   24000 rows → 10000, 14000        (4000 < 5000, merge into previous)
        ///   10001 rows → 10001               (1 < 5000, single chunk)
        size_t num_chunks = total_rows / target_chunk_rows;
        size_t last_chunk_remainder = total_rows % target_chunk_rows;
        if (last_chunk_remainder > 0 && last_chunk_remainder >= target_chunk_rows / 2)
            ++num_chunks;
        num_chunks = std::max<size_t>(num_chunks, 1);

        /// Compute the [start, end) row range for a given chunk index.
        /// All chunks except the last are exactly target_chunk_rows; the last chunk gets all remaining rows.
        auto get_chunk_range = [&](size_t chunk_idx) -> std::pair<size_t, size_t>
        {
            size_t chunk_start = offset + chunk_idx * target_chunk_rows;
            size_t chunk_end = (chunk_idx == num_chunks - 1) ? end : chunk_start + target_chunk_rows;
            return {chunk_start, chunk_end};
        };

        if (settings.data_part_type == MergeTreeDataPartType::Compact)
        {
            /// Compact parts: stream-then-chunks layout.
            /// For each substream, write ALL chunks contiguously.
            /// This requires 4 phases per bucket:
            /// Phase 1: Write StructurePrefix headers (scan path names, no flatten paths columns)
            /// Phase 2: Write Data (flatten + serialize one chunk at a time, buffer metadata)
            /// Phase 3: Write buffered metadata substreams
            /// Phase 4: Write Copy section in stream-then-chunks order

            /// One splitter per chunk, shared by all buckets, so each distinct path is hashed once per chunk.
            std::vector<std::unique_ptr<SharedDataBucketsSplitter>> chunk_splitters;
            chunk_splitters.reserve(num_chunks);
            for (size_t chunk_idx = 0; chunk_idx < num_chunks; ++chunk_idx)
            {
                auto [chunk_start, chunk_end] = get_chunk_range(chunk_idx);
                chunk_splitters.push_back(std::make_unique<SharedDataBucketsSplitter>(column, chunk_start, chunk_end, buckets));
            }

            for (size_t bucket = 0; bucket != buckets; ++bucket)
            {
                settings.path.push_back(Substream::Bucket);
                settings.path.back().bucket = bucket;

                /// Phase 1: Write all StructurePrefix chunk headers.
                Substream structure_stream_type = Substream::ObjectSharedDataStructurePrefix;
                settings.path.push_back(structure_stream_type);
                auto * structure_stream = settings.getter(settings.path);
                settings.path.pop_back();

                if (!structure_stream)
                    throw Exception(ErrorCodes::LOGICAL_ERROR,
                        "Got empty stream for shared data structure in ADVANCED_CHUNKED Compact serialization");

                for (size_t chunk_idx = 0; chunk_idx < num_chunks; ++chunk_idx)
                {
                    auto [chunk_start, chunk_end] = get_chunk_range(chunk_idx);
                    auto path_names = chunk_splitters[chunk_idx]->getBucketPathNames(bucket);

                    writeVarUInt(chunk_end - chunk_start, *structure_stream);
                    writeVarUInt(path_names.size(), *structure_stream);
                    for (const auto & path : path_names)
                        writeStringBinary(path, *structure_stream);
                }

                /// Phase 2: Write Data for all chunks, buffer metadata.
                std::vector<ChunkBucketSerializationMetadata> chunk_metadata;
                chunk_metadata.reserve(num_chunks);
                auto & data_stream = getDataStream(settings);
                for (size_t chunk_idx = 0; chunk_idx < num_chunks; ++chunk_idx)
                {
                    const auto & chunk_splitter = *chunk_splitters[chunk_idx];
                    auto bucket_paths = chunk_splitter.getBucketPaths(bucket);
                    chunk_metadata.push_back(serializeChunkBucketData(
                        chunk_splitter, bucket_paths, data_stream, settings, dynamic_type, dynamic_serialization, *shared_data_state->value_types, shared_data_state->substream_file_names,
                        MergeTreeObjectSharedDataSerializationVersion::ADVANCED_CHUNKED));
                }
                settings.path.pop_back();

                /// Phase 3: Write buffered metadata in stream-then-chunks order.
                /// Each substream is obtained once (writing one mark in Compact parts),
                /// then all chunks' data for that substream is written contiguously.
                auto & paths_marks_stream = getPathsMarksStream(settings);
                std::vector<MarkInCompressedFile> paths_marks_stream_marks;
                paths_marks_stream_marks.reserve(num_chunks);
                for (const auto & metadata : chunk_metadata)
                    paths_marks_stream_marks.push_back(writePathsMarks(metadata, paths_marks_stream, settings));
                settings.path.pop_back();

                auto & substreams_stream = getSubstreamsStream(settings);
                std::vector<std::vector<MarkInCompressedFile>> all_marks_of_paths_substreams;
                all_marks_of_paths_substreams.reserve(num_chunks);
                for (const auto & metadata : chunk_metadata)
                    all_marks_of_paths_substreams.push_back(writePathsSubstreams(metadata, substreams_stream, settings));
                settings.path.pop_back();

                auto & substreams_marks_stream = getSubstreamsMarksStream(settings);
                std::vector<std::vector<MarkInCompressedFile>> all_marks_of_paths_substreams_marks;
                all_marks_of_paths_substreams_marks.reserve(num_chunks);
                for (const auto & metadata : chunk_metadata)
                    all_marks_of_paths_substreams_marks.push_back(writeSubstreamsMarks(metadata, substreams_marks_stream, settings));
                settings.path.pop_back();

                auto & metadata_stream = getPathsSubstreamsMetadataStream(settings);
                std::vector<MarkInCompressedFile> metadata_stream_marks;
                metadata_stream_marks.reserve(num_chunks);
                for (size_t i = 0; i < chunk_metadata.size(); ++i)
                    metadata_stream_marks.push_back(writePathsSubstreamsMetadata(
                        all_marks_of_paths_substreams[i], all_marks_of_paths_substreams_marks[i], metadata_stream, settings));
                settings.path.pop_back();

                auto & structure_suffix_stream = getStructureSuffixStream(settings);
                for (size_t i = 0; i < chunk_metadata.size(); ++i)
                    writeStructureSuffix(chunk_metadata[i].data_stream_mark, paths_marks_stream_marks[i], metadata_stream_marks[i], structure_suffix_stream);
                settings.path.pop_back();

                settings.path.pop_back();
            }

            /// Phase 4: Write Copy section in stream-then-chunks order.
            /// In Compact parts each substream is contiguous, so we write
            /// all chunks' Sizes first, then all PathsIndexes, then all Values.
            auto cols = extractSharedDataColumns(column);

            settings.path.push_back(Substream::ObjectSharedDataCopy);

            /// Write all chunks' Sizes contiguously.
            /// Get the stream once — in Compact parts each settings.getter call writes a mark.
            settings.path.push_back(Substream::ObjectSharedDataCopySizes);
            auto * sizes_stream = settings.getter(settings.path);
            if (!sizes_stream)
                throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for shared data copy sizes");
            for (size_t chunk_idx = 0; chunk_idx < num_chunks; ++chunk_idx)
            {
                auto [chunk_start, chunk_end] = get_chunk_range(chunk_idx);
                SerializationArray::serializeOffsetsBinaryBulk(cols.offsets_column, chunk_start, chunk_end - chunk_start, *sizes_stream, settings.position_independent_encoding);
            }
            settings.path.pop_back();

            /// Write all chunks' PathsIndexes contiguously.
            auto & copy_indexes_stream = getCopyPathsIndexesStream(settings);
            for (size_t chunk_idx = 0; chunk_idx < num_chunks; ++chunk_idx)
            {
                auto [chunk_start, chunk_end] = get_chunk_range(chunk_idx);
                size_t nested_offset = chunk_start ? cols.offsets[chunk_start - 1] : 0;
                size_t nested_end = cols.offsets[chunk_end - 1];
                writeCopyIndexesForChunk(*chunk_splitters[chunk_idx], nested_end - nested_offset, copy_indexes_stream);
            }
            settings.path.pop_back();

            /// Write all chunks' Values contiguously.
            auto & copy_values_stream = getCopyValuesStream(settings);
            for (size_t chunk_idx = 0; chunk_idx < num_chunks; ++chunk_idx)
            {
                auto [chunk_start, chunk_end] = get_chunk_range(chunk_idx);
                size_t nested_offset = chunk_start ? cols.offsets[chunk_start - 1] : 0;
                size_t nested_end = cols.offsets[chunk_end - 1];
                size_t nested_limit = nested_end - nested_offset;
                if (nested_limit)
                    SerializationString::create()->serializeBinaryBulk(cols.values_column, copy_values_stream, nested_offset, nested_limit);
            }
            settings.path.pop_back();

            settings.path.pop_back();
        }
        else
        {
            /// Wide parts: chunk-then-streams layout.
            /// For each chunk, process all buckets (structure + data + metadata), then write copy.
            for (size_t chunk_idx = 0; chunk_idx < num_chunks; ++chunk_idx)
            {
                auto [chunk_start, chunk_end] = get_chunk_range(chunk_idx);
                SharedDataBucketsSplitter buckets_splitter(column, chunk_start, chunk_end, buckets);

                for (size_t bucket = 0; bucket != buckets; ++bucket)
                {
                    auto bucket_paths = buckets_splitter.getBucketPaths(bucket);

                    settings.path.push_back(Substream::Bucket);
                    settings.path.back().bucket = bucket;

                    /// Write structure prefix: number of rows and list of paths.
                    Substream structure_stream_type = Substream::ObjectSharedDataStructure;
                    settings.path.push_back(structure_stream_type);
                    auto * structure_stream = settings.getter(settings.path);
                    settings.path.pop_back();

                    if (!structure_stream)
                        throw Exception(ErrorCodes::LOGICAL_ERROR,
                            "Got empty stream for shared data structure in ADVANCED_CHUNKED Wide serialization");

                    writeVarUInt(chunk_end - chunk_start, *structure_stream);
                    writeVarUInt(bucket_paths.paths.size(), *structure_stream);
                    for (const auto & path : bucket_paths.paths)
                        writeStringBinary(path, *structure_stream);

                    /// Serialize data and write metadata.
                    auto & data_stream = getDataStream(settings);
                    auto metadata = serializeChunkBucketData(
                        buckets_splitter, bucket_paths, data_stream, settings, dynamic_type, dynamic_serialization, *shared_data_state->value_types, shared_data_state->substream_file_names,
                        MergeTreeObjectSharedDataSerializationVersion::ADVANCED_CHUNKED);
                    settings.path.pop_back();
                    writeAllChunkBucketMetadata(metadata, settings);

                    settings.path.pop_back();
                }

                /// Write Copy section for this chunk.
                writeChunkCopySection(column, chunk_start, chunk_end, buckets_splitter, settings);
            }
        }
    }
    else
    {
        /// If we add new serialization version in future and forget to implement something, better to get an exception instead of doing nothing.
        throw Exception(ErrorCodes::NOT_IMPLEMENTED, "serializeBinaryBulkWithMultipleStreams is not implemented for shared data serialization version {}", serialization_version.value);
    }
}

void SerializationObjectSharedData::serializeBinaryBulkStateSuffix(
    ISerialization::SerializeBinaryBulkSettings & settings, ISerialization::SerializeBinaryBulkStatePtr & state) const
{
    auto * shared_data_state = checkAndGetState<SerializeBinaryBulkStateObjectSharedData>(state);

    if (serialization_version.value == SerializationVersion::MAP)
    {
        serialization_map->serializeBinaryBulkStateSuffix(settings, shared_data_state->map_state);
    }
    else if (serialization_version.value == SerializationVersion::MAP_WITH_BUCKETS)
    {
        for (size_t bucket = 0; bucket != buckets; ++bucket)
        {
            settings.path.push_back(Substream::Bucket);
            settings.path.back().bucket = bucket;
            serialization_map->serializeBinaryBulkStateSuffix(settings, shared_data_state->bucket_map_states[bucket]);
            settings.path.pop_back();
        }
    }
    else if (serialization_version.value == SerializationVersion::ADVANCED
             || serialization_version.value == SerializationVersion::ADVANCED_CHUNKED)
    {
        /// ADVANCED/ADVANCED_CHUNKED doesn't have suffix.
    }
    else
    {
        /// If we add new serialization version in future and forget to implement something, better to get an exception instead of doing nothing.
        throw Exception(ErrorCodes::NOT_IMPLEMENTED, "serializeBinaryBulkStateSuffix is not implemented for shared data serialization version {}", serialization_version.value);
    }

}

void SerializationObjectSharedData::deserializeBinaryBulkStatePrefix(
    ISerialization::DeserializeBinaryBulkSettings & settings,
    ISerialization::DeserializeBinaryBulkStatePtr & state,
    ISerialization::SubstreamsDeserializeStatesCache * cache) const
{
    auto shared_data_state = std::make_shared<DeserializeBinaryBulkStateObjectSharedData>();

    if (serialization_version.value == SerializationVersion::MAP)
    {
        serialization_map->deserializeBinaryBulkStatePrefix(settings, shared_data_state->map_state, cache);
    }
    else if (serialization_version.value == SerializationVersion::MAP_WITH_BUCKETS)
    {
        shared_data_state->bucket_map_states.resize(buckets);
        for (size_t bucket = 0; bucket != buckets; ++bucket)
        {
            settings.path.push_back(Substream::Bucket);
            settings.path.back().bucket = bucket;
            serialization_map->deserializeBinaryBulkStatePrefix(settings, shared_data_state->bucket_map_states[bucket], cache);
            settings.path.pop_back();
        }
    }
    else if (serialization_version.value == SerializationVersion::ADVANCED
             || serialization_version.value == SerializationVersion::ADVANCED_CHUNKED)
    {
        shared_data_state->bucket_structure_states.resize(buckets);
        for (size_t bucket = 0; bucket != buckets; ++bucket)
        {
            settings.path.push_back(Substream::Bucket);
            settings.path.back().bucket = bucket;
            shared_data_state->bucket_structure_states[bucket] = deserializeStructureStatePrefix(settings, cache);
            auto * structure_state_concrete = checkAndGetState<DeserializeBinaryBulkStateObjectSharedDataStructure>(shared_data_state->bucket_structure_states[bucket]);
            structure_state_concrete->need_all_paths = true;
            settings.path.pop_back();
        }
    }
    else
    {
        /// If we add new serialization version in future and forget to implement something, better to get an exception instead of doing nothing.
        throw Exception(ErrorCodes::NOT_IMPLEMENTED, "deserializeBinaryBulkStatePrefix is not implemented for shared data serialization version {}", serialization_version.value);
    }

    state = std::move(shared_data_state);
}

ISerialization::DeserializeBinaryBulkStatePtr SerializationObjectSharedData::deserializeStructureStatePrefix(DeserializeBinaryBulkSettings & settings, SubstreamsDeserializeStatesCache * cache)
{
    settings.path.push_back(Substream::ObjectSharedDataStructure);
    DeserializeBinaryBulkStatePtr state = nullptr;
    if (auto cached_state = getFromSubstreamsDeserializeStatesCache(cache, settings.path))
    {
        state = cached_state;
    }
    else
    {
        state = std::make_shared<DeserializeBinaryBulkStateObjectSharedDataStructure>();
        /// Add state to cache so all columns/subcolumns that read from this stream will share the same state.
        addToSubstreamsDeserializeStatesCache(cache, settings.path, state);
    }

    settings.path.pop_back();
    return state;
}

void SerializationObjectSharedData::checkChunksMatchFirstBucket(
    const ChunkStructures & chunks, const ChunkStructures & first_bucket_chunks, size_t bucket)
{
    if (chunks.size() != first_bucket_chunks.size())
        throw Exception(
            ErrorCodes::LOGICAL_ERROR,
            "Bucket {} of Object shared data has {} chunks, but bucket 0 has {} chunks",
            bucket,
            chunks.size(),
            first_bucket_chunks.size());

    for (size_t chunk = 0; chunk != chunks.size(); ++chunk)
    {
        if (chunks[chunk].limit != first_bucket_chunks[chunk].limit || chunks[chunk].offset != first_bucket_chunks[chunk].offset)
            throw Exception(
                ErrorCodes::LOGICAL_ERROR,
                "Chunk {} of bucket {} of Object shared data has {} rows at offset {}, but the same chunk of bucket 0 has {} rows at offset {}",
                chunk,
                bucket,
                chunks[chunk].limit,
                chunks[chunk].offset,
                first_bucket_chunks[chunk].limit,
                first_bucket_chunks[chunk].offset);
    }
}

std::shared_ptr<SerializationObjectSharedData::ChunkStructures> SerializationObjectSharedData::deserializeStructure(
    size_t limit,
    ISerialization::DeserializeBinaryBulkSettings & settings,
    DeserializeBinaryBulkStateObjectSharedDataStructure & structure_state,
    ISerialization::SubstreamsCache * cache)
{
    /// First check if we already deserialized data from structure steam and have it in the cache.
    auto structure_path = settings.path;
    structure_path.push_back(Substream::ObjectSharedDataStructure);
    if (const auto * cached_structure = getElementFromSubstreamsCache(cache, structure_path))
    {
        return assert_cast<const SubstreamsCacheStructureElement *>(cached_structure)->chunk_structures;
    }

    auto result = std::make_shared<ChunkStructures>();

    /// In Compact part we always read whole chunks, so we don't need to worry about reading partial data.
    /// For ADVANCED there is exactly one chunk. For ADVANCED_CHUNKED there may be multiple chunks.
    if (settings.data_part_type == MergeTreeDataPartType::Compact)
    {
        if (!settings.use_specialized_prefixes_and_suffixes_substreams)
            throw Exception(ErrorCodes::LOGICAL_ERROR, "Compact part must use specialized substreams for prefixes and suffixes");

        /// Read all chunk prefixes from StructurePrefix stream.
        settings.path.push_back(Substream::ObjectSharedDataStructurePrefix);
        auto * structure_prefix_stream = settings.getter(settings.path);
        if (!structure_prefix_stream)
            throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty structure prefix stream for object shared data data");

        /// A Compact granule always contains at least one chunk, and an empty (0-row) granule still
        /// writes one empty chunk. Read at least one chunk so its structure bytes are always consumed.
        size_t total_chunk_rows = 0;
        do
        {
            ChunkStructure chunk_structure;
            deserializeChunkStructurePrefix(*structure_prefix_stream, chunk_structure, structure_state);
            total_chunk_rows += chunk_structure.num_rows;
            result->push_back(std::move(chunk_structure));
        } while (total_chunk_rows < limit);
        settings.path.pop_back();

        if (total_chunk_rows != limit)
            throw Exception(ErrorCodes::LOGICAL_ERROR,
                "Expected total chunk rows {} to equal requested rows {} in Compact part",
                total_chunk_rows, limit);

        /// Read all chunk suffixes from StructureSuffix stream.
        settings.path.push_back(Substream::ObjectSharedDataStructureSuffix);
        auto * structure_suffix_stream = settings.getter(settings.path);
        if (!structure_suffix_stream)
            throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty structure suffix stream for object shared data");

        for (auto & chunk : *result)
        {
            deserializeChunkStructureSuffix(*structure_suffix_stream, chunk);
            /// All chunks of a Compact granule are read fully.
            chunk.offset = 0;
            chunk.limit = chunk.num_rows;
        }
        settings.path.pop_back();
    }
    /// In Wide part we can read multiple chunks together and read only part of last chunk.
    else
    {
        auto * structure_stream = settings.getter(structure_path);

        if (!structure_stream)
            throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty structure stream for object shared data");

        /// Reset last read chunk state if we don't continue reading from it.
        if (!settings.continuous_reading)
            structure_state.last_chunk_structure.clear();

        size_t rows_to_read = limit;
        while (rows_to_read != 0)
        {
            auto & current_chunk = structure_state.last_chunk_structure;

            /// Calculate remaining rows in current chunk that can be read.
            size_t remaining_rows_in_chunk = current_chunk.num_rows - current_chunk.limit - current_chunk.offset;

            /// If there is nothing to read from current chunk - read the next one.
            if (remaining_rows_in_chunk == 0)
            {
                /// Finish if there is no more data in structure stream.
                if (structure_stream->eof())
                    break;

                current_chunk.clear();
                deserializeChunkStructurePrefix(*structure_stream, current_chunk, structure_state);
                deserializeChunkStructureSuffix(*structure_stream, current_chunk);
                remaining_rows_in_chunk = current_chunk.num_rows;
            }

            /// offset and limit in current chunk may be non 0 if we already read from this chunk before,
            /// so start reading from the last read row (offset + limit).
            current_chunk.offset += current_chunk.limit;

            /// Check if we need to read the whole chunk.
            if (remaining_rows_in_chunk <= rows_to_read)
            {
                current_chunk.limit = current_chunk.num_rows - current_chunk.offset;
                rows_to_read -= remaining_rows_in_chunk;
            }
            /// Otherwise we read only a part of the chunk.
            else
            {
                current_chunk.limit = rows_to_read;
                rows_to_read = 0;
            }

            result->push_back(current_chunk);
        }
    }

    /// Add deserialized data into cache.
    addElementToSubstreamsCache(cache, structure_path, std::make_unique<SubstreamsCacheStructureElement>(result));
    return result;
}

std::shared_ptr<SerializationObjectSharedData::PathsInfosChunks> SerializationObjectSharedData::deserializePathsInfos(
    const SerializationObjectSharedData::ChunkStructures & chunk_structures,
    const SerializationObjectSharedData::DeserializeBinaryBulkStateObjectSharedDataStructure & structure_state,
    ISerialization::DeserializeBinaryBulkSettings & settings,
    ISerialization::SubstreamsCache * cache)
{
    auto paths_infos_path = settings.path;
    paths_infos_path.push_back(Substream::ObjectSharedDataPathsInfos);
    /// First check if we already deserialized paths infos and have it in cache.
    if (auto * cached_paths_infos = getElementFromSubstreamsCache(cache, paths_infos_path))
        return assert_cast<SubstreamsCachePathsInfosElement *>(cached_paths_infos)->paths_infos_chunks;

    /// Deserialize paths infos chunk by chunk.
    auto paths_infos_chunks = std::make_shared<PathsInfosChunks>();
    paths_infos_chunks->reserve(chunk_structures.size());
    for (const auto & chunk_structure : chunk_structures)
    {
        auto & path_to_info = (*paths_infos_chunks).emplace_back().path_to_info;

        /// If there is nothing to read from this chunk, just skip it.
        if (chunk_structure.limit == 0 || chunk_structure.position_to_requested_path.empty())
            continue;

        bool need_paths_marks = false;
        bool need_subcolumns_info = false;
        for (const auto & [_, requested_path] : chunk_structure.position_to_requested_path)
        {
            /// For paths inside requested_paths_subcolumns we will need to read only subcolumns
            /// and don't need paths marks.
            if (structure_state.requested_paths_subcolumns.contains(requested_path))
                need_subcolumns_info = true;
            else
                need_paths_marks = true;
        }

        if (!settings.seek_stream_to_mark_callback)
            throw Exception(ErrorCodes::LOGICAL_ERROR, "Cannot read paths from object shared data with ADVANCED serialization version because seek_stream_to_mark_callback is not initialized");

        if (need_paths_marks)
        {
            settings.path.push_back(Substream::ObjectSharedDataPathsMarks);
            auto * paths_marks_stream = settings.getter(settings.path);

            if (!paths_marks_stream)
                throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for shared data paths marks");

            /// We don't read data from marks stream continuously, so we need to seek to the start of this chunk.
            settings.seek_stream_to_mark_callback(settings.path, chunk_structure.paths_marks_stream_mark);

            for (size_t i = 0; i != chunk_structure.num_paths; ++i)
            {
                auto path_it = chunk_structure.position_to_requested_path.find(i);
                /// Skip marks of not requested paths.
                if (path_it == chunk_structure.position_to_requested_path.end())
                {
                    paths_marks_stream->ignore(2 * sizeof(UInt64));
                }
                else
                {
                    auto & path_info = path_to_info[path_it->second];
                    readBinaryLittleEndian(path_info.data_mark.offset_in_compressed_file, *paths_marks_stream);
                    readBinaryLittleEndian(path_info.data_mark.offset_in_decompressed_block, *paths_marks_stream);
                }
            }

            settings.path.pop_back();
        }

        if (need_subcolumns_info)
        {
            /// Read metadata about paths subcolumns.
            settings.path.push_back(Substream::ObjectSharedDataPathsSubstreamsMetadata);
            auto * paths_substreams_metadata_stream = settings.getter(settings.path);

            if (!paths_substreams_metadata_stream)
                throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for shared data paths substreams metadata");

            /// We don't read data from marks stream continuously, so we need to seek to the start of this chunk.
            settings.seek_stream_to_mark_callback(settings.path, chunk_structure.paths_substreams_metadata_stream_mark);
            for (size_t i = 0; i != chunk_structure.num_paths; ++i)
            {
                auto path_it = chunk_structure.position_to_requested_path.find(i);
                /// Skip metadata of not requested paths.
                if (path_it == chunk_structure.position_to_requested_path.end())
                {
                    paths_substreams_metadata_stream->ignore(4 * sizeof(UInt64));
                }
                else
                {
                    auto & path_info = path_to_info[path_it->second];
                    readBinaryLittleEndian(path_info.substreams_mark.offset_in_compressed_file, *paths_substreams_metadata_stream);
                    readBinaryLittleEndian(path_info.substreams_mark.offset_in_decompressed_block, *paths_substreams_metadata_stream);
                    readBinaryLittleEndian(path_info.substreams_marks_mark.offset_in_compressed_file, *paths_substreams_metadata_stream);
                    readBinaryLittleEndian(path_info.substreams_marks_mark.offset_in_decompressed_block, *paths_substreams_metadata_stream);
                }
            }

            settings.path.pop_back();

            /// Read list of substreams for each path with requested subcolumns.
            settings.path.push_back(Substream::ObjectSharedDataSubstreams);
            auto * paths_substreams_stream = settings.getter(settings.path);

            if (!paths_substreams_stream)
                throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for shared data paths substreams");

            for (const auto & [_, requested_path] : chunk_structure.position_to_requested_path)
            {
                if (!structure_state.requested_paths_subcolumns.contains(requested_path))
                    continue;

                auto & path_info = path_to_info[requested_path];
                /// Seek to the start of the substreams list for this path.
                settings.seek_stream_to_mark_callback(settings.path, path_info.substreams_mark);
                size_t num_substreams = 0;
                readVarUInt(num_substreams, *paths_substreams_stream);
                reserveOrThrowTooMany(path_info.substreams, num_substreams, "substreams for a path");
                for (size_t i = 0; i != num_substreams; ++i)
                {
                    path_info.substreams.emplace_back();
                    readStringBinary(path_info.substreams.back(), *paths_substreams_stream);
                }
            }

            settings.path.pop_back();

            /// Read mark in the data stream for each substream of each path with requested subcolumns.
            settings.path.push_back(Substream::ObjectSharedDataSubstreamsMarks);
            auto * paths_substreams_marks_stream = settings.getter(settings.path);

            if (!paths_substreams_marks_stream)
                throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for shared data paths substreams marks");

            for (const auto & [_, requested_path] : chunk_structure.position_to_requested_path)
            {
                if (!structure_state.requested_paths_subcolumns.contains(requested_path))
                    continue;

                auto & path_info = path_to_info[requested_path];
                /// Seek to the start of the substreams marks for this path.
                settings.seek_stream_to_mark_callback(settings.path, path_info.substreams_marks_mark);
                for (size_t i = 0; i != path_info.substreams.size(); ++i)
                {
                    MarkInCompressedFile substream_mark{};
                    readBinaryLittleEndian(substream_mark.offset_in_compressed_file, *paths_substreams_marks_stream);
                    readBinaryLittleEndian(substream_mark.offset_in_decompressed_block, *paths_substreams_marks_stream);
                    path_info.substream_to_mark[path_info.substreams[i]] = substream_mark;
                }
            }

            settings.path.pop_back();
        }
    }

    addElementToSubstreamsCache(cache, paths_infos_path, std::make_unique<SubstreamsCachePathsInfosElement>(paths_infos_chunks));
    return paths_infos_chunks;
}

void SerializationObjectSharedData::prefetchPathsInfos(
    const SerializationObjectSharedData::ChunkStructures & chunk_structures,
    const SerializationObjectSharedData::DeserializeBinaryBulkStateObjectSharedDataStructure & structure_state,
    ISerialization::DeserializeBinaryBulkSettings & settings,
    ISerialization::SubstreamsCache * cache)
{
    if (!settings.prefetch_stream_at_mark_callback)
        return;

    auto paths_infos_path = settings.path;
    paths_infos_path.push_back(Substream::ObjectSharedDataPathsInfos);
    if (getElementFromSubstreamsCache(cache, paths_infos_path))
        return;

    /// The next chunks are stored right after the first one, so it's enough to prefetch from the first chunk we read.
    for (const auto & chunk_structure : chunk_structures)
    {
        if (chunk_structure.limit == 0 || chunk_structure.position_to_requested_path.empty())
            continue;

        bool need_paths_marks = false;
        bool need_subcolumns_info = false;
        for (const auto & [_, requested_path] : chunk_structure.position_to_requested_path)
        {
            if (structure_state.requested_paths_subcolumns.contains(requested_path))
                need_subcolumns_info = true;
            else
                need_paths_marks = true;
        }

        if (need_paths_marks)
        {
            settings.path.push_back(Substream::ObjectSharedDataPathsMarks);
            settings.prefetch_stream_at_mark_callback(settings.path, chunk_structure.paths_marks_stream_mark);
            settings.path.pop_back();
        }

        if (need_subcolumns_info)
        {
            settings.path.push_back(Substream::ObjectSharedDataPathsSubstreamsMetadata);
            settings.prefetch_stream_at_mark_callback(settings.path, chunk_structure.paths_substreams_metadata_stream_mark);
            settings.path.pop_back();
        }

        return;
    }
}

void SerializationObjectSharedData::prefetchPathsData(
    const SerializationObjectSharedData::ChunkStructures & chunk_structures,
    const PathsInfosChunks & paths_infos_chunks,
    const SerializationObjectSharedData::DeserializeBinaryBulkStateObjectSharedDataStructure & structure_state,
    ISerialization::DeserializeBinaryBulkSettings & settings,
    ISerialization::SubstreamsCache * cache)
{
    if (!settings.prefetch_stream_at_mark_callback)
        return;

    auto data_path = settings.path;
    data_path.push_back(Substream::ObjectSharedDataData);
    if (getElementFromSubstreamsCache(cache, data_path))
        return;

    for (size_t chunk_idx = 0; chunk_idx != chunk_structures.size(); ++chunk_idx)
    {
        const auto & chunk_structure = chunk_structures[chunk_idx];
        const auto & path_to_info = paths_infos_chunks[chunk_idx].path_to_info;
        if (chunk_structure.limit == 0 || path_to_info.empty() || chunk_structure.position_to_requested_path.empty())
            continue;

        /// deserializePathsData reads the requested paths in the order of their positions, starting from the first one.
        /// The first substream read of a path with only subcolumns requested depends on the subcolumns, so prefetch only a whole path.
        const auto & first_requested_path = chunk_structure.position_to_requested_path.begin()->second;
        if (structure_state.requested_paths_subcolumns.contains(first_requested_path))
            return;

        auto path_info_it = path_to_info.find(first_requested_path);
        if (path_info_it != path_to_info.end())
            settings.prefetch_stream_at_mark_callback(data_path, path_info_it->second.data_mark);
        return;
    }
}

std::shared_ptr<SerializationObjectSharedData::PathsDataChunks> SerializationObjectSharedData::deserializePathsData(
    const SerializationObjectSharedData::ChunkStructures & chunk_structures,
    const PathsInfosChunks & paths_infos_chunks,
    const SerializationObjectSharedData::DeserializeBinaryBulkStateObjectSharedDataStructure & structure_state,
    ISerialization::DeserializeBinaryBulkSettings & settings,
    const DataTypePtr & dynamic_type,
    const SerializationPtr & dynamic_serialization,
    ISerialization::SubstreamsCache * cache)
{
    settings.path.push_back(Substream::ObjectSharedDataData);
    /// First check if we already deserialized paths data and have it in cache.
    if (auto * cached_paths_data = getElementFromSubstreamsCache(cache, settings.path))
    {
        settings.path.pop_back();
        return assert_cast<SubstreamsCachePathsDataElement *>(cached_paths_data)->paths_data_chunks;
    }

    /// Deserialize paths data chunk by chunk.
    auto * data_stream = settings.getter(settings.path);
    if (!data_stream)
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for shared data data");

    auto paths_data_chunks = std::make_shared<PathsDataChunks>();
    paths_data_chunks->reserve(chunk_structures.size());

    if (!settings.seek_stream_to_mark_callback)
        throw Exception(ErrorCodes::LOGICAL_ERROR, "Cannot read paths from object shared data with ADVANCED serialization version because seek_stream_to_mark_callback is not initialized");

    DeserializeBinaryBulkSettings deserialization_settings;
    deserialization_settings.object_and_dynamic_read_statistics = false;
    deserialization_settings.position_independent_encoding = true;
    deserialization_settings.use_specialized_prefixes_and_suffixes_substreams = true;
    deserialization_settings.data_part_type = MergeTreeDataPartType::Compact;
    deserialization_settings.seek_stream_to_mark_callback = [&](const SubstreamPath &, const MarkInCompressedFile & mark)
    {
        settings.seek_stream_to_mark_callback(settings.path, mark);
    };

    StreamFileNameSettings stream_file_name_settings;
    stream_file_name_settings.escape_variant_substreams = false;

    for (size_t chunk_idx = 0; chunk_idx != chunk_structures.size(); ++chunk_idx)
    {
        const auto & chunk_structure = chunk_structures[chunk_idx];
        const auto & path_to_info = paths_infos_chunks[chunk_idx].path_to_info;
        auto & paths_data_chunk = (*paths_data_chunks).emplace_back();

        /// Skip chunk if there is nothing to read from it.
        if (!chunk_structure.limit || path_to_info.empty())
            continue;

        for (const auto & [_, requested_path] : chunk_structure.position_to_requested_path)
        {
            auto path_info_it = path_to_info.find(requested_path);
            if (path_info_it == path_to_info.end())
                throw Exception(ErrorCodes::LOGICAL_ERROR, "Info for path {} is not deserialized", requested_path);

            const auto & path_info = path_info_it->second;
            /// Reset callbacks that might be different for different paths.
            deserialization_settings.seek_stream_to_current_mark_callback = {};
            deserialization_settings.getter = {};

            /// If we have only subcolumns requested for this path, read all subcolumns.
            auto paths_subcolumns_it = structure_state.requested_paths_subcolumns.find(requested_path);
            if (paths_subcolumns_it != structure_state.requested_paths_subcolumns.end())
            {
                const auto & subcolumns_infos = paths_subcolumns_it->second;
                std::vector<SubstreamData> subcolumns_substream_data;
                subcolumns_substream_data.reserve(subcolumns_infos.size());
                for (const auto & subcolumn_info : subcolumns_infos)
                    subcolumns_substream_data.push_back(SubstreamData(subcolumn_info.serialization).withType(subcolumn_info.type));

                deserialization_settings.seek_stream_to_current_mark_callback = [&](const SubstreamPath & substream_path)
                {
                    auto stream_name = ISerialization::getFileNameForStream(NameAndTypePair("", dynamic_type), substream_path, stream_file_name_settings);

                    auto it = path_info.substream_to_mark.find(stream_name);
                    if (it == path_info.substream_to_mark.end())
                        throw Exception(ErrorCodes::LOGICAL_ERROR, "Substream {} for path {} is requested but not found in substreams list", stream_name, requested_path);

                    /// Seek to the requested substream in the data stream.
                    settings.seek_stream_to_mark_callback(settings.path, it->second);
                };

                deserialization_settings.getter = [&](const SubstreamPath & substream_path) -> ReadBuffer *
                {
                    /// Seek to the requested substream before returning the data stream.
                    deserialization_settings.seek_stream_to_current_mark_callback(substream_path);
                    return data_stream;
                };

                /// First, deserialize prefixes for all subcolumns.
                SubstreamsDeserializeStatesCache deserialize_states_cache;
                for (auto & data : subcolumns_substream_data)
                    data.serialization->deserializeBinaryBulkStatePrefix(deserialization_settings, data.deserialize_state, &deserialize_states_cache);

                /// Second, determine the order of subcolumns deserialization if we have multiple subcolumns of the same path.
                std::vector<size_t> order;
                if (subcolumns_infos.size() == 1)
                {
                    order.push_back(0);
                }
                else
                {
                    EnumerateStreamsSettings enumerate_settings;
                    enumerate_settings.data_part_type = MergeTreeDataPartType::Compact;
                    enumerate_settings.use_specialized_prefixes_and_suffixes_substreams = true;
                    order = getSubcolumnsDeserializationOrder("", subcolumns_substream_data, path_info.substreams, enumerate_settings, stream_file_name_settings);
                }

                /// Finally, deserialize data of subcolumns in determined order.
                SubstreamsCache cache_for_subcolumns;
                for (auto pos : order)
                {
                    auto subcolumn = subcolumns_infos[pos].type->createColumn();
                    subcolumns_substream_data[pos].serialization->deserializeBinaryBulkWithMultipleStreams(*subcolumn, chunk_structure.num_rows, deserialization_settings, subcolumns_substream_data[pos].deserialize_state, &cache_for_subcolumns);
                    /// The callers read the rows of the chunk out of this column, so a shorter one
                    /// would be read out of bounds.
                    if (subcolumn->size() != chunk_structure.num_rows)
                        throw Exception(
                            ErrorCodes::LOGICAL_ERROR,
                            "Unexpected size of subcolumn {} of path {} in Object shared data: {}. Expected size {}",
                            subcolumns_infos[pos].name,
                            requested_path,
                            subcolumn->size(),
                            chunk_structure.num_rows);

                    paths_data_chunk.paths_subcolumns_data[requested_path][subcolumns_infos[pos].name] = std::move(subcolumn);
                }
            }
            /// Otherwise read the whole path data.
            else
            {
                deserialization_settings.getter = [&](const SubstreamPath &) -> ReadBuffer * { return data_stream; };
                settings.seek_stream_to_mark_callback(settings.path, path_info.data_mark);
                DeserializeBinaryBulkStatePtr path_state;
                auto dynamic_column = dynamic_type->createColumn();
                dynamic_serialization->deserializeBinaryBulkStatePrefix(deserialization_settings, path_state, nullptr);
                dynamic_serialization->deserializeBinaryBulkWithMultipleStreams(*dynamic_column, chunk_structure.num_rows, deserialization_settings, path_state, nullptr);
                if (dynamic_column->size() != chunk_structure.num_rows)
                    throw Exception(
                        ErrorCodes::LOGICAL_ERROR,
                        "Unexpected size of path {} in Object shared data: {}. Expected size {}",
                        requested_path,
                        dynamic_column->size(),
                        chunk_structure.num_rows);

                paths_data_chunk.paths_data[requested_path] = std::move(dynamic_column);
            }
        }
    }

    addElementToSubstreamsCache(cache, settings.path, std::make_unique<SubstreamsCachePathsDataElement>(paths_data_chunks));
    settings.path.pop_back();

    return paths_data_chunks;
}


void SerializationObjectSharedData::deserializeBinaryBulkWithMultipleStreams(
    IColumn & column,
    size_t limit,
    ISerialization::DeserializeBinaryBulkSettings & settings,
    ISerialization::DeserializeBinaryBulkStatePtr & state,
    ISerialization::SubstreamsCache * cache) const
{
    if (!state)
        return;

    auto * shared_data_state = checkAndGetState<DeserializeBinaryBulkStateObjectSharedData>(state);

    if (serialization_version.value == SerializationVersion::MAP)
    {
        /// Deserialize the shared data map and cache it for path subcolumn reads (SerializationObjectSharedDataPath).
        size_t prev_size = column.size();
        serialization_map->deserializeBinaryBulkWithMultipleStreams(column, limit, settings, shared_data_state->map_state, cache);
        addColumnWithNumReadRowsToSubstreamsCache(cache, settings.path, column.getPtr(), column.size() - prev_size);
    }
    else if (serialization_version.value == SerializationVersion::MAP_WITH_BUCKETS)
    {
        Columns shared_data_buckets(buckets);
        for (size_t bucket = 0; bucket != buckets; ++bucket)
        {
            settings.path.push_back(Substream::Bucket);
            settings.path.back().bucket = bucket;
            /// Deserialize the bucket's map and cache it for a path subcolumn read of the same bucket.
            auto mutable_bucket_column = column.cloneEmpty();
            serialization_map->deserializeBinaryBulkWithMultipleStreams(*mutable_bucket_column, limit, settings, shared_data_state->bucket_map_states[bucket], cache);
            shared_data_buckets[bucket] = std::move(mutable_bucket_column);
            addColumnWithNumReadRowsToSubstreamsCache(cache, settings.path, shared_data_buckets[bucket], shared_data_buckets[bucket]->size());
            settings.path.pop_back();
        }

        collectSharedDataFromBuckets(shared_data_buckets, column);
    }
    else if (serialization_version.value == SerializationVersion::ADVANCED
             || serialization_version.value == SerializationVersion::ADVANCED_CHUNKED)
    {
        /// Check if we have shared data column in cache.
        if (insertDataFromSubstreamsCacheIfAny(cache, settings, column))
            return;

        size_t prev_size = column.size();

        /// In Compact part we always read whole chunk(s), so we don't need to worry about reading partial data.
        if (settings.data_part_type == MergeTreeDataPartType::Compact)
        {
            /// Per-chunk path lists. Each chunk has its own path-to-index mapping for PathsIndexes.
            std::vector<VectorWithMemoryTracking<String>> chunks_paths;
            /// Number of rows in each chunk (same across all buckets).
            std::vector<size_t> chunks_num_rows;

            /// Collect paths per chunk from all buckets.
            for (size_t bucket = 0; bucket != buckets; ++bucket)
            {
                settings.path.push_back(Substream::Bucket);
                settings.path.back().bucket = bucket;

                if (!settings.use_specialized_prefixes_and_suffixes_substreams)
                    throw Exception(ErrorCodes::LOGICAL_ERROR, "Compact part must use specialized prefixes substreams");

                settings.path.push_back(Substream::ObjectSharedDataStructurePrefix);
                auto * structure_prefix_stream = settings.getter(settings.path);
                if (!structure_prefix_stream)
                    return;

                /// If we have seek_stream_to_current_mark_callback callback, we can seek to the start of each structure
                /// stream in each bucket and don't need to deserialize flattened paths data/marks/substreams/etc.
                if (settings.seek_stream_to_current_mark_callback)
                    settings.seek_stream_to_current_mark_callback(settings.path);

                auto * structure_state = checkAndGetState<DeserializeBinaryBulkStateObjectSharedDataStructure>(shared_data_state->bucket_structure_states[bucket]);

                /// A Compact granule always contains at least one chunk, and an empty (0-row) granule
                /// still writes one empty chunk, so read at least one chunk to always consume its bytes.
                std::vector<ChunkStructure> chunk_structures;
                size_t total_chunk_rows = 0;
                do
                {
                    ChunkStructure chunk_structure;
                    deserializeChunkStructurePrefix(*structure_prefix_stream, chunk_structure, *structure_state);
                    total_chunk_rows += chunk_structure.num_rows;
                    chunk_structures.push_back(std::move(chunk_structure));
                } while (total_chunk_rows < limit);

                if (total_chunk_rows != limit)
                    throw Exception(ErrorCodes::LOGICAL_ERROR,
                        "Expected total chunk rows {} to equal requested rows {} in Compact part in bucket {}",
                        total_chunk_rows, limit, bucket);

                settings.path.pop_back();

                /// Initialize per-chunk structures on first bucket.
                if (bucket == 0)
                {
                    chunks_paths.resize(chunk_structures.size());
                    chunks_num_rows.reserve(chunk_structures.size());
                    for (const auto & chunk_structure : chunk_structures)
                        chunks_num_rows.push_back(chunk_structure.num_rows);
                }

                /// Collect paths per chunk.
                for (size_t chunk_idx = 0; chunk_idx < chunk_structures.size(); ++chunk_idx)
                    chunks_paths[chunk_idx].insert(chunks_paths[chunk_idx].end(), chunk_structures[chunk_idx].all_paths.begin(), chunk_structures[chunk_idx].all_paths.end());

                /// Skip deserialization of flattened paths data/marks/substreams/etc if we can.
                if (settings.seek_stream_to_current_mark_callback)
                {
                    settings.path.pop_back();
                    continue;
                }

                /// Ignore all other data in all other streams for all chunks.
                settings.path.push_back(Substream::ObjectSharedDataData);
                auto * data_stream = settings.getter(settings.path);
                settings.path.pop_back();

                if (!data_stream)
                    throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for object shared data data");

                DeserializeBinaryBulkSettings deserialization_settings;
                deserialization_settings.object_and_dynamic_read_statistics = false;
                deserialization_settings.position_independent_encoding = true;
                deserialization_settings.use_specialized_prefixes_and_suffixes_substreams = true;
                deserialization_settings.data_part_type = MergeTreeDataPartType::Compact;
                deserialization_settings.getter = [&](const SubstreamPath &) -> ReadBuffer * { return data_stream; };

                for (const auto & chunk_structure : chunk_structures)
                {
                    for (size_t i = 0; i != chunk_structure.num_paths; ++i)
                    {
                        auto path_column = dynamic_type->createColumn();
                        DeserializeBinaryBulkStatePtr path_state;
                        dynamic_serialization->deserializeBinaryBulkStatePrefix(deserialization_settings, path_state, nullptr);
                        /// We only need to consume this path's data from the stream to advance to the next path; the column is discarded.
                        dynamic_serialization->deserializeBinaryBulkWithMultipleStreams(*path_column, chunk_structure.num_rows, deserialization_settings, path_state, nullptr);
                    }
                }

                settings.path.push_back(Substream::ObjectSharedDataPathsMarks);
                auto * paths_marks_stream = settings.getter(settings.path);
                settings.path.pop_back();

                if (!paths_marks_stream)
                    throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for object shared data paths marks");

                for (const auto & chunk_structure : chunk_structures)
                    paths_marks_stream->ignore(sizeof(UInt64) * chunk_structure.num_paths * 2);

                settings.path.push_back(Substream::ObjectSharedDataSubstreams);
                auto * paths_substreams_stream = settings.getter(settings.path);
                settings.path.pop_back();

                if (!paths_substreams_stream)
                    throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for object shared data paths substreams");

                /// Track total substreams per chunk for SubstreamsMarks skipping.
                std::vector<size_t> chunk_total_substreams(chunk_structures.size(), 0);
                for (size_t chunk_idx = 0; chunk_idx != chunk_structures.size(); ++chunk_idx)
                {
                    for (size_t i = 0; i != chunk_structures[chunk_idx].num_paths; ++i)
                    {
                        size_t num_substreams = 0;
                        readVarUInt(num_substreams, *paths_substreams_stream);
                        chunk_total_substreams[chunk_idx] += num_substreams;
                        for (size_t j = 0; j != num_substreams; ++j)
                            skipStringBinary(*paths_substreams_stream);
                    }
                }

                settings.path.push_back(Substream::ObjectSharedDataSubstreamsMarks);
                auto * substreams_marks_stream = settings.getter(settings.path);
                settings.path.pop_back();

                if (!substreams_marks_stream)
                    throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for object shared data paths substreams marks");

                for (size_t chunk_idx = 0; chunk_idx != chunk_structures.size(); ++chunk_idx)
                    substreams_marks_stream->ignore(sizeof(UInt64) * chunk_total_substreams[chunk_idx] * 2);

                settings.path.push_back(Substream::ObjectSharedDataPathsSubstreamsMetadata);
                auto * paths_substreams_metadata_stream = settings.getter(settings.path);
                settings.path.pop_back();

                if (!paths_substreams_metadata_stream)
                    throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for object shared data paths substreams metadata");

                for (const auto & chunk_structure : chunk_structures)
                    paths_substreams_metadata_stream->ignore(sizeof(UInt64) * chunk_structure.num_paths * 4);

                settings.path.push_back(Substream::ObjectSharedDataStructureSuffix);
                auto * structure_suffix_stream = settings.getter(settings.path);
                settings.path.pop_back();

                if (!structure_suffix_stream)
                    throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for object shared data structure suffix");

                for (auto & chunk_structure : chunk_structures)
                    deserializeChunkStructureSuffix(*structure_suffix_stream, chunk_structure);

                settings.path.pop_back();
            }

            /// Now we have per-chunk path lists and can deserialize shared data copy with paths indexes and values.
            auto & shared_data_array_column = assert_cast<ColumnArray &>(column);
            auto & shared_data_tuple_column = assert_cast<ColumnTuple &>(shared_data_array_column.getData());
            auto & offsets_column = shared_data_array_column.getOffsetsColumn();
            auto & paths_column = shared_data_tuple_column.getColumn(0);
            auto & values_column = shared_data_tuple_column.getColumn(1);

            size_t prev_last_offset = shared_data_array_column.getOffsets().back();
            size_t prev_offset_size = shared_data_array_column.getOffsets().size();

            settings.path.push_back(Substream::ObjectSharedDataCopy);

            /// Read array sizes.
            settings.path.push_back(Substream::ObjectSharedDataCopySizes);
            if (settings.seek_stream_to_current_mark_callback)
                settings.seek_stream_to_current_mark_callback(settings.path);

            if (!SerializationArray::deserializeOffsetsBinaryBulk(offsets_column, limit, settings, cache))
                throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for object shared data copy sizes");
            settings.path.pop_back();

            /// Read paths indexes per-chunk: each chunk has its own path-to-index mapping.
            settings.path.push_back(Substream::ObjectSharedDataCopyPathsIndexes);
            auto * indexes_stream = settings.getter(settings.path);
            if (!indexes_stream)
                throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for shared data copy indexes");

            auto & offsets = shared_data_array_column.getOffsets();
            size_t offsets_current_chunk_start = prev_offset_size;
            for (size_t chunk_idx = 0; chunk_idx < chunks_paths.size(); ++chunk_idx)
            {
                /// All chunks of a Compact granule are read fully.
                size_t chunk_nested_limit
                    = offsets[offsets_current_chunk_start + chunks_num_rows[chunk_idx] - ssize_t(1)]
                    - offsets[offsets_current_chunk_start - ssize_t(1)];
                /// Read indexes and collect paths into paths_column.
                deserializeIndexesAndCollectPaths(paths_column, *indexes_stream, std::move(chunks_paths[chunk_idx]), chunk_nested_limit);
                offsets_current_chunk_start += chunks_num_rows[chunk_idx];
            }
            settings.path.pop_back();

            size_t nested_limit = offsets.back() - prev_last_offset;

            /// Read paths values.
            settings.path.push_back(Substream::ObjectSharedDataCopyValues);
            auto * values_stream = settings.getter(settings.path);
            if (!values_stream)
                throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for shared data copy values");

            size_t values_size_before = values_column.size();
            SerializationString::create()->deserializeBinaryBulk(values_column, *values_stream, nested_limit, 0);
            /// The number of values comes from the offsets, so a shorter column would be read out of bounds.
            if (values_column.size() != values_size_before + nested_limit)
                throw Exception(
                    ErrorCodes::LOGICAL_ERROR,
                    "Unexpected number of values in Object shared data: {}. Expected {}",
                    values_column.size() - values_size_before,
                    nested_limit);

            settings.path.pop_back();

            settings.path.pop_back();
        }
        /// In Wide part we can read multiple chunks together and read only part of the last chunk.
        else
        {
            /// Collect list of paths from all buckets for each chunk.
            std::vector<VectorWithMemoryTracking<String>> chunks_paths;
            /// Collect the number of rows to read for each chunk.
            std::vector<size_t> chunks_limits;
            std::shared_ptr<ChunkStructures> first_bucket_chunk_structures;

            for (size_t bucket = 0; bucket != buckets; ++bucket)
            {
                settings.path.push_back(Substream::Bucket);
                settings.path.back().bucket = bucket;

                auto * structure_state = checkAndGetState<DeserializeBinaryBulkStateObjectSharedDataStructure>(shared_data_state->bucket_structure_states[bucket]);
                /// Read structure for all chunks in this bucket.
                auto chunk_structures = deserializeStructure(limit, settings, *structure_state, cache);
                if (!chunk_structures)
                    return;

                /// Initialize chunks_paths/chunks_limits on first bucket.
                if (bucket == 0)
                {
                    first_bucket_chunk_structures = chunk_structures;
                    chunks_paths.resize(chunk_structures->size());
                    chunks_limits.reserve(chunk_structures->size());
                    for (size_t chunk_idx = 0; chunk_idx != chunk_structures->size(); ++chunk_idx)
                        chunks_limits.push_back((*chunk_structures)[chunk_idx].limit);
                }
                else
                {
                    checkChunksMatchFirstBucket(*chunk_structures, *first_bucket_chunk_structures, bucket);
                }

                for (size_t chunk_idx = 0; chunk_idx != chunk_structures->size(); ++chunk_idx)
                    chunks_paths[chunk_idx].insert(chunks_paths[chunk_idx].end(), (*chunk_structures)[chunk_idx].all_paths.begin(), (*chunk_structures)[chunk_idx].all_paths.end());

                settings.path.pop_back();
            }

            /// Now we have a list of all paths stored in each chunk. Read shared data copy with paths indexes and values.
            settings.path.push_back(Substream::ObjectSharedDataCopy);

            auto & shared_data_array_column = assert_cast<ColumnArray &>(column);
            auto & shared_data_tuple_column = assert_cast<ColumnTuple &>(shared_data_array_column.getData());
            auto & offsets_column = shared_data_array_column.getOffsetsColumn();
            auto & paths_column = shared_data_tuple_column.getColumn(0);
            auto & values_column = shared_data_tuple_column.getColumn(1);

            size_t prev_last_offset = shared_data_array_column.getOffsets().back();
            size_t prev_offset_size = shared_data_array_column.getOffsets().size();

            /// Read array sizes.
            settings.path.push_back(Substream::ObjectSharedDataCopySizes);
            if (!SerializationArray::deserializeOffsetsBinaryBulk(offsets_column, limit, settings, cache))
                throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for object shared data copy sizes");

            settings.path.pop_back();

            /// Read paths indexes.
            settings.path.push_back(Substream::ObjectSharedDataCopyPathsIndexes);
            auto * indexes_stream = settings.getter(settings.path);

            if (!indexes_stream)
                throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for object shared data copy indexes");

            /// Each chunk has its own set of indexes, we should deserialize them chunk by chunk.
            size_t offsets_current_chunk_start = prev_offset_size;
            auto & offsets = shared_data_array_column.getOffsets();

            /// The chunks and the sizes stream describe the same rows: covering more would index the
            /// offsets out of bounds, fewer would leave the paths short. Reported as a short read, like
            /// a truncated elements stream in SerializationArray.
            size_t num_chunks_rows = std::accumulate(chunks_limits.begin(), chunks_limits.end(), size_t(0));
            size_t num_offsets_rows = offsets.size() - prev_offset_size;
            if (num_chunks_rows != num_offsets_rows)
                throw Exception(
                    ErrorCodes::CANNOT_READ_ALL_DATA,
                    "Chunks of Object shared data contain {} rows, but {} rows were read from the sizes stream",
                    num_chunks_rows,
                    num_offsets_rows);

            for (size_t chunk_idx = 0; chunk_idx != chunks_paths.size(); ++chunk_idx)
            {
                /// Calculate how many index entries should be read for this chunk.
                size_t chunk_nested_limit
                    = offsets[offsets_current_chunk_start + chunks_limits[chunk_idx] - ssize_t(1)]
                    - offsets[offsets_current_chunk_start - ssize_t(1)];
                /// Read indexes and collect paths into paths_column.
                deserializeIndexesAndCollectPaths(paths_column, *indexes_stream, std::move(chunks_paths[chunk_idx]), chunk_nested_limit);
                offsets_current_chunk_start += chunks_limits[chunk_idx];
            }
            settings.path.pop_back();

            /// Values can be read as usual String column from multiple chunks.
            /// We need to calculate the limit for it based on offsets.
            size_t nested_limit = offsets.back() - prev_last_offset;

            /// Read values.
            settings.path.push_back(Substream::ObjectSharedDataCopyValues);
            auto * values_stream = settings.getter(settings.path);
            if (!values_stream)
                throw Exception(ErrorCodes::LOGICAL_ERROR, "Got empty stream for object shared data copy values");

            size_t values_size_before = values_column.size();
            SerializationString::create()->deserializeBinaryBulk(values_column, *values_stream, nested_limit, 0);
            /// The number of values comes from the offsets, so a shorter column would be read out of bounds.
            if (values_column.size() != values_size_before + nested_limit)
                throw Exception(
                    ErrorCodes::LOGICAL_ERROR,
                    "Unexpected number of values in Object shared data: {}. Expected {}",
                    values_column.size() - values_size_before,
                    nested_limit);

            settings.path.pop_back();

            settings.path.pop_back();
        }

        addColumnWithNumReadRowsToSubstreamsCache(cache, settings.path, column.getPtr(), column.size() - prev_size);
    }
    else
    {
        /// If we add new serialization version in future and forget to implement something, better to get an exception instead of doing nothing.
        throw Exception(ErrorCodes::NOT_IMPLEMENTED, "deserializeBinaryBulkStatePrefix is not implemented for shared data serialization version {}", serialization_version.value);
    }
}

}
