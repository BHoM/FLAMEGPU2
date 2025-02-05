#ifndef INCLUDE_FLAMEGPU_RUNTIME_UTILITY_ENVIRONMENTMANAGER_CUH_
#define INCLUDE_FLAMEGPU_RUNTIME_UTILITY_ENVIRONMENTMANAGER_CUH_

#include <cuda_runtime.h>

#include <cstddef>
#include <unordered_map>
#include <array>
#include <string>
#include <type_traits>
#include <list>
#include <utility>
#include <typeindex>
#include <set>
#include <vector>
#include <mutex>
#include <shared_mutex>
#include <map>
#include <functional>
#include <memory>

#include "flamegpu/exception/FLAMEGPUException.h"
#include "flamegpu/gpu/detail/CUDAErrorChecking.cuh"
#include "flamegpu/runtime/detail/curve/curve.cuh"
#include "flamegpu/util/Any.h"
#include "flamegpu/util/type_decode.h"

namespace flamegpu {

struct SubEnvironmentData;
class EnvironmentDescription;
class CUDASimulation;
class CUDAAgent;

namespace io {
class XMLStateWriter;
class XMLStateReader;
class JSONStateWriter;
class JSONStateReader;
class JSONStateReader_impl;
}  // namespace io

/**
 * Singleton manager for managing environment properties storage in constant memory
 * This is an internal class, that should not be accessed directly by modellers
 * @see EnvironmentDescription For describing the initial state of a model's environment properties
 * @see AgentEnvironment For reading environment properties during agent functions on the device
 * @see HostEnvironment For accessing environment properties during host functions
 * @note Not thread-safe
 */
class EnvironmentManager {
    /**
     * Uses instance to for RTC compilation
     */
    friend class CUDAAgent;
    /**
     * Uses instance to initialise a models environment properties on the device
     */
    friend class CUDASimulation;
    /**
     * Uses instance to access env properties in host functions
     */
    friend class HostEnvironment;
    /**
     * Accesses pointer to hc_buffer
     */
    friend class DefragProp;
    /**
     * Accesses properties to find all of a model's vars
     */
    friend class io::XMLStateWriter;
    friend class io::XMLStateReader;
    friend class io::JSONStateWriter;
    friend class io::JSONStateReader;
    friend class io::JSONStateReader_impl;
    /**
     * CUDASimulation instance id and Property name
     */
    typedef std::pair<unsigned int, std::string> NamePair;
    struct NamePairHash {
        size_t operator()(const NamePair& k) const {
            return std::hash<unsigned int>()(k.first) ^
                (std::hash<std::string>()(k.second) << 1);
        }
    };

