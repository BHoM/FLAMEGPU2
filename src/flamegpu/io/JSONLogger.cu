#include "flamegpu/io/JSONLogger.h"

#include <rapidjson/writer.h>
#include <rapidjson/prettywriter.h>
#include <rapidjson/stringbuffer.h>
#include <iostream>
#include <fstream>
#include <string>

#include "flamegpu/sim/RunPlan.h"
#include "flamegpu/sim/LogFrame.h"

namespace flamegpu {
namespace io {

JSONLogger::JSONLogger(const std::string &outPath, bool _prettyPrint, bool _truncateFile)
    : out_path(outPath)
    , prettyPrint(_prettyPrint)
    , truncateFile(_truncateFile) { }

void JSONLogger::log(const RunLog &log, const RunPlan &plan, bool logSteps, bool logExit, bool logStepTime, bool logExitTime) const {
  logCommon(log, &plan, false, logSteps, logExit, logStepTime, logExitTime);
}
void JSONLogger::log(const RunLog &log, bool logConfig, bool logSteps, bool logExit, bool logStepTime, bool logExitTime) const {
  logCommon(log, nullptr, logConfig, logSteps, logExit, logStepTime, logExitTime);
}

template<typename T>
void JSONLogger::writeAny(T &writer, const util::Any &value, const unsigned int &elements) const {
    // Output value
    if (elements > 1) {
        writer.StartArray();
    }
    // Loop through elements, to construct array
    for (unsigned int el = 0; el < elements; ++el) {
        if (value.type == std::type_index(typeid(float))) {
            writer.Double(static_cast<const float*>(value.ptr)[el]);
        } else if (value.type == std::type_index(typeid(double))) {
            writer.Double(static_cast<const double*>(value.ptr)[el]);
        } else if (value.type == std::type_index(typeid(int64_t))) {
            writer.Int64(static_cast<const int64_t*>(value.ptr)[el]);
        } else if (value.type == std::type_index(typeid(uint64_t))) {
            writer.Uint64(static_cast<const uint64_t*>(value.ptr)[el]);
        } else if (value.type == std::type_index(typeid(int32_t))) {
            writer.Int(static_cast<const int32_t*>(value.ptr)[el]);
        } else if (value.type == std::type_index(typeid(uint32_t))) {
            writer.Uint(static_cast<const uint32_t*>(value.ptr)[el]);
        } else if (value.type == std::type_index(typeid(int16_t))) {
            writer.Int(static_cast<const int16_t*>(value.ptr)[el]);
        } else if (value.type == std::type_index(typeid(uint16_t))) {
            writer.Uint(static_cast<const uint16_t*>(value.ptr)[el]);
        } else if (value.type == std::type_index(typeid(int8_t))) {
            writer.Int(static_cast<int32_t>(static_cast<const int8_t*>(value.ptr)[el]));  // Char outputs weird if being used as an integer
        } else if (value.type == std::type_index(typeid(uint8_t))) {
            writer.Uint(static_cast<uint32_t>(static_cast<const uint8_t*>(value.ptr)[el]));  // Char outputs weird if being used as an integer
        } else if (value.type == std::type_index(typeid(char))) {
            writer.Int(static_cast<int32_t>(static_cast<const char*>(value.ptr)[el]));  // Char outputs weird if being used as an integer
        } else {
            THROW exception::RapidJSONError("Attempting to export value of unsupported type '%s', "
                "in JSONLogger::writeAny()\n", value.type.name());
        }
    }
    if (elements > 1) {
        writer.EndArray();
    }
}
template<typename T>
void JSONLogger::writeLogFrame(T& writer, const StepLogFrame& frame, bool logTime) const {
    writer.StartObject();
    {
        if (logTime) {
            writer.Key("step_time");
            writer.Double(frame.getStepTime());
        }
        writeCommonLogFrame(writer, frame);
    }
    writer.EndObject();
}
template<typename T>
void JSONLogger::writeLogFrame(T& writer, const ExitLogFrame& frame, bool logTime) const {
    writer.StartObject();
    {
        if (logTime) {
            writer.Key("rtc_time");
            writer.Double(frame.getRTCTime());
            writer.Key("init_time");
            writer.Double(frame.getInitTime());
            writer.Key("exit_time");
            writer.Double(frame.getExitTime());
            writer.Key("total_time");
            writer.Double(frame.getTotalTime());
        }
        writeCommonLogFrame(writer, frame);
    }
    writer.EndObject();
}
template<typename T>
void JSONLogger::writeCommonLogFrame(T &writer, const LogFrame &frame) const {
    // Add static items
    writer.Key("step_index");
    writer.Uint(frame.getStepCount());
    if (frame.getEnvironment().size()) {
        // Add dynamic environment values
        writer.Key("environment");
        writer.StartObject();
        {
            for (const auto &prop : frame.getEnvironment()) {
                writer.Key(prop.first.c_str());
                // Log value
                writeAny(writer, prop.second, prop.second.elements);
            }
        }
        writer.EndObject();
    }

    if (frame.getAgents().size()) {
        // Add dynamic agent values
        writer.Key("agents");
        writer.StartObject();
        {
            // This assumes that sort order places all agents of same name, different state consecutively
            std::string current_agent;
            for (const auto &agent : frame.getAgents()) {
                // Start/end new agent
                if (current_agent != agent.first.first) {
                    if (!current_agent.empty())
                        writer.EndObject();
                    current_agent = agent.first.first;
                    writer.Key(current_agent.c_str());
                    writer.StartObject();
                }
                // Start new state
                writer.Key(agent.first.second.c_str());
                writer.StartObject();
                {
                    // Log agent count if provided
                    if (agent.second.second != UINT_MAX) {
                        writer.Key("count");
                        writer.Uint(agent.second.second);
                    }
                    if (agent.second.first.size()) {
                        writer.Key("variables");
                        writer.StartObject();
                        // This assumes that sort order places all variables of same name, different reduction consecutively
                        std::string current_variable;
                        // Log each reduction
                        for (auto &var : agent.second.first) {
                            // Start/end new variable
                            if (current_variable != var.first.name) {
                                if (!current_variable.empty())
                                    writer.EndObject();
                                current_variable = var.first.name;
                                writer.Key(current_variable.c_str());
                                writer.StartObject();
                            }
                            // Build name key for the variable
                            writer.Key(LoggingConfig::toString(var.first.reduction));
                            // Log value
                            writeAny(writer, var.second, 1);
                        }
                        if (!current_variable.empty())
                            writer.EndObject();
                        writer.EndObject();
                    }
                }
                writer.EndObject();
            }
            if (!current_agent.empty())
                writer.EndObject();
        }
        writer.EndObject();
    }
}

template<typename T>
void JSONLogger::logConfig(T &writer, const RunLog &log) const {
    writer.Key("config");
    writer.StartObject();
    {
        writer.Key("random_seed");
        writer.Uint64(log.getRandomSeed());
    }
    writer.EndObject();
}
template<typename T>
void JSONLogger::logConfig(T &writer, const RunPlan &plan) const {
    writer.Key("config");
    writer.StartObject();
    {
        // Add static items
        writer.Key("random_seed");
        writer.Uint64(plan.getRandomSimulationSeed());
        writer.Key("steps");
        writer.Uint(plan.getSteps());
        // Add dynamic environment overrides
        writer.Key("environment");
        writer.StartObject();
        {
            for (const auto &prop : plan.property_overrides) {
                const EnvironmentDescription::PropData &env_prop = plan.environment->at(prop.first);
                writer.Key(prop.first.c_str());
                writeAny(writer, prop.second, env_prop.data.elements);
            }
        }
        writer.EndObject();
    }
    writer.EndObject();
}
template<typename T>
void JSONLogger::logPerformanceSpecs(T& writer, const RunLog& log) const {
    writer.Key("performance_specs");
    writer.StartObject();
    {
        // Add static items
        writer.Key("device_name");
        writer.String(log.getPerformanceSpecs().device_name.c_str());
        writer.Key("device_cc_major");
        writer.Int(log.getPerformanceSpecs().device_cc_major);
        writer.Key("device_cc_minor");
        writer.Int(log.getPerformanceSpecs().device_cc_minor);
        writer.Key("cuda_version");
        writer.Int(log.getPerformanceSpecs().cuda_version);
        writer.Key("seatbelts");
        writer.Bool(log.getPerformanceSpecs().seatbelts);
        writer.Key("flamegpu_version");
        writer.String(log.getPerformanceSpecs().flamegpu_version.c_str());
    }
    writer.EndObject();
}
template<typename T>
void JSONLogger::logSteps(T &writer, const RunLog &log, bool logTime) const {
    writer.Key("steps");
    writer.StartArray();
    {
        for (const auto &step : log.getStepLog()) {
            writeLogFrame(writer, step, logTime);
        }
    }
    writer.EndArray();
}
template<typename T>
void JSONLogger::logExit(T &writer, const RunLog &log, bool logTime) const {
    writer.Key("exit");
    writeLogFrame(writer, log.getExitLog(), logTime);
}

template<typename T>
void JSONLogger::logCommon(T &writer, const RunLog &log, const RunPlan *plan, bool doLogConfig, bool doLogSteps, bool doLogExit, bool doLogStepTime, bool doLogExitTime) const {
    // Begin json output object
    writer->StartObject();
    {
        // Log config
        if (plan) {
            logConfig(*writer, *plan);
        } else if (doLogConfig) {
            logConfig(*writer, log);
        }
        if (doLogStepTime || doLogExitTime) {
            logPerformanceSpecs(*writer, log);
        }

        // Log step log
        if (doLogSteps) {
            logSteps(*writer, log, doLogStepTime);
        }

        // Log exit log
        if (doLogExit) {
            logExit(*writer, log, doLogExitTime);
        }
    }
    // End Json file
    writer->EndObject();
}
void JSONLogger::logCommon(const RunLog &log, const RunPlan *plan, bool doLogConfig, bool doLogSteps, bool doLogExit, bool doLogStepTime, bool doLogExitTime) const {
    // Init writer
    rapidjson::StringBuffer s;
    if (prettyPrint) {
        // rapidjson::Writer doesn't have virtual methods, so can't pass rapidjson::PrettyWriter around as ptr to rapidjson::writer
        rapidjson::PrettyWriter<rapidjson::StringBuffer>* writer = new rapidjson::PrettyWriter<rapidjson::StringBuffer>(s);
        writer->SetIndent('\t', 1);
        logCommon(writer, log, plan, doLogConfig, doLogSteps, doLogExit, doLogStepTime, doLogExitTime);
        delete writer;
    } else {
        rapidjson::Writer<rapidjson::StringBuffer> *writer = new rapidjson::Writer<rapidjson::StringBuffer>(s);
        logCommon(writer, log, plan, doLogConfig, doLogSteps, doLogExit, doLogStepTime, doLogExitTime);
        delete writer;
    }
    // Perform output
    std::ofstream out(out_path, truncateFile ? std::ofstream::trunc : std::ofstream::app);
    if (!out.is_open()) {
        THROW exception::RapidJSONError("Unable to open file '%s' for writing\n", out_path.c_str());
    }

    out << s.GetString();
    out << "\n";
    out.close();
}

}  // namespace io
}  // namespace flamegpu
