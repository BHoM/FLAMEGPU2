#include <regex>

#include "flamegpu/model/AgentDescription.h"

#include "flamegpu/model/AgentFunctionDescription.h"
#include "flamegpu/exception/FLAMEGPUException.h"

namespace flamegpu {

/**
 * Constructors
 */
AgentDescription::AgentDescription(std::shared_ptr<const ModelData> _model, AgentData *const data)
    : model(_model)
    , agent(data) { }


bool AgentDescription::operator==(const AgentDescription& rhs) const {
    return *this->agent == *rhs.agent;  // Compare content is functionally the same
}
bool AgentDescription::operator!=(const AgentDescription& rhs) const {
    return !(*this == rhs);
}


/**
 * Accessors
 */
void AgentDescription::newState(const std::string &state_name) {
    // If state doesn't already exist
    if (agent->states.find(state_name) == agent->states.end()) {
        // If default state  has not been added
        if (!agent->keepDefaultState) {
            // Special case, where default state has been replaced
            if (agent->states.size() == 1 && (*agent->states.begin()) == ModelData::DEFAULT_STATE) {
                agent->states.clear();
                agent->initial_state = state_name;
                // Update initial/end state on all functions
                // As prev has been removed
                for (auto &f : agent->functions) {
                    f.second->initial_state = state_name;
                    f.second->end_state = state_name;
                }
            }
        }
        agent->states.insert(state_name);
        return;
    } else if (state_name == ModelData::DEFAULT_STATE) {
        agent->keepDefaultState = true;
        agent->states.insert(state_name);  // Re add incase it was dropped
    } else {
        THROW exception::InvalidStateName("Agent ('%s') already contains state '%s', "
            "in AgentDescription::newState().",
            agent->name.c_str(), state_name.c_str());
    }
}
void AgentDescription::setInitialState(const std::string &init_state) {
    if (agent->states.find(init_state) != agent->states.end()) {
        this->agent->initial_state = init_state;
        return;
    }
    THROW exception::InvalidStateName("Agent ('%s') does not contain state '%s', "
        "in AgentDescription::setInitialState().",
        agent->name.c_str(), init_state.c_str());
}

AgentFunctionDescription &AgentDescription::Function(const std::string &function_name) {
    auto f = agent->functions.find(function_name);
    if (f != agent->functions.end()) {
        return *f->second->description;
    }
    THROW exception::InvalidAgentFunc("Agent ('%s') does not contain function '%s', "
        "in AgentDescription::Function().",
        agent->name.c_str(), function_name.c_str());
}

/**
 * Const Accessors
 */
std::string AgentDescription::getName() const {
    return agent->name;
}

ModelData::size_type AgentDescription::getStatesCount() const {
    // Downcast, will never have more than UINT_MAX VARS
    return static_cast<ModelData::size_type>(agent->states.size());
}
std::string AgentDescription::getInitialState() const {
    return agent->initial_state;
}
const std::type_index &AgentDescription::getVariableType(const std::string &variable_name) const {
    auto f = agent->variables.find(variable_name);
    if (f != agent->variables.end()) {
        return f->second.type;
    }
    THROW exception::InvalidAgentVar("Agent ('%s') does not contain variable '%s', "
        "in AgentDescription::getVariableType().",
        agent->name.c_str(), variable_name.c_str());
}
size_t AgentDescription::getVariableSize(const std::string &variable_name) const {
    auto f = agent->variables.find(variable_name);
    if (f != agent->variables.end()) {
        return f->second.type_size;
    }
    THROW exception::InvalidAgentVar("Agent ('%s') does not contain variable '%s', "
        "in AgentDescription::getVariableSize().",
        agent->name.c_str(), variable_name.c_str());
}
ModelData::size_type AgentDescription::getVariableLength(const std::string &variable_name) const {
    auto f = agent->variables.find(variable_name);
    if (f != agent->variables.end()) {
        return f->second.elements;
    }
    THROW exception::InvalidAgentVar("Agent ('%s') does not contain variable '%s', "
        "in AgentDescription::getVariableLength().",
        agent->name.c_str(), variable_name.c_str());
}
ModelData::size_type AgentDescription::getVariablesCount() const {
    // Downcast, will never have more than UINT_MAX VARS
    return static_cast<ModelData::size_type>(agent->variables.size());
}
const AgentFunctionDescription& AgentDescription::getFunction(const std::string &function_name) const {
    auto f = agent->functions.find(function_name);
    if (f != agent->functions.end()) {
        return *f->second->description;
    }
    THROW exception::InvalidAgentFunc("Agent ('%s') does not contain function '%s', "
        "in AgentDescription::getFunction().",
        agent->name.c_str(), function_name.c_str());
}
ModelData::size_type AgentDescription::getFunctionsCount() const {
    // Downcast, will never have more than UINT_MAX VARS
    return static_cast<ModelData::size_type>(agent->functions.size());
}

ModelData::size_type AgentDescription::getAgentOutputsCount() const {
    return agent->agent_outputs;
}

const std::set<std::string> &AgentDescription::getStates() const {
    return agent->states;
}

void AgentDescription::setSortPeriod(const unsigned int sortPeriod) {
    agent->sortPeriod = sortPeriod;
}

bool AgentDescription::hasState(const std::string &state_name) const {
    return agent->states.find(state_name) != agent->states.end();
}
bool AgentDescription::hasVariable(const std::string &variable_name) const {
    return agent->variables.find(variable_name) != agent->variables.end();
}
bool AgentDescription::hasFunction(const std::string &function_name) const {
    return agent->functions.find(function_name) != agent->functions.end();
}
bool AgentDescription::isOutputOnDevice() const {
    return agent->isOutputOnDevice();
}

AgentFunctionDescription& AgentDescription::newRTCFunction(const std::string& function_name, const std::string& func_src) {
    if (agent->functions.find(function_name) == agent->functions.end()) {
        // Use Regex to get agent function name, and input/output message type
        std::regex rgx(R"###(.*FLAMEGPU_AGENT_FUNCTION\([ \t]*(\w+),[ \t]*([:\w]+),[ \t]*([:\w]+)[ \t]*\))###");
        std::smatch match;
        if (std::regex_search(func_src, match, rgx)) {
            if (match.size() == 4) {
                std::string code_func_name = match[1];  // not yet clear if this is required
                std::string in_type_name = match[2];
                std::string out_type_name = match[3];
                if (in_type_name == "flamegpu::MessageSpatial3D" || in_type_name == "flamegpu::MessageSpatial2D" || out_type_name == "flamegpu::MessageSpatial3D" || out_type_name == "flamegpu::MessageSpatial2D") {
                    if (agent->variables.find("_auto_sort_bin_index") == agent->variables.end()) {
                        agent->variables.emplace("_auto_sort_bin_index", Variable(1, std::vector<unsigned int> {0}));
                    }
                }
                // set the runtime agent function source in agent function data
                std::string func_src_str = std::string(function_name + "_program\n");
#ifdef OUTPUT_RTC_DYNAMIC_FILES
                func_src_str.append("#line 1 \"").append(code_func_name).append("_impl.cu\"\n");
#endif
                func_src_str.append("#include \"flamegpu/runtime/DeviceAPI.cuh\"\n");
                // Include the required headers for the input message type.
                std::string in_type_include_name = in_type_name.substr(in_type_name.find_last_of("::") + 1);
                func_src_str = func_src_str.append("#include \"flamegpu/runtime/messaging/"+ in_type_include_name + "/" + in_type_include_name + "Device.cuh\"\n");
                // If the message input and output types do not match, also include the input type
                if (in_type_name != out_type_name) {
                    std::string out_type_include_name = out_type_name.substr(out_type_name.find_last_of("::") + 1);
                    func_src_str = func_src_str.append("#include \"flamegpu/runtime/messaging/"+ out_type_include_name + "/" + out_type_include_name + "Device.cuh\"\n");
                }
                // Append line pragma to correct file/line number in same format as OUTPUT_RTC_DYNAMIC_FILES
#ifndef OUTPUT_RTC_DYNAMIC_FILES
                func_src_str.append("#line 1 \"").append(code_func_name).append("_impl.cu\"\n");
#endif
                // If src begins (\r)\n, trim that
                // Append the function source
                if (func_src.find_first_of("\n") <= 1) {
                    func_src_str.append(func_src.substr(func_src.find_first_of("\n") + 1));
                } else {
                    func_src_str.append(func_src);
                }
                auto rtn = std::shared_ptr<AgentFunctionData>(new AgentFunctionData(this->agent->shared_from_this(), function_name, func_src_str, in_type_name, out_type_name, code_func_name));
                agent->functions.insert({function_name, rtn});  // emplace causes nvhpc with gcc 9 to segfault
                return *rtn->description;
            } else {
                THROW exception::InvalidAgentFunc("Runtime agent function('%s') is missing FLAMEGPU_AGENT_FUNCTION arguments e.g. (func_name, message_input_type, message_output_type), "
                    "in AgentDescription::newRTCFunction().",
                    agent->name.c_str());
            }
        } else {
            THROW exception::InvalidAgentFunc("Runtime agent function('%s') is missing FLAMEGPU_AGENT_FUNCTION, "
                "in AgentDescription::newRTCFunction().",
                agent->name.c_str());
        }
    }
    THROW exception::InvalidAgentFunc("Agent ('%s') already contains function '%s', "
        "in AgentDescription::newRTCFunction().",
        agent->name.c_str(), function_name.c_str());
}

AgentFunctionDescription& AgentDescription::newRTCFunctionFile(const std::string& function_name, const std::string& file_path) {
    if (agent->functions.find(function_name) == agent->functions.end()) {
        // Load file and forward to regular RTC method
        std::ifstream file;
        file.open(file_path);
        if (file.is_open()) {
            std::stringstream sstream;
            sstream << file.rdbuf();
            const std::string func_src = sstream.str();
            return newRTCFunction(function_name, func_src);
        }
        THROW exception::InvalidFilePath("Unable able to open file '%s', "
            "in AgentDescription::newRTCFunctionFile().",
            file_path.c_str());
    }
    THROW exception::InvalidAgentFunc("Agent ('%s') already contains function '%s', "
        "in AgentDescription::newRTCFunctionFile().",
        agent->name.c_str(), function_name.c_str());
}

}  // namespace flamegpu
