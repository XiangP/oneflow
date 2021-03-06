/*
Copyright 2020 The OneFlow Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
#include "oneflow/core/framework/framework.h"
#include "oneflow/user/kernels/model_update_kernel_util.h"

namespace oneflow {

template<typename T, typename G>
struct SGDUpdateKernelUtil<DeviceType::kCPU, T, G> {
  static void Update(DeviceCtx* ctx, int64_t n, float scale, float l1, float l2, float weight_decay,
                     const float* learning_rate, const G* model_diff, T* model);
};

template<typename T, typename G>
void SGDUpdateKernelUtil<DeviceType::kCPU, T, G>::Update(DeviceCtx* ctx, int64_t n, float scale,
                                                         float l1, float l2, float weight_decay,
                                                         const float* learning_rate,
                                                         const G* model_diff, T* model) {
  const T lr = *learning_rate;
  for (int64_t i = 0; i != n; ++i) {
    SGDUpdateFunctor<T, G>()(model_diff + i, model + i, scale, l1, l2, weight_decay, lr);
  }
}

template struct SGDUpdateKernelUtil<DeviceType::kCPU, float, float>;
template struct SGDUpdateKernelUtil<DeviceType::kCPU, double, double>;

template<typename T, typename K>
struct IndexedSlicesSGDUpdateKernelUtil<DeviceType::kCPU, T, K> {
  static void Update(DeviceCtx* ctx, int64_t num_indices, int64_t num_features,
                     int64_t feature_size, int64_t feature_id_offset, const float* learning_rate,
                     const K* indices, const T* values, T* model);
};

template<typename T, typename K>
void IndexedSlicesSGDUpdateKernelUtil<DeviceType::kCPU, T, K>::Update(
    DeviceCtx* ctx, int64_t num_indices, int64_t num_features, int64_t feature_size,
    int64_t feature_id_offset, const float* learning_rate, const K* indices, const T* values,
    T* model) {
  FOR_RANGE(int64_t, i, 0, num_indices) {
    const K feature_id = indices[i];
    CHECK_GE(feature_id, 0);
    const K local_feature_id = feature_id - feature_id_offset;
    if (local_feature_id >= 0 && local_feature_id < num_features) {
      const T* from = values + i * feature_size;
      T* to = model + local_feature_id * feature_size;
      for (int64_t j = 0; j < feature_size; ++j) { to[j] -= from[j] * (*learning_rate); }
    }
  }
}

#define INITIATE_INDEXED_SLICES_SGD_UPDATE_KERNEL_UTIL_CPU(in_type_pair, index_type_pair) \
  template struct IndexedSlicesSGDUpdateKernelUtil<                                       \
      DeviceType::kCPU, OF_PP_PAIR_FIRST(in_type_pair), OF_PP_PAIR_FIRST(index_type_pair)>;
OF_PP_SEQ_PRODUCT_FOR_EACH_TUPLE(INITIATE_INDEXED_SLICES_SGD_UPDATE_KERNEL_UTIL_CPU,
                                 FLOATING_DATA_TYPE_SEQ, INDEX_DATA_TYPE_SEQ);
#undef INITIATE_INDEXED_SLICES_SGD_UPDATE_KERNEL_UTIL_CPU

template<typename T, typename G>
struct MomentumUpdateKernelUtil<DeviceType::kCPU, T, G> {
  static void Update(DeviceCtx* ctx, int64_t n, float scale, float l1, float l2, float beta,
                     float weight_decay, const float* learning_rate, const G* model_diff, T* model,
                     T* momentum);
};

template<typename T, typename G>
void MomentumUpdateKernelUtil<DeviceType::kCPU, T, G>::Update(
    DeviceCtx* ctx, int64_t n, float scale, float l1, float l2, float beta, float weight_decay,
    const float* learning_rate, const G* model_diff, T* model, T* momentum) {
  const T lr = *learning_rate;
  for (int64_t i = 0; i != n; ++i) {
    MomentumUpdateFunctor<T, G>()(model_diff + i, model + i, momentum + i, scale, l1, l2, beta,
                                  weight_decay, lr);
  }
}

template struct MomentumUpdateKernelUtil<DeviceType::kCPU, float, float>;
template struct MomentumUpdateKernelUtil<DeviceType::kCPU, double, double>;

template<typename T, typename K, typename IDX>
struct IndexedSlicesMomentumMdUpdateKernelUtil<DeviceType::kCPU, T, K, IDX> {
  static void Update(DeviceCtx* ctx, T beta, int64_t num_instance, int64_t feature_size,
                     int64_t lower_bound, int64_t upper_bound, const IDX* num_unique_instance,
                     const float* learning_rate, const K* indices, const T* values, T* model,
                     T* momentum);
};

template<typename T, typename K, typename IDX>
void IndexedSlicesMomentumMdUpdateKernelUtil<DeviceType::kCPU, T, K, IDX>::Update(
    DeviceCtx* ctx, T beta, int64_t num_instance, int64_t feature_size, int64_t lower_bound,
    int64_t upper_bound, const IDX* num_unique_instance, const float* learning_rate,
    const K* indices, const T* values, T* model, T* momentum) {
  const int64_t n = *num_unique_instance * feature_size;
  const T lr = *learning_rate;
  for (int64_t i = 0; i != n; ++i) {
    const IDX indices_idx = i / feature_size;
    const IDX inner_idx = i - indices_idx * feature_size;
    const IDX instance_id = indices[indices_idx];
    if (instance_id >= lower_bound && instance_id < upper_bound) {
      const IDX model_idx = (instance_id - lower_bound) * feature_size + inner_idx;
      MomentumUpdateFunctor<T, T>()(values + i, model + model_idx, momentum + model_idx, 1.0, 0.0,
                                    0.0, beta, 0.0, lr);
    }
  }
}

#define INSTANTIATE_INDEXED_SLICES_MOMENTUM_MODEL_UPDATE_KERNEL_UTIL_CPU(                 \
    val_type_pair, key_type_pair, idx_type_pair)                                          \
  template struct IndexedSlicesMomentumMdUpdateKernelUtil<                                \
      DeviceType::kCPU, OF_PP_PAIR_FIRST(val_type_pair), OF_PP_PAIR_FIRST(key_type_pair), \
      OF_PP_PAIR_FIRST(idx_type_pair)>;
OF_PP_SEQ_PRODUCT_FOR_EACH_TUPLE(INSTANTIATE_INDEXED_SLICES_MOMENTUM_MODEL_UPDATE_KERNEL_UTIL_CPU,
                                 FLOATING_DATA_TYPE_SEQ, INDEX_DATA_TYPE_SEQ, INDEX_DATA_TYPE_SEQ);
#undef INSTANTIATE_INDEXED_SLICES_MOMENTUM_MODEL_UPDATE_KERNEL_UTIL_CPU

template<typename T, typename G>
struct AdamUpdateKernelUtil<DeviceType::kCPU, T, G> {
  static void Update(DeviceCtx* ctx, int64_t n, float scale, float l1, float l2, float beta1,
                     float beta2, float epsilon, bool do_bias_correction, float weight_decay,
                     const float* learning_rate, const G* model_diff, T* model, T* m, T* v,
                     T* beta1_t, T* beta2_t);
};

template<typename T, typename G>
void AdamUpdateKernelUtil<DeviceType::kCPU, T, G>::Update(
    DeviceCtx* ctx, int64_t n, float scale, float l1, float l2, float beta1, float beta2,
    float epsilon, bool do_bias_correction, float weight_decay, const float* learning_rate,
    const G* model_diff, T* model, T* m, T* v, T* beta1_t, T* beta2_t) {
  float lr;
  if (do_bias_correction) {
    lr = *learning_rate * std::sqrt(1 - *beta2_t) / (1 - *beta1_t);
    *beta1_t *= beta1;
    *beta2_t *= beta2;
  } else {
    lr = *learning_rate;
  }
  FOR_RANGE(int64_t, i, 0, n) {
    AdamUpdateFunctor<T, G>()(model_diff + i, model + i, m + i, v + i, scale, l1, l2, beta1, beta2,
                              epsilon, weight_decay, lr);
  }
}

template struct AdamUpdateKernelUtil<DeviceType::kCPU, float, float>;
template struct AdamUpdateKernelUtil<DeviceType::kCPU, double, double>;

template<typename T, typename K, typename IDX>
struct IndexedSlicesAdamMdUpdateKernelUtil<DeviceType::kCPU, T, K, IDX> {
  static void Update(DeviceCtx* ctx, float beta1, float beta2, float epsilon,
                     bool do_bias_correction, int64_t num_instance, int64_t feature_size,
                     int64_t lower_bound, int64_t upper_bound, const IDX* num_unique_instance,
                     const float* learning_rate, const K* indices, const T* values, T* model, T* m,
                     T* v, T* beta1_t, T* beta2_t) {
    float lr;
    if (do_bias_correction) {
      lr = *learning_rate * std::sqrt(1 - *beta2_t) / (1 - *beta1_t);
      *beta1_t *= beta1;
      *beta2_t *= beta2;
    } else {
      lr = *learning_rate;
    }
    const int64_t n = *num_unique_instance * feature_size;
    FOR_RANGE(int64_t, i, 0, n) {
      const IDX indices_idx = i / feature_size;
      const IDX inner_idx = i - indices_idx * feature_size;
      const IDX instance_id = indices[indices_idx];
      if (instance_id >= lower_bound && instance_id < upper_bound) {
        const IDX model_idx = (instance_id - lower_bound) * feature_size + inner_idx;
        AdamUpdateFunctor<T, T>()(values + i, model + model_idx, m + model_idx, v + model_idx, 1, 0,
                                  0, beta1, beta2, epsilon, 0, lr);
      }
    }
  }
};

#define INSTANTIATE_INDEXED_SLICES_ADAM_MODEL_UPDATE_KERNEL_UTIL_CPU(val_type_pair, key_type_pair, \
                                                                     idx_type_pair)                \
  template struct IndexedSlicesAdamMdUpdateKernelUtil<                                             \
      DeviceType::kCPU, OF_PP_PAIR_FIRST(val_type_pair), OF_PP_PAIR_FIRST(key_type_pair),          \
      OF_PP_PAIR_FIRST(idx_type_pair)>;
OF_PP_SEQ_PRODUCT_FOR_EACH_TUPLE(INSTANTIATE_INDEXED_SLICES_ADAM_MODEL_UPDATE_KERNEL_UTIL_CPU,
                                 FLOATING_DATA_TYPE_SEQ, INDEX_DATA_TYPE_SEQ, INDEX_DATA_TYPE_SEQ);
#undef INSTANTIATE_INDEXED_SLICES_ADAM_MODEL_UPDATE_KERNEL_UTIL_CPU

}  // namespace oneflow
