// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "core/providers/cuda/cu_inc/common.cuh"
#include "gather_impl.h"

#include <cub/device/device_radix_sort.cuh>
#include <cub/device/device_reduce.cuh>
#include <cub/device/device_run_length_encode.cuh>
#include <cub/device/device_scan.cuh>
#include <cub/iterator/counting_input_iterator.cuh>
#include <cub/iterator/discard_output_iterator.cuh>

namespace onnxruntime {
namespace cuda {

__host__ __device__ inline int64_t GetIndexValue(const void* index_data, size_t index_element_size, size_t offset) {
  switch (index_element_size) {
    case sizeof(int32_t):
      return *(reinterpret_cast<const int32_t*>(index_data) + offset);
      break;
    case sizeof(int64_t):
      return *(reinterpret_cast<const int64_t*>(index_data) + offset);
      break;
    default:
      break;
  }
  // What is a sensible thing to do here?
  assert(false);
  return std::numeric_limits<int64_t>::max();
}

template <typename T>
__global__ void _GatherKernel(
    const int64_t input_block_size,
    const int64_t indices_max,
    const fast_divmod output_block_size,
    const fast_divmod block_size,
    const void* indices_data,
    const size_t index_element_size,
    const T* input_data,
    T* output_data,
    const CUDA_LONG N) {
  CALCULATE_ELEMENTWISE_INDEX_OR_EXIT(id, N);
  CUDA_LONG input_index = 0;
  int input_block_index, block_offset;
  output_block_size.divmod(id, input_block_index, block_offset);
  int indices_index, offset;
  block_size.divmod(block_offset, indices_index, offset);
  int64_t idx = GetIndexValue(indices_data, index_element_size, indices_index);
  idx = idx < 0 ? idx + indices_max : idx;
  if (idx < 0 || idx >= indices_max) {
    output_data[id] = 0;
    return;
  }

  input_index = input_block_index * input_block_size + idx * block_size.d_ + offset;
  output_data[id] = input_data[input_index];
}

void GatherImpl(
    cudaStream_t stream,
    const int64_t input_block_size,
    const int64_t indices_max,
    const fast_divmod& output_block_size,
    const fast_divmod& block_size,
    const void* indices_data,
    size_t index_element_size,
    const void* input_data,
    size_t element_size,
    void* output_data,
    const size_t N) {
  int blocksPerGrid = (int)(ceil(static_cast<float>(N) / GridDim::maxThreadsPerBlock));

  switch (element_size) {
    case sizeof(int8_t): {
      using CudaType = typename ToCudaType<int8_t>::MappedType;
      _GatherKernel<<<blocksPerGrid, GridDim::maxThreadsPerBlock, 0, stream>>>(
          input_block_size, indices_max, output_block_size, block_size, indices_data, index_element_size,
          reinterpret_cast<const CudaType*>(input_data), reinterpret_cast<CudaType*>(output_data), (CUDA_LONG)N);

    } break;
    case sizeof(int16_t): {
      using CudaType = typename ToCudaType<int16_t>::MappedType;
      _GatherKernel<<<blocksPerGrid, GridDim::maxThreadsPerBlock, 0, stream>>>(
          input_block_size, indices_max, output_block_size, block_size, indices_data, index_element_size,
          reinterpret_cast<const CudaType*>(input_data), reinterpret_cast<CudaType*>(output_data), (CUDA_LONG)N);

    } break;
    case sizeof(int32_t): {
      using CudaType = typename ToCudaType<int32_t>::MappedType;
      _GatherKernel<<<blocksPerGrid, GridDim::maxThreadsPerBlock, 0, stream>>>(
          input_block_size, indices_max, output_block_size, block_size, indices_data, index_element_size,
          reinterpret_cast<const CudaType*>(input_data), reinterpret_cast<CudaType*>(output_data), (CUDA_LONG)N);

    } break;
    case sizeof(int64_t): {
      using CudaType = typename ToCudaType<int64_t>::MappedType;
      _GatherKernel<<<blocksPerGrid, GridDim::maxThreadsPerBlock, 0, stream>>>(
          input_block_size, indices_max, output_block_size, block_size, indices_data, index_element_size,
          reinterpret_cast<const CudaType*>(input_data), reinterpret_cast<CudaType*>(output_data), (CUDA_LONG)N);

    } break;

    default:
      ORT_THROW("Unsupported element size by the Gather CUDA kernel");
  }
}

template <typename TInputIterator, typename TOutputIterator>
__global__ void CopyKernel(TOutputIterator dst, TInputIterator src, int64_t length) {
  CALCULATE_ELEMENTWISE_INDEX_OR_EXIT(id, length);
  dst[id] = src[id];
}

// get sorted dX and dY indices, ordered by dX indices
template <typename TIndex>
void GetSortedIndices(
    cudaStream_t stream,
    const CudaScratchBufferAllocator& allocator,
    const TIndex* dX_indices,
    GatheredIndexIndex_t num_gathered_indices,
    IAllocatorUniquePtr<TIndex>& dX_indices_sorted_out,
    IAllocatorUniquePtr<TIndex>& dY_indices_sorted_out) {
  auto dY_indices = allocator.GetScratchBuffer<TIndex>(num_gathered_indices);
  CopyKernel<<<CeilDiv(num_gathered_indices, GridDim::maxThreadsPerBlock),
               GridDim::maxThreadsPerBlock, 0, stream>>>(
      dY_indices.get(), cub::CountingInputIterator<TIndex>{0}, num_gathered_indices);

  auto dX_indices_sorted = allocator.GetScratchBuffer<TIndex>(num_gathered_indices);
  auto dY_indices_sorted = allocator.GetScratchBuffer<TIndex>(num_gathered_indices);

  size_t temp_storage_size_bytes = 0;
  CUDA_CALL_THROW(cub::DeviceRadixSort::SortPairs(
      nullptr, temp_storage_size_bytes,
      dX_indices, dX_indices_sorted.get(),
      dY_indices.get(), dY_indices_sorted.get(),
      num_gathered_indices, 0, sizeof(TIndex) * 8, stream));

  auto temp_storage = allocator.GetScratchBuffer<void>(temp_storage_size_bytes);
  CUDA_CALL_THROW(cub::DeviceRadixSort::SortPairs(
      temp_storage.get(), temp_storage_size_bytes,
      dX_indices, dX_indices_sorted.get(),
      dY_indices.get(), dY_indices_sorted.get(),
      num_gathered_indices, 0, sizeof(TIndex) * 8, stream));

  dX_indices_sorted_out = std::move(dX_indices_sorted);
  dY_indices_sorted_out = std::move(dY_indices_sorted);
}

template <typename T>
IAllocatorUniquePtr<T> GetOffsetsFromCounts(
    cudaStream_t stream,
    const CudaScratchBufferAllocator& allocator,
    const T* counts, int32_t num_counts) {
  auto offsets = allocator.GetScratchBuffer<T>(num_counts);
  size_t temp_storage_size_bytes = 0;
  CUDA_CALL_THROW(cub::DeviceScan::ExclusiveSum(
      nullptr, temp_storage_size_bytes,
      counts, offsets.get(), num_counts, stream));

  auto temp_storage = allocator.GetScratchBuffer<void>(temp_storage_size_bytes);
  CUDA_CALL_THROW(cub::DeviceScan::ExclusiveSum(
      temp_storage.get(), temp_storage_size_bytes,
      counts, offsets.get(), num_counts, stream));

  return offsets;
}

constexpr GatheredIndexIndex_t kMaxPartialSegmentSize = 10;

// partial sums implementation adapted from here:
// https://github.com/pytorch/pytorch/blob/b186831c08e0e4e447eedb8a5cfab582995d37f9/aten/src/ATen/native/cuda/EmbeddingBackwardKernel.cu
__global__ void ComputePerSegmentPartialSegmentCountsKernel(
    SegmentIndex_t* ret, const GatheredIndexIndex_t* segment_offsets,
    SegmentIndex_t num_of_segments, GatheredIndexIndex_t num_gathered_indices) {
  const auto id = blockIdx.x * blockDim.x + threadIdx.x;
  if (id < num_of_segments) {
    const auto idx_start = segment_offsets[id];
    const auto idx_end = (id == num_of_segments - 1) ? num_gathered_indices : segment_offsets[id + 1];
    const auto size = idx_end - idx_start;
    ret[id] = CeilDiv(size, kMaxPartialSegmentSize);
  }
}

__global__ void ComputePartialSegmentOffsetsKernel(
    GatheredIndexIndex_t* ret,
    const SegmentIndex_t* partials_per_segment,
    const SegmentIndex_t* partials_per_segment_offset,
    const GatheredIndexIndex_t* segment_offsets,
    SegmentIndex_t num_of_segments) {
  const auto id = blockIdx.x * blockDim.x + threadIdx.x;
  if (id < num_of_segments) {
    auto idx = partials_per_segment_offset[id];
    const auto num_partials = partials_per_segment[id];
    const auto segment_offset = segment_offsets[id];
    for (SegmentIndex_t i = 0; i < num_partials; ++i) {
      ret[idx++] = segment_offset + i * kMaxPartialSegmentSize;
    }
  }
}

// get partial sums of gathered dY values first, then sum the partial sums into
// the corresponding dX value
template <typename TIndex>
void PartialSumsImpl(
    cudaStream_t stream,
    const CudaScratchBufferAllocator& allocator,
    const TIndex* dX_indices_sorted,
    const TIndex* dY_indices_sorted,
    const GatheredIndexIndex_t num_gathered_indices,
    const int64_t num_gathered_per_index,
    const int64_t gather_dimension_size,
    const GatheredIndexIndex_t* segment_offsets,
    const SegmentIndex_t num_segments,
    SegmentIndex_t& last_segment_partial_segment_offset_out,
    SegmentIndex_t& last_segment_partial_segment_count_out,
    IAllocatorUniquePtr<SegmentIndex_t>& per_segment_partial_segment_counts_out,
    IAllocatorUniquePtr<SegmentIndex_t>& per_segment_partial_segment_offsets_out) {
  // each segment is split into partial segments of at most
  // kMaxPartialSegmentSize index pairs.

  // compute the number of partial segments per segment
  auto per_segment_partial_segment_counts = allocator.GetScratchBuffer<SegmentIndex_t>(num_segments);
  {
    const auto blocks_per_grid = CeilDiv(num_gathered_indices, GridDim::maxThreadsPerBlock);
    ComputePerSegmentPartialSegmentCountsKernel<<<blocks_per_grid, GridDim::maxThreadsPerBlock, 0, stream>>>(
        per_segment_partial_segment_counts.get(),
        segment_offsets, num_segments, num_gathered_indices);
  }

  // compute partial segment offsets per segment
  auto per_segment_partial_segment_offsets = GetOffsetsFromCounts(
      stream, allocator, per_segment_partial_segment_counts.get(), num_segments);

  // SegmentIndex_t host_num_partial_segments = 0;
  {
    SegmentIndex_t last_segment_partial_segment_offset = 0,
                   last_segment_partial_segment_count = 0;
    // CPU/GPU sync!
    CUDA_CALL_THROW(cudaMemcpyAsync(
        &last_segment_partial_segment_offset,
        &per_segment_partial_segment_offsets.get()[num_segments - 1],
        sizeof(SegmentIndex_t), cudaMemcpyDeviceToHost, stream));
    // CPU/GPU sync!
    CUDA_CALL_THROW(cudaMemcpyAsync(
        &last_segment_partial_segment_count,
        &per_segment_partial_segment_counts.get()[num_segments - 1],
        sizeof(SegmentIndex_t), cudaMemcpyDeviceToHost, stream));
    CUDA_CALL_THROW(cudaStreamSynchronize(stream));
    // host_num_partial_segments =
    //     last_segment_partial_segment_offset + last_segment_partial_segment_count;

    last_segment_partial_segment_offset_out = last_segment_partial_segment_offset;
    last_segment_partial_segment_count_out = last_segment_partial_segment_count;
  }

  printf("last_segment_partial_segment_offset: %d, last_segment_partial_segment_count: %d\n",
         last_segment_partial_segment_offset_out, last_segment_partial_segment_count_out);

  per_segment_partial_segment_counts_out = std::move(per_segment_partial_segment_counts);
  per_segment_partial_segment_offsets_out = std::move(per_segment_partial_segment_offsets);
}

template <typename TIndex>
void GatherGradPrepare(
    cudaStream_t stream,
    const CudaScratchBufferAllocator& allocator,
    const TIndex* dX_indices,
    const GatheredIndexIndex_t num_gathered_indices,
    int64_t gather_dimension_size,
    int64_t num_gathered_per_index,
    SegmentIndex_t& host_num_segments,
    SegmentIndex_t& last_segment_partial_segment_offset_out,
    SegmentIndex_t& last_segment_partial_segment_count_out,
    IAllocatorUniquePtr<SegmentIndex_t>& per_segment_partial_segment_counts_out,
    IAllocatorUniquePtr<SegmentIndex_t>& per_segment_partial_segment_offsets_out) {
  IAllocatorUniquePtr<TIndex> dX_indices_sorted, dY_indices_sorted;
  GetSortedIndices(
      stream,
      allocator,
      dX_indices, num_gathered_indices,
      dX_indices_sorted, dY_indices_sorted);

  // get number of segments and segment counts
  // SegmentIndex_t host_num_segments = 0;
  auto segment_counts = allocator.GetScratchBuffer<GatheredIndexIndex_t>(num_gathered_indices);
  {
    auto num_segments = allocator.GetScratchBuffer<SegmentIndex_t>(1);
    size_t temp_storage_size_bytes = 0;
    CUDA_CALL_THROW(cub::DeviceRunLengthEncode::Encode(
        nullptr, temp_storage_size_bytes,
        dX_indices_sorted.get(), cub::DiscardOutputIterator<TIndex>{}, segment_counts.get(),
        num_segments.get(), num_gathered_indices, stream));

    auto temp_storage = allocator.GetScratchBuffer<void>(temp_storage_size_bytes);
    CUDA_CALL_THROW(cub::DeviceRunLengthEncode::Encode(
        temp_storage.get(), temp_storage_size_bytes,
        dX_indices_sorted.get(), cub::DiscardOutputIterator<TIndex>{}, segment_counts.get(),
        num_segments.get(), num_gathered_indices, stream));

    // CPU/GPU sync!
    CUDA_CALL_THROW(cudaMemcpyAsync(
        &host_num_segments, num_segments.get(), sizeof(SegmentIndex_t), cudaMemcpyDeviceToHost, stream));
    CUDA_CALL_THROW(cudaStreamSynchronize(stream));
  }

  // constexpr GatheredIndexIndex_t kMaxSegmentSizeThreshold = 32;
  // if (host_max_segment_count <= kMaxSegmentSizeThreshold) {
  //   DirectSumImpl(
  //       stream, dX_indices_sorted.get(), dY_indices_sorted.get(),
  //       dY_data, dX_data,
  //       num_gathered_indices, num_gathered_per_index, gather_dimension_size, num_batches);
  // } else {
  {
    auto segment_offsets = GetOffsetsFromCounts(
        stream, allocator, segment_counts.get(), host_num_segments);
    segment_counts.reset();

    PartialSumsImpl(
        stream,
        allocator,
        dX_indices_sorted.get(), dY_indices_sorted.get(),
        num_gathered_indices, num_gathered_per_index, gather_dimension_size,
        segment_offsets.get(), host_num_segments,
        last_segment_partial_segment_offset_out, last_segment_partial_segment_count_out,
        per_segment_partial_segment_counts_out, per_segment_partial_segment_offsets_out);
  }
}

#define SPECIALIZED(TIndex)                                                        \
  template void GatherGradPrepare<TIndex>(                                         \
      cudaStream_t stream,                                                         \
      const CudaScratchBufferAllocator& allocator,                                 \
      const TIndex* dX_indices,                                                    \
      const GatheredIndexIndex_t num_gathered_indices,                             \
      int64_t gather_dimension_size,                                               \
      int64_t num_gathered_per_index,                                              \
      SegmentIndex_t& host_num_segments,                                           \
      SegmentIndex_t& last_segment_partial_segment_offset_out,                     \
      SegmentIndex_t& last_segment_partial_segment_count_out,                      \
      IAllocatorUniquePtr<SegmentIndex_t>& per_segment_partial_segment_counts_out, \
      IAllocatorUniquePtr<SegmentIndex_t>& per_segment_partial_segment_offsets_out);

SPECIALIZED(int32_t)
SPECIALIZED(int64_t)

#undef SPECIALIZED

}  // namespace cuda
}  // namespace onnxruntime
