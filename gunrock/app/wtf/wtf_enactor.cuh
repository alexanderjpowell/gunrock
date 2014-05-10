// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * wtf_enactor.cuh
 *
 * @brief WTF Problem Enactor
 */

#pragma once

#include <gunrock/util/kernel_runtime_stats.cuh>
#include <gunrock/util/test_utils.cuh>

#include <gunrock/oprtr/advance/kernel.cuh>
#include <gunrock/oprtr/advance/kernel_policy.cuh>
#include <gunrock/oprtr/filter/kernel.cuh>
#include <gunrock/oprtr/filter/kernel_policy.cuh>

#include <gunrock/app/enactor_base.cuh>
#include <gunrock/app/wtf/wtf_problem.cuh>
#include <gunrock/app/wtf/wtf_functor.cuh>

#include <moderngpu.cuh>

#include <cub/cub.cuh>

using namespace mgpu;

namespace gunrock {
namespace app {
namespace wtf {

/**
 * @brief WTF problem enactor class.
 *
 * @tparam INSTRUMWENT Boolean type to show whether or not to collect per-CTA clock-count statistics
 */
template<bool INSTRUMENT>
class WTFEnactor : public EnactorBase
{
    // Members
    protected:

    volatile int        *done;
    int                 *d_done;
    cudaEvent_t         throttle_event;

    // Methods
    protected:

    /**
     * @brief Prepare the enactor for WTF kernel call. Must be called prior to each WTF search.
     *
     * @param[in] problem WTF Problem object which holds the graph data and WTF problem data to compute.
     * @param[in] edge_map_grid_size CTA occupancy for edge mapping kernel call.
     * @param[in] filter_grid_size CTA occupancy for vertex mapping kernel call.
     *
     * \return cudaError_t object which indicates the success of all CUDA function calls.
     */
    template <typename ProblemData>
    cudaError_t Setup(
        ProblemData *problem)
    {
        typedef typename ProblemData::SizeT         SizeT;
        typedef typename ProblemData::VertexId      VertexId;
        
        cudaError_t retval = cudaSuccess;


        do {
            //initialize the host-mapped "done"
            if (!done) {
                int flags = cudaHostAllocMapped;

                // Allocate pinned memory for done
                if (retval = util::GRError(cudaHostAlloc((void**)&done, sizeof(int) * 1, flags),
                    "WTFEnactor cudaHostAlloc done failed", __FILE__, __LINE__)) break;

                // Map done into GPU space
                if (retval = util::GRError(cudaHostGetDevicePointer((void**)&d_done, (void*) done, 0),
                    "WTFEnactor cudaHostGetDevicePointer done failed", __FILE__, __LINE__)) break;

                // Create throttle event
                if (retval = util::GRError(cudaEventCreateWithFlags(&throttle_event, cudaEventDisableTiming),
                    "WTFEnactor cudaEventCreateWithFlags throttle_event failed", __FILE__, __LINE__)) break;
            }

            done[0]             = -1;

            //graph slice
            typename ProblemData::GraphSlice *graph_slice = problem->graph_slices[0];

            // Bind row-offsets texture
            cudaChannelFormatDesc   row_offsets_desc = cudaCreateChannelDesc<SizeT>();
            if (retval = util::GRError(cudaBindTexture(
                    0,
                    gunrock::oprtr::edge_map_forward::RowOffsetTex<SizeT>::ref,
                    graph_slice->d_row_offsets,
                    row_offsets_desc,
                    (graph_slice->nodes + 1) * sizeof(SizeT)),
                        "WTFEnactor cudaBindTexture row_offset_tex_ref failed", __FILE__, __LINE__)) break;

        } while (0);
        
        return retval;
    }

    public:

    /**
     * @brief WTFEnactor constructor
     */
    WTFEnactor(bool DEBUG = false) :
        EnactorBase(EDGE_FRONTIERS, DEBUG),
        done(NULL),
        d_done(NULL)
    {}

    /**
     * @brief WTFEnactor destructor
     */
    virtual ~WTFEnactor()
    {
        if (done) {
            util::GRError(cudaFreeHost((void*)done),
                "WTFEnactor cudaFreeHost done failed", __FILE__, __LINE__);

            util::GRError(cudaEventDestroy(throttle_event),
                "WTFEnactor cudaEventDestroy throttle_event failed", __FILE__, __LINE__);
        }
    }

    /**
     * \addtogroup PublicInterface
     * @{
     */

