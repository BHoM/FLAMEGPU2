 /**
 * @file ModelDescription.cpp
 * @authors Paul
 * @date
 * @brief
 *
 * @see
 * @warning
 */

#include "ModelDescription.h"
#include "../io/statereader.h"

ModelDescription::ModelDescription(const std::string model_name) : agents(), messages(), name(model_name) {}

ModelDescription::~ModelDescription() {}

const std::string ModelDescription::getName() const {
	return name;
}

void ModelDescription::addAgent(const AgentDescription &agent) {
	agents.insert(AgentMap::value_type(agent.getName(), agent));
}

void ModelDescription::addMessage(const MessageDescription &message) {
	messages.insert(MessageMap::value_type(message.getName(), message));
}

/** 
* Initialise the simulation. Allocated host and device memory. Reads the initial agent configuration from XML.
* @param input	XML file path for agent initial configuration
*/
void ModelDescription::initialise(const AgentDescription &agent, char* input)
{
	//read initial states
	StateReader stateread_;
	stateread_.readInitialStates(agent, input);

}


const AgentDescription& ModelDescription::getAgentDescription(const std::string agent_name) const{
	AgentMap::const_iterator iter;
	iter = agents.find(agent_name);
	if (iter == agents.end())
		throw InvalidAgentVar();
	return iter->second;
}

const MessageDescription& ModelDescription::getMessageDescription(const std::string message_name) const{
	MessageMap::const_iterator iter;
	iter = messages.find(message_name);
	if (iter == messages.end())
		throw InvalidMessageVar();
	return iter->second;
}

const AgentMap& ModelDescription::getAgentMap() const {
	return agents;
}

const MessageMap& ModelDescription::getMessageMap() const {
	return messages;
}
