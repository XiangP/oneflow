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

#include "oneflow/core/device/cudnn_util.h"
#include "oneflow/core/framework/framework.h"
#include "oneflow/core/ndarray/ndarray_util.h"
#include "oneflow/core/kernel/kernel_util.cuh"

namespace oneflow {

namespace {

class LayerNormCudnnBnCtx final {
 public:
  LayerNormCudnnBnCtx(const ShapeView& data_shape, const ShapeView& param_shape,
                      DataType data_type) {
    const int64_t cudnn_c = param_shape.elem_cnt();
    CHECK_EQ(data_shape.elem_cnt() % cudnn_c, 0);
    const int64_t cudnn_w = data_shape.elem_cnt() / cudnn_c;
    CHECK_LT(cudnn_c, GetMaxVal<int32_t>());
    CHECK_LT(cudnn_w, GetMaxVal<int32_t>());
    data_tensor_desc_.reset(new CudnnTensorDesc(CUDNN_TENSOR_NCHW, data_type, 1,
                                                static_cast<int32_t>(cudnn_c), 1,
                                                static_cast<int32_t>(cudnn_w)));
    DataType param_dtype = data_type == DataType::kFloat16 ? DataType::kFloat : data_type;
    param_tensor_desc_.reset(new CudnnTensorDesc(CUDNN_TENSOR_NCHW, param_dtype, 1,
                                                 static_cast<int32_t>(cudnn_c), 1, 1));
#if (CUDNN_VERSION >= 7000)
    mode_ = CUDNN_BATCHNORM_SPATIAL_PERSISTENT;
#else
    mode_ = CUDNN_BATCHNORM_SPATIAL;
#endif
  }
  ~LayerNormCudnnBnCtx() = default;

  const cudnnTensorDescriptor_t& data_tensor_desc() const { return data_tensor_desc_->Get(); }
  const cudnnTensorDescriptor_t& param_tensor_desc() const { return param_tensor_desc_->Get(); }
  cudnnBatchNormMode_t mode() const { return mode_; };

