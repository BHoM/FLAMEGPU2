#ifndef INCLUDE_FLAMEGPU_GPU_CUDASIMULATION_H_
#define INCLUDE_FLAMEGPU_GPU_CUDASIMULATION_H_
#include <atomic>
#include <memory>
#include <vector>
#include <string>
#include <unordered_map>
#include <map>
#include <set>

#include "flamegpu/exception/FLAMEGPUDeviceException.cuh"
#include "flamegpu/sim/Simulation.h"
#include "flamegpu/runtime/detail/curve/curve.cuh"
#include "flamegpu/gpu/CUDAScatter.cuh"
#include "flamegpu/gpu/CUDAEnsemble.h"
#include "flamegpu/runtime/utility/RandomManager.cuh"
#include "flamegpu/runtime/HostNewAgentAPI.h"
#include "flamegpu/gpu/CUDAMacroEnvironment.h"

#ifdef VISUALISATION
#include "flamegpu/visualiser/ModelVis.h"
#endif

#ifdef _MSC_VER
#pragma warning(push, 2)
#include "jitify/jitify.hpp"
#pragma warning(pop)
#else
#include "jitify/jitify.hpp"
#endif

namespace flamegpu {

class AgentVector;
class CUDAAgent;
class CUDAMessage;
class LoggingConfig;
class StepLoggingConfig;
class RunPlan;

struct RunLog;

/**
 * CUDA runner for Simulation interface
 * Executes a FLAMEGPU2 model using GPU
 */
class CUDASimulation : public Simulation {
    /**
     * Requires internal access to scan/scatter singletons
     */
    friend class HostAgentAPI;
    friend class SimRunner;
    /**
     * Map of a number of CUDA agents by name.
     * The CUDA agents are responsible for allocating and managing all the device memory
     */
    typedef std::unordered_map<std::string, std::unique_ptr<CUDAAgent>> CUDAAgentMap;
    /**
     * Map of a number of CUDA messages by name.
     * The CUDA messages are responsible for allocating and managing all the device memory
     */
    typedef std::unordered_map<std::string, std::unique_ptr<CUDAMessage>> CUDAMessageMap;
    /**
     * Map of a number of CUDA sub models by name.
     * The CUDA submodels are responsible for allocating and managing all the device memory of non mapped agent vars
     * Ordered is used, so that random seed mutation always occurs same order.
     */
    typedef std::map<std::string, std::unique_ptr<CUDASimulation>> CUDASubModelMap;

 public:
    /**
     * CUDA runner specific config
     */
    struct Config {
        /**
         * GPU to execute model on
         * Defaults to device 0, this is most performant device as detected by CUDA
         */
        int device_id = 0;
        /**
         * Enable / disable the use of concurrency within a layer.
         * Defaults to enabled.
         */
        bool inLayerConcurrency = true;
    };
    /**
     * Initialise cuda runner
     * Allocates memory for agents/messages, copies environment properties to device etc
     * If provided, you can pass runtime arguments to this constructor, to automatically call inititialise()
     * This is not required, you can call inititialise() manually later, or not at all.
     * @param model The model description to initialise the runner to execute
     * @param argc Runtime argument count
     * @param argv Runtime argument list ptr
     */
    explicit CUDASimulation(const ModelDescription& model, int argc = 0, const char** argv = nullptr);

 private:
    /**
     * Alt constructor used by CUDAEnsemble
     */
    explicit CUDASimulation(const std::shared_ptr<const ModelData> &model);
    /**
     * Private constructor, used to initialise submodels
     * Allocates CUDASubAgents, and handles mappings
     * @param submodel_desc The submodel description of the submodel (this should be from the already cloned model hierarchy)
     * @param master_model The CUDASimulation of the master model
     * @todo Move common components (init list and initOffsetsAndMap()) into a common/shared constructor
     */
    CUDASimulation(const std::shared_ptr<SubModelData>& submodel_desc, CUDASimulation *master_model);

