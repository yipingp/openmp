//===---- parallel.cu - NVPTX OpenMP parallel implementation ----- CUDA -*-===//
//
//                     The LLVM Compiler Infrastructure
//
// This file is dual licensed under the MIT and the University of Illinois Open
// Source Licenses. See LICENSE.txt for details.
//
//===----------------------------------------------------------------------===//
//
// Parallel implemention in the GPU. Here is the pattern:
//
//    while (not finished) {
//
//    if (master) {
//      sequential code, decide which par loop to do, or if finished
//     __kmpc_kernel_prepare_parallel() // exec by master only
//    }
//    syncthreads // A
//    __kmpc_kernel_parallel() // exec by all
//    if (this thread is included in the parallel) {
//      switch () for all parallel loops
//      __kmpc_kernel_end_parallel() // exec only by threads in parallel
//    }
//
//
//    The reason we don't exec end_parallel for the threads not included
//    in the parallel loop is that for each barrier in the parallel
//    region, these non-included threads will cycle through the
//    syncthread A. Thus they must preserve their current threadId that
//    is larger than thread in team.
//
//    To make a long story short...
//
//===----------------------------------------------------------------------===//

#include "omptarget-nvptx.h"

typedef struct ConvergentSimdJob {
  omptarget_nvptx_TaskDescr taskDescr;
  omptarget_nvptx_TaskDescr *convHeadTaskDescr;
  uint16_t slimForNextSimd;
} ConvergentSimdJob;

////////////////////////////////////////////////////////////////////////////////
// support for convergent simd (team of threads in a warp only)
////////////////////////////////////////////////////////////////////////////////
EXTERN bool __kmpc_kernel_convergent_simd(void *buffer, uint32_t Mask,
                                          bool *IsFinal, int32_t *LaneSource,
                                          int32_t *LaneId, int32_t *NumLanes) {
  PRINT0(LD_IO, "call to __kmpc_kernel_convergent_simd\n");
  uint32_t ConvergentMask = Mask;
  int32_t ConvergentSize = __popc(ConvergentMask);
  uint32_t WorkRemaining = ConvergentMask >> (*LaneSource + 1);
  *LaneSource += __ffs(WorkRemaining);
  *IsFinal = __popc(WorkRemaining) == 1;
  uint32_t lanemask_lt;
  asm("mov.u32 %0, %%lanemask_lt;" : "=r"(lanemask_lt));
  *LaneId = __popc(ConvergentMask & lanemask_lt);

  int threadId = GetLogicalThreadIdInBlock();
  int sourceThreadId = (threadId & ~(WARPSIZE - 1)) + *LaneSource;

  ConvergentSimdJob *job = (ConvergentSimdJob *)buffer;
  int32_t SimdLimit =
      omptarget_nvptx_threadPrivateContext->SimdLimitForNextSimd(threadId);
  job->slimForNextSimd = SimdLimit;

  int32_t SimdLimitSource = __SHFL_SYNC(Mask, SimdLimit, *LaneSource);
  // reset simdlimit to avoid propagating to successive #simd
  if (SimdLimitSource > 0 && threadId == sourceThreadId)
    omptarget_nvptx_threadPrivateContext->SimdLimitForNextSimd(threadId) = 0;

  // We cannot have more than the # of convergent threads.
  if (SimdLimitSource > 0)
    *NumLanes = min(ConvergentSize, SimdLimitSource);
  else
    *NumLanes = ConvergentSize;
  ASSERT(LT_FUSSY, *NumLanes > 0, "bad thread request of %d threads",
         *NumLanes);

  // Set to true for lanes participating in the simd region.
  bool isActive = false;
  // Initialize state for active threads.
  if (*LaneId < *NumLanes) {
    omptarget_nvptx_TaskDescr *currTaskDescr =
        omptarget_nvptx_threadPrivateContext->GetTopLevelTaskDescr(threadId);
    omptarget_nvptx_TaskDescr *sourceTaskDescr =
        omptarget_nvptx_threadPrivateContext->GetTopLevelTaskDescr(
            sourceThreadId);
    job->convHeadTaskDescr = currTaskDescr;
    // install top descriptor from the thread for which the lanes are working.
    omptarget_nvptx_threadPrivateContext->SetTopLevelTaskDescr(threadId,
                                                               sourceTaskDescr);
    isActive = true;
  }

  // requires a memory fence between threads of a warp
  return isActive;
}

