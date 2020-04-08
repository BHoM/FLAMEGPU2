#include "flamegpu/visualiser/ModelVis.h"

#include "flamegpu/gpu/CUDAAgentModel.h"
#include "flamegpu/model/ModelData.h"

ModelVis::ModelVis(const CUDAAgentModel &_model)
    : modelCfg(_model.getModelDescription().name.c_str())
    , model(_model)
    , modelData(_model.getModelDescription()) { }
AgentVis &ModelVis::addAgent(const std::string &agent_name) {
    // If agent exists
    if (modelData.agents.find(agent_name) != modelData.agents.end()) {
        // If agent is not already in vis map
        auto visAgent = agents.find(agent_name);
        if (visAgent == agents.end()) {
            // Create new vis agent
            return agents.emplace(agent_name, AgentVis(model.getCUDAAgent(agent_name))).first->second;
        }
        return visAgent->second;
    }
    THROW InvalidAgentName("Agent name '%s' was not found within the model description hierarchy, "
        "in ModelVis::addAgent()\n",
        agent_name.c_str());
}
AgentVis &ModelVis::Agent(const std::string &agent_name) {
    // If agent exists
    if (modelData.agents.find(agent_name) != modelData.agents.end()) {
        // If agent is not already in vis map
        auto visAgent = agents.find(agent_name);
        if (visAgent != agents.end()) {
            // Create new vis agent
            return visAgent->second;
        }
        THROW InvalidAgentName("Agent name '%s' has not been marked for visualisation, ModelVis::addAgent() must be called first, "
            "in ModelVis::Agent()\n",
            agent_name.c_str());
    }
    THROW InvalidAgentName("Agent name '%s' was not found within the model description hierarchy, "
        "in ModelVis::Agent()\n",
        agent_name.c_str());
}


// Below methods are related to executing the visualiser
void ModelVis::activate() {
    // Only execute if background thread is not active
    if (!visualiser || !visualiser->isRunning()) {
        // Init visualiser
        visualiser = std::make_unique<FLAMEGPU_Visualisation>(modelCfg);  // Window resolution
        for (auto &agent : agents) {
            // If x and y aren't set, throw exception
            if (agent.second.x_var == "" || agent.second.y_var == "") {
                THROW VisualisationException("Agent '%s' has not had x and y variables set, "
                    "in ModelVis::activate()\n",
                    agent.second.agentData.name.c_str());
            }
            agent.second.initBindings(visualiser);
        }
        visualiser->start();
    }
}

void ModelVis::deactivate() {
    if (visualiser && visualiser->isRunning()) {
        visualiser->stop();
        join();
        visualiser.reset();
    }
}

void ModelVis::join() {
    if (visualiser) {
        visualiser->join();
        visualiser.reset();
    }
}
bool ModelVis::isRunning() const {
    return visualiser ? visualiser->isRunning() : false;
}
void ModelVis::updateBuffers() {
    if (visualiser) {
        for (auto &a : agents) {
            a.second.requestBufferResizes(visualiser);
        }
        // wait for lock visualiser (its probably executing render loop in separate thread) This might not be 100% safe. RequestResize might need extra thread safety.
        visualiser->lockMutex();
        for (auto &a : agents) {
            a.second.updateBuffers(visualiser);
        }
        visualiser->releaseMutex();
    }
}




void ModelVis::setWindowTitle(const std::string& title) {
    ModelConfig::setString(&modelCfg.windowTitle, title);
}
void ModelVis::setWindowDimensions(const unsigned int& width, const unsigned int& height) {
    modelCfg.windowDimensions[0] = width;
    modelCfg.windowDimensions[1] = height;
}
void ModelVis::setClearColor(const float& red, const float& green, const float& blue) {
    modelCfg.clearColor[0] = red;
    modelCfg.clearColor[1] = green;
    modelCfg.clearColor[2] = blue;
}
void ModelVis::setFPSVisible(const bool& showFPS) {
    modelCfg.fpsVisible = showFPS;
}

void ModelVis::setFPSColor(const float& red, const float& green, const float& blue) {
    modelCfg.fpsColor[0] = red;
    modelCfg.fpsColor[1] = green;
    modelCfg.fpsColor[2] = blue;
}