 public:
    /**
     * Inverse operation of contructor
     */
    virtual ~CUDASimulation();
    /**
     * Run the initFunctions of Simulation
     */
    void initFunctions() override;
    /**
     * Steps the simulation once
     * @return False if an exit condition was triggered
     */
    bool step() override;
    /**
     * Run the exitFunctions of the Simulation.. 
     */
    void exitFunctions() override;
    /**
     * Execute the simulation until config.steps have been executed, or an exit condition trips
     * Includes init and exit functions calls.
     */
    void simulate() override;
    /**
     * Execute the simulation using the configuration and environment properties from the provided RunPlan
     * @param plan The RunPlan to use to execute the simulation
     *
     * @throw exception::InvalidArgument If the provided RunPlan does not match the CUDASimulation's ModelDescription
     * @note The config.steps and config.random_seed values will be ignored, in favour of those provided by the RunPlan
     */
    void simulate(const RunPlan &plan);
    /**
     * Replaces internal population data for the specified agent
     * @param population The agent type and data to replace agents with
     * @param state_name The agent state to add the agents to
     * @throw exception::InvalidCudaAgent If the agent type is not recognised
     */
    void setPopulationData(AgentVector& population, const std::string &state_name = ModelData::DEFAULT_STATE) override;
    /**
     * Returns the internal population data for the specified agent
     * @param population The agent type and data to fetch
     * @param state_name The agent state to get the agents from
     * @throw exception::InvalidCudaAgent If the agent type is not recognised
     */
    void getPopulationData(AgentVector& population, const std::string& state_name = ModelData::DEFAULT_STATE) override;
    /**
     * Update the current value of the named environment property
     * @param property_name Name of the environment property to be updated
     * @param value New value for the named environment property
     * @tparam T Type of the environment property
     * @throws exception::InvalidEnvPropertyType If the named environment property does not exist with the specified type
     * @throws exception::ReadOnlyEnvProperty If the named environment property is marked as read-only
     */
    template<typename T>
    void setEnvironmentProperty(const std::string &property_name, const T& value);
    /**
     * Update the current value of the named environment property array
     * @param property_name Name of the environment property to be updated
     * @param value New value for the named environment property
     * @tparam T Type of the elements of the environment property array
     * @throws exception::InvalidEnvPropertyType If the named environment property does not exist with the specified type
     * @throws exception::ReadOnlyEnvProperty If the named environment property is marked as read-only
     */
    template<typename T, unsigned int N>
    void setEnvironmentProperty(const std::string &property_name, const std::array<T, N> &value);
    /**
     * Update the value of the specified element of the named environment property array
     * @param property_name Name of the environment property to be updated
     * @param index Index of the element within the property array to be updated
     * @param value New value for the named environment property
     * @tparam T Type of the elements of the environment property array
     * @throws exception::InvalidEnvPropertyType If the named environment property does not exist with the specified type
     * @throws exception::ReadOnlyEnvProperty If the named environment property is marked as read-only
     */
    template<typename T>
    void setEnvironmentProperty(const std::string& property_name, const EnvironmentManager::size_type &index, const T& value);
#ifdef SWIG
    /**
     * Update the current value of the named environment property array
     * @param property_name Name of the environment property to be updated
     * @param value New value for the named environment property
     * @tparam T Type of the elements of the environment property array
     * @return Returns the previous value
     * @throws exception::InvalidEnvPropertyType If the named environment property does not exist with the specified type
     * @throws exception::ReadOnlyEnvProperty If the named environment property is marked as read-only
     */
    template<typename T>
    void setEnvironmentPropertyArray(const std::string& property_name, const std::vector<T>& value);
#endif
    /**
     * Return the current value of the named environment property
     * @param property_name Name of the environment property to be returned
     * @tparam T Type of the environment property
     * @throws exception::InvalidEnvPropertyType If the named environment property does not exist with the specified type
     */
    template<typename T>
    T getEnvironmentProperty(const std::string &property_name);
    /**
     * Return the current value of the named environment property array
     * @param property_name Name of the environment property to be returned
     * @tparam T Type of the elements of the environment property array
     * @throws exception::InvalidEnvPropertyType If the named environment property does not exist with the specified type
     */
    template<typename T, unsigned int N>
    std::array<T, N> getEnvironmentProperty(const std::string &property_name);
    /**
     * Return the current value of the specified element of the named environment property array
     * @param property_name Name of the environment property to be returned
     * @param index Index of the element within the property array to be returned
     * @tparam T Type of the elements of the environment property array
     * @throws exception::InvalidEnvPropertyType If the named environment property does not exist with the specified type
     */
    template<typename T>
    T getEnvironmentProperty(const std::string& property_name, const EnvironmentManager::size_type& index);
#ifdef SWIG
    /**
     * Return the current value of the named environment property array
     * @param property_name Name of the environment property to be updated
     * @tparam T Type of the elements of the environment property array
     * @throws exception::InvalidEnvProperty If a property array of the name does not exist
     */
    template<typename T>
    std::vector<T> getEnvironmentPropertyArray(const std::string& property_name);
#endif
    /**
     * Returns the manager for the specified agent
     * @todo remove? this is mostly internal methods that modeller doesn't need access to
     */
    CUDAAgent& getCUDAAgent(const std::string &agent_name) const;
    AgentInterface &getAgent(const std::string &name) override;
    /**
     * Returns the manager for the specified agent
     * @todo remove? this is mostly internal methods that modeller doesn't need access to
     */
    CUDAMessage& getCUDAMessage(const std::string &message_name) const;
    /**
     * @return A mutable reference to the cuda model specific configuration struct
     * @see Simulation::applyConfig() Should be called afterwards to apply changes
     */
    Config &CUDAConfig();
    /**
     * Returns the number of times step() has been called since the simulation was last reset/init
     */
    unsigned int getStepCounter() override;
    /**
     * Manually resets the step counter
     */
    void resetStepCounter() override;
    /**
     * @return An immutable reference to the cuda model specific configuration struct
     */
    const Config &getCUDAConfig() const;
    /**
     * Configure which step data should be logged
     * @param stepConfig The step logging config for the CUDASimulation
     * @note This must be for the same model description hierarchy as the CUDASimulation
     */
    void setStepLog(const StepLoggingConfig &stepConfig);
    /**
     * Configure which exit data should be logged
     * @param exitConfig The logging config for the CUDASimulation
     * @note This must be for the same model description hierarchy as the CUDASimulation
     */
    void setExitLog(const LoggingConfig &exitConfig);
    /**
     * Returns a reference to the current exit log
     */
    const RunLog &getRunLog() const override;
#ifdef VISUALISATION
    /**
     * Creates (on first call) and returns the visualisation configuration options for this model instance
     */
    visualiser::ModelVis &getVisualisation();
#endif