 private:
  std::unique_ptr<CudnnTensorDesc> data_tensor_desc_;
  std::unique_ptr<CudnnTensorDesc> param_tensor_desc_;
  cudnnBatchNormMode_t mode_;
};

template<typename T, bool do_scale, bool do_center>
__global__ void InstanceScaleCenterGpu(const int64_t elem_cnt, const int64_t instance_size,
                                       const T* in, const T* gamma, const T* beta, T* out) {
  CUDA_1D_KERNEL_LOOP_T(int64_t, i, elem_cnt) {
    const int64_t elem_id = i % instance_size;
    T v = in[i];
    if (do_scale) { v *= gamma[elem_id]; }
    if (do_center) { v += beta[elem_id]; }
    out[i] = v;
  }
}

template<bool do_scale, bool do_center>
__global__ void InstanceScaleCenterH2Gpu(const int64_t h2_elem_cnt, const int64_t h2_instance_size,
                                         const half* in, const half* gamma, const half* beta,
                                         half* out) {
  const auto* in_h2 = reinterpret_cast<const half2*>(in);
  const auto* gamma_h2 = reinterpret_cast<const half2*>(gamma);
  const auto* beta_h2 = reinterpret_cast<const half2*>(beta);
  auto* out_h2 = reinterpret_cast<half2*>(out);
  CUDA_1D_KERNEL_LOOP_T(int64_t, i, h2_elem_cnt) {
    const int64_t elem_id = i % h2_instance_size;
    half2 v2 = in_h2[i];
    if (do_scale) { v2 = __hmul2(v2, gamma_h2[elem_id]); }
    if (do_center) { v2 = __hadd2(v2, beta_h2[elem_id]); }
    out_h2[i] = v2;
  }
}

template<typename T>
void InstanceScaleCenter(DeviceCtx* ctx, const int64_t batch_size, const int64_t instance_size,
                         const T* in, const T* gamma, const T* beta, T* out) {
  const int64_t elem_cnt = batch_size * instance_size;
  if (beta != nullptr && gamma != nullptr) {  // scale and center
    InstanceScaleCenterGpu<T, true, true>
        <<<BlocksNum4ThreadsNum(elem_cnt), kCudaThreadsNumPerBlock, 0, ctx->cuda_stream()>>>(
            elem_cnt, instance_size, in, gamma, beta, out);
  } else if (gamma != nullptr) {  // scale only
    InstanceScaleCenterGpu<T, true, false>
        <<<BlocksNum4ThreadsNum(elem_cnt), kCudaThreadsNumPerBlock, 0, ctx->cuda_stream()>>>(
            elem_cnt, instance_size, in, gamma, nullptr, out);
  } else if (beta != nullptr) {  // center only
    InstanceScaleCenterGpu<T, false, true>
        <<<BlocksNum4ThreadsNum(elem_cnt), kCudaThreadsNumPerBlock, 0, ctx->cuda_stream()>>>(
            elem_cnt, instance_size, in, nullptr, beta, out);
  } else {
    UNIMPLEMENTED();
  }
}

void InstanceScaleCenterH2(DeviceCtx* ctx, const int64_t batch_size, const int64_t instance_size,
                           const half* in, const half* gamma, const half* beta, half* out) {
  CHECK_EQ(instance_size % 2, 0);
  const int64_t elem_cnt_h2 = batch_size * instance_size / 2;
  const int64_t instance_size_h2 = instance_size / 2;
  if (beta != nullptr && gamma != nullptr) {  // scale and center
    InstanceScaleCenterH2Gpu<true, true>
        <<<BlocksNum4ThreadsNum(elem_cnt_h2), kCudaThreadsNumPerBlock, 0, ctx->cuda_stream()>>>(
            elem_cnt_h2, instance_size_h2, in, gamma, beta, out);
  } else if (gamma != nullptr) {  // scale only
    InstanceScaleCenterH2Gpu<true, false>
        <<<BlocksNum4ThreadsNum(elem_cnt_h2), kCudaThreadsNumPerBlock, 0, ctx->cuda_stream()>>>(
            elem_cnt_h2, instance_size_h2, in, gamma, nullptr, out);
  } else if (beta != nullptr) {  // center only
    InstanceScaleCenterH2Gpu<false, true>
        <<<BlocksNum4ThreadsNum(elem_cnt_h2), kCudaThreadsNumPerBlock, 0, ctx->cuda_stream()>>>(
            elem_cnt_h2, instance_size_h2, in, nullptr, beta, out);
  } else {
    UNIMPLEMENTED();
  }
}

template<>
void InstanceScaleCenter<float16>(DeviceCtx* ctx, const int64_t batch_size,
                                  const int64_t instance_size, const float16* in,
                                  const float16* gamma, const float16* beta, float16* out) {
  if (instance_size % 2 == 0) {
    InstanceScaleCenterH2(ctx, batch_size, instance_size, reinterpret_cast<const half*>(in),
                          reinterpret_cast<const half*>(gamma), reinterpret_cast<const half*>(beta),
                          reinterpret_cast<half*>(out));
  } else {
    InstanceScaleCenter<half>(ctx, batch_size, instance_size, reinterpret_cast<const half*>(in),
                              reinterpret_cast<const half*>(gamma),
                              reinterpret_cast<const half*>(beta), reinterpret_cast<half*>(out));
  }
}

constexpr int64_t kLayerNormGpuBlockSize = 512;

int GetLayerNormBlockSize() { return kLayerNormGpuBlockSize; }

int GetLayerNormNumBlocks() { return 256; }

template<typename T>
int GetDynamicSharedMemorySize(const bool has_beta_diff, const int32_t instance_size) {
  int size = instance_size * sizeof(T);
  if (has_beta_diff) { size += instance_size * sizeof(T); }
  return size;
}

template<>
int GetDynamicSharedMemorySize<half>(const bool has_beta_diff, const int32_t instance_size) {
  int size = instance_size * sizeof(float);
  if (has_beta_diff) { size += instance_size * sizeof(float); }
  return size;
}

template<typename T>
__global__ void LayerNormParamGradImpl(const int n, const int instance_size,
                                       const bool has_beta_diff, const bool has_normalized_diff,
                                       const T* dy, const T* normalized, const T* gamma,
                                       T* gamma_diff, T* beta_diff, T* normalized_diff) {
  extern __shared__ __align__(sizeof(T)) unsigned char fw_shared_buf[];
  auto* gamma_diff_sum_buf = reinterpret_cast<T*>(fw_shared_buf);
  auto* beta_diff_sum_buf = gamma_diff_sum_buf + instance_size;
  const int tid = threadIdx.x;
  for (int elem_id = tid; elem_id < instance_size; elem_id += blockDim.x) {
    gamma_diff_sum_buf[elem_id] = 0;
    if (has_beta_diff) { beta_diff_sum_buf[elem_id] = 0; }
  }
  __syncthreads();
  CUDA_1D_KERNEL_LOOP(i, n) {
    const int32_t elem_id = i % instance_size;
    T dy_val = dy[i];
    T normalized_val = normalized[i];
    gpu_atomic_add(&gamma_diff_sum_buf[elem_id], dy_val * normalized_val);
    if (has_beta_diff) { gpu_atomic_add(&beta_diff_sum_buf[elem_id], dy_val); }
    if (has_normalized_diff) {
      T gamma_val = gamma[elem_id];
      normalized_diff[i] = gamma_val * dy_val;
    }
  }
  __syncthreads();
  for (int elem_id = tid; elem_id < instance_size; elem_id += blockDim.x) {
    T gamma_diff_sum = gamma_diff_sum_buf[elem_id];
    gpu_atomic_add(gamma_diff + elem_id, gamma_diff_sum);
    if (has_beta_diff) {
      T beta_diff_sum = beta_diff_sum_buf[elem_id];
      gpu_atomic_add(beta_diff + elem_id, beta_diff_sum);
    }
  }
}

template<>
__global__ void LayerNormParamGradImpl<half>(const int n, const int instance_size,
                                             const bool has_beta_diff,
                                             const bool has_normalized_diff, const half* dy,
                                             const half* normalized, const half* gamma,
                                             half* gamma_diff, half* beta_diff,
                                             half* normalized_diff) {
#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ >= 700 && CUDA_VERSION >= 10000
  extern __shared__ __align__(sizeof(float)) unsigned char fw_shared_buf[];
  auto* gamma_diff_sum_buf = reinterpret_cast<half*>(fw_shared_buf);
  auto* beta_diff_sum_buf = gamma_diff_sum_buf + 2 * instance_size;
  const int tid = threadIdx.x;
  for (int elem_id = tid; elem_id < instance_size; elem_id += blockDim.x) {
    gamma_diff_sum_buf[2 * elem_id] = __float2half(0);
    if (has_beta_diff) { beta_diff_sum_buf[2 * elem_id] = __float2half(0); }
  }
  __syncthreads();
  CUDA_1D_KERNEL_LOOP(i, n) {
    const int32_t elem_id = i % instance_size;
    half dy_val = dy[i];
    half normalized_val = normalized[i];
    gpu_atomic_add(&gamma_diff_sum_buf[2 * elem_id], __hmul(dy_val, normalized_val));
    if (has_beta_diff) { gpu_atomic_add(&beta_diff_sum_buf[2 * elem_id], dy_val); }
    if (has_normalized_diff) {
      half gamma_val = gamma[elem_id];
      normalized_diff[i] = __hmul(gamma_val, dy_val);
    }
  }
  __syncthreads();
  for (int elem_id = tid; elem_id < instance_size; elem_id += blockDim.x) {
    half gamma_diff_sum = gamma_diff_sum_buf[2 * elem_id];
    half beta_diff_sum = beta_diff_sum_buf[2 * elem_id];
    gpu_atomic_add(gamma_diff + elem_id, gamma_diff_sum);
    gpu_atomic_add(beta_diff + elem_id, beta_diff_sum);
  }
#else
  printf("use half LayerNormParamGradImpl need nvcc arch >= 700 and cuda >= 10.0");
  assert(false);
#endif
}

template<typename T>
void LayerNormParamGradGpu(DeviceCtx* ctx, const int64_t n, const int64_t instance_size,
                           const bool has_beta_diff, const bool has_normalized_diff, const T* dy,
                           const T* normalized, const T* gamma, T* gamma_diff, T* beta_diff,
                           T* normalized_diff) {
  LayerNormParamGradImpl<<<GetLayerNormNumBlocks(), GetLayerNormBlockSize(),
                           GetDynamicSharedMemorySize<T>(has_beta_diff, instance_size),
                           ctx->cuda_stream()>>>(n, instance_size, has_beta_diff,
                                                 has_normalized_diff, dy, normalized, gamma,
                                                 gamma_diff, beta_diff, normalized_diff);
}

template<>
void LayerNormParamGradGpu<float16>(DeviceCtx* ctx, const int64_t n, const int64_t instance_size,
                                    const bool has_beta_diff, const bool has_normalized_diff,
                                    const float16* dy, const float16* normalized,
                                    const float16* gamma, float16* gamma_diff, float16* beta_diff,
                                    float16* normalized_diff) {
  LayerNormParamGradGpu<half>(
      ctx, n, instance_size, has_beta_diff, has_normalized_diff, reinterpret_cast<const half*>(dy),
      reinterpret_cast<const half*>(normalized), reinterpret_cast<const half*>(gamma),
      reinterpret_cast<half*>(gamma_diff), reinterpret_cast<half*>(beta_diff),
      reinterpret_cast<half*>(normalized_diff));
}

bool IsDtypeSupport(DataType data_type) {
  if (data_type != DataType::kFloat16) {
    return true;
  } else {
#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ >= 700 && CUDA_VERSION >= 10000
    return true;
#else
    return false;
#endif
  }
}

template<typename T>
int GetMaxInstanceSize(const bool has_beta_diff) {
  int shared_mem_size = sizeof(T);
  if (has_beta_diff) { shared_mem_size += sizeof(T); }
  return 16 * 1024 / shared_mem_size;
}

template<>
int GetMaxInstanceSize<float16>(const bool has_beta_diff) {
  int shared_mem_size = sizeof(float);
  if (has_beta_diff) { shared_mem_size += sizeof(float); }
  return 16 * 1024 / shared_mem_size;
}

}  // namespace

template<typename T, typename BNParamT>
class LayerNormGpuKernel final : public user_op::OpKernel {
 public:
  LayerNormGpuKernel() = default;
  ~LayerNormGpuKernel() = default;