EXTERN void __kmpc_kernel_end_convergent_simd(void *buffer) {
  PRINT0(LD_IO | LD_PAR, "call to __kmpc_kernel_end_convergent_parallel\n");
  // pop stack
  int threadId = GetLogicalThreadIdInBlock();
  ConvergentSimdJob *job = (ConvergentSimdJob *)buffer;
  omptarget_nvptx_threadPrivateContext->SimdLimitForNextSimd(threadId) =
      job->slimForNextSimd;
  omptarget_nvptx_threadPrivateContext->SetTopLevelTaskDescr(
      threadId, job->convHeadTaskDescr);
}

typedef struct ConvergentParallelJob {
  omptarget_nvptx_TaskDescr taskDescr;
  omptarget_nvptx_TaskDescr *convHeadTaskDescr;
  uint16_t tnumForNextPar;
} ConvergentParallelJob;

////////////////////////////////////////////////////////////////////////////////
// support for convergent parallelism (team of threads in a warp only)
////////////////////////////////////////////////////////////////////////////////
EXTERN bool __kmpc_kernel_convergent_parallel(void *buffer, uint32_t Mask,
                                              bool *IsFinal,
                                              int32_t *LaneSource) {
  PRINT0(LD_IO, "call to __kmpc_kernel_convergent_parallel\n");
  uint32_t ConvergentMask = Mask;
  int32_t ConvergentSize = __popc(ConvergentMask);
  uint32_t WorkRemaining = ConvergentMask >> (*LaneSource + 1);
  *LaneSource += __ffs(WorkRemaining);
  *IsFinal = __popc(WorkRemaining) == 1;
  uint32_t lanemask_lt;
  asm("mov.u32 %0, %%lanemask_lt;" : "=r"(lanemask_lt));
  uint32_t OmpId = __popc(ConvergentMask & lanemask_lt);

  int threadId = GetLogicalThreadIdInBlock();
  int sourceThreadId = (threadId & ~(WARPSIZE - 1)) + *LaneSource;

  ConvergentParallelJob *job = (ConvergentParallelJob *)buffer;
  int32_t NumThreadsClause =
      omptarget_nvptx_threadPrivateContext->NumThreadsForNextParallel(threadId);
  job->tnumForNextPar = NumThreadsClause;

  int32_t NumThreadsSource = __SHFL_SYNC(Mask, NumThreadsClause, *LaneSource);
  // reset numthreads to avoid propagating to successive #parallel
  if (NumThreadsSource > 0 && threadId == sourceThreadId)
    omptarget_nvptx_threadPrivateContext->NumThreadsForNextParallel(threadId) =
        0;

  // We cannot have more than the # of convergent threads.
  uint16_t NumThreads;
  if (NumThreadsSource > 0)
    NumThreads = min(ConvergentSize, NumThreadsSource);
  else
    NumThreads = ConvergentSize;
  ASSERT(LT_FUSSY, NumThreads > 0, "bad thread request of %d threads",
         NumThreads);

  // Set to true for workers participating in the parallel region.
  bool isActive = false;
  // Initialize state for active threads.
  if (OmpId < NumThreads) {
    // init L2 task descriptor and storage for the L1 parallel task descriptor.
    omptarget_nvptx_TaskDescr *newTaskDescr = &job->taskDescr;
    ASSERT0(LT_FUSSY, newTaskDescr, "expected a task descr");
    omptarget_nvptx_TaskDescr *currTaskDescr =
        omptarget_nvptx_threadPrivateContext->GetTopLevelTaskDescr(threadId);
    omptarget_nvptx_TaskDescr *sourceTaskDescr =
        omptarget_nvptx_threadPrivateContext->GetTopLevelTaskDescr(
            sourceThreadId);
    job->convHeadTaskDescr = currTaskDescr;
    newTaskDescr->CopyConvergentParent(sourceTaskDescr, OmpId, NumThreads);
    // install new top descriptor
    omptarget_nvptx_threadPrivateContext->SetTopLevelTaskDescr(threadId,
                                                               newTaskDescr);
    isActive = true;
  }

  // requires a memory fence between threads of a warp
  return isActive;
}

EXTERN void __kmpc_kernel_end_convergent_parallel(void *buffer) {
  PRINT0(LD_IO | LD_PAR, "call to __kmpc_kernel_end_convergent_parallel\n");
  // pop stack
  int threadId = GetLogicalThreadIdInBlock();
  ConvergentParallelJob *job = (ConvergentParallelJob *)buffer;
  omptarget_nvptx_threadPrivateContext->SetTopLevelTaskDescr(
      threadId, job->convHeadTaskDescr);
  omptarget_nvptx_threadPrivateContext->NumThreadsForNextParallel(threadId) =
      job->tnumForNextPar;
}

