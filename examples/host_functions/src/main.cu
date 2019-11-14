#include <iostream>
#include <cstdio>
#include <cstdlib>

#include "flamegpu/flame_api.h"
#include "flamegpu/runtime/flamegpu_api.h"

FLAMEGPU_AGENT_FUNCTION(device_function) {
    const float &prop_float = FLAMEGPU->environment.get<float>("float");
    const int16_t &prop_int16 = FLAMEGPU->environment.get<int16_t>("int16_t");
    const uint64_t &prop_uint64_0 = FLAMEGPU->environment.get<uint64_t>("uint64_t", 0);
    const uint64_t &prop_uint64_1 = FLAMEGPU->environment.get<uint64_t>("uint64_t", 1);
    const uint64_t &prop_uint64_2 = FLAMEGPU->environment.get<uint64_t>("uint64_t", 2);
    if (blockIdx.x * blockDim.x + threadIdx.x == 0) {
        printf("Agent Function[Thread 0]! Properties(Float: %g, int16: %hd, uint64[3]: {%llu, %llu, %llu})\n", prop_float, prop_int16, prop_uint64_0, prop_uint64_1, prop_uint64_2);
    }
    return ALIVE;
}
FLAMEGPU_INIT_FUNCTION(init_function) {
    float min_x = FLAMEGPU->agent("agent").min<float>("x");
    float max_x = FLAMEGPU->agent("agent").max<float>("x");
    printf("Init Function! (Min: %g, Max: %g)\n", min_x, max_x);
}
FLAMEGPU_CUSTOM_REDUCTION(customSum, a, b) {
    return a + b;
}
FLAMEGPU_CUSTOM_TRANSFORM(customTransform, a) {
    return (a == 0 || a == 1) ? 1 : 0;
}
FLAMEGPU_STEP_FUNCTION(step_function) {
    auto agent = FLAMEGPU->agent("agent");
    int sum_a = agent.sum<int>("a");
    int custom_sum_a = agent.reduce<int>("a", customSum, 0);
    unsigned int count_a = agent.count<int>("a", 1);
    unsigned int countif_a = agent.transformReduce<int, unsigned int>("a", customTransform, customSum, 0u);
    printf("Step Function! (Sum: %d, CustomSum: %d, Count: %u, CustomCountIf: %u)\n", sum_a, custom_sum_a, count_a, countif_a);
}
FLAMEGPU_EXIT_FUNCTION(exit_function) {
    float uniform_real = FLAMEGPU->random.uniform<float>();
    int uniform_int = FLAMEGPU->random.uniform<int>(1, 10);
    float normal = FLAMEGPU->random.normal<float>();
    float logNormal = FLAMEGPU->random.logNormal<float>(1, 1);
    printf("Exit Function! (%g, %i, %g, %g)\n",
        uniform_real, uniform_int, normal, logNormal);
}
FLAMEGPU_HOST_FUNCTION(host_function) {
    std::vector<unsigned int> hist_x = FLAMEGPU->agent("agent").histogramEven<float>("x", 8, -0.5, 1023.5);
    printf("Host Function! (Hist: [%u, %u, %u, %u, %u, %u, %u, %u]\n",
        hist_x[0], hist_x[1], hist_x[2], hist_x[3], hist_x[4], hist_x[5], hist_x[6], hist_x[7]);
    FLAMEGPU->environment.set<int16_t>("int16_t", FLAMEGPU->environment.get<int16_t>("int16_t") + 1);
}
FLAMEGPU_EXIT_CONDITION(exit_condition) {
    const float CHANCE = 0.15f;
    float uniform_real = FLAMEGPU->random.uniform<float>();
    printf("Exit Condition! (Rolled: %g)\n", uniform_real);
    if (uniform_real < CHANCE) {
        printf("Rolled number is less than %g, exiting!\n", CHANCE);
        return EXIT;
    }
    return CONTINUE;
}


int main(void) {
    const unsigned int AGENT_COUNT = 1024;
    ModelDescription flame_model("host_functions_example");

    // {//agent
        AgentDescription agent("agent");
        agent.addAgentVariable<float>("x");
        agent.addAgentVariable<int>("a");

        // {// Device fn
            AgentFunctionDescription deviceFn("device_function");
            deviceFn.setFunction(&device_function);
            agent.addAgentFunction(deviceFn);
        // }

        flame_model.addAgent(agent);

        // Init pop
        AgentPopulation population(agent, AGENT_COUNT);
        for (unsigned int i = 0; i < AGENT_COUNT; i++) {
            AgentInstance instance = population.getNextInstance();
            instance.setVariable<float>("x", static_cast<float>(i));
            instance.setVariable<int>("a", i % 2 == 0 ? 1 : 0);
        }
    // }

    /**
     * GLOBALS
     */
    EnvironmentDescription envProperties;
    {
        envProperties.add<float>("float", 12.0f);
        envProperties.add<int16_t>("int16_t", 0);
        envProperties.add<uint64_t, 3>("uint64_t", {11llu, 12llu, 13llu});
        flame_model.setEnvironment(envProperties);
    }
     /**
      * Simulation
      */

    Simulation simulation(flame_model);

    // Attach init/step/exit functions and exit condition
    // {
        simulation.addInitFunction(&init_function);
        simulation.addStepFunction(&step_function);
        simulation.addExitFunction(&exit_function);
        simulation.addExitCondition(&exit_condition);
        // Run until exit condition triggers
        simulation.setSimulationSteps(0);
    // }

    // {
        SimulationLayer devicefn_layer(simulation, "devicefn_layer");
        devicefn_layer.addAgentFunction("device_function");
        simulation.addSimulationLayer(devicefn_layer);
        // TODO: simulation.insertFunctionLayerAt(layer, int index) //Should insert at the layer position and move all other layer back
    // }

    // {
        SimulationLayer hostfn_layer(simulation, "hostfn_layer");
        hostfn_layer.addHostFunction(&host_function);
        simulation.addSimulationLayer(hostfn_layer);
    // }


    /**
     * Execution
     */
    CUDAAgentModel cuda_model(flame_model);
    cuda_model.setInitialPopulationData(population);
    cuda_model.simulate(simulation);

    cuda_model.getPopulationData(population);

    getchar();
    return 0;
}