 public:
    /**
     * Max amount of space that can be used for storing environmental properties
     */
    static const size_t MAX_BUFFER_SIZE = 10 * 1024;  // 10KB
    /**
     * Offset relative to c_buffer
     * Length in bytes
     */
    typedef unsigned int size_type;
    /**
     * Used to group items required by freeFragments 
     */
    typedef std::pair<ptrdiff_t, size_t> OffsetLen;
    /**
     * Gives names to indices of OffsetLen
     */
    enum OL {
        OFFSET = 0,
        LEN = 1,
    };
    /**
     * Used to group items required by properties
     */
    struct EnvProp {
        /**
         * @param _offset Offset into c_buffer/hc_buffer
         * @param _length Length of associated storage
         * @param _isConst Is the stored data constant
         * @param _elements How many elements does the stored data contain (1 if not array)
         * @param _type Type of property (from typeid())
        * @param _rtc_offset Offset into the instances rtc cache, this can be skipped if the relevant rtc cache has not yet been built
         */
        EnvProp(const ptrdiff_t &_offset, const size_t &_length, const bool &_isConst, const size_type &_elements, const std::type_index &_type, const ptrdiff_t &_rtc_offset = 0)
            : offset(_offset),
            length(_length),
            isConst(_isConst),
            elements(_elements),
            type(_type),
            rtc_offset(_rtc_offset) {}
        ptrdiff_t offset;
        size_t length;
        bool isConst;
        size_type elements;
        const std::type_index type;
        ptrdiff_t rtc_offset;  // This is set by buildRTCOffsets();
    };
    /**
     * Used to represent properties of a mapped environment property
     */
    struct MappedProp {
        /**
         * @param _masterProp Master property of mapping
         * @param _isConst Is the stored data constant
         */
        MappedProp(const NamePair &_masterProp, const bool &_isConst)
            : masterProp(_masterProp),
            isConst(_isConst) {}
        const NamePair masterProp;
        const bool isConst;
    };
    /**
     * This structure is a clone of EnvProp
     * However, instead of offset (which points to an offset into hc_buffer)
     * data is available, which points to host memory
     */
    struct DefragProp {
        /**
         * @param ep Environment property to clone
         * @note ep.offset is converted to a host pointer by adding to hc_buffer
         */
        explicit DefragProp(const EnvProp &ep)
            :data(EnvironmentManager::getInstance().hc_buffer + ep.offset),
            length(ep.length),
            isConst(ep.isConst),
            elements(ep.elements),
            type(ep.type),
            rtc_offset(ep.rtc_offset) { }
        /**
        * @param _data Pointer to the data in host memory
        * @param _length Length of associated storage
        * @param _isConst Is the stored data constant
        * @param _elements How many elements does the stored data contain (1 if not array)
        * @param _type Type of propert (from typeid())
        * @param _rtc_offset Offset into the instances rtc cache, this can be skipped if the relevant rtc cache has not yet been built
        */
        DefragProp(void *_data, const size_t &_length, const bool &_isConst, const size_type &_elements, const std::type_index &_type, const ptrdiff_t &_rtc_offset = 0)
            : data(_data),
            length(_length),
            isConst(_isConst),
            elements(_elements),
            type(_type),
            rtc_offset(_rtc_offset) { }
        void *data;
        size_t length;
        bool isConst;
        size_type elements;
        const std::type_index type;
        ptrdiff_t rtc_offset;
    };
    /**
     * Struct used by rtc_caches
     * Represents a personalised constant cache buffer for a single CUDASimulation instance
     * These are shared by submodels
     */
    struct RTCEnvPropCache {
        /**
         * Host copy of the device memory pointed to by c_buffer
         */
        char hc_buffer[MAX_BUFFER_SIZE];
        /**
         * Offset relative to c_buffer, where no more data has been stored
         */
        ptrdiff_t nextFree = 0;
    };
    /**
     * Transparent operators for DefragMap
     * This allows them to be secondarily ordered based on NamePair if size is equal
     */
    friend bool operator<(const std::pair<size_t, const NamePair>& fk, const size_t& lk) { return fk.first < lk; }
    friend bool operator<(const size_t& lk, const std::pair<size_t, const NamePair>& fk) { return lk < fk.first; }
    friend bool operator<(const std::pair<size_t, const NamePair>& fk1, const std::pair<size_t, const NamePair>& fk2) {
        if (fk1.first == fk2.first) {
            // If size equal, order by instance_id
            if (fk1.second.first == fk2.second.first) {
                // If instance id is equal, order by name
                return fk1.second.second < fk2.second.second;
            }
            return fk1.second.first < fk2.second.first;
        }
        return fk1.first < fk2.first;
    }
    /**
     * Typedef for the map used for defragementation
     * The map is ordered by key of type size, therefore a reverse sort creates aligned data
     * Specify a transparent operator, to allow us to operate only over size_t part of key
     */
    typedef std::multimap<std::pair<size_t, const NamePair>, DefragProp, std::less<>> DefragMap;
    /**
     * Activates a models environment properties, by adding them to constant cache
     * @param instance_id instance_id of the CUDASimulation instance the properties are attached to
     * @param desc environment properties description to use
     * @param isPureRTC If true, Curve collision warnings (debug build only) will be suppressed as they are irrelevant to RTC models
     */
    void init(const unsigned int &instance_id, const EnvironmentDescription &desc, bool isPureRTC);
    /**
     * Submodel variant of init()
     * Activates a models unmapped environment properties, by adding them to constant cache
     * Maps a models mapped environment properties to their master property
     * @param instance_id instance_id of the CUDASimulation instance the properties are attached to
     * @param desc environment properties description to use
     * @param isPureRTC If true, Curve collision warnings (debug build only) will be suppressed as they are irrelevant to RTC models
     * @param master_instance_id instance_id of the CUDASimulation instance of the parent of the submodel
     * @param mapping Metadata for which environment properties are mapped between master and submodels
     */
    void init(const unsigned int &instance_id, const EnvironmentDescription &desc, bool isPureRTC, const unsigned int &master_instance_id, const SubEnvironmentData &mapping);
    /**
     * RTC functions hold their own unique constants for environment variables. This function copies all environment variable to the RTC copies.
     * It can not be incorporated into init() as init will be called before RTC functions have been compiled.
     * Uses the already populated Environment data from the cudaSimulation rather than environmentDescription.
     * @param cudaSimulation the cuda model being initialised.
     */
    void initRTC(const CUDASimulation &cudaSimulation);
    /**
     * Deactives all environmental properties linked to the named model from constant cache
     * @param curve The Curve singleton instance to use, it is important that we purge curve for the correct device
     * @param instance_id instance_id of the CUDASimulation instance the properties are attached to
     */
    void free(detail::curve::Curve &curve, const unsigned int &instance_id);
    /**
     * Adds a new environment property
     * @param name name used for accessing the property
     * @param value stored value of the property
     * @param isConst If set to true, it is not possible to change the value
     * @tparam T Type of the environmental property to be created
     * @throws exception::DuplicateEnvProperty If a property of the same name already exists
     */
    template<typename T>
    void newProperty(const NamePair &name, const T &value, const bool &isConst = false);
    /**
     * Convenience method: Adds a new environment property
     * @param instance_id instance_id of the CUDASimulation instance the property is attached to
     * @param var_name name used for accessing the property
     * @param value stored value of the property
     * @param isConst If set to true, it is not possible to change the value
     * @tparam T Type of the environmental property to be created
     * @throws exception::DuplicateEnvProperty If a property of the same name already exists
     * @see add(const NamePair &, const T &, const bool &)
     */
    template<typename T>
    void newProperty(const unsigned int &instance_id, const std::string &var_name, const T &value, const bool &isConst = false);
    /**
     * Adds a new environment property array
     * @param name name used for accessing the property
     * @param value stored value of the property
     * @param isConst If set to true, it is not possible to change the value
     * @tparam T Type of the environmental property array to be created
     * @tparam N Length of the environmental property array to be created
     * @throws exception::DuplicateEnvProperty If a property of the same name already exists
     */
    template<typename T, size_type N>
    void newProperty(const NamePair &name, const std::array<T, N> &value, const bool &isConst = false);
    /**
     * Convenience method: Adds a new environment property array
     * @param instance_id instance_id of the CUDASimulation instance the property is attached to
     * @param var_name name used for accessing the property
     * @param value stored value of the property
     * @param isConst If set to true, it is not possible to change the value
     * @tparam T Type of the environmental property array to be created
     * @tparam N Length of the environmental property array to be created
     * @throws exception::DuplicateEnvProperty If a property of the same name already exists
     * @see add(const NamePair &, const std::array<T, N> &, const bool &)
     */
    template<typename T, size_type N>
    void newProperty(const unsigned int &instance_id, const std::string &var_name, const std::array<T, N> &value, const bool &isConst = false);
    /**
     * Sets an environment property
     * @param name name used for accessing the property
     * @param value value to set the property
     * @tparam T Type of the environmental property array to be created
     * @return Returns the previous value
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     * @throws exception::ReadOnlyEnvProperty If the named property is marked as const
     */
    template<typename T>
    T setProperty(const NamePair &name, const T &value);
    /**
     * Convenience method: Sets an environment property
     * @param instance_id instance_id of the CUDASimulation instance the property is attached to
     * @param var_name name used for accessing the property
     * @param value value to set the property
     * @tparam T Type of the environmental property array to be created
     * @return Returns the previous value
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     * @throws exception::ReadOnlyEnvProperty If the named property is marked as const
     * @see add(const NamePair &, const T &)
     */
    template<typename T>
    T setProperty(const unsigned int &instance_id, const std::string &var_name, const T &value);
    /**
     * Convenience method: Sets an environment property
     * @param instance_id instance_id of the CUDASimulation instance the property is attached to
     * @param var_name name used for accessing the property
     * @param data Ptr to source data
     * @param len Length of source data in bytes
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     * @throws exception::InvalidEnvProperty If len does not match the data length of the env property
     * @throws exception::ReadOnlyEnvProperty If the named property is marked as const
     */
    void setProperty(const unsigned int& instance_id, const std::string& var_name, void *data, size_t len);
    /**
     * Sets an environment property array
     * @param name name used for accessing the property array
     * @param value value to set the property array
     * @tparam T Type of the environmental property array to be created
     * @tparam N Length of the environmental property array to be created
     * @return Returns the previous value
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     * @throws exception::ReadOnlyEnvProperty If the named property is marked as const
     */
    template<typename T, size_type N>
    std::array<T, N> setProperty(const NamePair &name, const std::array<T, N> &value);
    /**
     * Convenience method: Sets an environment property array
     * @param instance_id instance_id of the CUDASimulation instance the property is attached to
     * @param var_name name used for accessing the property
     * @param value value to set the property array
     * @tparam T Type of the environmental property array to be created
     * @tparam N Length of the environmental property array to be created
     * @return Returns the previous value
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     * @throws exception::ReadOnlyEnvProperty If the named property is marked as const
     * @see set(const NamePair &, const std::array<T, N> &)
     */
    template<typename T, size_type N>
    std::array<T, N> setProperty(const unsigned int &instance_id, const std::string &var_name, const std::array<T, N> &value);
#ifdef SWIG
    /**
     * Sets an environment property array
     * @param name name used for accessing the property array
     * @param value value to set the property array
     * @tparam T Type of the environmental property array to be created
     * @return Returns the previous value
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     * @throws exception::ReadOnlyEnvProperty If the named property is marked as const
     */
    template<typename T>
    std::vector<T> setPropertyArray(const NamePair &name, const std::vector<T> &value);
#endif
    /**
     * Sets an element of an environment property array
     * @param name name used for accessing the property array
     * @param index Index of the element within the array
     * @param value value to set the element of the property array
     * @tparam T Type of the environmental property array to be created
     * @return Returns the previous value
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     * @throws std::out_of_range
     */
    template<typename T>
    T setProperty(const NamePair &name, const size_type &index, const T &value);
    /**
     * Convenience method: Sets an element of an environment property array
     * @param instance_id instance_id of the CUDASimulation instance the property is attached to
     * @param var_name name used for accessing the property
     * @param index Index of the element within the array
     * @param value value to set the element of the property array
     * @tparam T Type of the environmental property array to be created
     * @return Returns the previous value
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     * @throws std::out_of_range
     * @see set(const NamePair &, const size_type &, const T &)
     */
    template<typename T>
    T setProperty(const unsigned int &instance_id, const std::string &var_name, const size_type &index, const T &value);
    /**
     * Gets an environment property
     * @param name name used for accessing the property
     * @tparam T Type of the environmental property array to be created
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     * @see get(const NamePair &)
     */
    template<typename T>
    T getProperty(const NamePair &name);
    /**
     * Convenience method: Gets an environment property
     * @param instance_id instance_id of the CUDASimulation instance the property is attached to
     * @param var_name name used for accessing the property
     * @tparam T Type of the environmental property array to be created
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     */
    template<typename T>
    T getProperty(const unsigned int &instance_id, const std::string &var_name);
    /**
     * Gets an environment property array
     * @param name name used for accessing the property array
     * @tparam T Type of the environmental property array to be created
     * @tparam N Length of the environmental property array to be created
     * @throws exception::InvalidEnvProperty If a property array of the name does not exist
     */
    template<typename T, size_type N>
    std::array<T, N> getProperty(const NamePair &name);
    /**
     * Convenience method: Gets an environment property array
     * @param instance_id instance_id of the CUDASimulation instance the property is attached to
     * @param var_name name used for accessing the property
     * @tparam T Type of the environmental property array to be created
     * @tparam N Length of the environmental property array to be created
     * @throws exception::InvalidEnvProperty If a property array of the name does not exist
     * @see get(const NamePair &)
     */
    template<typename T, size_type N>
    std::array<T, N> getProperty(const unsigned int &instance_id, const std::string &var_name);
    /**
     * Gets an element of an environment property array
     * @param name name used for accessing the property array
     * @param index Index of the element within the array
     * @tparam T Type of the value to be returned
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     * @throws std::out_of_range
     */
    template<typename T>
    T getProperty(const NamePair &name, const size_type &index);
#ifdef SWIG
    /**
     * Convenience method: Gets an environment property array
     * @param name name used for accessing the property array
     * @tparam T Type of the environmental property array to be created
     * @throws exception::InvalidEnvProperty If a property array of the name does not exist
     * @see get(const NamePair &)
     */
    template<typename T>
    std::vector<T> getPropertyArray(const NamePair& name);
#endif
    /**
     * Convenience method: Gets an element of an environment property array
     * @param instance_id instance_id of the CUDASimulation instance the property is attached to
     * @param var_name name used for accessing the property
     * @param index The index of the element within the environment property array
     * @tparam T Type of the value to be returned
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     * @throws std::out_of_range
     * @see get(const NamePair &, const size_type &)
     */
    template<typename T>
    T getProperty(const unsigned int &instance_id, const std::string &var_name, const size_type &index);
    /**
     * Returns the current value of an environment property as an Any object
     * This method should not be exposed to users
     * @param instance_id instance_id of the CUDASimulation instance the property is attached to
     * @param var_name name used for accessing the property
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     */
    util::Any getPropertyAny(const unsigned int &instance_id, const std::string &var_name) const;
    /**
     * Removes an environment property
     * @param name name used for accessing the property
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     * @note This may be used to remove and recreate environment properties (and arrays) marked const
     */
    void removeProperty(const NamePair &name);
    /**
     * Convenience method: Removes an environment property
     * @param instance_id instance_id of the CUDASimulation instance the property is attached to
     * @param var_name name used for accessing the property
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     * @note This may be used to remove and recreate environment properties (and arrays) marked const
     * @see remove(const NamePair &)
     */
    void removeProperty(const unsigned int &instance_id, const std::string &var_name);
    /**
     * Returns all environment properties owned by a model to their default values
     * This means that properties inherited by a submodel will not be reset to their default values
     * @param instance_id instance_id of the CUDASimulation instance the property is attached to
     * @param desc The environment description (this is where the defaults are pulled from)
     * @todo This is not a particularly efficient implementation, as it updates them all individually.
     */
    void resetModel(const unsigned int &instance_id, const EnvironmentDescription &desc);
    /**
     * Returns whether the named env property exists
     * @param name name used for accessing the property
     */
    inline bool containsProperty(const NamePair &name) const {
        std::shared_lock<std::shared_timed_mutex> lock(mutex);
        return properties.find(name) != properties.end() || mapped_properties.find(name) != mapped_properties.end();
    }
    /**
     * Convenience method: Returns whether the named env property exists
     * @param instance_id instance_id of the CUDASimulation instance the property is attached to
     * @param var_name name used for accessing the property
     * @see contains(const NamePair &)
     */
    inline bool containsProperty(const unsigned int &instance_id, const std::string &var_name) const { return containsProperty(toName(instance_id, var_name)); }
    /**
     * Returns whether the named env property is marked as const
     * @param name name used for accessing the property
     * @return true if the var is marked as constant (cannot be changed during simulation)
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     */
    inline bool isConst(const NamePair &name) const {
        std::shared_lock<std::shared_timed_mutex> lock(mutex);
        const auto a = properties.find(name);
        if (a != properties.end())
            return a->second.isConst;
        const auto b = mapped_properties.find(name);
        if (b != mapped_properties.end()) {
            return b->second.isConst;
        }
        THROW exception::InvalidEnvProperty("Environmental property with name '%u:%s' does not exist, "
            "in EnvironmentManager::isConst().",
            name.first, name.second.c_str());
    }
    /**
     * Convenience method: Returns whether the named env property is marked as const
     * @param instance_id instance_id of the CUDASimulation instance the property is attached to
     * @param var_name name used for accessing the property
     * @return true if the var is marked as constant (cannot be changed during simulation)
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     * @see isConst(const NamePair &)
     */
    inline bool isConst(const unsigned int &instance_id, const std::string &var_name) const { return isConst(toName(instance_id, var_name)); }
    /**
     * Returns the number of elements of the named env property (1 if not an array)
     * @param name name used for accessing the property
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     */
    inline size_type length(const NamePair &name) const {
        std::shared_lock<std::shared_timed_mutex> lock(mutex);
        auto a = properties.find(name);
        if (a != properties.end())
            return a->second.elements;
        const auto b = mapped_properties.find(name);
        if (b != mapped_properties.end()) {
            a = properties.find(b->second.masterProp);
            if (a != properties.end())
                return a->second.elements;
            THROW exception::InvalidEnvProperty("Mapped environmental property with name '%u:%s' maps to missing property with name '%u:%s', "
                "in EnvironmentManager::length().",
                name.first, name.second.c_str(), b->second.masterProp.first, b->second.masterProp.second.c_str());
        }
        THROW exception::InvalidEnvProperty("Environmental property with name '%u:%s' does not exist, "
            "in EnvironmentManager::length().",
            name.first, name.second.c_str());
    }
    /**
     * Convenience method: Returns the number of elements of the named env property (1 if not an array)
     * @param instance_id instance_id of the CUDASimulation instance the property is attached to
     * @param var_name name used for accessing the property
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     * @see length(const NamePair &)
     */
    inline size_type length(const unsigned int &instance_id, const std::string &var_name) const { return length(toName(instance_id, var_name)); }
    /**
     * Returns the variable type of named env property
     * @param name name used for accessing the property
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     */
    inline std::type_index type(const NamePair &name) const {
        std::shared_lock<std::shared_timed_mutex> lock(mutex);
        auto a = properties.find(name);
        if (a != properties.end())
            return a->second.type;
        const auto b = mapped_properties.find(name);
        if (b != mapped_properties.end()) {
            a = properties.find(b->second.masterProp);
            if (a != properties.end())
                return a->second.type;
            THROW exception::InvalidEnvProperty("Mapped environmental property with name '%u:%s' maps to missing property with name '%u:%s', "
                "in EnvironmentManager::type().",
                name.first, name.second.c_str(), b->second.masterProp.first, b->second.masterProp.second.c_str());
        }
        THROW exception::InvalidEnvProperty("Environmental property with name '%u:%s' does not exist, "
            "in EnvironmentManager::type().",
            name.first, name.second.c_str());
    }
    /**
     * Convenience method: Returns the variable type of named env property
     * @param instance_id instance_id of the CUDASimulation instance the property is attached to
     * @param var_name name used for accessing the property
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     * @see type(const NamePair &)
     */
    inline std::type_index type(const unsigned int &instance_id, const std::string &var_name) const { return type(toName(instance_id, var_name)); }
    /**
     * Returns the size of the base type of the named env property (e.g. 4 if float)
     * @param name name used for accessing the property
     * @throws exception::InvalidEnvProperty If a property of the name does not exist
     */
    inline size_t type_size(const NamePair& name) const {
        std::shared_lock<std::shared_timed_mutex> lock(mutex);
        auto a = properties.find(name);
        if (a != properties.end())
            return a->second.length;
        const auto b = mapped_properties.find(name);
        if (b != mapped_properties.end()) {
            a = properties.find(b->second.masterProp);
            if (a != properties.end())
                return a->second.length;
            THROW exception::InvalidEnvProperty("Mapped environmental property with name '%u:%s' maps to missing property with name '%u:%s', "
                "in EnvironmentManager::type_size().",
                name.first, name.second.c_str(), b->second.masterProp.first, b->second.masterProp.second.c_str());
        }
        THROW exception::InvalidEnvProperty("Environmental property with name '%u:%s' does not exist, "
            "in EnvironmentManager::type_size().",
            name.first, name.second.c_str());
    }
    /**
     * Returns the available space remaining (bytes) for storing environmental properties
     */
    inline size_t freeSpace() const { std::shared_lock<std::shared_timed_mutex> lock(mutex); return m_freeSpace; }
    /**
     * This is the string used to generate CURVE_NAMESPACE_HASH
     */
    static const char CURVE_NAMESPACE_STRING[23];
    /**
     * Hash never changes, so we store a copy at creation
     * Also ensure the device constexpr version matches
     */
    const detail::curve::Curve::NamespaceHash CURVE_NAMESPACE_HASH;
    /**
     * Returns read-only access to the properties map
     * @note You must acquire a lock on mutex before calling this method
     */
    const std::unordered_map<NamePair, EnvProp, NamePairHash> &getPropertiesMap() const {
        return properties;
    }
    /**
     * Returns readonly access to mapped properties
     * @note You must acquire a lock on mutex before calling this method
     */    
    const std::unordered_map<NamePair, MappedProp, NamePairHash> &getMappedProperties() const {
        return mapped_properties;
    }
    /**
     * Used by IO methods to efficiently access environment
     * @note You must acquire a lock on mutex before calling this method
     */
    const void * getHostBuffer() const {
        return hc_buffer;
    }
    /**
     * Updates the copy of the environment property cache on the device
     * @param instance_id Used to update the specified instance's rtc too
     */
    void updateDevice(const unsigned int &instance_id);

