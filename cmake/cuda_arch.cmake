# Build a list of gencode arguments, based on CUDA verison.
# Accepts user override via CUDA_ARCH
# CMAKE > 3.18 introduces CUDA_ARCHITECTURES as a cmake-native way of generating gencodes (Policy CMP0104). Set the value to OFF to prevent errors for it being not provided.
if(${CMAKE_VERSION} VERSION_GREATER_EQUAL "3.18")
    set(CMAKE_CUDA_ARCHITECTURES "OFF")
endif()


# Check if any have been provided by the users
string(LENGTH "${CUDA_ARCH}" CUDA_ARCH_LENGTH)

# Define the default compute capabilites incase not provided by the user
set(DEFAULT_CUDA_ARCH "20;35;50;60;70;80;")

# Get the valid options for the current compiler.
# Run nvcc --help to get the help string which contains all valid compute_ sm_ for that version.
execute_process(COMMAND ${CMAKE_CUDA_COMPILER} "--help" OUTPUT_VARIABLE NVCC_HELP_STR ERROR_VARIABLE NVCC_HELP_STR)
# Match all comptue_XX or sm_XXs
string(REGEX MATCHALL "'(sm|compute)_[0-9]+'" SUPPORTED_CUDA_ARCH "${NVCC_HELP_STR}" )
# Strip just the numeric component
string(REGEX REPLACE "'(sm|compute)_([0-9]+)'" "\\2" SUPPORTED_CUDA_ARCH "${SUPPORTED_CUDA_ARCH}" )
# Remove dupes and sort to build the correct list of supported CUDA_ARCH.
list(REMOVE_DUPLICATES SUPPORTED_CUDA_ARCH)
list(REMOVE_ITEM SUPPORTED_CUDA_ARCH "")
list(SORT SUPPORTED_CUDA_ARCH)

# Update defaults to only be those supported
# @todo might be better to instead do a dry run compilation with each gencode to validate?
foreach(ARCH IN LISTS DEFAULT_CUDA_ARCH)
    if (NOT ARCH IN_LIST SUPPORTED_CUDA_ARCH)
        list(REMOVE_ITEM DEFAULT_CUDA_ARCH "${ARCH}")
    endif()
    list(REMOVE_DUPLICATES CUDA_ARCH)
    list(REMOVE_ITEM CUDA_ARCH "")
    list(SORT CUDA_ARCH)
endforeach()


if(NOT CUDA_ARCH_LENGTH EQUAL 0)
    # Convert user provided string argument to a list.
    string (REPLACE " " ";" CUDA_ARCH "${CUDA_ARCH}")
    string (REPLACE "," ";" CUDA_ARCH "${CUDA_ARCH}")

    # Remove duplicates, empty items and sort.
    list(REMOVE_DUPLICATES CUDA_ARCH)
    list(REMOVE_ITEM CUDA_ARCH "")
    list(SORT CUDA_ARCH)

    # Validate the list.
    foreach(ARCH IN LISTS CUDA_ARCH)
        if (NOT ARCH IN_LIST SUPPORTED_CUDA_ARCH)
            message(WARNING
            "  CUDA_ARCH '${ARCH}' not supported by CUDA ${CMAKE_CUDA_COMPILER_VERSION} and is being ignored.\n"
            "  Choose from: ${SUPPORTED_CUDA_ARCH}")
            list(REMOVE_ITEM CUDA_ARCH "${ARCH}")
        endif()
    endforeach()

    # @todo - validate that the CUDA_ARCH provided are supported by the compiler
endif()

# If the list is empty post validation, set it to the (validated) defaults
list(LENGTH CUDA_ARCH CUDA_ARCH_LENGTH)
if(CUDA_ARCH_LENGTH EQUAL 0)
    set(CUDA_ARCH ${DEFAULT_CUDA_ARCH})
endif()

# @todo - LTO needs to be disabled if nvcc is too old.

# Propagate the validated values to the parent scope, to reduce warning duplication.
get_directory_property(hasParent PARENT_DIRECTORY)
if(hasParent)
    set(CUDA_ARCH ${CUDA_ARCH} PARENT_SCOPE)
