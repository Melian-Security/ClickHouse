#pragma once

#include <DataTypes/Serializations/ISerialization.h>
#include <base/StringViewHash.h>
#include <city.h>

#include <memory>
#include <unordered_map>
#include <vector>


namespace DB
{

/// A map from substream paths to values, for code that resolves the same substream paths again and again (for every
/// granule, or for every path of JSON shared data), where making the stream name of a path and looking it up would cost
/// more than the work done with the stream.
///
/// A key consists of the fields of a substream that stream names are made of: the type, the bucket, and the names of
/// a variant element, a named substream and an object path. Paths are hashed by these fields and compared on lookup.
/// The same substreams are usually requested in the same order again, so the entry that followed the previously found
/// one last time is checked first, without hashing the path.
///
/// References to values stay valid as long as the map. Not thread-safe.
template <typename Value>
class SubstreamPathMap
{
public:
    /// Returns nullptr if the path is not in the map.
    Value * find(const ISerialization::SubstreamPath & path)
    {
        if (last && last->next && last->next->matches(path))
        {
            last = last->next;
            return &last->value;
        }

        auto it = entries.find(hash(path));
        if (it == entries.end())
            return nullptr;

        Entry * entry = it->second.get();
        while (entry && !entry->matches(path))
            entry = entry->same_hash.get();

        if (!entry)
            return nullptr;

        follow(entry);
        return &entry->value;
    }

    /// The path must not be in the map.
    Value & insert(const ISerialization::SubstreamPath & path, Value value)
    {
        auto entry = std::make_unique<Entry>(path, std::move(value));
        Entry * inserted = entry.get();
        auto & slot = entries[hash(path)];
        entry->same_hash = std::move(slot);
        slot = std::move(entry);
        follow(inserted);
        return inserted->value;
    }

private:
    struct Substream
    {
        ISerialization::Substream::Type type;
        size_t bucket;
        String variant_element_name;
        String name_of_substream;
        String object_path_name;
    };

    struct Entry
    {
        Entry(const ISerialization::SubstreamPath & path, Value value_)
            : value(std::move(value_))
        {
            substreams.reserve(path.size());
            for (const auto & substream : path)
                substreams.push_back(
                    {substream.type, substream.bucket, substream.variant_element_name, substream.name_of_substream, substream.object_path_name});
        }

        bool matches(const ISerialization::SubstreamPath & path) const
        {
            if (substreams.size() != path.size())
                return false;
            for (size_t i = 0; i != substreams.size(); ++i)
            {
                const auto & substream = substreams[i];
                if (substream.type != path[i].type || substream.bucket != path[i].bucket
                    || substream.variant_element_name != path[i].variant_element_name
                    || substream.name_of_substream != path[i].name_of_substream
                    || substream.object_path_name != path[i].object_path_name)
                    return false;
            }
            return true;
        }

        std::vector<Substream> substreams;
        Value value;
        /// The entry found after this one the last time this one was found.
        Entry * next = nullptr;
        /// Another entry whose path has the same hash.
        std::unique_ptr<Entry> same_hash;
    };

    static UInt64 hash(const ISerialization::SubstreamPath & path)
    {
        /// Most substreams have no names, so only the names that are set are hashed.
        UInt64 result = path.size();
        auto combine = [&](UInt64 value) { result = CityHash_v1_0_2::Hash128to64({result, value}); };
        for (const auto & substream : path)
        {
            combine((static_cast<UInt64>(substream.type) << 32) ^ substream.bucket);
            for (const String * str : {&substream.variant_element_name, &substream.name_of_substream, &substream.object_path_name})
                combine(str->empty() ? 0 : StringViewHash64()(*str));
        }
        return result;
    }

    void follow(Entry * entry)
    {
        if (last)
            last->next = entry;
        last = entry;
    }

    std::unordered_map<UInt64, std::unique_ptr<Entry>> entries;
    Entry * last = nullptr;
};

}