 private:
    /**
     * Joins the two strings into a std::pair
     * @param instance_id becomes first item of pair
     * @param var_name becomes second item of pair
     * @return Returns std::make_pair(instance_id, var_name)
     */
    static NamePair toName(const unsigned int &instance_id, const std::string &var_name);
    /**
     * Returns the sum of the curve variable hash for the two items within name
     * @param name Pair of the two items to produce the curve value hash
     * @note Not static, because eventually we might need to use curve singleton
     */
    detail::curve::Curve::VariableHash toHash(const NamePair &name) const;
    /**
     * Common add handler
     */
    void newProperty(const NamePair &name, const char *ptr, const size_t &len, const bool &isConst, const size_type &elements, const std::type_index &type);
    /**
     * Cleanup freeFragments
     * @param curve The curve instance to use (important if thread has cuda device set wrong)
     * @param mergeProps Used by init to defragement whilst merging in new data
     * @param newmaps Namepairs of newly mapped properties, yet to to be setup (essentially ones not yet registered in curve)
     * @param isPureRTC If true, Curve collision warnings (debug build only) will be suppressed as they are irrelevant to RTC models
     * @note any EnvPROP
     */
    void defragment(detail::curve::Curve &curve, const DefragMap * mergeProps = nullptr, std::set<NamePair> newmaps = {}, bool isPureRTC = false);
    /**
     * This is the RTC version of defragment()
     * RTC Constant offsets are fixed at RTC time, and exist in their own constant block.
     * Therefore if the main constant cache is defragmented, and offsets change, the RTC constants will be incorrect.
     * Which fix this by maintaining a seperate constant cache per CUDASimulation instance
     * @param instance_id Instance id of the cuda agent model that owns the properties
     * @param master_instance_id Instance id of the parent model (If this isn't a submodel, pass instance_id here too
     * @param mergeProperties Ordered map of properties to be stored.
     */
    void buildRTCOffsets(const unsigned int &instance_id, const unsigned int &master_instance_id, const DefragMap &mergeProperties);
    /**
     * Returns the rtccache ptr for the named instance id
     * @param instance_id Instance id of the cuda agent model that owns the properties
     */
    char* getRTCCache(const unsigned int& instance_id);
    /**
     * Useful for adding individual variables to RTC cache later on
     */
    void addRTCOffset(const NamePair &name);
    /**
     * Device pointer to the environment property buffer in __constant__ memory
     */
    const char *c_buffer;
    /**
     * Host copy of the device memory pointed to by c_buffer
     */
    char hc_buffer[MAX_BUFFER_SIZE];
    /**
     * Offset relative to c_buffer, where no more data has been stored
     */
    ptrdiff_t nextFree;
    /**
     * Unused space within c_buffer, including gaps in freeFragments
     */
    size_t m_freeSpace;
    /**
     * List of fragments remaining from deleted environment variables
     */
    std::list<OffsetLen> freeFragments;
    /**
     * Host copy of data related to each stored property
     */
    std::unordered_map<NamePair, EnvProp, NamePairHash> properties;
    /**
     * This lists all currently mapped properties, so their access can be redirected to the appropriate property
     */
    std::unordered_map<NamePair, MappedProp, NamePairHash> mapped_properties;
    /**
     * Map of model name to CUDASimulation for use in updating RTC values
     */
    std::unordered_map<unsigned int, const CUDASimulation&> cuda_agent_models;
    /**
     * Map of RTC caches per CUDASimulation instance
     * They are shared by submodels
     */
    std::unordered_map<unsigned int, std::shared_ptr<RTCEnvPropCache>> rtc_caches;
    /**
     * Flag indicating that curve has/hasn't been initialised yet on a device.
     */
    bool deviceInitialised;
    /*
     * Convenience fn for managing deviceRequiresUpdate
     * @param instance_id Sim instance id, UINT_MAX sets all
     */
    void setDeviceRequiresUpdateFlag(const unsigned int &instance_id = UINT_MAX);
    /**
     * These flags control what happens when updateDevice() is called
     * Their primary purpose is to cause the device memory to updated as lazily as possible
     */
    struct EnvUpdateFlags {
        /**
         * Update the device constant cache for main C env var storage
         */
        bool c_update_required = true;
        /**
         * Update the RTC environment cache for a specific CUDASimulation instance
         */
        bool rtc_update_required = true;
        /**
         * Additionally register all variables inside CURVE
         * This should only be triggered after a device reset, when EnvironmentManager::purge()  has been called
         * As properties are registered with curve when they are first added to EnvironmentManager
         **/
        bool curve_registration_required = false;
    };
    /**
     * Flag indicating whether the device copy is upto date
     * sim_instance_id:(C needs update, RTC needs update)
     */
    std::unordered_map<unsigned int, EnvUpdateFlags> deviceRequiresUpdate;
    /**
     * Function to initialise device-side portions of the environment manager
     */
    void initialiseDevice();
    /**
     * Managed multi-threaded access to the internal storage
     * All read-only methods take a shared-lock
     * All methods which modify the internals require a unique-lock
     * Some private methods expect a lock to be gained before calling (to prevent the same thread attempting to lock the mutex twice)
     */
    mutable std::shared_timed_mutex mutex;
    std::shared_lock<std::shared_timed_mutex> getSharedLock() const { return std::shared_lock<std::shared_timed_mutex>(mutex); }
    std::unique_lock<std::shared_timed_mutex> getUniqueLock() const { return std::unique_lock<std::shared_timed_mutex>(mutex); }
    /**
     * This mutex exists to stop defrag being called, between curve being updated, and an agent function executing
     */
    mutable std::shared_timed_mutex device_mutex;
    std::shared_lock<std::shared_timed_mutex> getDeviceSharedLock() const { return std::shared_lock<std::shared_timed_mutex>(device_mutex); }
    std::unique_lock<std::shared_timed_mutex> getDeviceUniqueLock() const { return std::unique_lock<std::shared_timed_mutex>(device_mutex); }
    /**
     * This mutex only protects deviceRequiresUpdate map
     */
    mutable std::shared_timed_mutex deviceRequiresUpdate_mutex;
    /**
     * Remainder of class is singleton pattern
     */
    EnvironmentManager();
    /**
     * Wipes out host mirrors of device memory
     * Only really to be used after calls to cudaDeviceReset()
     * @note Only currently used after some tests
     */
    void purge();

