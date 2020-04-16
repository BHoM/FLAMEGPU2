#ifndef INCLUDE_FLAMEGPU_VISUALISER_STATICMODELVIS_H_
#define INCLUDE_FLAMEGPU_VISUALISER_STATICMODELVIS_H_
#include "config/ModelConfig.h"

class StaticModelVis {
 public:
    /**
     * Reference which this interface manages
     */
    explicit StaticModelVis(ModelConfig::StaticModel &_m);
    /**
     * Scale each dimension of the model to the corresponding world scales
     * @param xLen World scale of the model's on the x axis
     * @param yLen World scale of the model's on the y axis
     * @param zLen World scale of the model's on the z axis
     * @note Y is considered the vertical axis
     */
    void setModelScale(float xLen, float yLen, float zLen);
    /**
     * Uniformly scale model so that max dimension equals this
     * @param maxLen World scale of the model's relative to the axis which it is
     * largest
     */
    void setModelScale(float maxLen);
    /**
     * Translation applied to the model
     * @param x X coordinate
     * @param y Y coordinate
     * @param z Z coordinate
     * @note Y is considered the vertical axis
     */
    void setModelLocation(float x, float y, float z);
    /**
     * Rotation applied to the model (before translation)
     * @param x X component of axis vector
     * @param y Y component of axis vector
     * @param z Z component of axis vector
     * @param radians How far the model is rotated about the axis
     * @note Y is considered the vertical axis
     */
    void setModelRotation(float x, float y, float z, float radians);

 private:
    ModelConfig::StaticModel &m;
};

#endif  // INCLUDE_FLAMEGPU_VISUALISER_STATICMODELVIS_H_