    /**
     * @brief Obtain statistics about the last WTF search enacted.
     *
     * @param[out] total_queued Total queued elements in WTF kernel running.
     * @param[out] avg_duty Average kernel running duty (kernel run time/kernel lifetime).
     */
    void GetStatistics(
        long long &total_queued,
        double &avg_duty)
    {
        cudaThreadSynchronize();

        total_queued = enactor_stats.total_queued;
        
        avg_duty = (enactor_stats.total_lifetimes >0) ?
            double(enactor_stats.total_runtimes) / enactor_stats.total_lifetimes : 0.0;
    }

    /** @} */

    /**
     * @brief Enacts a page rank computing on the specified graph.
     *
     * @tparam EdgeMapPolicy Kernel policy for forward edge mapping.
     * @tparam FilterPolicy Kernel policy for vertex mapping.
     * @tparam WTFProblem WTF Problem type.
     *
     * @param[in] problem WTFProblem object.
     * @param[in] src Source node for WTF.
     * @param[in] max_grid_size Max grid size for WTF kernel calls.
     *
     * \return cudaError_t object which indicates the success of all CUDA function calls.
     */
    template<
        typename AdvanceKernelPolicy,
        typename FilterKernelPolicy,
        typename WTFProblem>
    cudaError_t EnactWTF(
    CudaContext                        &context,
    WTFProblem                          *problem,
    typename WTFProblem::SizeT           max_iteration,
    int                                 max_grid_size = 0)
    {
        typedef typename WTFProblem::SizeT       SizeT;
        typedef typename WTFProblem::VertexId    VertexId;
        typedef typename WTFProblem::Value       Value;

        typedef PRFunctor<
            VertexId,
            SizeT,
            Value,
            WTFProblem> PrFunctor;

        cudaError_t retval = cudaSuccess;

        do {
            if (DEBUG) {
                printf("Iteration, Edge map queue, Vertex map queue\n");
                printf("0");
            }

            fflush(stdout);

            // Lazy initialization
            if (retval = Setup(problem)) break;

            if (retval = EnactorBase::Setup(problem,
                                            max_grid_size,
                                            AdvanceKernelPolicy::CTA_OCCUPANCY,
                                            FilterKernelPolicy::CTA_OCCUPANCY))
                                            break;

            // Single-gpu graph slice
            typename WTFProblem::GraphSlice *graph_slice = problem->graph_slices[0];
            typename WTFProblem::DataSlice *data_slice = problem->d_data_slices[0];

            frontier_attribute.queue_length         = graph_slice->nodes;
            frontier_attribute.queue_index          = 0;        // Work queue index
            frontier_attribute.selector             = 0;

            frontier_attribute.queue_reset          = true;

            frontier_attribute.queue_reset = true;
            int edge_map_queue_len = frontier_attribute.queue_length;

            // Step through WTF iterations 
            while (done[0] < 0) {

                if (retval = work_progress.SetQueueLength(frontier_attribute.queue_index, edge_map_queue_len)) break;
                // Edge Map
                gunrock::oprtr::advance::LaunchKernel<AdvanceKernelPolicy, WTFProblem, PrFunctor>(
                    d_done,
                    enactor_stats,
                    frontier_attribute,
                    data_slice,
                    (VertexId*)NULL,
                    (bool*)NULL,
                    (bool*)NULL,
                    (unsigned int*)NULL,
                    graph_slice->frontier_queues.d_keys[frontier_attribute.selector],              // d_in_queue
                    graph_slice->frontier_queues.d_keys[frontier_attribute.selector^1],            // d_out_queue
                    (VertexId*)NULL,
                    (VertexId*)NULL,
                    graph_slice->d_row_offsets,
                    graph_slice->d_column_indices,
                    (SizeT*)NULL,
                    (VertexId*)NULL,
                    graph_slice->frontier_elements[frontier_attribute.selector],                   // max_in_queue
                    graph_slice->frontier_elements[frontier_attribute.selector^1],                 // max_out_queue
                    this->work_progress,
                    context,
                    gunrock::oprtr::advance::V2V);

                if (DEBUG && (retval = util::GRError(cudaThreadSynchronize(), "edge_map_forward::Kernel failed", __FILE__, __LINE__))) break;
                cudaEventQuery(throttle_event);                                 // give host memory mapped visibility to GPU updates 

                frontier_attribute.queue_index++;

                if (DEBUG) {
                    if (retval = work_progress.GetQueueLength(frontier_attribute.queue_index, frontier_attribute.queue_length)) break;
                    printf(", %lld", (long long) frontier_attribute.queue_length);
                }

                if (INSTRUMENT) {
                    if (retval = enactor_stats.advance_kernel_stats.Accumulate(
                        enactor_stats.advance_grid_size,
                        enactor_stats.total_runtimes,
                        enactor_stats.total_lifetimes)) break;
                }

                // Throttle
                if (enactor_stats.iteration & 1) {
                    if (retval = util::GRError(cudaEventRecord(throttle_event),
                        "WTFEnactor cudaEventRecord throttle_event failed", __FILE__, __LINE__)) break;
                } else {
                    if (retval = util::GRError(cudaEventSynchronize(throttle_event),
                        "WTFEnactor cudaEventSynchronize throttle_event failed", __FILE__, __LINE__)) break;
                }

                if (frontier_attribute.queue_reset)
                    frontier_attribute.queue_reset = false;

                if (done[0] == 0) break; 
                
                if (retval = work_progress.SetQueueLength(frontier_attribute.queue_index, edge_map_queue_len)) break;

                // Vertex Map
                gunrock::oprtr::filter::Kernel<FilterKernelPolicy, WTFProblem, PrFunctor>
                <<<enactor_stats.filter_grid_size, FilterKernelPolicy::THREADS>>>(
                    enactor_stats.iteration,
                    frontier_attribute.queue_reset,
                    frontier_attribute.queue_index,
                    enactor_stats.num_gpus,
                    frontier_attribute.queue_length,
                    d_done,
                    graph_slice->frontier_queues.d_keys[frontier_attribute.selector],      // d_in_queue
                    NULL,
                    graph_slice->frontier_queues.d_keys[frontier_attribute.selector^1],    // d_out_queue
                    data_slice,
                    NULL,
                    work_progress,
                    graph_slice->frontier_elements[frontier_attribute.selector],           // max_in_queue
                    graph_slice->frontier_elements[frontier_attribute.selector^1],         // max_out_queue
                    enactor_stats.filter_kernel_stats);

                if (DEBUG && (retval = util::GRError(cudaThreadSynchronize(), "filter_forward::Kernel failed", __FILE__, __LINE__))) break;
                cudaEventQuery(throttle_event); // give host memory mapped visibility to GPU updates     

                enactor_stats.iteration++;
                frontier_attribute.queue_index++;


                if (retval = work_progress.GetQueueLength(frontier_attribute.queue_index, frontier_attribute.queue_length)) break;
                //num_elements = queue_length;

                //util::DisplayDeviceResults(problem->data_slices[0]->d_rank_next,
                //    graph_slice->nodes);
                //util::DisplayDeviceResults(problem->data_slices[0]->d_rank_curr,
                //    graph_slice->nodes);
    
                //swap rank_curr and rank_next
                util::MemsetCopyVectorKernel<<<128,
                  128>>>(problem->data_slices[0]->d_rank_curr,
                      problem->data_slices[0]->d_rank_next, graph_slice->nodes);
                util::MemsetKernel<<<128, 128>>>(problem->data_slices[0]->d_rank_next,
                    (Value)0.0, graph_slice->nodes);

                if (INSTRUMENT || DEBUG) {
                    if (retval = work_progress.GetQueueLength(frontier_attribute.queue_index, frontier_attribute.queue_length)) break;
                    enactor_stats.total_queued += frontier_attribute.queue_length;
                    if (DEBUG) printf(", %lld", (long long) frontier_attribute.queue_length);
                    if (INSTRUMENT) {
                        if (retval = enactor_stats.filter_kernel_stats.Accumulate(
                            enactor_stats.filter_grid_size,
                            enactor_stats.total_runtimes,
                            enactor_stats.total_lifetimes)) break;
                    }
                }

                if (done[0] == 0 || frontier_attribute.queue_length == 0 || enactor_stats.iteration > max_iteration) break;

                if (DEBUG) printf("\n%lld", (long long) enactor_stats.iteration);

            }

            if (retval) break;
        
        // sort the PR value TODO: make this a utility function
        Value *rank_curr;
        VertexId *node_id;
        if (util::GRError((retval = cudaMalloc(&rank_curr, sizeof(Value)*graph_slice->nodes)), "sort WTF malloc rank_curr failed", __FILE__, __LINE__)) return retval;
        if (util::GRError((retval = cudaMalloc(&node_id, sizeof(VertexId)*graph_slice->nodes)), "sort WTF malloc node_id failed", __FILE__, __LINE__)) return retval;

        cub::DoubleBuffer<Value> d_rank_curr(problem->data_slices[0]->d_rank_curr, rank_curr);
        cub::DoubleBuffer<VertexId> d_node_id(problem->data_slices[0]->d_node_ids, node_id);

        void *d_temp_storage = NULL;
        size_t temp_storage_bytes = 0;
        if (util::GRError((retval = cub::DeviceRadixSort::SortPairsDescending(d_temp_storage, temp_storage_bytes, d_rank_curr, d_node_id, graph_slice->nodes)), "cub::DeviceRadixSort::SortPairsDescending failed", __FILE__, __LINE__)) return retval; 
        if (util::GRError((retval = cudaMalloc(&d_temp_storage, temp_storage_bytes)), "sort WTF malloc d_temp_storage failed", __FILE__, __LINE__)) return retval;
        if (util::GRError((retval = cub::DeviceRadixSort::SortPairsDescending(d_temp_storage, temp_storage_bytes, d_rank_curr, d_node_id, graph_slice->nodes)), "cub::DeviceRadixSort::SortPairsDescending failed", __FILE__, __LINE__)) return retval;

        if (util::GRError((retval = cudaMemcpy(problem->data_slices[0]->d_rank_curr, d_rank_curr.Current(), sizeof(Value)*graph_slice->nodes, cudaMemcpyDeviceToDevice)), "sort WTF copy back rank_currs failed", __FILE__, __LINE__)) return retval;
        if (util::GRError((retval = cudaMemcpy(problem->data_slices[0]->d_node_ids, d_node_id.Current(), sizeof(VertexId)*graph_slice->nodes, cudaMemcpyDeviceToDevice)), "sort WTF copy back node ids failed", __FILE__, __LINE__)) return retval;

        if (util::GRError((retval = cudaFree(d_temp_storage)), "sort WTF free d_temp_storage failed", __FILE__, __LINE__)) return retval;
        if (util::GRError((retval = cudaFree(node_id)), "sort WTF free node_id failed", __FILE__, __LINE__)) return retval;
        if (util::GRError((retval = cudaFree(rank_curr)), "sort WTF free rank_curr failed", __FILE__, __LINE__)) return retval;

        /*
           1 according to the first 1000 Circle of Trust nodes. Get all their neighbors.
           2 write these circle of trust nodes in a bitmap
           3 compute atomicAdd their neighbors' incoming node number.
           4 set hub nodes in the frontier_keys and auth nodes in the frontier_values
           5 change the salsa functor to be aware of the bitmap test
         */


        } while(0); 

        if (DEBUG) printf("\nGPU WTF Done.\n");
        return retval;
    }