    /**
     * Performs a cudaMemCopyToSymbol in the runtime library and also updates the symbols of any RTC functions (which exist separately within their own cuda module)
     * Will thrown an error if any of the calls fail.
     * @param symbol A device symbol
     * @param rtc_symbol_name The name of the symbol
     * @param src Source memory address
     * @param count Size in bytes to copy
     * @param offset Offset from start of symbol in bytes
     */
    void RTCSafeCudaMemcpyToSymbol(const void* symbol, const char* rtc_symbol_name, const void* src, size_t count, size_t offset = 0) const;

    /**
     * Performs a cudaMemCopy to a pointer in the runtime library and also updates the symbols of any RTC functions (which exist separately within their own cuda module)
     * Will thrown an error if any of the calls fail.
     * @param ptr a pointer to a symbol in device memory
     * @param rtc_symbol_name The name of the symbol
     * @param src Source memory address
     * @param count Size in bytes to copy
     * @param offset Offset from start of symbol in bytes
     */
    void RTCSafeCudaMemcpyToSymbolAddress(void* ptr, const char* rtc_symbol_name, const void* src, size_t count, size_t offset = 0) const;

   /**
     * Get the duration of the last time RTC was iniitliased 
     * @return elapsed time of last simulation call in seconds.
     */
    double getElapsedTimeRTCInitialisation() const;

    /**
     * Get the duration of the last call to simulate() in seconds. 
     * @return elapsed time of last simulation call in seconds.
     */
    double getElapsedTimeSimulation() const;

    /**
     * Get the duration of the last call to initFunctions() in seconds. 
     * @return elapsed time of last simulation call in seconds.
     */
    double getElapsedTimeInitFunctions() const;

    /**
     * Get the duration of the last call to stepFunctions() in seconds. 
     * @return elapsed time of last simulation call in seconds.
     */
    double getElapsedTimeExitFunctions() const;

    /**
     * Get the duration of each step() since the last call to `reset`
     * @return vector of step times 
     */
    std::vector<double> getElapsedTimeSteps() const;