 protected:
    /**
     * Returns the EnvironmentManager singleton instance
     */
    static EnvironmentManager& getInstance();
    static std::mutex instance_mutex;

    const CUDASimulation& getCUDASimulation(const unsigned int &instance_id);
    /**
     * Update the copy of the env var that exists in the rtc_cache to match the main cache
     * @param name namepair of the variable to be updated
     */
    void updateRTCValue(const NamePair &name);

 public:
    // Public deleted creates better compiler errors
    EnvironmentManager(EnvironmentManager const&) = delete;
    void operator=(EnvironmentManager const&) = delete;
};

/**
 * Constructors
 */
template<typename T>
void EnvironmentManager::newProperty(const NamePair &name, const T &value, const bool &isConst) {
    // Limited to Arithmetic types
    // Compound types would allow host pointers inside structs to be passed
    static_assert(std::is_arithmetic<typename type_decode<T>::type_t>::value || std::is_enum<typename type_decode<T>::type_t>::value,
        "Only arithmetic types can be used as environmental properties");
    if (containsProperty(name)) {
        THROW exception::DuplicateEnvProperty("Environmental property with name '%u:%s' already exists, "
            "in EnvironmentManager::add().",
            name.first, name.second.c_str());
    }
    newProperty(name, reinterpret_cast<const char*>(&value), sizeof(T), isConst, 1, typeid(T));
}
template<typename T>
void EnvironmentManager::newProperty(const unsigned int &instance_id, const std::string &var_name, const T &value, const bool &isConst) {
    newProperty<T>(toName(instance_id, var_name), value, isConst);
}
template<typename T, EnvironmentManager::size_type N>
void EnvironmentManager::newProperty(const NamePair &name, const std::array<T, N> &value, const bool &isConst) {
    // Limited to Arithmetic types
    // Compound types would allow host pointers inside structs to be passed
    static_assert(std::is_arithmetic<typename type_decode<T>::type_t>::value || std::is_enum<typename type_decode<T>::type_t>::value,
        "Only arithmetic types can be used as environmental properties");
    if (containsProperty(name)) {
        THROW exception::DuplicateEnvProperty("Environmental property with name '%u:%s' already exists, "
            "in EnvironmentManager::add().",
            name.first, name.second.c_str());
    }
    newProperty(name, reinterpret_cast<const char*>(value.data()), N * sizeof(T), isConst, N, typeid(T));
}
template<typename T, EnvironmentManager::size_type N>
void EnvironmentManager::newProperty(const unsigned int &instance_id, const std::string &var_name, const std::array<T, N> &value, const bool &isConst) {
    newProperty<T, N>(toName(instance_id, var_name), value, isConst);
}

/**
 * Setters
 */
template<typename T>
T EnvironmentManager::setProperty(const NamePair &name, const T &value) {
    // Limited to Arithmetic types
    // Compound types would allow host pointers inside structs to be passed
    static_assert(std::is_arithmetic<typename type_decode<T>::type_t>::value || std::is_enum<typename type_decode<T>::type_t>::value,
        "Only arithmetic types can be used as environmental properties");
    const std::type_index typ_id = type(name);
    if (typ_id != std::type_index(typeid(typename type_decode<T>::type_t))) {
        THROW exception::InvalidEnvPropertyType("Environmental property ('%u:%s') type (%s) does not match template argument T (%s), "
            "in EnvironmentManager::setProperty().",
            name.first, name.second.c_str(), typ_id.name(), typeid(typename type_decode<T>::type_t).name());
    }
    const size_type array_len = length(name);
    if (array_len != type_decode<T>::len_t) {
        THROW exception::InvalidEnvPropertyType("Named environmental property is an array of length %u, the array function or appropriate vector type must be used! "
            "in EnvironmentManager::setProperty().",
            array_len);
    }
    if (isConst(name)) {
        THROW exception::ReadOnlyEnvProperty("Environmental property ('%u:%s') is marked as const and cannot be changed, "
            "in EnvironmentManager::setProperty().",
            name.first, name.second.c_str());
    }
    // Copy old data to return
    T rtn = getProperty<T>(name);
    std::unique_lock<std::shared_timed_mutex> lock(mutex);
    // Find property offset
    ptrdiff_t buffOffset = 0;
    const auto a = properties.find(name);
    if (a != properties.end()) {
        buffOffset = a->second.offset;
    } else {
        buffOffset = properties.at(mapped_properties.at(name).masterProp).offset;
    }
    // Store data
    memcpy(hc_buffer + buffOffset, &value, sizeof(T));
    // Do rtc too
    updateRTCValue(name);
    // Set device update flag
    setDeviceRequiresUpdateFlag(name.first);

    return rtn;
}
template<typename T>
T EnvironmentManager::setProperty(const unsigned int &instance_id, const std::string &var_name, const T &value) {
    return setProperty<T>(toName(instance_id, var_name), value);
}
template<typename T, EnvironmentManager::size_type N>
std::array<T, N> EnvironmentManager::setProperty(const NamePair &name, const std::array<T, N> &value) {
    // Limited to Arithmetic types
    // Compound types would allow host pointers inside structs to be passed
    static_assert(std::is_arithmetic<typename type_decode<T>::type_t>::value || std::is_enum<typename type_decode<T>::type_t>::value,
        "Only arithmetic types can be used as environmental properties");
    const std::type_index typ_id = type(name);
    if (typ_id != std::type_index(typeid(typename type_decode<T>::type_t))) {
        THROW exception::InvalidEnvPropertyType("Environmental property array ('%u:%s') type (%s) does not match template argument T (%s), "
            "in EnvironmentManager::setProperty().",
            name.first, name.second.c_str(), typ_id.name(), typeid(typename type_decode<T>::type_t).name());
    }
    if (isConst(name)) {
        THROW exception::ReadOnlyEnvProperty("Environmental property array ('%u:%s') is marked as const and cannot be changed, "
            "in EnvironmentManager::setProperty().",
            name.first, name.second.c_str());
    }
    const size_type array_len = length(name);
    if (array_len != type_decode<T>::len_t * N) {
        THROW exception::OutOfBoundsException("Length of named environmental property array (%u) does not match template argument N (%u)! "
            "in EnvironmentManager::setProperty().",
            array_len, type_decode<T>::len_t * N);
    }
    // Copy old data to return
    std::array<T, N> rtn = getProperty<T, N>(name);
    std::unique_lock<std::shared_timed_mutex> lock(mutex);
    // Find property offset
    ptrdiff_t buffOffset = 0;
    const auto a = properties.find(name);
    if (a != properties.end()) {
        buffOffset = a->second.offset;
    } else {
        buffOffset = properties.at(mapped_properties.at(name).masterProp).offset;
    }
    // Store data
    memcpy(hc_buffer + buffOffset, value.data(), N * sizeof(T));
    // Do rtc too
    updateRTCValue(name);
    // Set device update flag
    setDeviceRequiresUpdateFlag(name.first);

    return rtn;
}
template<typename T, EnvironmentManager::size_type N>
std::array<T, N> EnvironmentManager::setProperty(const unsigned int &instance_id, const std::string &var_name, const std::array<T, N> &value) {
    return setProperty<T, N>(toName(instance_id, var_name), value);
}
#ifdef SWIG
template<typename T>
std::vector<T> EnvironmentManager::setPropertyArray(const NamePair& name, const std::vector<T>& value) {
    // Limited to Arithmetic types
    // Compound types would allow host pointers inside structs to be passed
    static_assert(std::is_arithmetic<typename type_decode<T>::type_t>::value || std::is_enum<typename type_decode<T>::type_t>::value,
        "Only arithmetic types can be used as environmental properties");
    const std::type_index typ_id = type(name);
    if (typ_id != std::type_index(typeid(typename type_decode<T>::type_t))) {
        THROW exception::InvalidEnvPropertyType("Environmental property array ('%u:%s') type (%s) does not match template argument T (%s), "
            "in EnvironmentManager::setPropertyArray().",
            name.first, name.second.c_str(), typ_id.name(), typeid(typename type_decode<T>::type_t).name());
    }
    if (isConst(name)) {
        THROW exception::ReadOnlyEnvProperty("Environmental property array ('%u:%s') is marked as const and cannot be changed, "
            "in EnvironmentManager::setPropertyArray().",
            name.first, name.second.c_str());
    }
    const size_type array_len = length(name);
    if (array_len != type_decode<T>::len_t * value.size()) {
        THROW exception::OutOfBoundsException("Length of named environmental property array (%u) does not match length of provided array (%llu)! "
            "in EnvironmentManager::setPropertyArray().",
            array_len, type_decode<T>::len_t * value.size());
    }
    std::unique_lock<std::shared_timed_mutex> lock(mutex);
    // Find property offset
    ptrdiff_t buffOffset = 0;
    const auto a = properties.find(name);
    if (a != properties.end()) {
        buffOffset = a->second.offset;
    } else {
        buffOffset = properties.at(mapped_properties.at(name).masterProp).offset;
    }
    // Copy old data to return
    std::vector<T> rtn(value.size());
    if (a != properties.end()) {
        memcpy(rtn.data(), reinterpret_cast<T*>(hc_buffer + buffOffset), array_len * sizeof(T));
    } else {
        memcpy(rtn.data(), reinterpret_cast<T*>(hc_buffer + buffOffset), array_len * sizeof(T));
    }
    // Store data
    memcpy(hc_buffer + buffOffset, value.data(), value.size() * sizeof(T));
    // Do rtc too
    updateRTCValue(name);
    // Set device update flag
    setDeviceRequiresUpdateFlag(name.first);

    return rtn;
}
#endif
template<typename T>
T EnvironmentManager::setProperty(const NamePair &name, const size_type &index, const T &value) {
    // Limited to Arithmetic types
    // Compound types would allow host pointers inside structs to be passed
    static_assert(std::is_arithmetic<typename type_decode<T>::type_t>::value || std::is_enum<typename type_decode<T>::type_t>::value,
        "Only arithmetic types can be used as environmental properties");
    const std::type_index typ_id = type(name);
    if (typ_id != std::type_index(typeid(typename type_decode<T>::type_t))) {
        THROW exception::InvalidEnvPropertyType("Environmental property array ('%u:%s') type (%s) does not match template argument T (%s), "
            "in EnvironmentManager::setProperty().",
            name.first, name.second.c_str(), typ_id.name(), typeid(typename type_decode<T>::type_t).name());
    }
    if (isConst(name)) {
        THROW exception::ReadOnlyEnvProperty("Environmental property array ('%u:%s') is marked as const and cannot be changed, "
            "in EnvironmentManager::setProperty().",
            name.first, name.second.c_str());
    }
    const size_type array_len = length(name);
    const unsigned int t_index = type_decode<T>::len_t * index + type_decode<T>::len_t;
    if (t_index > array_len || t_index < index) {
        THROW exception::OutOfBoundsException("Index(%u) exceeds named environmental property array's length (%u), "
            "in EnvironmentManager::setProperty().",
            index, array_len);
    }
    std::unique_lock<std::shared_timed_mutex> lock(mutex);
    // Find property offset
    ptrdiff_t buffOffset = 0;
    const auto a = properties.find(name);
    if (a != properties.end()) {
        buffOffset = a->second.offset + index * sizeof(T);
    } else {
        const auto &master_name = mapped_properties.at(name).masterProp;
        buffOffset = properties.at(master_name).offset + index * sizeof(T);
    }
    // Copy old data to return
    T rtn = *reinterpret_cast<T*>(hc_buffer + buffOffset);
    // Store data
    memcpy(hc_buffer + buffOffset, &value, sizeof(T));
    // Do rtc too
    updateRTCValue(name);
    // Set device update flag
    setDeviceRequiresUpdateFlag(name.first);

    return rtn;
}
template<typename T>
T EnvironmentManager::setProperty(const unsigned int &instance_id, const std::string &var_name, const size_type &index, const T &value) {
    return setProperty<T>(toName(instance_id, var_name), index, value);
}

/**
 * Getters
 */
template<typename T>
T EnvironmentManager::getProperty(const NamePair &name) {
    // Limited to Arithmetic types
    // Compound types would allow host pointers inside structs to be passed
    static_assert(std::is_arithmetic<typename type_decode<T>::type_t>::value || std::is_enum<typename type_decode<T>::type_t>::value,
        "Only arithmetic types can be used as environmental properties");
    const std::type_index typ_id = type(name);
    if (typ_id != std::type_index(typeid(typename type_decode<T>::type_t))) {
        THROW exception::InvalidEnvPropertyType("Environmental property ('%u:%s') type (%s) does not match template argument T (%s), "
            "in EnvironmentManager::getProperty().",
            name.first, name.second.c_str(), typ_id.name(), typeid(typename type_decode<T>::type_t).name());
    }
    const size_type array_len = length(name);
    if (array_len != type_decode<T>::len_t) {
        THROW exception::InvalidEnvPropertyType("Named environmental property is an array of length %u, the array function or appropriate vector type must be used! "
            "in EnvironmentManager::getProperty().",
            array_len);
    }
    std::shared_lock<std::shared_timed_mutex> lock(mutex);
    // Copy old data to return
    const auto a = properties.find(name);
    if (a != properties.end())
        return *reinterpret_cast<T*>(hc_buffer + a->second.offset);
    return *reinterpret_cast<T*>(hc_buffer + properties.at(mapped_properties.at(name).masterProp).offset);
}
template<typename T>
T EnvironmentManager::getProperty(const unsigned int &instance_id, const std::string &var_name) {
    return getProperty<T>(toName(instance_id, var_name));
}
template<typename T, EnvironmentManager::size_type N>
std::array<T, N> EnvironmentManager::getProperty(const NamePair &name) {
    // Limited to Arithmetic types
    // Compound types would allow host pointers inside structs to be passed
    static_assert(std::is_arithmetic<typename type_decode<T>::type_t>::value || std::is_enum<typename type_decode<T>::type_t>::value,
        "Only arithmetic types can be used as environmental properties");
    const std::type_index typ_id = type(name);
    if (typ_id != std::type_index(typeid(typename type_decode<T>::type_t))) {
        THROW exception::InvalidEnvPropertyType("Environmental property array ('%u:%s') type (%s) does not match template argument T (%s), "
            "in EnvironmentManager::getProperty().",
            name.first, name.second.c_str(), typ_id.name(), typeid(typename type_decode<T>::type_t).name());
    }
    const size_type array_len = length(name);
    if (array_len != N * type_decode<T>::len_t) {
        THROW exception::OutOfBoundsException("Length of named environmental property array (%u) does not match templated length (%u)! "
            "in EnvironmentManager::getProperty().",
            array_len, N * type_decode<T>::len_t);
    }
    // Copy old data to return
    std::array<T, N> rtn;
    std::shared_lock<std::shared_timed_mutex> lock(mutex);
    const auto a = properties.find(name);
    if (a != properties.end()) {
        memcpy(rtn.data(), reinterpret_cast<T*>(hc_buffer + a->second.offset), N * sizeof(T));
    } else {
        memcpy(rtn.data(), reinterpret_cast<T*>(hc_buffer + properties.at(mapped_properties.at(name).masterProp).offset), N * sizeof(T));
    }
    return rtn;
}
template<typename T, EnvironmentManager::size_type N>
std::array<T, N> EnvironmentManager::getProperty(const unsigned int &instance_id, const std::string &var_name) {
    return getProperty<T, N>(toName(instance_id, var_name));
}
template<typename T>
T EnvironmentManager::getProperty(const NamePair &name, const size_type &index) {
    // Limited to Arithmetic types
    // Compound types would allow host pointers inside structs to be passed
    static_assert(std::is_arithmetic<typename type_decode<T>::type_t>::value || std::is_enum<typename type_decode<T>::type_t>::value,
        "Only arithmetic types can be used as environmental properties");
    const std::type_index typ_id = type(name);
    if (typ_id != std::type_index(typeid(typename type_decode<T>::type_t))) {
        THROW exception::InvalidEnvPropertyType("Environmental property array ('%u:%s') type (%s) does not match template argument T (%s), "
            "in EnvironmentManager::getProperty().",
            name.first, name.second.c_str(), typ_id.name(), typeid(typename type_decode<T>::type_t).name());
    }
    const size_type array_len = length(name);
    const unsigned int t_index = type_decode<T>::len_t * index + type_decode<T>::len_t;
    if (t_index > array_len || t_index < index) {
        THROW exception::OutOfBoundsException("Index(%u) exceeds named environmental property array's length (%u), "
            "in EnvironmentManager::getProperty().",
            type_decode<T>::len_t * index, array_len);
    }
    std::shared_lock<std::shared_timed_mutex> lock(mutex);
    // Copy old data to return
    const auto a = properties.find(name);
    if (a != properties.end())
        return *reinterpret_cast<T*>(hc_buffer + a->second.offset + index * sizeof(T));
    return *reinterpret_cast<T*>(hc_buffer + properties.at(mapped_properties.at(name).masterProp).offset + index * sizeof(T));
}
#ifdef SWIG
template<typename T>
std::vector<T> EnvironmentManager::getPropertyArray(const NamePair& name) {
    // Limited to Arithmetic types
    // Compound types would allow host pointers inside structs to be passed
    static_assert(std::is_arithmetic<typename type_decode<T>::type_t>::value || std::is_enum<typename type_decode<T>::type_t>::value,
        "Only arithmetic types can be used as environmental properties");
    const std::type_index typ_id = type(name);
    if (typ_id != std::type_index(typeid(typename type_decode<T>::type_t))) {
        THROW exception::InvalidEnvPropertyType("Environmental property array ('%u:%s') type (%s) does not match template argument T (%s), "
            "in EnvironmentManager::getPropertyArray().",
            name.first, name.second.c_str(), typ_id.name(), typeid(typename type_decode<T>::type_t).name());
    }
    const size_type array_len = length(name);
    if (array_len % type_decode<T>::len_t != 0) {
        THROW exception::InvalidEnvPropertyType("Environmental property array ('%u:%s') length (%u) is not a multiple of vector length (%d), "
            "in EnvironmentManager::getPropertyArray().",
            name.first, name.second.c_str(), array_len, type_decode<T>::len_t);
    }
    // Copy old data to return
    std::vector<T> rtn(static_cast<size_t>(array_len / type_decode<T>::len_t));
    std::shared_lock<std::shared_timed_mutex> lock(mutex);
    const auto a = properties.find(name);
    if (a != properties.end()) {
        memcpy(rtn.data(), reinterpret_cast<T*>(hc_buffer + a->second.offset), array_len * sizeof(typename type_decode<T>::type_t));
    } else {
        memcpy(rtn.data(), reinterpret_cast<T*>(hc_buffer + properties.at(mapped_properties.at(name).masterProp).offset), array_len * sizeof(typename type_decode<T>::type_t));
    }
    return rtn;
}
#endif
template<typename T>
T EnvironmentManager::getProperty(const unsigned int &instance_id, const std::string &var_name, const size_type &index) {
    return getProperty<T>(toName(instance_id, var_name), index);
}

}  // namespace flamegpu

#endif  // INCLUDE_FLAMEGPU_RUNTIME_UTILITY_ENVIRONMENTMANAGER_CUH_