////////////////////////////////////////////////////////////////////////////////
// support for parallel that goes parallel (1 static level only)
////////////////////////////////////////////////////////////////////////////////

// return number of cuda threads that participate to parallel
// calculation has to consider simd implementation in nvptx
// i.e. (num omp threads * num lanes)
//
// cudathreads =
//    if(num_threads != 0) {
//      if(thread_limit > 0) {
//        min (num_threads*numLanes ; thread_limit*numLanes);
//      } else {
//        min (num_threads*numLanes; blockDim.x)
//      }
//    } else {
//      if (thread_limit != 0) {
//        min (thread_limit*numLanes; blockDim.x)
//      } else { // no thread_limit, no num_threads, use all cuda threads
//        blockDim.x;
//      }
//    }
//
// This routine is always called by the team master..
EXTERN void __kmpc_kernel_prepare_parallel(void *WorkFn,
                                           int16_t IsOMPRuntimeInitialized) {
  PRINT0(LD_IO, "call to __kmpc_kernel_prepare_parallel\n");
  assert(IsOMPRuntimeInitialized && "expected initialized runtime.");

  omptarget_nvptx_workFn = WorkFn;

  // This routine is only called by the team master.  The team master is
  // the first thread of the last warp.  It always has the logical thread
  // id of 0 (since it is a shadow for the first worker thread).
  int threadId = 0;
  omptarget_nvptx_TaskDescr *currTaskDescr =
      omptarget_nvptx_threadPrivateContext->GetTopLevelTaskDescr(threadId);
  ASSERT0(LT_FUSSY, currTaskDescr, "expected a top task descr");
  ASSERT0(LT_FUSSY, !currTaskDescr->InParallelRegion(),
          "cannot be called in a parallel region.");
  if (currTaskDescr->InParallelRegion()) {
    PRINT0(LD_PAR, "already in parallel: go seq\n");
    return;
  }

  uint16_t CudaThreadsForParallel = 0;
  uint16_t NumThreadsClause =
      omptarget_nvptx_threadPrivateContext->NumThreadsForNextParallel(threadId);

  // we cannot have more than block size
  uint16_t CudaThreadsAvail = GetNumberOfWorkersInTeam();

  // currTaskDescr->ThreadLimit(): If non-zero, this is the limit as
  // specified by the thread_limit clause on the target directive.
  // GetNumberOfWorkersInTeam(): This is the number of workers available
  // in this kernel instance.
  //
  // E.g: If thread_limit is 33, the kernel is launched with 33+32=65
  // threads.  The last warp is the master warp so in this case
  // GetNumberOfWorkersInTeam() returns 64.

  // this is different from ThreadAvail of OpenMP because we may be
  // using some of the CUDA threads as SIMD lanes
  int NumLanes = 1;
  if (NumThreadsClause != 0) {
    // reset request to avoid propagating to successive #parallel
    omptarget_nvptx_threadPrivateContext->NumThreadsForNextParallel(threadId) =
        0;

    // assume that thread_limit*numlanes is already <= CudaThreadsAvail
    // because that is already checked on the host side (CUDA offloading rtl)
    if (currTaskDescr->ThreadLimit() != 0)
      CudaThreadsForParallel =
          NumThreadsClause * NumLanes < currTaskDescr->ThreadLimit() * NumLanes
              ? NumThreadsClause * NumLanes
              : currTaskDescr->ThreadLimit() * NumLanes;
    else {
      CudaThreadsForParallel = (NumThreadsClause * NumLanes > CudaThreadsAvail)
                                   ? CudaThreadsAvail
                                   : NumThreadsClause * NumLanes;
    }
  } else {
    if (currTaskDescr->ThreadLimit() != 0) {
      CudaThreadsForParallel =
          (currTaskDescr->ThreadLimit() * NumLanes > CudaThreadsAvail)
              ? CudaThreadsAvail
              : currTaskDescr->ThreadLimit() * NumLanes;
    } else
      CudaThreadsForParallel = CudaThreadsAvail;
  }

#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ >= 700
  // On Volta and newer architectures we require that all lanes in
  // a warp participate in the parallel region.  Round down to a
  // multiple of WARPSIZE since it is legal to do so in OpenMP.
  // CudaThreadsAvail is the number of workers available in this
  // kernel instance and is greater than or equal to
  // currTaskDescr->ThreadLimit().
  if (CudaThreadsForParallel < CudaThreadsAvail) {
    CudaThreadsForParallel =
        (CudaThreadsForParallel < WARPSIZE)
            ? 1
            : CudaThreadsForParallel & ~((uint16_t)WARPSIZE - 1);
  }
#endif

  ASSERT(LT_FUSSY, CudaThreadsForParallel > 0,
         "bad thread request of %d threads", CudaThreadsForParallel);
  ASSERT0(LT_FUSSY, GetThreadIdInBlock() == GetMasterThreadID(),
          "only team master can create parallel");

  // set number of threads on work descriptor
  // this is different from the number of cuda threads required for the parallel
  // region
  omptarget_nvptx_WorkDescr &workDescr = getMyWorkDescriptor();
  workDescr.WorkTaskDescr()->CopyToWorkDescr(currTaskDescr,
                                             CudaThreadsForParallel / NumLanes);
  // init counters (copy start to init)
  workDescr.CounterGroup().Reset();
}

