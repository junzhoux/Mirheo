#pragma once

#include "exchanger_interfaces.h"

namespace mirheo
{

class ParticleVector;
class CellList;
class ParticlePacker;

class ParticleHaloExchanger : public Exchanger
{
public:
    ParticleHaloExchanger();
    ~ParticleHaloExchanger();
    
    void attach(ParticleVector *pv, CellList *cl, const std::vector<std::string>& extraChannelNames);

private:
    std::vector<CellList*> cellLists;
    std::vector<ParticleVector*> particles;
    std::vector<std::unique_ptr<ParticlePacker>> packers, unpackers;

    void prepareSizes(size_t id, cudaStream_t stream) override;
    void prepareData (size_t id, cudaStream_t stream) override;
    void combineAndUploadData(size_t id, cudaStream_t stream) override;
    bool needExchange(size_t id) override;
};

} // namespace mirheo
