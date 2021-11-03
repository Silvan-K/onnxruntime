// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#ifndef USE_ONNXRUNTIME_DLL
#ifdef __GNUC__
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wignored-qualifiers"
#pragma GCC diagnostic ignored "-Wunused-parameter"
#else
#endif
#include <google/protobuf/message_lite.h>
#ifdef __GNUC__
#pragma GCC diagnostic pop
#endif
#endif

#include "core/session/onnxruntime_cxx_api.h"
#include "gtest/gtest.h"
#include "test/test_environment.h"
#include <thread>

std::unique_ptr<Ort::Env> ort_env;

#define ORT_RETURN_IF_NON_NULL_STATUS(arg) \
  if (arg) {                               \
    return -1;                             \
  }

namespace TestGlobalCustomThreadHooks {

std::vector<std::thread> threads;
int32_t custom_thread_creation_options = 5;
int32_t custom_creation_hook_called = 0;
int32_t custom_join_hook_called = 0;

THREAD_HANDLE CreateThreadCustomized(void* options, OrtThreadWorkerFn work_loop, void* param) {
  if (*((int32_t*)options) == 5) {
    custom_creation_hook_called += 1;
  }
  threads.push_back(std::thread(work_loop, param));
  return (THREAD_HANDLE)threads.back().native_handle();
}

void JoinThreadCustomized(THREAD_HANDLE handle) {
  for (auto& t : threads) {
    if ((THREAD_HANDLE)t.native_handle() == handle) {
      custom_join_hook_called += 1;
      t.join();
    }
  }
}

}  // namespace TestGlobalCustomThreadHooks

using namespace TestGlobalCustomThreadHooks;

int main(int argc, char** argv) {
  int status = 0;
  const int thread_pool_size = std::thread::hardware_concurrency();
  ORT_TRY {
    ::testing::InitGoogleTest(&argc, argv);
    const OrtApi* g_ort = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    std::unique_ptr<OrtStatus, decltype(OrtApi::ReleaseStatus)> st_ptr(nullptr, g_ort->ReleaseStatus);
    OrtThreadingOptions* tp_options;

    st_ptr.reset(g_ort->CreateThreadingOptions(&tp_options));
    ORT_RETURN_IF_NON_NULL_STATUS(st_ptr);

    st_ptr.reset(g_ort->SetGlobalSpinControl(tp_options, 0));
    ORT_RETURN_IF_NON_NULL_STATUS(st_ptr);

    st_ptr.reset(g_ort->SetGlobalIntraOpNumThreads(tp_options, thread_pool_size));
    ORT_RETURN_IF_NON_NULL_STATUS(st_ptr);

    st_ptr.reset(g_ort->SetGlobalIntraOpCustomCreateThreadFn(tp_options, CreateThreadCustomized));
    ORT_RETURN_IF_NON_NULL_STATUS(st_ptr);

    st_ptr.reset(g_ort->SetGlobalIntraOpCustomThreadCreationOptions(tp_options, &custom_thread_creation_options));
    ORT_RETURN_IF_NON_NULL_STATUS(st_ptr);

    st_ptr.reset(g_ort->SetGlobalIntraOpCustomJoinThreadFn(tp_options, JoinThreadCustomized));
    ORT_RETURN_IF_NON_NULL_STATUS(st_ptr);

    st_ptr.reset(g_ort->SetGlobalInterOpNumThreads(tp_options, thread_pool_size));
    ORT_RETURN_IF_NON_NULL_STATUS(st_ptr);

    st_ptr.reset(g_ort->SetGlobalInterOpCustomCreateThreadFn(tp_options, CreateThreadCustomized));
    ORT_RETURN_IF_NON_NULL_STATUS(st_ptr);

    st_ptr.reset(g_ort->SetGlobalInterOpCustomThreadCreationOptions(tp_options, &custom_thread_creation_options));
    ORT_RETURN_IF_NON_NULL_STATUS(st_ptr);

    st_ptr.reset(g_ort->SetGlobalInterOpCustomJoinThreadFn(tp_options, JoinThreadCustomized));
    ORT_RETURN_IF_NON_NULL_STATUS(st_ptr);

    st_ptr.reset(g_ort->SetGlobalDenormalAsZero(tp_options));
    ORT_RETURN_IF_NON_NULL_STATUS(st_ptr);

    ort_env.reset(new Ort::Env(tp_options, ORT_LOGGING_LEVEL_VERBOSE, "Default"));  // this is the only change from test/providers/test_main.cc
    g_ort->ReleaseThreadingOptions(tp_options);
    status = RUN_ALL_TESTS();
  }
  ORT_CATCH(const std::exception& ex) {
    ORT_HANDLE_EXCEPTION([&]() {
      std::cerr << ex.what();
      status = -1;
    });
  }

  //TODO: Fix the C API issue
  ort_env.reset();  //If we don't do this, it will crash

#ifndef _OPENMP
  const int expexted_custom_calls = (thread_pool_size - 1) << 1;
  ORT_ENFORCE(custom_creation_hook_called == expexted_custom_calls, "custom thread creation functions were not called as expected");
  ORT_ENFORCE(custom_join_hook_called == expexted_custom_calls, "custom thread joining functions were not called as expected");
#endif

#ifndef USE_ONNXRUNTIME_DLL
  //make memory leak checker happy
  ::google::protobuf::ShutdownProtobufLibrary();
#endif
  return status;
}