    /** 
     * Get the duration of an individual step in seconds.
     * @param step Index of step, must be less than the number of steps executed.
     * @return elapsed time of required step in seconds
     */
    double getElapsedTimeStep(unsigned int step) const;

    /**
     * Returns the unique instance id of this CUDASimulation instance
     * @note This value is used internally for environment property storage
     */
    using Simulation::getInstanceID;

 protected:
    /**
     * Returns the model to a clean state
     * This clears all agents and message lists, resets environment properties and reseeds random generation.
     * Also calls resetStepCounter();
     * @param submodelReset This should only be set to true when called automatically when a submodel reaches it's exit condition during execution. This performs a subset of the regular reset procedure.
     * @note If triggered on a submodel, agent states and environment properties mapped to a parent agent, and random generation are not affected.
     * @note If random was manually seeded, it will return to it's original state. If random was seeded from time, it will return to a new random state.
     */
    void reset(bool submodelReset) override;
    /**
     * Called by Simulation::applyConfig() to trigger any runner specific configs
     * @see CUDASimulation::CUDAConfig()
     */
    void applyConfig_derived() override;
    /**
     * Called by Simulation::checkArgs() to trigger any runner specific argument checking
     * This only handles arg 0 before returning
     * @return True if the argument was handled successfully
     * @see Simulation::checkArgs()
     */
    bool checkArgs_derived(int argc, const char** argv, int &i) override;
    /**
     * Called by Simulation::printHelp() to print help for runner specific runtime args
     * @see Simulation::printHelp()
     */
    void printHelp_derived() override;
    /**
     * Called at the start of Simulation::initialise(int, const char**) to reset runner specific config struct
     * @see Simulation::initialise(int, const char**)
     */
    void resetDerivedConfig() override;

 private:
    /**
     * Reinitalises random generation for this model and all submodels
     * @param seed New random seed (this updates stored seed in config)
     */
    void reseed(const uint64_t &seed);
    /**
     * Number of times step() has been called since sim was last reset/init
     */
    unsigned int step_count;
    /**
     * Duration of the last call to simulate() in seconds
     */
    double elapsedSecondsSimulation;
    /**
     * Duration of the last call to initFunctions() in seconds
     */
    double elapsedSecondsInitFunctions;
    /**
     * Duration of the last call to exitFunctions() in seconds
     */
    double elapsedSecondsExitFunctions;
   /**
     * Duration of the last call to initialiseRTC() in seconds
     */
    double elapsedSecondsRTCInitialisation;

    /**
     * Vector of per step timing information in seconds
     */
    std::vector<double> elapsedSecondsPerStep;
    /**
     * Update the step counter for host and device.
     */
    void incrementStepCounter();
    /**
     * Map of agent storage 
     */
    CUDAAgentMap agent_map;
    /**
     * Macro env property storage
     */
    CUDAMacroEnvironment macro_env;
    /**
     * Internal model config
     */
    Config config;
    /**
     * Step logging config
     */
    std::shared_ptr<const StepLoggingConfig> step_log_config;
    /**
     * Exit logging config
     */
    std::shared_ptr<const LoggingConfig> exit_log_config;
    /**
     * Collection of currently logged data
     */
    std::unique_ptr<RunLog> run_log;
    /**
     * Clear and reinitialise the current run_log
     */
    void resetLog();
    /**
     * Check if step_count is a divisible by step_log_config.frequency
     * If true, add the current simulation state to the step log
     * @param step_time_seconds Duration of the step to be logged in seconds
     */
    void processStepLog(const double &step_time_seconds);
    /**
     * Replace the current exit log with the current simulation state
     */
    void processExitLog();
    /**
     * Map of message storage 
     */
    CUDAMessageMap message_map;
    /**
     * Map of submodel storage
     */
    CUDASubModelMap submodel_map;
    /**
     * Streams created within this cuda context for executing functions within layers in parallel
     */
    std::vector<cudaStream_t> streams;

    /** 
     * Ensure the correct number of streams exist.
     */
    void createStreams(const unsigned int nStreams);

    /**
     * Get a specific stream based on index (if possible). 
     * In some cases, this may return the 0th stream based on class flags.
     * @return specified cudaStream
     */
    cudaStream_t getStream(const unsigned int n);