 private:
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
  void Compute(user_op::KernelComputeContext* ctx) const override {
    const user_op::Tensor* x = ctx->Tensor4ArgNameAndIndex("x", 0);
    user_op::Tensor* y = ctx->Tensor4ArgNameAndIndex("y", 0);
    user_op::Tensor* mean = ctx->Tensor4ArgNameAndIndex("mean", 0);
    user_op::Tensor* inv_variance = ctx->Tensor4ArgNameAndIndex("inv_variance", 0);
    const bool scale = ctx->Attr<bool>("scale");
    const bool center = ctx->Attr<bool>("center");
    user_op::Tensor* normalized = scale ? ctx->Tensor4ArgNameAndIndex("normalized", 0) : y;
    const double epsilon = ctx->Attr<double>("epsilon");
    CHECK_GE(epsilon, CUDNN_BN_MIN_EPSILON);
    LayerNormCudnnBnCtx bn_ctx(x->shape(), mean->shape(), x->data_type());
    user_op::Tensor* tmp_buffer = ctx->Tensor4ArgNameAndIndex("tmp_buffer", 0);
    const size_t aligned_buffer_size =
        GetCudaAlignedSize(mean->shape().elem_cnt() * GetSizeOfDataType(mean->data_type()));
    char* cudnn_bn_scale_ones_dptr = tmp_buffer->mut_dptr<char>();
    char* cudnn_bn_bias_zeros_dptr = cudnn_bn_scale_ones_dptr + aligned_buffer_size;
    NewKernelUtil<DeviceType::kGPU>::Fill(ctx->device_ctx(), mean->shape().elem_cnt(),
                                          static_cast<BNParamT>(1),
                                          reinterpret_cast<BNParamT*>(cudnn_bn_scale_ones_dptr));
    NewKernelUtil<DeviceType::kGPU>::Fill(ctx->device_ctx(), mean->shape().elem_cnt(),
                                          static_cast<BNParamT>(0),
                                          reinterpret_cast<BNParamT*>(cudnn_bn_bias_zeros_dptr));
    OF_CUDNN_CHECK(cudnnBatchNormalizationForwardTraining(
        ctx->device_ctx()->cudnn_handle(), bn_ctx.mode(), CudnnSPOnePtr<T>(), CudnnSPZeroPtr<T>(),
        bn_ctx.data_tensor_desc(), x->dptr<T>(), bn_ctx.data_tensor_desc(),
        normalized->mut_dptr<T>(), bn_ctx.param_tensor_desc(),
        reinterpret_cast<BNParamT*>(cudnn_bn_scale_ones_dptr),
        reinterpret_cast<BNParamT*>(cudnn_bn_bias_zeros_dptr), 1.0, nullptr, nullptr, epsilon,
        mean->mut_dptr(), inv_variance->mut_dptr()));

    if (scale || center) {
      const T* gamma_ptr = nullptr;
      const T* beta_ptr = nullptr;
      int64_t instance_size;
      if (scale) {
        const user_op::Tensor* gamma = ctx->Tensor4ArgNameAndIndex("gamma", 0);
        instance_size = gamma->shape().elem_cnt();
        gamma_ptr = gamma->dptr<T>();
      }
      if (center) {
        const user_op::Tensor* beta = ctx->Tensor4ArgNameAndIndex("beta", 0);
        if (gamma_ptr) {
          CHECK_EQ(beta->shape().elem_cnt(), instance_size);
        } else {
          instance_size = beta->shape().elem_cnt();
        }
        beta_ptr = beta->dptr<T>();
      }
      CHECK_EQ(y->shape().elem_cnt() % instance_size, 0);
      const int64_t batch_size = y->shape().elem_cnt() / instance_size;
      InstanceScaleCenter<T>(ctx->device_ctx(), batch_size, instance_size, normalized->dptr<T>(),
                             gamma_ptr, beta_ptr, y->mut_dptr<T>());
    }
  };
};

#define REGISTER_LAYER_NORM_GPU_KERNEL(dtype, bn_param_dtype)                         \
  REGISTER_USER_KERNEL("layer_norm")                                                  \
      .SetCreateFn<LayerNormGpuKernel<dtype, bn_param_dtype>>()                       \
      .SetIsMatchedHob((user_op::HobDeviceTag() == "gpu")                             \
                       & (user_op::HobDataType("x", 0) == GetDataType<dtype>::value)) \
      .SetInferTmpSizeFn([](oneflow::user_op::InferContext* ctx) {                    \
        user_op::TensorDesc* mean = ctx->TensorDesc4ArgNameAndIndex("mean", 0);       \
        const DataType& data_type = mean->data_type();                                \
        const int64_t elem_cnt = mean->shape().elem_cnt();                            \
        return GetCudaAlignedSize(elem_cnt * GetSizeOfDataType(data_type)) * 2;       \
      });

REGISTER_LAYER_NORM_GPU_KERNEL(float, float)
REGISTER_LAYER_NORM_GPU_KERNEL(double, double)
REGISTER_LAYER_NORM_GPU_KERNEL(float16, float)

template<typename T, typename BNParamT>
class LayerNormGradGpuKernel final : public user_op::OpKernel {
 public:
  LayerNormGradGpuKernel() = default;
  ~LayerNormGradGpuKernel() = default;