// All workers call this function.  Deactivate those not needed.
// Fn - the outlined work function to execute.
// returns True if this thread is active, else False.
//
// Only the worker threads call this routine.
EXTERN bool __kmpc_kernel_parallel(void **WorkFn,
                                   int16_t IsOMPRuntimeInitialized) {
  PRINT0(LD_IO | LD_PAR, "call to __kmpc_kernel_parallel\n");

  assert(IsOMPRuntimeInitialized && "expected initialized runtime.");

  // Work function and arguments for L1 parallel region.
  *WorkFn = omptarget_nvptx_workFn;

  // If this is the termination signal from the master, quit early.
  if (!*WorkFn)
    return false;

  // Only the worker threads call this routine and the master warp
  // never arrives here.  Therefore, use the nvptx thread id.
  int threadId = GetThreadIdInBlock();
  omptarget_nvptx_WorkDescr &workDescr = getMyWorkDescriptor();
  // Set to true for workers participating in the parallel region.
  bool isActive = false;
  // Initialize state for active threads.
  if (threadId < workDescr.WorkTaskDescr()->ThreadsInTeam()) {
    // init work descriptor from workdesccr
    omptarget_nvptx_TaskDescr *newTaskDescr =
        omptarget_nvptx_threadPrivateContext->Level1TaskDescr(threadId);
    ASSERT0(LT_FUSSY, newTaskDescr, "expected a task descr");
    newTaskDescr->CopyFromWorkDescr(workDescr.WorkTaskDescr());
    // install new top descriptor
    omptarget_nvptx_threadPrivateContext->SetTopLevelTaskDescr(threadId,
                                                               newTaskDescr);
    // init private from int value
    workDescr.CounterGroup().Init(
        omptarget_nvptx_threadPrivateContext->Priv(threadId));
    PRINT(LD_PAR,
          "thread will execute parallel region with id %d in a team of "
          "%d threads\n",
          newTaskDescr->ThreadId(), newTaskDescr->NThreads());

    isActive = true;
  }

  return isActive;
}

EXTERN void __kmpc_kernel_end_parallel() {
  // pop stack
  PRINT0(LD_IO | LD_PAR, "call to __kmpc_kernel_end_parallel\n");
  assert(isRuntimeInitialized() && "expected initialized runtime.");

  // Only the worker threads call this routine and the master warp
  // never arrives here.  Therefore, use the nvptx thread id.
  int threadId = GetThreadIdInBlock();
  omptarget_nvptx_TaskDescr *currTaskDescr = getMyTopTaskDescriptor(threadId);
  omptarget_nvptx_threadPrivateContext->SetTopLevelTaskDescr(
      threadId, currTaskDescr->GetPrevTaskDescr());
}

////////////////////////////////////////////////////////////////////////////////
// support for parallel that goes sequential
////////////////////////////////////////////////////////////////////////////////

EXTERN void __kmpc_serialized_parallel(kmp_Indent *loc, uint32_t global_tid) {
  PRINT0(LD_IO, "call to __kmpc_serialized_parallel\n");

  if (isRuntimeUninitialized()) {
    assert(isSPMDMode() && "Expected SPMD mode with uninitialized runtime.");
    omptarget_nvptx_simpleThreadPrivateContext->IncParLevel();
    return;
  }

  // assume this is only called for nested parallel
  int threadId = GetLogicalThreadIdInBlock();

  // unlike actual parallel, threads in the same team do not share
  // the workTaskDescr in this case and num threads is fixed to 1

  // get current task
  omptarget_nvptx_TaskDescr *currTaskDescr = getMyTopTaskDescriptor(threadId);
  currTaskDescr->SaveLoopData();

  // allocate new task descriptor and copy value from current one, set prev to
  // it
  omptarget_nvptx_TaskDescr *newTaskDescr =
      (omptarget_nvptx_TaskDescr *)SafeMalloc(sizeof(omptarget_nvptx_TaskDescr),
                                              "new seq parallel task");
  newTaskDescr->CopyParent(currTaskDescr);

  // tweak values for serialized parallel case:
  // - each thread becomes ID 0 in its serialized parallel, and
  // - there is only one thread per team
  newTaskDescr->ThreadId() = 0;
  newTaskDescr->ThreadsInTeam() = 1;

  // set new task descriptor as top
  omptarget_nvptx_threadPrivateContext->SetTopLevelTaskDescr(threadId,
                                                             newTaskDescr);
}

