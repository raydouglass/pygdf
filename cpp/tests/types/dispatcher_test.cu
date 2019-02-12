/*
 * Copyright (c) 2018, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include <cudf.h>
#include <utilities/type_dispatcher.hpp>
#include "gtest/gtest.h"
#include "tests/utilities/cudf_test_fixtures.h"
#include "utilities/tuple_for_each.hpp"
#include <thrust/device_vector.h>
#include <cstdint>

/**
 * @file dispatcher_test.cu
 * @brief Tests the type_dispatcher
 */

struct DispatcherTest : public GdfTest {
  std::tuple<int8_t, int16_t, int32_t, int64_t, float, double, cudf::date32,
             cudf::date64, cudf::timestamp, cudf::category>
      supported_types;

  std::vector<gdf_dtype> supported_dtypes{
      GDF_INT8,    GDF_INT16,  GDF_INT32,  GDF_INT64,     GDF_FLOAT32,
      GDF_FLOAT64, GDF_DATE32, GDF_DATE64, GDF_TIMESTAMP, GDF_CATEGORY};

  // These types are not supported by the type_dispatcher
  std::vector<gdf_dtype> unsupported_dtypes{GDF_invalid, GDF_STRING};
};

TEST_F(DispatcherTest, NumberOfTypesTest) {
  // N_GDF_TYPES indicates how many enums there are in `gdf_dtype`,
  // therefore, if a gdf_dtype is added without updating this test, the test
  // will fail
  const size_t expected_num_supported_dtypes =
      N_GDF_TYPES - unsupported_dtypes.size();

  // Note: If this test fails, that means a type was added to gdf_dtype
  // without adding it to the `supported_dtypes` list in this test fixture
  ASSERT_EQ(expected_num_supported_dtypes, supported_dtypes.size())
      << "Number of supported types does not match what was expected.";

  ASSERT_EQ(expected_num_supported_dtypes,
            std::tuple_size<decltype(supported_types)>::value);
}

namespace {
template <typename ExpectedType>
struct type_tester {
  template <typename DispatchedType>
  bool operator()() {
    return std::is_same<ExpectedType, DispatchedType>::value;
  }
};
}  // namespace

// Ensure that the type_to_gdf_dtype trait maps to the correct gdf_dtype
TEST_F(DispatcherTest, TraitsTest) {
  cudf::detail::for_each(supported_types, [](auto type_dummy) {
    using T = decltype(type_dummy);
    EXPECT_TRUE(cudf::type_dispatcher(cudf::type_to_gdf_dtype<T>::value,
                                      type_tester<T>{}));
  });
}

namespace {
struct test_functor {
  template <typename T>
  __host__ __device__ bool operator()(gdf_dtype type_id) {
    return (type_id == cudf::type_to_gdf_dtype<T>::value);
  }
};

__global__ void dispatch_test_kernel(gdf_dtype type, bool* d_result) {
  if (0 == threadIdx.x + blockIdx.x * blockDim.x)
    *d_result = cudf::type_dispatcher(type, test_functor{}, type);
}
}  // namespace

TEST_F(DispatcherTest, HostDispatchFunctor) {
  for (auto const& t : this->supported_dtypes) {
    bool result = cudf::type_dispatcher(t, test_functor{}, t);
    EXPECT_TRUE(result);
  }
}

TEST_F(DispatcherTest, DeviceDispatchFunctor) {
  thrust::device_vector<bool> result(1);
  for (auto const& t : this->supported_dtypes) {
    dispatch_test_kernel<<<1, 1>>>(t, result.data().get());
    cudaDeviceSynchronize();
    EXPECT_EQ(true, result[0]);
  }
}

// These tests excerise the `assert(false)` on unsupported dtypes in the
// type_dispatcher The assert is only present if the NDEBUG macro isn't defined
#ifndef NDEBUG

// Unsuported gdf_dtypes should cause program to exit
TEST_F(DispatcherDeathTest, UnsuportedTypesTest) {
  testing::FLAGS_gtest_death_test_style = "threadsafe";
  for (auto const& t : unsupported_dtypes) {
    EXPECT_DEATH(cudf::type_dispatcher(t, test_functor{}, t), "");
  }
}

// Unsuported gdf_dtypes in device code should set appropriate error code
// and invalidates device context
TEST_F(DispatcherDeathTest, DeviceDispatchFunctor) {
  testing::FLAGS_gtest_death_test_style = "threadsafe";
  thrust::device_vector<bool> result(1);

  auto call_kernel = [&result](gdf_dtype t) {
    dispatch_test_kernel<<<1, 1>>>(t, result.data().get());
    auto error_code = cudaDeviceSynchronize();

    // Kernel should fail with `cudaErrorAssert` on an unsupported gdf_dtype
    // This error invalidates the current device context, so we need to kill
    // the current process. Running with EXPECT_DEATH spawns a new process for
    // each attempted kernel launch
    EXPECT_EQ(cudaErrorAssert, error_code);
    exit(-1);
  };

  for (auto const& t : unsupported_dtypes) {
    EXPECT_DEATH(call_kernel(t), "");
  }
}

#endif