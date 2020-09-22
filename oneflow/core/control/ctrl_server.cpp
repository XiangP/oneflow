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
#include "oneflow/core/control/ctrl_server.h"
#include "oneflow/core/actor/act_event_logger.h"
#include "oneflow/core/job/profiler.h"
#include "oneflow/core/job/env_desc.h"
#include "grpc/grpc_posix.h"

namespace oneflow {

namespace {

int ExtractPortFromAddr(const std::string& addr) {
  size_t pos = addr.find(':');
  return oneflow_cast<int>(addr.substr(pos + 1));
}

}  // namespace

CtrlServer::~CtrlServer() {
  // NOTE(chengcheng): This enqueues a special event (with a null tag) that causes
  // the completion queue to be shut down on the polling thread.
  grpc::Alarm alarm(cq_.get(), gpr_now(GPR_CLOCK_MONOTONIC), nullptr);
  loop_thread_.join();
}

CtrlServer::CtrlServer() : is_first_connect_(true), this_machine_addr_("") {
  Init();
  int port = Global<EnvDesc>::Get()->ctrl_port();
  grpc::ServerBuilder server_builder;
  server_builder.SetMaxMessageSize(INT_MAX);
  int bound_port = 0;
  server_builder.AddListeningPort("0.0.0.0:" + std::to_string(port),
                                  grpc::InsecureServerCredentials(), &bound_port);
  grpc_service_.reset(new CtrlService::AsyncService);
  server_builder.RegisterService(grpc_service_.get());
  cq_ = server_builder.AddCompletionQueue();
  grpc_server_ = server_builder.BuildAndStart();
  CHECK_EQ(port, bound_port) << "Port " << port << " is unavailable";
  LOG(INFO) << "CtrlServer listening on "
            << "0.0.0.0:" + std::to_string(port);
  loop_thread_ = std::thread(&CtrlServer::HandleRpcs, this);
}

void CtrlServer::HandleRpcs() {
  EnqueueRequests();

  void* tag = nullptr;
  bool ok = false;
  while (cq_->Next(&tag, &ok)) {
    if (!ok) { break; }
    auto call = static_cast<CtrlCallIf*>(tag);
    if (call) {
      call->Process();
    } else {
      // NOTE(chengcheng): A null `call` indicates that this is the shutdown alarm.
      LOG(INFO) << "cclog: CQ shutdown! Before";
      cq_->Shutdown();
      LOG(INFO) << "cclog: CQ shutdown! End";
      LOG(INFO) << "cclog: Server shutdown! Before";
      grpc_server_->Shutdown();
      LOG(INFO) << "cclog: Server shutdown! End";
      break;
    }
  }
}

void CtrlServer::Init() {
  Add([this](CtrlCall<CtrlMethod::kLoadServer>* call) {
    if (this->is_first_connect_) {
      this->this_machine_addr_ = call->request().addr();
      this->is_first_connect_ = false;
    } else {
      CHECK_EQ(call->request().addr(), this->this_machine_addr_);
    }
    call->SendResponse();
    EnqueueRequest<CtrlMethod::kLoadServer>();
  });

  Add([this](CtrlCall<CtrlMethod::kBarrier>* call) {
    const std::string& barrier_name = call->request().name();
    int32_t barrier_num = call->request().num();
    auto barrier_call_it = barrier_calls_.find(barrier_name);
    if (barrier_call_it == barrier_calls_.end()) {
      barrier_call_it =
          barrier_calls_
              .emplace(barrier_name, std::make_pair(std::list<CtrlCallIf*>{}, barrier_num))
              .first;
    }
    CHECK_EQ(barrier_num, barrier_call_it->second.second);
    barrier_call_it->second.first.push_back(call);
    if (barrier_call_it->second.first.size() == barrier_call_it->second.second) {
      for (CtrlCallIf* pending_call : barrier_call_it->second.first) {
        pending_call->SendResponse();
      }
      barrier_calls_.erase(barrier_call_it);
    }

    EnqueueRequest<CtrlMethod::kBarrier>();
  });

  Add([this](CtrlCall<CtrlMethod::kTryLock>* call) {
    const std::string& lock_name = call->request().name();
    auto name2lock_status_it = name2lock_status_.find(lock_name);
    if (name2lock_status_it == name2lock_status_.end()) {
      call->mut_response()->set_result(TryLockResult::kLocked);
      auto waiting_until_done_calls = new std::list<CtrlCallIf*>;
      CHECK(name2lock_status_.emplace(lock_name, waiting_until_done_calls).second);
    } else {
      if (name2lock_status_it->second) {
        call->mut_response()->set_result(TryLockResult::kDoing);
      } else {
        call->mut_response()->set_result(TryLockResult::kDone);
      }
    }
    call->SendResponse();
    EnqueueRequest<CtrlMethod::kTryLock>();
  });

  Add([this](CtrlCall<CtrlMethod::kNotifyDone>* call) {
    const std::string& lock_name = call->request().name();
    auto name2lock_status_it = name2lock_status_.find(lock_name);
    auto waiting_calls = static_cast<std::list<CtrlCallIf*>*>(name2lock_status_it->second);
    for (CtrlCallIf* waiting_call : *waiting_calls) { waiting_call->SendResponse(); }
    delete waiting_calls;
    name2lock_status_it->second = nullptr;
    call->SendResponse();
    EnqueueRequest<CtrlMethod::kNotifyDone>();
  });

  Add([this](CtrlCall<CtrlMethod::kWaitUntilDone>* call) {
    const std::string& lock_name = call->request().name();
    void* lock_status = name2lock_status_.at(lock_name);
    if (lock_status) {
      auto waiting_calls = static_cast<std::list<CtrlCallIf*>*>(lock_status);
      waiting_calls->push_back(call);
    } else {
      call->SendResponse();
    }
    EnqueueRequest<CtrlMethod::kWaitUntilDone>();
  });

  Add([this](CtrlCall<CtrlMethod::kPushKV>* call) {
    const std::string& k = call->request().key();
    const std::string& v = call->request().val();
    CHECK(kv_.emplace(k, v).second);

    auto pending_kv_calls_it = pending_kv_calls_.find(k);
    if (pending_kv_calls_it != pending_kv_calls_.end()) {
      for (auto pending_call : pending_kv_calls_it->second) {
        pending_call->mut_response()->set_val(v);
        pending_call->SendResponse();
      }
      pending_kv_calls_.erase(pending_kv_calls_it);
    }
    call->SendResponse();
    EnqueueRequest<CtrlMethod::kPushKV>();
  });

  Add([this](CtrlCall<CtrlMethod::kClearKV>* call) {
    const std::string& k = call->request().key();
    CHECK_EQ(kv_.erase(k), 1);
    CHECK(pending_kv_calls_.find(k) == pending_kv_calls_.end());
    call->SendResponse();
    EnqueueRequest<CtrlMethod::kClearKV>();
  });

  Add([this](CtrlCall<CtrlMethod::kPullKV>* call) {
    const std::string& k = call->request().key();
    auto kv_it = kv_.find(k);
    if (kv_it != kv_.end()) {
      call->mut_response()->set_val(kv_it->second);
      call->SendResponse();
    } else {
      pending_kv_calls_[k].push_back(call);
    }
    EnqueueRequest<CtrlMethod::kPullKV>();
  });

  Add([this](CtrlCall<CtrlMethod::kPushActEvent>* call) {
    ActEvent act_event = call->request().act_event();
    call->SendResponse();
    Global<ActEventLogger>::Get()->PrintActEventToLogDir(act_event);
    EnqueueRequest<CtrlMethod::kPushActEvent>();
  });

  Add([this](CtrlCall<CtrlMethod::kClear>* call) {
    name2lock_status_.clear();
    kv_.clear();
    CHECK(pending_kv_calls_.empty()) << "size(): " << pending_kv_calls_.size()
                                     << ", begin()->key: " << pending_kv_calls_.begin()->first;
    call->SendResponse();
    EnqueueRequest<CtrlMethod::kClear>();
  });

  Add([this](CtrlCall<CtrlMethod::kIncreaseCount>* call) {
    int32_t& count = count_[call->request().key()];
    count += call->request().val();
    call->mut_response()->set_val(count);
    call->SendResponse();
    EnqueueRequest<CtrlMethod::kIncreaseCount>();
  });

  Add([this](CtrlCall<CtrlMethod::kEraseCount>* call) {
    CHECK_EQ(count_.erase(call->request().key()), 1);
    call->SendResponse();
    EnqueueRequest<CtrlMethod::kEraseCount>();
  });
}

}  // namespace oneflow