    /**
     * \addtogroup PublicInterface
     * @{
     */

    /**
     * @brief WTF Enact kernel entry.
     *
     * @tparam WTFProblem WTF Problem type. @see PRProblem
     *
     * @param[in] problem Pointer to WTFProblem object.
     * @param[in] src Source node for WTF.
     * @param[in] max_grid_size Max grid size for WTF kernel calls.
     *
     * \return cudaError_t object which indicates the success of all CUDA function calls.
     */
    template <typename WTFProblem>
    cudaError_t Enact(
        CudaContext                     &context,
        WTFProblem                      *problem,
        typename WTFProblem::SizeT       max_iteration,
        int                             max_grid_size = 0)
    {
        if (this->cuda_props.device_sm_version >= 300) {
            typedef gunrock::oprtr::filter::KernelPolicy<
                WTFProblem,                         // Problem data type
            300,                                // CUDA_ARCH
            INSTRUMENT,                         // INSTRUMENT
            0,                                  // SATURATION QUIT
            true,                               // DEQUEUE_WTFOBLEM_SIZE
            8,                                  // MIN_CTA_OCCUPANCY
            6,                                  // LOG_THREADS
            1,                                  // LOG_LOAD_VEC_SIZE
            0,                                  // LOG_LOADS_PER_TILE
            5,                                  // LOG_RAKING_THREADS
            5,                                  // END_BITMASK_CULL
            8>                                  // LOG_SCHEDULE_GRANULARITY
                FilterKernelPolicy;

            typedef gunrock::oprtr::advance::KernelPolicy<
                WTFProblem,                         // Problem data type
                300,                                // CUDA_ARCH
                INSTRUMENT,                         // INSTRUMENT
                8,                                  // MIN_CTA_OCCUPANCY
                6,                                  // LOG_THREADS
                1,                                  // LOG_LOAD_VEC_SIZE
                0,                                  // LOG_LOADS_PER_TILE
                0,
                0,
                5,                                  // LOG_RAKING_THREADS
                32,                            // WARP_GATHER_THRESHOLD
                128 * 4,                            // CTA_GATHER_THRESHOLD
                7,                                  // LOG_SCHEDULE_GRANULARITY
                gunrock::oprtr::advance::TWC_FORWARD>
                    AdvanceKernelPolicy;

            return EnactWTF<AdvanceKernelPolicy, FilterKernelPolicy, WTFProblem>(
                    context, problem, max_iteration, max_grid_size);
        }

        //to reduce compile time, get rid of other architecture for now
        //TODO: add all the kernelpolicy settings for all archs

        printf("Not yet tuned for this architecture\n");
        return cudaErrorInvalidDeviceFunction;
    }

    /** @} */

};

} // namespace wtf
} // namespace app
} // namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End: