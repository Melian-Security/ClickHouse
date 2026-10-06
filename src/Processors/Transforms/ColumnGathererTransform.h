#pragma once

#include <IO/ReadBuffer.h>
#include <Common/PODArray.h>
#include <Processors/Merges/Algorithms/IMergingAlgorithm.h>
#include <Processors/Merges/IMergingTransform.h>

namespace Poco { class Logger; }


namespace DB
{


/// Tiny struct, stores number of a Part from which current row was fetched, and insertion flag.
struct RowSourcePart
{
    UInt8 data = 0;

    RowSourcePart() = default;

    explicit RowSourcePart(size_t source_num, bool skip_flag = false)
    {
        static_assert(sizeof(*this) == 1, "Size of RowSourcePart is too big due to compiler settings");
        setSourceNum(source_num);
        setSkipFlag(skip_flag);
    }

    size_t getSourceNum() const { return data & MASK_NUMBER; }

    /// In CollapsingMergeTree case flag means "skip this rows"
    bool getSkipFlag() const { return (data & MASK_FLAG) != 0; }

    void setSourceNum(size_t source_num)
    {
        data = (data & MASK_FLAG) | (static_cast<UInt8>(source_num) & MASK_NUMBER);
    }

    void setSkipFlag(bool flag)
    {
        data = flag ? data | MASK_FLAG : data & ~MASK_FLAG;
    }

    static constexpr size_t MAX_PARTS = 0x7F;
    static constexpr UInt8 MASK_NUMBER = 0x7F;
    static constexpr UInt8 MASK_FLAG = 0x80;
};

using MergedRowSources = PODArray<RowSourcePart>;


/** Gather single stream from multiple streams according to streams mask.
  * Stream mask maps row number to index of source stream.
  * Streams should contain exactly one column.
  */
class ColumnGathererStream final : public IMergingAlgorithm
{
public:
    ColumnGathererStream(
        size_t num_inputs,
        ReadBuffer & row_sources_buf_,
        size_t block_preferred_size_rows_,
        size_t block_preferred_size_bytes_,
        std::optional<size_t> max_dynamic_subcolumns_,
        bool is_result_sparse_);

    const char * getName() const override { return "ColumnGathererStream"; }
    void initialize(Inputs inputs) override;
    void consume(Input & input, size_t source_num) override;
    Status merge() override;

    /// for use in implementations of IColumn::gather()
    template <typename Column>
    void gather(Column & column_res);

    /// Consecutive rows of one source block.
    struct Range
    {
        const IColumn * column;
        size_t start;
        size_t length;
    };

    /// For use in implementations of IColumn::gather() of columns that insert several ranges at once faster than
    /// one at a time, for example subcolumn by subcolumn. Produces the same column and the same block boundaries
    /// as `gather`. `insert_ranges(ranges)` must have the same effect as inserting `ranges` in order with
    /// insertFrom / insertRangeFrom. The column must also satisfy:
    /// - byteSize does not decrease when rows are inserted;
    /// - popBack of the rows inserted last brings the column back to the state it had before inserting them.
    template <typename Column, typename InsertRanges>
    void gatherInBatches(Column & column_res, InsertRanges && insert_ranges);

    MergedStats getMergedStats() const override { return {.bytes = merged_bytes, .rows = merged_rows, .blocks = merged_blocks}; }

private:
    void updateStats(const IColumn & column);

    /// Cache required fields
    struct Source
    {
        ColumnPtr column;
        size_t pos = 0;
        size_t size = 0;

        void update(ColumnPtr column_);
    };

    MutableColumnPtr result_column;

    std::vector<Source> sources;
    ReadBuffer & row_sources_buf;

    const size_t block_preferred_size_rows;
    const size_t block_preferred_size_bytes;
    const std::optional<size_t> max_dynamic_subcolumns;
    const bool is_result_sparse;

    Source * source_to_fully_copy = nullptr;

    /// A range of the batch being inserted by `gatherInBatches`, and where it ends in row sources.
    struct BatchRange
    {
        size_t source_num;
        size_t start;
        size_t length;
        bool skip;
        RowSourcePart * row_sources_end;
    };

    std::vector<BatchRange> batch;
    std::vector<Range> batch_ranges;