    /**
     * Destroy all streams
     */
    void destroyStreams();

    /**
     * Synchronize all streams for this simulation.
     * To be used in place of device syncs, to reduce blocking in an ensemble.
     */
    void synchronizeAllStreams();

    /**
     * Execute a single layer as part of a step.
     */
    void stepLayer(const std::shared_ptr<LayerData>& layer, const unsigned int layerIndex);
    void layerHostFunctions(const std::shared_ptr<LayerData>& layer, const unsigned int layerIndex);

    /**
     * Execute the step functions of the model. 
     * This should only be called within step();
     */
    void stepStepFunctions();
    bool stepExitConditions();

    /**
     * Spatially sort the agents.
     * This should only be called within step();
     */
    void spatialSortAgent(const std::string& funcName, const std::string& agentName, const std::string& state, const int mode);

    constexpr static int Agent2D = 0;
    constexpr static int Agent3D = 1;

    /**
     * Store the agent functions which require spatial sorting
     */
    std::set<std::string> sortTriggers2D;
    std::set<std::string> sortTriggers3D;

    /**
     * Determines which agents require sorting - only used once during initialisation. Must be called manually if not using .simulate()
     */
    void determineAgentsToSort();

    /**
     * Struct containing references to the various singletons which may include CUDA code, and therefore can only be initialsed after the deferred arg parsing is completed.
     */
    struct Singletons {
      /**
       * Curve instance used for variable mapping
       * @todo Is this necessary? CUDAAgent/CUDAMessage have their own copy
       */
      detail::curve::Curve &curve;
      /**
       * Resizes device random array during step()
       */
      RandomManager rng;
      /**
       * Held here for tracking when to release cuda memory
       */
      CUDAScatter scatter;
      /**
       * Held here for tracking when to release cuda memory
       */
      EnvironmentManager &environment;
#if !defined(SEATBELTS) || SEATBELTS
      /**
       * Provides buffers for device error checking
       */
      exception::DeviceExceptionManager exception;
#endif
      Singletons(detail::curve::Curve &curve, EnvironmentManager &environment) : curve(curve), environment(environment) { }
    } * singletons;
    /**
     * Common method for adding this Model's data to env manager
     */
    void initEnvironmentMgr();
    /**
     * Flag indicating that the model has been initialsed
     */
    bool singletonsInitialised;

    /**
     * Flag indicating that RTC functions have been compiled
     */
    bool rtcInitialised;
    /**
     * Set to the ID of the device on which the simulation was initialised
     * Cannot change device after this point
     */
    int deviceInitialised = -1;

    /**
     * Initialise the instances singletons.
     */
    void initialiseSingletons();
    /**
     * Initialise the rtc by building any RTC functions.
     * This must be done at the start of step to ensure that any device selection has taken place and to preserve the context between runtime and RTC.
     */
    void initialiseRTC();
    /**
     * One instance of host api is used for entire model
     */
    std::unique_ptr<HostAPI> host_api;
    /**
     * Adds any agents stored in agentData to the device
     * Clears agent storage in agentData
     * @param streamId Stream index to perform scatter on
     * @note called at the end of step() and after all init/hostLayer functions and exit conditions have finished
     */
    void processHostAgentCreation(const unsigned int &streamId);

 public:
    typedef std::vector<NewAgentStorage> AgentDataBuffer;
    typedef std::unordered_map<std::string, AgentDataBuffer> AgentDataBufferStateMap;
    typedef std::unordered_map<std::string, VarOffsetStruct> AgentOffsetMap;
    typedef std::unordered_map<std::string, AgentDataBufferStateMap> AgentDataMap;