EXTERN void __kmpc_end_serialized_parallel(kmp_Indent *loc,
                                           uint32_t global_tid) {
  PRINT0(LD_IO, "call to __kmpc_end_serialized_parallel\n");

  if (isRuntimeUninitialized()) {
    assert(isSPMDMode() && "Expected SPMD mode with uninitialized runtime.");
    omptarget_nvptx_simpleThreadPrivateContext->DecParLevel();
    return;
  }

  // pop stack
  int threadId = GetLogicalThreadIdInBlock();
  omptarget_nvptx_TaskDescr *currTaskDescr = getMyTopTaskDescriptor(threadId);
  // set new top
  omptarget_nvptx_threadPrivateContext->SetTopLevelTaskDescr(
      threadId, currTaskDescr->GetPrevTaskDescr());
  // free
  SafeFree(currTaskDescr, (char *)"new seq parallel task");
  currTaskDescr = getMyTopTaskDescriptor(threadId);
  currTaskDescr->RestoreLoopData();
}

EXTERN uint16_t __kmpc_parallel_level(kmp_Indent *loc, uint32_t global_tid) {
  PRINT0(LD_IO, "call to __kmpc_parallel_level\n");

  if (isRuntimeUninitialized()) {
    assert(isSPMDMode() && "Expected SPMD mode with uninitialized runtime.");
    return omptarget_nvptx_simpleThreadPrivateContext->GetParallelLevel();
  }

  int threadId = GetLogicalThreadIdInBlock();
  omptarget_nvptx_TaskDescr *currTaskDescr =
      omptarget_nvptx_threadPrivateContext->GetTopLevelTaskDescr(threadId);
  if (currTaskDescr->InL2OrHigherParallelRegion())
    return 2;
  else if (currTaskDescr->InParallelRegion())
    return 1;
  else
    return 0;
}

// This kmpc call returns the thread id across all teams. It's value is
// cached by the compiler and used when calling the runtime. On nvptx
// it's cheap to recalculate this value so we never use the result
// of this call.
EXTERN int32_t __kmpc_global_thread_num(kmp_Indent *loc) {
  return GetLogicalThreadIdInBlock();
}

////////////////////////////////////////////////////////////////////////////////
// push params
////////////////////////////////////////////////////////////////////////////////

EXTERN void __kmpc_push_num_threads(kmp_Indent *loc, int32_t tid,
                                    int32_t num_threads) {
  PRINT(LD_IO, "call kmpc_push_num_threads %d\n", num_threads);
  assert(isRuntimeInitialized() && "Runtime must be initialized.");
  tid = GetLogicalThreadIdInBlock();
  omptarget_nvptx_threadPrivateContext->NumThreadsForNextParallel(tid) =
      num_threads;
}

EXTERN void __kmpc_push_simd_limit(kmp_Indent *loc, int32_t tid,
                                   int32_t simd_limit) {
  PRINT(LD_IO, "call kmpc_push_simd_limit %d\n", simd_limit);
  assert(isRuntimeInitialized() && "Runtime must be initialized.");
  tid = GetLogicalThreadIdInBlock();
  omptarget_nvptx_threadPrivateContext->SimdLimitForNextSimd(tid) = simd_limit;
}

// Do nothing. The host guarantees we started the requested number of
// teams and we only need inspection of gridDim.

EXTERN void __kmpc_push_num_teams(kmp_Indent *loc, int32_t tid,
                                  int32_t num_teams, int32_t thread_limit) {
  PRINT(LD_IO, "call kmpc_push_num_teams %d\n", num_teams);
  ASSERT0(LT_FUSSY, FALSE,
          "should never have anything with new teams on device");
}

EXTERN void __kmpc_push_proc_bind(kmp_Indent *loc, uint32_t tid,
                                  int proc_bind) {
  PRINT(LD_IO, "call kmpc_push_proc_bind %d\n", proc_bind);
}