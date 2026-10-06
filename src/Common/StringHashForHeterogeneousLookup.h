#pragma once

#include <string>
#include <string_view>
#include <functional>

namespace DB
{

/// A string with its hash computed once, so the same key can be looked up in several
/// maps that use StringHashForHeterogeneousLookup without being rehashed for each map.
/// The stored hash must equal std::hash<std::string_view> of the value.
struct PrehashedStringView
{
    std::string_view value;
    size_t hash;

    explicit PrehashedStringView(std::string_view value_) : value(value_), hash(std::hash<std::string_view>()(value_)) {}
    PrehashedStringView(std::string_view value_, size_t hash_) : value(value_), hash(hash_) {}

    friend bool operator==(const PrehashedStringView & lhs, const std::string & rhs) { return lhs.value == rhs; }
};

/// See https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2018/p0919r3.html
struct StringHashForHeterogeneousLookup
{
    using hash_type = std::hash<std::string_view>;
    using transparent_key_equal = std::equal_to<>;
    using is_transparent = void; // required to make find() work with different type than key_type

    auto operator()(const std::string_view view) const
    {
        return hash_type()(view);
    }

    auto operator()(const std::string & str) const
    {
        return hash_type()(str);
    }

    auto operator()(const char * data) const
    {
        return hash_type()(data);
    }

    size_t operator()(const PrehashedStringView & prehashed) const
    {
        return prehashed.hash;
    }
};

}
