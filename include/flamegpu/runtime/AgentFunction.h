#ifndef INCLUDE_FLAMEGPU_RUNTIME_AGENTFUNCTION_H_
#define INCLUDE_FLAMEGPU_RUNTIME_AGENTFUNCTION_H_

#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <curand_kernel.h>

// #include "flamegpu/runtime/flamegpu_device_api.h"

#include "flamegpu/exception/FGPUDeviceException.h"
#include "flamegpu/runtime/AgentFunction_shim.h"
#include "flamegpu/gpu/CUDAScanCompaction.h"


// ! FLAMEGPU function return type
enum FLAME_GPU_AGENT_STATUS { ALIVE = 1, DEAD = 0 };

typedef void(AgentFunctionWrapper)(
#ifndef NO_SEATBELTS
    DeviceExceptionBuffer *error_buffer,
#endif
    Curve::NamespaceHash instance_id_hash,
    Curve::NamespaceHash agent_func_name_hash,
    Curve::NamespaceHash messagename_inp_hash,
    Curve::NamespaceHash messagename_outp_hash,
    Curve::NamespaceHash agent_output_hash,
    const unsigned int popNo,
    const void *in_messagelist_metadata,
    const void *out_messagelist_metadata,
    curandState *d_rng,
    unsigned int *scanFlag_agentDeath,
    unsigned int *scanFlag_messageOutput,
    unsigned int *scanFlag_agentOutput);  // Can't put __global__ in a typedef

typedef void(AgentFunctionEnsembleWrapper)(
#ifndef NO_SEATBELTS
    DeviceExceptionBuffer *error_buffer,
#endif
    unsigned int total_instances,
    unsigned int *instance_offsets,
    Curve::NamespaceHash *instance_id_hash_array,
    Curve::NamespaceHash agent_func_name_hash,
    Curve::NamespaceHash messagename_inp_hash,
    Curve::NamespaceHash messagename_outp_hash,
    Curve::NamespaceHash agent_output_hash,
    const void ** in_messagelist_metadata,
    const void ** out_messagelist_metadata,
    curandState *d_rng,
    unsigned int *scanFlag_agentDeath,
    unsigned int *scanFlag_messageOutput,
    unsigned int *scanFlag_agentOutput);  // Can't put __global__ in a typedef

/**
 * Wrapper function for launching agent functions
 * Initialises FLAMEGPU_API instance
 * @param error_buffer If provided, this buffer is used for reporting device exceptions.
 * @param instance_id_hash CURVE hash of the CUDASimulation's instance id
 * @param agent_func_name_hash CURVE hash of the agent + function's names
 * @param messagename_inp_hash CURVE hash of the input message's name
 * @param messagename_outp_hash CURVE hash of the output message's name
 * @param agent_output_hash CURVE hash of "_agent_birth" or 0 if agent birth not present
 * @param popNo Total number of agents executing the function (number of threads launched)
 * @param in_messagelist_metadata Pointer to the MsgIn metadata struct, it is interpreted by MsgIn
 * @param out_messagelist_metadata Pointer to the MsgOut metadata struct, it is interpreted by MsgOut
 * @param d_rng Array of curand states for this kernel
 * @param scanFlag_agentDeath Scanflag array for agent death
 * @param scanFlag_messageOutput Scanflag array for optional message output
 * @param scanFlag_agentOutput Scanflag array for optional agent output
 * @tparam AgentFunction The modeller defined agent function (defined as FLAMEGPU_AGENT_FUNCTION in model code)
 * @tparam MsgIn Message handler for input messages (e.g. MsgNone, MsgBruteForce, MsgSpatial3D)
 * @tparam MsgOut Message handler for output messages (e.g. MsgNone, MsgBruteForce, MsgSpatial3D)
 */