endif()
# If the list is somehow empty now, do not set any gencodes arguments, instead using the compiler defaults.
list(LENGTH CUDA_ARCH CUDA_ARCH_LENGTH)
if(NOT CUDA_ARCH_LENGTH EQUAL 0)
    # Only do this if required.I.e. CUDA_ARCH is the same as the last time this file was included
    if(NOT CUDA_ARCH_APPLIED EQUAL CUDA_ARCH)
        message(STATUS "Generating Compute Capabilities: ${CUDA_ARCH}")
        if(hasParent)
            set(CUDA_ARCH_APPLIED "${CUDA_ARCH}" PARENT_SCOPE )
        endif()
    endif()
    set(MIN_CUDA_ARCH)
    # Convert to gencode arguments

    foreach(ARCH IN LISTS CUDA_ARCH)
	if(USE_LTO)
          add_compile_options("$<$<COMPILE_LANGUAGE:CUDA>:SHELL:-gencode arch=compute_${ARCH}$<COMMA>code=lto_${ARCH}>")
        else()
          add_compile_options("$<$<COMPILE_LANGUAGE:CUDA>:SHELL:-gencode arch=compute_${ARCH}$<COMMA>code=sm_${ARCH}>")
          add_link_options("$<DEVICE_LINK:SHELL:-gencode arch=compute_${ARCH}$<COMMA>code=sm_${ARCH}>")
        endif()
    endforeach()

    # Add the last arch again as compute_, compute_ to enable forward looking JIT
    list(GET CUDA_ARCH -1 LAST_ARCH)
    
    # LTO doesn't (yet) support JIT and executables must link against a single architecture. I.e. USE_LTO should only be supported if  CUDA 11.2+ and CUDA_ARCH has a length of 1?
    # The docs and blog post seem to disagree on this point
    if(USE_LTO)
        # From the docs: 
        # > If you want to compile using -gencode to build for multiple arch, use -dc -gencode arch=compute_NN,code=lto_NN to specify the intermediate IR to be stored (where NN is the SM architecture version). Then use -dlto option to link for a specific architecture. There is no JIT support for LTO codes so you need to statically link to a final sm_NN architecture.
        # Not sure what the point of building for multiple arches is if you have to then link to a single one.
        add_link_options("$<DEVICE_LINK:SHELL:-dlto -arch=sm_${LAST_ARCH}>")
    else()
        # Currently only adding the last arch when not LTOing. 
        add_compile_options("$<$<COMPILE_LANGUAGE:CUDA>:SHELL:-gencode arch=compute_${LAST_ARCH}$<COMMA>code=compute_${LAST_ARCH}>")
        add_link_options("$<DEVICE_LINK:SHELL:-gencode arch=compute_${LAST_ARCH}$<COMMA>code=compute_${LAST_ARCH}>")
    endif()
    # Dump the callgraph to see if it points out where registers come from.
    # add_link_options("$<DEVICE_LINK:SHELL:-Xnvlink -dump-callgraph>")
    
    # Enable verbose ptxas 
    add_compile_options("$<$<COMPILE_LANGUAGE:CUDA>:SHELL:-Xptxas -v>")
    #add_link_options("$<$<COMPILE_LANGUAGE:CUDA>:SHELL:-gencode arch=compute_${LAST_ARCH},code=compute_${LAST_ARCH}>")

    # Get the minimum device architecture to pass through to nvcc to enable graceful failure prior to cuda execution.
    list(GET CUDA_ARCH 0 MIN_CUDA_ARCH)

    # Set the minimum arch flags for all compilers
    add_definitions(-DMIN_CUDA_ARCH=${MIN_CUDA_ARCH})
else()
    message(STATUS "Generating default CUDA Compute Capabilities ${CUDA_ARCH}")
endif()

# Supress deprecated architecture warnings, as they are not fitered out by checking against nvcc help.
# Ideally a warning would be output once at config time (i.e. above) and not at every file compilation.
# But this is challenging due to multiline string detection.
# Could potentially compile a simple program, without this flag to detect if its valid/deprecated? Would likely increase build time.
set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} -Wno-deprecated-gpu-targets")

# If CUDA 11.2+, can build multiple architectures in parallel. Note this will be multiplicative against the number of threads launched for parallel cmake build, which may anger some systems.
if(CMAKE_CUDA_COMPILER_VERSION VERSION_GREATER_EQUAL "11.2" AND USE_NVCC_THREADS AND DEFINED NVCC_THREADS AND NVCC_THREADS GREATER_EQUAL 0)
    set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} --threads ${NVCC_THREADS}")
endif()

