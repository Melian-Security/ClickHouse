#pragma once

#include <Common/SipHash.h>
#include <Common/transformEndianness.h>

#include <bit>
#include <type_traits>


/// Feeds a sequence of fixed-size values to `SipHash` through a small stack buffer.
///
/// The bytes that reach the hash are exactly the bytes that `hash.update(value)` per value would
/// feed, in the same order, so the resulting hash is identical. Only the call granularity changes:
/// `SipHash::update` with a few bytes on an unaligned stream state assembles the pending word byte
/// by byte on every call, while one call over the whole buffer consumes it in 8-byte words.
/// `flush` must be called before the hash is used or another value is fed to it directly.
template <typename T>
requires std::is_arithmetic_v<T>
class SipHashBuffer
{
public:
    explicit SipHashBuffer(SipHash & hash_) : hash(hash_) {}

    ALWAYS_INLINE void add(T value)
    {
        if constexpr (std::endian::native == std::endian::big)
            DB::transformEndianness<std::endian::little>(value);
        buffer[size] = value;
        ++size;
        if (size == capacity)
            flush();
    }

    ALWAYS_INLINE void flush()
    {
        if (size)
            hash.update(reinterpret_cast<const char *>(buffer), size * sizeof(T));
        size = 0;
    }

private:
    static constexpr size_t capacity = 1024 / sizeof(T);

    SipHash & hash;
    T buffer[capacity];
    size_t size = 0;
};