 private:
    void assignAgentIDs();
    /**
     * Set to false whenever an agent population is imported from outside
     * Checked before init functions and when step() is called by a user
     */
    bool agent_ids_have_init = true;
    /**
     * Provides the offset data for variable storage
     * Used by host agent creation
     */
    AgentOffsetMap agentOffsets;
    /**
     * Storage used by host agent creation before copying data to device at end of each step()
     */
    AgentDataMap agentData;
    void initOffsetsAndMap();
#ifdef VISUALISATION
    /**
     * Empty if getVisualisation() hasn't been called
     */
    std::unique_ptr<visualiser::ModelVis> visualisation;
#endif
    /**
     * This tracks the current number of alive CUDASimulation instances
     * When the last is destructed, cudaDeviceReset is triggered();
     */
    static std::atomic<int> active_instances;
    /**
     * Active instances, but linked to the device each instance has been initialised on
     */
    static std::map<int, std::atomic<int>> active_device_instances;
    /**
     * These exist to prevent us doing device reset in the short period between checking last sim of device, and reset
     */
    static std::map<int, std::shared_timed_mutex> active_device_mutex;
    /**
     * This controls access to active_device_instances, active_device_mutex
     */
    static std::shared_timed_mutex active_device_maps_mutex;
    /**
     * Returns false if any agent functions or agent function conditions are not RTC
     * Used by constructor to set isPureRTC constant value
     * @param _model The agent model hierarchy to check
     */
    static bool detectPureRTC(const std::shared_ptr<const ModelData>& _model);

 protected:
    /**
     * If true, the model is pureRTC, and hence does not use non-RTC curve
     */
    const bool isPureRTC;

 public:
    /**
     * If changed to false, will not auto cudaDeviceReset when final CUDASimulation instance is destructed
     */
    static bool AUTO_CUDA_DEVICE_RESET;
};

template<typename T>
void CUDASimulation::setEnvironmentProperty(const std::string& property_name, const T& value) {
    if (!property_name.empty() && property_name[0] == '_') {
        THROW exception::ReservedName("Environment property names cannot begin with '_', this is reserved for internal usage, "
            "in CUDASimulation::setEnvironmentProperty().");
    }
    if (!singletonsInitialised)
        initialiseSingletons();
    singletons->environment.setProperty<T>({instance_id, property_name}, value);
}
template<typename T, unsigned int N>
void CUDASimulation::setEnvironmentProperty(const std::string& property_name, const std::array<T, N>& value) {
    if (!property_name.empty() && property_name[0] == '_') {
        THROW exception::ReservedName("Environment property names cannot begin with '_', this is reserved for internal usage, "
            "in CUDASimulation::setEnvironmentProperty().");
    }
    if (!singletonsInitialised)
        initialiseSingletons();
    singletons->environment.setProperty<T, N>({ instance_id, property_name }, value);
}
template<typename T>
void CUDASimulation::setEnvironmentProperty(const std::string& property_name, const EnvironmentManager::size_type& index, const T& value) {
    if (!singletonsInitialised)
        initialiseSingletons();
    singletons->environment.setProperty<T>({ instance_id, property_name }, index, value);
}
template<typename T>
T CUDASimulation::getEnvironmentProperty(const std::string& property_name) {
    if (!singletonsInitialised)
        initialiseSingletons();
    return singletons->environment.getProperty<T>({ instance_id, property_name });
}
template<typename T, unsigned int N>
std::array<T, N> CUDASimulation::getEnvironmentProperty(const std::string& property_name) {
    if (!singletonsInitialised)
        initialiseSingletons();
    return singletons->environment.getProperty<T, N>({ instance_id, property_name });
}
template<typename T>
T CUDASimulation::getEnvironmentProperty(const std::string& property_name, const EnvironmentManager::size_type& index) {
    if (!singletonsInitialised)
        initialiseSingletons();
    return singletons->environment.getProperty<T>({ instance_id, property_name }, index);
}
#ifdef SWIG
template<typename T>
void CUDASimulation::setEnvironmentPropertyArray(const std::string& property_name, const std::vector<T>& value) {
    if (!property_name.empty() && property_name[0] == '_') {
        THROW exception::ReservedName("Environment property names cannot begin with '_', this is reserved for internal usage, "
            "in CUDASimulation::setEnvironmentPropertyArray().");
    }
    if (!singletonsInitialised)
        initialiseSingletons();
    singletons->environment.setPropertyArray<T>({ instance_id, property_name }, value);
}
template<typename T>
std::vector<T> CUDASimulation::getEnvironmentPropertyArray(const std::string& property_name) {
    if (!singletonsInitialised)
        initialiseSingletons();
    return singletons->environment.getPropertyArray<T>({ instance_id, property_name });
}
#endif
}  // namespace flamegpu

#endif  // INCLUDE_FLAMEGPU_GPU_CUDASIMULATION_H_