 private:
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
  void Compute(user_op::KernelComputeContext* ctx) const override {
    const user_op::Tensor* dy = ctx->Tensor4ArgNameAndIndex("dy", 0);
    const user_op::Tensor* x = ctx->Tensor4ArgNameAndIndex("x", 0);
    const user_op::Tensor* mean = ctx->Tensor4ArgNameAndIndex("mean", 0);
    const user_op::Tensor* inv_variance = ctx->Tensor4ArgNameAndIndex("inv_variance", 0);
    user_op::Tensor* dx = ctx->Tensor4ArgNameAndIndex("dx", 0);
    user_op::Tensor* tmp_buffer = ctx->Tensor4ArgNameAndIndex("tmp_buffer", 0);
    const size_t aligned_buffer_size =
        GetCudaAlignedSize(mean->shape().elem_cnt() * GetSizeOfDataType(mean->data_type()));
    char* cudnn_bn_scale_ones_dptr = tmp_buffer->mut_dptr<char>();
    char* cudnn_bn_scale_diff_buf_dptr = cudnn_bn_scale_ones_dptr + aligned_buffer_size;
    char* cudnn_bn_bias_diff_buf_dptr = cudnn_bn_scale_ones_dptr + aligned_buffer_size;
    NewKernelUtil<DeviceType::kGPU>::Fill(ctx->device_ctx(), mean->shape().elem_cnt(),
                                          static_cast<BNParamT>(1),
                                          reinterpret_cast<BNParamT*>(cudnn_bn_scale_ones_dptr));
    const double epsilon = ctx->Attr<double>("epsilon");
    CHECK_GE(epsilon, CUDNN_BN_MIN_EPSILON);
    LayerNormCudnnBnCtx bn_ctx(x->shape(), mean->shape(), x->data_type());
    OF_CUDNN_CHECK(cudnnBatchNormalizationBackward(
        ctx->device_ctx()->cudnn_handle(), bn_ctx.mode(), CudnnSPOnePtr<T>(), CudnnSPZeroPtr<T>(),
        CudnnSPOnePtr<T>(), CudnnSPZeroPtr<T>(), bn_ctx.data_tensor_desc(), x->dptr<T>(),
        bn_ctx.data_tensor_desc(), dy->dptr<T>(), bn_ctx.data_tensor_desc(), dx->mut_dptr<T>(),
        bn_ctx.param_tensor_desc(), reinterpret_cast<const BNParamT*>(cudnn_bn_scale_ones_dptr),
        reinterpret_cast<BNParamT*>(cudnn_bn_scale_diff_buf_dptr),
        reinterpret_cast<BNParamT*>(cudnn_bn_bias_diff_buf_dptr), epsilon, mean->dptr(),
        inv_variance->dptr()));
  };
};

#define REGISTER_LAYER_NORM_GRAD_GPU_KERNEL(dtype, bn_param_dtype)                     \
  REGISTER_USER_KERNEL("layer_norm_grad")                                              \
      .SetCreateFn<LayerNormGradGpuKernel<dtype, bn_param_dtype>>()                    \
      .SetIsMatchedHob((user_op::HobDeviceTag() == "gpu")                              \
                       & (user_op::HobDataType("dy", 0) == GetDataType<dtype>::value)) \
      .SetInferTmpSizeFn([](oneflow::user_op::InferContext* ctx) {                     \
        user_op::TensorDesc* mean = ctx->TensorDesc4ArgNameAndIndex("mean", 0);        \
        const DataType& data_type = mean->data_type();                                 \
        const int64_t elem_cnt = mean->shape().elem_cnt();                             \
        return GetCudaAlignedSize(elem_cnt * GetSizeOfDataType(data_type)) * 3;        \
      });

REGISTER_LAYER_NORM_GRAD_GPU_KERNEL(float, float)
REGISTER_LAYER_NORM_GRAD_GPU_KERNEL(double, double)
REGISTER_LAYER_NORM_GRAD_GPU_KERNEL(float16, float)

template<typename T>
class LayerNormParamGradGpuKernel final : public user_op::OpKernel {
 public:
  LayerNormParamGradGpuKernel() = default;
  ~LayerNormParamGradGpuKernel() = default;