    ssize_t next_required_source = -1;
    UInt64 merged_rows = 0;
    UInt64 merged_bytes = 0;
    UInt64 merged_blocks = 0;
};

class ColumnGathererTransform final : public IMergingTransform<ColumnGathererStream>
{
public:
    ColumnGathererTransform(
        SharedHeader header,
        size_t num_inputs,
        std::unique_ptr<ReadBuffer> row_sources_buf_,
        size_t block_preferred_size_rows_,
        size_t block_preferred_size_bytes_,
        std::optional<size_t> max_dynamic_subcolumns_,
        bool is_result_sparse_);

    String getName() const override { return "ColumnGathererTransform"; }

protected:
    void onFinish() override;

    std::unique_ptr<ReadBuffer> row_sources_buf_holder; /// Keep ownership of row_sources_buf while it's in use by ColumnGathererStream.
    LoggerPtr log;
};


template <typename Column>
void ColumnGathererStream::gather(Column & column_res)
{
    row_sources_buf.nextIfAtEnd();
    RowSourcePart * row_source_pos = reinterpret_cast<RowSourcePart *>(row_sources_buf.position());
    RowSourcePart * row_sources_end = reinterpret_cast<RowSourcePart *>(row_sources_buf.buffer().end());

    if (next_required_source == -1)
    {
        /// Start new column.
        /// Actually reserve works only for fixed size columns.
        /// So it's safe to ignore preferred size in bytes and call reserve for number of rows.
        size_t size_to_reserve = std::min(static_cast<size_t>(row_sources_end - row_source_pos), block_preferred_size_rows);
        column_res.reserve(size_to_reserve);
    }

    next_required_source = -1;

    /// We use do ... while here to ensure there will be at least one iteration of this loop.
    /// Because the column_res.byteSize() could be bigger than block_preferred_size_bytes already at this point.
    do
    {
        if (row_source_pos >= row_sources_end)
            break;

        RowSourcePart row_source = *row_source_pos;
        size_t source_num = row_source.getSourceNum();
        Source & source = sources[source_num];
        bool source_skip = row_source.getSkipFlag();

        if (source.pos >= source.size) /// Fetch new block from source_num part
        {
            next_required_source = source_num;
            return;
        }

        ++row_source_pos;

        /// Consecutive optimization. TODO: precompute lengths
        size_t len = 1;
        size_t max_len = std::min(static_cast<size_t>(row_sources_end - row_source_pos), source.size - source.pos); // interval should be in the same block

        while (len < max_len && row_source_pos->data == row_source.data)
        {
            ++len;
            ++row_source_pos;
        }

        row_sources_buf.position() = reinterpret_cast<char *>(row_source_pos);

        if (!source_skip)
        {
            /// Whole block could be produced via copying pointer from current block
            if (source.pos == 0 && source.size == len)
            {
                /// If current block already contains data, return it.
                /// Whole column from current source will be returned on next read() iteration.
                source_to_fully_copy = &source;
                return;
            }
            if (len == 1)
                column_res.insertFrom(*source.column, source.pos);
            else
                column_res.insertRangeFrom(*source.column, source.pos, len);
        }

        source.pos += len;
    } while (column_res.size() < block_preferred_size_rows && column_res.byteSize() < block_preferred_size_bytes);
}

template <typename Column, typename InsertRanges>
void ColumnGathererStream::gatherInBatches(Column & column_res, InsertRanges && insert_ranges)
{
    row_sources_buf.nextIfAtEnd();
    RowSourcePart * row_source_pos = reinterpret_cast<RowSourcePart *>(row_sources_buf.position());
    RowSourcePart * row_sources_end = reinterpret_cast<RowSourcePart *>(row_sources_buf.buffer().end());

    if (next_required_source == -1)
    {
        size_t size_to_reserve = std::min(static_cast<size_t>(row_sources_end - row_source_pos), block_preferred_size_rows);
        column_res.reserve(size_to_reserve);
    }

    next_required_source = -1;

    /// `gather` checks the limits on the block size after every range. Here they are checked after every batch of
    /// ranges. The byte size only grows with inserts, so if it is below the limit after a batch, it was below the
    /// limit after each range of the batch, and `gather` would not have stopped inside it. Otherwise the batch is
    /// removed and inserted again range by range, as `gather` does.
    /// To make that rare, a batch is sized to fill about half of the bytes left, judging by the bytes per row so far.
    size_t bytes = column_res.byteSize();
    double bytes_per_row = 0;
    if (row_source_pos < row_sources_end)
    {
        const auto & first_source = sources[row_source_pos->getSourceNum()];
        if (first_source.size)
            bytes_per_row = static_cast<double>(first_source.column->byteSize()) / static_cast<double>(first_source.size);
    }

    while (true)
    {
        size_t max_batch_rows = block_preferred_size_rows;
        if (bytes_per_row > 0)
        {
            double bytes_left = bytes < block_preferred_size_bytes ? static_cast<double>(block_preferred_size_bytes - bytes) : 0;
            max_batch_rows = static_cast<size_t>(std::min(bytes_left / 2 / bytes_per_row, static_cast<double>(block_preferred_size_rows)));
        }
        max_batch_rows = std::max<size_t>(max_batch_rows, 1);

        batch.clear();
        batch_ranges.clear();
        size_t batch_rows = 0;
        /// What `gather` would do after this batch if it does not stop inside it.
        bool stop = false;
        ssize_t required_source = -1;
        Source * fully_copy_source = nullptr;
        RowSourcePart * fully_copy_end = nullptr;

        do
        {
            if (row_source_pos >= row_sources_end)
            {
                stop = true;
                break;
            }

            RowSourcePart row_source = *row_source_pos;
            size_t source_num = row_source.getSourceNum();
            Source & source = sources[source_num];
            bool source_skip = row_source.getSkipFlag();

            if (source.pos >= source.size)
            {
                required_source = source_num;
                break;
            }

            RowSourcePart * range_end = row_source_pos + 1;
            size_t len = 1;
            size_t max_len = std::min(static_cast<size_t>(row_sources_end - range_end), source.size - source.pos);
            while (len < max_len && range_end->data == row_source.data)
            {
                ++len;
                ++range_end;
            }

            if (!source_skip && source.pos == 0 && source.size == len)
            {
                fully_copy_source = &source;
                fully_copy_end = range_end;
                break;
            }

            batch.push_back({source_num, source.pos, len, source_skip, range_end});
            if (!source_skip)
            {
                batch_ranges.push_back({source.column.get(), source.pos, len});
                batch_rows += len;
            }
            source.pos += len;
            row_source_pos = range_end;

            if (column_res.size() + batch_rows >= block_preferred_size_rows)
                stop = true;
        } while (!stop && batch_rows < max_batch_rows);

        size_t bytes_before_batch = bytes;
        if (!batch_ranges.empty())
            insert_ranges(batch_ranges);
        bytes = column_res.byteSize();

        /// A batch of one range was inserted the same way as by `gather`, which stops after it.
        if (batch.size() == 1 && bytes >= block_preferred_size_bytes)
        {
            row_sources_buf.position() = reinterpret_cast<char *>(row_source_pos);
            return;
        }

        if (!batch.empty() && bytes >= block_preferred_size_bytes)
        {
            column_res.popBack(batch_rows);
            for (size_t i = 0; i != batch.size(); ++i)
            {
                const auto & range = batch[i];
                if (!range.skip)
                {
                    const auto & column = *sources[range.source_num].column;
                    if (range.length == 1)
                        column_res.insertFrom(column, range.start);
                    else
                        column_res.insertRangeFrom(column, range.start, range.length);
                }

                if (column_res.size() >= block_preferred_size_rows || column_res.byteSize() >= block_preferred_size_bytes)
                {
                    /// Give the rows of the remaining ranges back to their sources.
                    for (size_t j = batch.size() - 1; j > i; --j)
                        sources[batch[j].source_num].pos = batch[j].start;
                    row_sources_buf.position() = reinterpret_cast<char *>(range.row_sources_end);
                    return;
                }
            }
        }

        row_sources_buf.position() = reinterpret_cast<char *>(row_source_pos);

        if (stop)
            return;

        if (required_source != -1)
        {
            next_required_source = required_source;
            return;
        }

        if (fully_copy_source)
        {
            row_sources_buf.position() = reinterpret_cast<char *>(fully_copy_end);
            source_to_fully_copy = fully_copy_source;
            return;
        }

        if (batch_rows)
            bytes_per_row = static_cast<double>(bytes - bytes_before_batch) / static_cast<double>(batch_rows);
    }
}

}