template<typename AgentFunction, typename MsgIn, typename MsgOut>
__global__ void agent_function_wrapper(
#ifndef NO_SEATBELTS
    DeviceExceptionBuffer *error_buffer,
#endif
    Curve::NamespaceHash instance_id_hash,
    Curve::NamespaceHash agent_func_name_hash,
    Curve::NamespaceHash messagename_inp_hash,
    Curve::NamespaceHash messagename_outp_hash,
    Curve::NamespaceHash agent_output_hash,
    const unsigned int popNo,
    const void *in_messagelist_metadata,
    const void *out_messagelist_metadata,
    curandState *d_rng,
    unsigned int *scanFlag_agentDeath,
    unsigned int *scanFlag_messageOutput,
    unsigned int *scanFlag_agentOutput) {
#ifndef NO_SEATBELTS
    // We place this at the start of shared memory, so we can locate it anywhere in device code without a reference
    extern __shared__ DeviceExceptionBuffer *buff[];
    buff[0] = error_buffer;
#endif
    // Must be terminated here, else AgentRandom has bounds issues inside FLAMEGPU_DEVICE_API constructor
    if (FLAMEGPU_DEVICE_API<MsgIn, MsgOut>::TID() >= popNo)
        return;
    // create a new device FLAME_GPU instance
    FLAMEGPU_DEVICE_API<MsgIn, MsgOut> api = FLAMEGPU_DEVICE_API<MsgIn, MsgOut>(
        instance_id_hash,
        agent_func_name_hash,
        agent_output_hash,
        d_rng,
        scanFlag_agentOutput,
        MsgIn::In(agent_func_name_hash, messagename_inp_hash, in_messagelist_metadata),
        MsgOut::Out(agent_func_name_hash, messagename_outp_hash, out_messagelist_metadata, scanFlag_messageOutput));

    // call the user specified device function
    FLAME_GPU_AGENT_STATUS flag = AgentFunction()(&api);
    if (scanFlag_agentDeath) {
        // (scan flags will not be processed unless agent death has been requested in model definition)
        scanFlag_agentDeath[FLAMEGPU_DEVICE_API<MsgIn, MsgOut>::TID()] = flag;
#ifndef NO_SEATBELTS
    } else if (flag == DEAD) {
        DTHROW("Agent death must be enabled per agent function when defining the model.\n");
#endif
    }
}
/**
 * Wrapper function for launching agent functions as part of an ensemble
 * Initialises FLAMEGPU_API instance
 * @param error_buffer If provided, this buffer is used for reporting device exceptions.
 * @param total_instances Total number of instances in this ensemble launch
 * @param instance_offsets Array of where each instance begins based on global thread index
 * @param instance_id_hash_array Array of instance id hashes, these should be different for each instance
 * @param agent_func_name_hash CURVE hash of the agent + function's names
 * @param messagename_inp_hash CURVE hash of the input message's name
 * @param messagename_outp_hash CURVE hash of the output message's name
 * @param agent_output_hash CURVE hash of "_agent_birth" or 0 if agent birth not present
 * @param in_messagelist_metadata Pointer to the MsgIn metadata struct, it is interpreted by MsgIn
 * @param out_messagelist_metadata Pointer to the MsgOut metadata struct, it is interpreted by MsgOut
 * @param d_rng Array of curand states for this kernel
 * @param scanFlag_agentDeath Scanflag array for agent death
 * @param scanFlag_messageOutput Scanflag array for optional message output
 * @param scanFlag_agentOutput Scanflag array for optional agent output
 * @tparam AgentFunction The modeller defined agent function (defined as FLAMEGPU_AGENT_FUNCTION in model code)
 * @tparam MsgIn Message handler for input messages (e.g. MsgNone, MsgBruteForce, MsgSpatial3D)
 * @tparam MsgOut Message handler for output messages (e.g. MsgNone, MsgBruteForce, MsgSpatial3D)
 */
template<typename AgentFunction, typename MsgIn, typename MsgOut>
__global__ void agent_function_ensemble_wrapper(
#ifndef NO_SEATBELTS
    DeviceExceptionBuffer *error_buffer,
#endif
    unsigned int total_instances,
    unsigned int *instance_offsets,
    Curve::NamespaceHash *instance_id_hash_array,
    Curve::NamespaceHash agent_func_name_hash,
    Curve::NamespaceHash messagename_inp_hash,
    Curve::NamespaceHash messagename_outp_hash,
    Curve::NamespaceHash agent_output_hash,
    const void ** in_messagelist_metadata,
    const void ** out_messagelist_metadata,
    curandState *d_rng,
    unsigned int *scanFlag_agentDeath,
    unsigned int *scanFlag_messageOutput,
    unsigned int *scanFlag_agentOutput) {
#ifndef NO_SEATBELTS
    // We place this at the start of shared memory, so we can locate it anywhere in device code without a reference
    extern __shared__ DeviceExceptionBuffer *buff[];
    buff[0] = error_buffer;
#endif
    // Must be terminated here, else AgentRandom has bounds issues inside FLAMEGPU_DEVICE_API constructor
    if (FLAMEGPU_DEVICE_API<MsgIn, MsgOut>::TID() >= instance_offsets[total_instances])
        return;
    // Perform a search to extract correct instance_id_hash
    // Note this cannot handle active instances with 0 length
    unsigned int min = 0;
    {
        unsigned int max = total_instances;

        while (min + 1 != max) {
            unsigned int tid = FLAMEGPU_DEVICE_API<MsgIn, MsgOut>::TID();
            const unsigned int val = min + ((max-min)/2);
            const unsigned int test = instance_offsets[val];
            if (tid < test) {
                max = val;
            } else if (tid >= test) {
                min = val;
            }
        }
        instance_id_hash = instance_id_hash_array[min];
        instance_id_hash = instance_id_hash_array[min];
        instance_id_hash = instance_id_hash_array[min];
        instance_id_hash = instance_id_hash_array[min];
        instance_id_hash = instance_id_hash_array[min];
    }
    // create a new device FLAME_GPU instance
    FLAMEGPU_DEVICE_API<MsgIn, MsgOut> api = FLAMEGPU_DEVICE_API<MsgIn, MsgOut>(
        instance_id_hash_array[min],
        agent_func_name_hash,
        agent_output_hash,
        d_rng,
        scanFlag_agentOutput,
        MsgIn::In(agent_func_name_hash, messagename_inp_hash, in_messagelist_metadata[min]),
        MsgOut::Out(agent_func_name_hash, messagename_outp_hash, out_messagelist_metadata[min], scanFlag_messageOutput));

    // call the user specified device function
    FLAME_GPU_AGENT_STATUS flag = AgentFunction()(&api);
    if (scanFlag_agentDeath) {
        // (scan flags will not be processed unless agent death has been requested in model definition)
        scanFlag_agentDeath[FLAMEGPU_DEVICE_API<MsgIn, MsgOut>::TID()] = flag;
#ifndef NO_SEATBELTS
    } else if (flag == DEAD) {
        DTHROW("Agent death must be enabled per agent function when defining the model.\n");
#endif
    }
}

#endif  // INCLUDE_FLAMEGPU_RUNTIME_AGENTFUNCTION_H_