 private:
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
  void Compute(user_op::KernelComputeContext* ctx) const override {
    using NdUtil = NdarrayUtil<DeviceType::kGPU, T>;
    auto Val = NdUtil::GetValNdarrayBuilder();
    auto Var = NdUtil::GetVarNdarrayBuilder();
    const user_op::Tensor* dy = ctx->Tensor4ArgNameAndIndex("dy", 0);
    user_op::Tensor* beta_diff = ctx->Tensor4ArgNameAndIndex("beta_diff", 0);
    user_op::Tensor* gamma_diff = ctx->Tensor4ArgNameAndIndex("gamma_diff", 0);
    user_op::Tensor* normalized_diff = ctx->Tensor4ArgNameAndIndex("normalized_diff", 0);
    user_op::Tensor* gamma = ctx->Tensor4ArgNameAndIndex("gamma", 0);
    const bool has_beta_diff = beta_diff != nullptr;
    const bool has_gamma_diff = gamma_diff != nullptr;
    const bool has_normalized_diff = normalized_diff != nullptr;
    const bool has_gamma = gamma != nullptr;
    const int64_t begin_params_axis = ctx->Attr<int64_t>("begin_params_axis");
    const int64_t m = dy->shape().Count(begin_params_axis);
    if (IsDtypeSupport(dy->data_type()) && has_gamma_diff
        && m < GetMaxInstanceSize<T>(has_beta_diff)) {
      const user_op::Tensor* normalized = ctx->Tensor4ArgNameAndIndex("normalized", 0);
      const T* normalized_ptr = has_gamma_diff ? normalized->dptr<T>() : nullptr;
      const T* gamma_ptr = gamma->dptr<T>();
      T* gamma_diff_ptr = gamma_diff->mut_dptr<T>();
      T* beta_diff_ptr = has_beta_diff ? beta_diff->mut_dptr<T>() : nullptr;
      T* normalized_diff_ptr = has_normalized_diff ? normalized_diff->mut_dptr<T>() : nullptr;
      LayerNormParamGradGpu<T>(ctx->device_ctx(), dy->shape().elem_cnt(), m, has_beta_diff,
                               has_normalized_diff, dy->dptr<T>(), normalized_ptr, gamma_ptr,
                               gamma_diff_ptr, beta_diff_ptr, normalized_diff_ptr);
    } else {
      if (has_beta_diff) {
        user_op::Tensor* reduce_buf = ctx->Tensor4ArgNameAndIndex("reduce_buf", 0);
        CHECK_EQ(m, beta_diff->shape().elem_cnt());
        CHECK_EQ(dy->shape().elem_cnt() % m, 0);
        const int64_t n = dy->shape().elem_cnt() / m;
        NdUtil::ReduceSum(ctx->device_ctx(), Var({1, m}, beta_diff->mut_dptr<T>()),
                          Val({n, m}, dy->dptr<T>()), Var({n, m}, reduce_buf->mut_dptr<T>()));
      }
      if (has_gamma_diff) {
        const user_op::Tensor* normalized = ctx->Tensor4ArgNameAndIndex("normalized", 0);
        user_op::Tensor* reduce_buf = ctx->Tensor4ArgNameAndIndex("reduce_buf", 0);
        CHECK_EQ(m, gamma_diff->shape().elem_cnt());
        CHECK_EQ(dy->shape().elem_cnt() % m, 0);
        const int64_t n = dy->shape().elem_cnt() / m;
        NdUtil::BroadcastMul(ctx->device_ctx(), Var({n, m}, reduce_buf->mut_dptr<T>()),
                             Val({n, m}, normalized->dptr<T>()), Val({n, m}, dy->dptr<T>()));
        NdUtil::ReduceSum(ctx->device_ctx(), Var({1, m}, gamma_diff->mut_dptr<T>()),
                          Val({n, m}, reduce_buf->dptr<T>()),
                          Var({n, m}, reduce_buf->mut_dptr<T>()));
      }
      if (has_normalized_diff) {
        if (has_gamma) {
          CHECK_EQ(m, gamma->shape().elem_cnt());
          CHECK_EQ(dy->shape().elem_cnt() % m, 0);
          const int64_t n = dy->shape().elem_cnt() / m;
          NdUtil::BroadcastMul(ctx->device_ctx(), Var({n, m}, normalized_diff->mut_dptr<T>()),
                               Val({n, m}, dy->dptr<T>()), Val({1, m}, gamma->dptr<T>()));
        } else {
          Memcpy<DeviceType::kGPU>(ctx->device_ctx(), normalized_diff->mut_dptr<void>(),
                                   dy->dptr<void>(),
                                   dy->shape().elem_cnt() * GetSizeOfDataType(dy->data_type()));
        }
      }
    }
  };
};

#define REGISTER_LAYER_NORM_PARAM_GRAD_GPU_KERNEL(dtype)  \
  REGISTER_USER_KERNEL("layer_norm_param_grad")           \
      .SetCreateFn<LayerNormParamGradGpuKernel<dtype>>()  \
      .SetIsMatchedHob((user_op::HobDeviceTag() == "gpu") \
                       & (user_op::HobDataType("dy", 0) == GetDataType<dtype>::value));

REGISTER_LAYER_NORM_PARAM_GRAD_GPU_KERNEL(float)
REGISTER_LAYER_NORM_PARAM_GRAD_GPU_KERNEL(double)
REGISTER_LAYER_NORM_PARAM_GRAD_GPU_KERNEL(float16)

}  // namespace oneflow
