#include "particles.h"
#include "common.h"
#include "shifters.h"

#include <core/pvs/particle_vector.h>
#include <core/utils/cuda_common.h>
#include <core/utils/kernel_launch.h>

#include <type_traits>

namespace ParticlePackerKernels
{
template <typename T>
__global__ void packToBuffer(int n, const MapEntry *map, const size_t *offsetsBytes, const int *offsets, const T *srcData, char *buffer)
{
    int i = threadIdx.x + blockIdx.x * blockDim.x;
    if (i > n) return;

    auto m = map[i];
    int buffId = m.getBufId();
    int  srcId = m.getId();

    T *dstData = (T*) (buffer + offsetsBytes[buffId]);
    int dstId = i - offsets[buffId];
    
    dstData[dstId] = srcData[srcId]; // TODO shift
}

template <typename T>
__global__ void unpackFromBuffer(int nBuffers, const int *offsets, int n, const char *buffer, const size_t *offsetsBytes, T *dstData)
{
    int i = threadIdx.x + blockIdx.x * blockDim.x;

    extern __shared__ int sharedOffsets[];

    for (int i = threadIdx.x; i < nBuffers; i += blockDim.x)
        sharedOffsets[i] = offsets[i];
    __syncthreads();

    if (i > n) return;
    
    int buffId = dispatchThreadsPerBuffer(nBuffers, sharedOffsets, i);
    int pid = i - sharedOffsets[buffId];
    
    const T *srcData = (const T*) (buffer + offsetsBytes[buffId]);

    dstData[pid] = srcData[pid]; // TODO shift
}

} // namespace ParticlePackerKernels

ParticlePacker::ParticlePacker(ParticleVector *pv, LocalParticleVector *lpv, PackPredicate predicate) :
    Packer(pv, lpv, predicate)
{}

size_t ParticlePacker::getPackedSizeBytes(int n)
{
    return _getPackedSizeBytes(lpv->dataPerParticle, n);
}

void ParticlePacker::packToBuffer(const DeviceBuffer<MapEntry>& map, const PinnedBuffer<int>& sizes,
                                  const PinnedBuffer<int>& offsets, char *buffer, cudaStream_t stream)
{
    auto& manager = lpv->dataPerParticle;

    offsetsBytes.resize_anew(offsets.size());
    offsetsBytes.clear(stream);
    updateOffsets<float4>(sizes.size(), sizes.devPtr(), offsetsBytes.devPtr(), stream); // positions
    
    for (const auto& name_desc : manager.getSortedChannels())
    {
        if (!predicate(name_desc)) continue;
        auto& desc = name_desc.second;

        auto packChannel = [&](auto pinnedBuffPtr)
        {
            using T = typename std::remove_pointer<decltype(pinnedBuffPtr)>::type::value_type;

            int n = map.size();
            const int nthreads = 128;

            SAFE_KERNEL_LAUNCH(
                ParticlePackerKernels::packToBuffer,
                getNblocks(n, nthreads), nthreads, 0, stream,
                n, map.devPtr(), offsetsBytes.devPtr(), offsets.devPtr(),
                pinnedBuffPtr->devPtr(), buffer);

            updateOffsets<T>(sizes.size(), sizes.devPtr(), offsetsBytes.devPtr(), stream);
        };
        
        mpark::visit(packChannel, desc->varDataPtr);
    }
}

void ParticlePacker::unpackFromBuffer(const PinnedBuffer<int>& offsets, const PinnedBuffer<int>& sizes,
                                      const char *buffer, cudaStream_t stream)
{
    auto& manager = lpv->dataPerParticle;

    offsetsBytes.resize_anew(offsets.size());
    offsetsBytes.clear(stream);
    updateOffsets<float4>(sizes.size(), sizes.devPtr(), offsetsBytes.devPtr(), stream); // positions

    for (const auto& name_desc : manager.getSortedChannels())
    {
        if (!predicate(name_desc)) continue;
        auto& desc = name_desc.second;

        auto unpackChannel = [&](auto pinnedBuffPtr)
        {
            using T = typename std::remove_pointer<decltype(pinnedBuffPtr)>::type::value_type;

            int nBuffers = sizes.size();
            int n = offsets[nBuffers];
            const int nthreads = 128;
            const size_t sharedMem = nBuffers * sizeof(int);

            SAFE_KERNEL_LAUNCH(
                ParticlePackerKernels::unpackFromBuffer,
                getNblocks(n, nthreads), nthreads, sharedMem, stream,
                nBuffers, offsets.devPtr(), n, buffer,
                offsetsBytes.devPtr(), pinnedBuffPtr->devPtr());

            updateOffsets<T>(sizes.size(), sizes.devPtr(), offsetsBytes.devPtr(), stream);
        };
        
        mpark::visit(unpackChannel, desc->varDataPtr);
    }
}