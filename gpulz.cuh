#include "utils.h"
#include <cuda.h>
#include <cuda_runtime.h>
#include <cuda_runtime_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <cmath>
#include <thrust/scan.h>
#include <thrust/execution_policy.h>

#define BLOCK_SIZE 2048    // in unit of byte, the size of one data block
#define THREAD_SIZE 128    // in unit of datatype, the size of the thread block, so as the size of symbols per iteration
#define WINDOW_SIZE 32     // in unit of datatype, maximum 255, the size of the sliding window, so as the maximum match length
#define INPUT_TYPE int8_t // define input type, since c++ doesn't support runtime data type defination

// #define GDS_SWITCH // switch to use GDS or not

// Define the compress match kernel functions
template <typename T>
__global__ void compressKernelI(T *input, uint32_t numOfBlocks, uint32_t *flagArrSizeGlobal, uint32_t *compressedDataSizeGlobal, uint8_t *tmpFlagArrGlobal, uint8_t *tmpCompressedDataGlobal, int minEncodeLength, uint8_t *notEmptyFlagArr)
{
    // Block size in uint of datatype
    const uint32_t blockSize = BLOCK_SIZE / sizeof(T);

    // Window size in uint of datatype
    const uint32_t threadSize = THREAD_SIZE;

    // Allocate shared memory for the lookahead buffer of the whole block, the
    // sliding window is included
    __shared__ T buffer[blockSize];

    // initialize the tid
    int tid = 0;

    // Copy the memeory from global to shared
    for (int i = 0; i < blockSize / threadSize; i++)
    {
        buffer[threadIdx.x + threadSize * i] =
            input[blockIdx.x * blockSize + threadIdx.x + threadSize * i];
    }

    // tell if all the data in this data chunk are zero
    __shared__ int notEmptyFlag;

    if (threadIdx.x == 0)
    {
        notEmptyFlag = 0;
    }

    __syncthreads();

    for (int iterationIdx = 0; iterationIdx < (int)(blockSize / threadSize); iterationIdx++)
    {
        if (__any_sync(0xFFFFFFFF, buffer[threadIdx.x + iterationIdx * threadSize]))
        {
            if (threadIdx.x % 32 == 0)
            {
                notEmptyFlag = 1;
            }
        }
    }
    __syncthreads();

    if (notEmptyFlag == 0)
    {
        return;
    }

    if (threadIdx.x == 0)
    {
        notEmptyFlagArr[blockIdx.x] = 1;
    }

    __shared__ uint8_t lengthBuffer[blockSize];
    __shared__ uint8_t offsetBuffer[blockSize];
    __shared__ uint32_t prefixBuffer[blockSize + 1];

    // Synchronize all threads to ensure that the buffer is fully loaded
    __syncthreads();

    // find match for every data point
    for (int iteration = 0; iteration < (int)(blockSize / threadSize);
         iteration++)
    {
        // Initialize the lookahead buffer and the sliding window pointers
        tid = threadIdx.x + iteration * threadSize;
        int bufferStart = tid;
        int bufferPointer = bufferStart;
        int windowStart =
            bufferStart - int(WINDOW_SIZE) < 0 ? 0 : bufferStart - WINDOW_SIZE;
        int windowPointer = windowStart;

        uint8_t maxLen = 0;
        uint8_t maxOffset = 0;
        uint8_t len = 0;
        uint8_t offset = 0;

        while (windowPointer < bufferStart && bufferPointer < blockSize)
        {
            if (buffer[bufferPointer] == buffer[windowPointer])
            {
                if (offset == 0)
                {
                    offset = bufferPointer - windowPointer;
                }
                len++;
                bufferPointer++;
            }
            else
            {
                if (len > maxLen)
                {
                    maxLen = len;
                    maxOffset = offset;
                }
                len = 0;
                offset = 0;
                bufferPointer = bufferStart;
            }
            windowPointer++;
        }
        if (len > maxLen)
        {
            maxLen = len;
            maxOffset = offset;
        }

        lengthBuffer[threadIdx.x + iteration * threadSize] = maxLen;
        offsetBuffer[threadIdx.x + iteration * threadSize] = maxOffset;

        // initialize array as 0
        prefixBuffer[threadIdx.x + iteration * threadSize] = 0;
    }
    __syncthreads();

    // find encode information
    uint32_t flagCount = 0;
    __shared__ uint8_t byteFlagArr[(blockSize / 8)];

    if (threadIdx.x == 0)
    {
        uint8_t flagPosition = 0x01;
        uint8_t byteFlag = 0;

        int encodeIndex = 0;

        while (encodeIndex < blockSize)
        {
            // if length < minEncodeLength, no match is found
            if (lengthBuffer[encodeIndex] < minEncodeLength)
            {
                prefixBuffer[encodeIndex] = sizeof(T);
                encodeIndex++;
            }
            // if length > minEncodeLength, match is found
            else
            {
                prefixBuffer[encodeIndex] = 2;
                encodeIndex += lengthBuffer[encodeIndex];
                byteFlag |= flagPosition;
            }
            // store the flag if there are 8 bits already
            if (flagPosition == 0x80)
            {
                byteFlagArr[flagCount] = byteFlag;
                flagCount++;
                flagPosition = 0x01;
                byteFlag = 0;
                continue;
            }
            flagPosition <<= 1;
        }
        if (flagPosition != 0x01)
        {
            byteFlagArr[flagCount] = byteFlag;
            flagCount++;
        }
    }
    __syncthreads();

    // prefix summation, up-sweep
    int prefixSumOffset = 1;
    for (uint32_t d = blockSize >> 1; d > 0; d = d >> 1)
    {
        for (int iteration = 0; iteration < (int)(blockSize / threadSize);
             iteration++)
        {
            tid = threadIdx.x + iteration * threadSize;
            if (tid < d)
            {
                int ai = prefixSumOffset * (2 * tid + 1) - 1;
                int bi = prefixSumOffset * (2 * tid + 2) - 1;
                prefixBuffer[bi] += prefixBuffer[ai];
            }
            __syncthreads();
        }
        prefixSumOffset *= 2;
    }

    // clear the last element
    if (threadIdx.x == 0)
    {
        // printf("block size: %d flag array size: %d\n", prefixBuffer[blockSize - 1], flagCount);
        compressedDataSizeGlobal[blockIdx.x] = prefixBuffer[blockSize - 1];
        flagArrSizeGlobal[blockIdx.x] = flagCount;
        prefixBuffer[blockSize] = prefixBuffer[blockSize - 1];
        prefixBuffer[blockSize - 1] = 0;
    }
    __syncthreads();

    // prefix summation, down-sweep
    for (int d = 1; d < blockSize; d *= 2)
    {
        prefixSumOffset >>= 1;
        for (int iteration = 0; iteration < (int)(blockSize / threadSize);
             iteration++)
        {
            tid = threadIdx.x + iteration * threadSize;

            if (tid < d)
            {
                int ai = prefixSumOffset * (2 * tid + 1) - 1;
                int bi = prefixSumOffset * (2 * tid + 2) - 1;

                uint32_t t = prefixBuffer[ai];
                prefixBuffer[ai] = prefixBuffer[bi];
                prefixBuffer[bi] += t;
            }
            __syncthreads();
        }
    }

    // encoding phase one
    int tmpCompressedDataGlobalOffset;
    tmpCompressedDataGlobalOffset = blockSize * blockIdx.x * sizeof(T);
    for (int iteration = 0; iteration < (int)(blockSize / threadSize); iteration++)
    {
        tid = threadIdx.x + iteration * threadSize;
        if (prefixBuffer[tid + 1] != prefixBuffer[tid])
        {
            if (lengthBuffer[tid] < minEncodeLength)
            {
                uint32_t tmpOffset = prefixBuffer[tid];
                uint8_t *bytePtr = (uint8_t *)&buffer[tid];
                for (int tmpIndex = 0; tmpIndex < sizeof(T); tmpIndex++)
                {
                    tmpCompressedDataGlobal[tmpCompressedDataGlobalOffset + tmpOffset + tmpIndex] = *(bytePtr + tmpIndex);
                }
            }
            else
            {
                uint32_t tmpOffset = prefixBuffer[tid];
                tmpCompressedDataGlobal[tmpCompressedDataGlobalOffset + tmpOffset] = lengthBuffer[tid];
                tmpCompressedDataGlobal[tmpCompressedDataGlobalOffset + tmpOffset + 1] = offsetBuffer[tid];
            }
        }
    }

    // Copy the memeory back
    if (threadIdx.x == 0)
    {
        for (int flagArrIndex = 0; flagArrIndex < flagCount; flagArrIndex++)
        {
            tmpFlagArrGlobal[blockSize / 8 * blockIdx.x + flagArrIndex] = byteFlagArr[flagArrIndex];
        }
    }
}

// Define the compress Encode kernel functions
template <typename T>
__global__ void compressKernelIII(uint32_t numOfBlocks, uint32_t *flagArrOffsetGlobal, uint32_t *compressedDataOffsetGlobal, uint8_t *tmpFlagArrGlobal, uint8_t *tmpCompressedDataGlobal, uint8_t *flagArrGlobal, uint8_t *compressedDataGlobal)
{
    // Block size in uint of bytes
    const int blockSize = BLOCK_SIZE / sizeof(T);

    // Window size in uint of bytes
    const int threadSize = THREAD_SIZE;

    // find block index
    int blockIndex = blockIdx.x;

    int flagArrOffset = flagArrOffsetGlobal[blockIndex];
    int flagArrSize = flagArrOffsetGlobal[blockIndex + 1] - flagArrOffsetGlobal[blockIndex];

    int compressedDataOffset = compressedDataOffsetGlobal[blockIndex];
    int compressedDataSize = compressedDataOffsetGlobal[blockIndex + 1] - compressedDataOffsetGlobal[blockIndex];

    int tid = threadIdx.x;

    while (tid < flagArrSize)
    {
        flagArrGlobal[flagArrOffset + tid] = tmpFlagArrGlobal[blockSize / 8 * blockIndex + tid];
        tid += threadSize;
    }

    tid = threadIdx.x;

    while (tid < compressedDataSize)
    {
        compressedDataGlobal[compressedDataOffset + tid] = tmpCompressedDataGlobal[blockSize * sizeof(T) * blockIndex + tid];
        tid += threadSize;
    }
}

// Define the decompress kernel functions
template <typename T>
__global__ void decompressKernel(T *output, uint32_t numOfBlocks, uint32_t *flagArrOffsetGlobal, uint32_t *compressedDataOffsetGlobal, uint8_t *flagArrGlobal, uint8_t *compressedDataGlobal, uint8_t *notEmptyFlagArr)
{
    // Block size in unit of datatype
    const uint32_t blockSize = BLOCK_SIZE / sizeof(T);

    int tid = blockIdx.x * blockDim.x + threadIdx.x;

    if (tid < numOfBlocks)
    {
        if (notEmptyFlagArr[tid] != 0)
        {
            int flagArrOffset = flagArrOffsetGlobal[tid];
            int flagArrSize = flagArrOffsetGlobal[tid + 1] - flagArrOffsetGlobal[tid];

            int compressedDataOffset = compressedDataOffsetGlobal[tid];

            uint32_t dataPointsIndex = 0;
            uint32_t compressedDataIndex = 0;

            uint8_t byteFlag;

            for (int flagArrayIndex = 0; flagArrayIndex < flagArrSize; flagArrayIndex++)
            {
                byteFlag = flagArrGlobal[flagArrOffset + flagArrayIndex];

                for (int bitCount = 0; bitCount < 8; bitCount++)
                {
                    int matchFlag = (byteFlag >> bitCount) & 0x1;
                    if (matchFlag == 1)
                    {
                        int length = compressedDataGlobal[compressedDataOffset + compressedDataIndex];
                        int offset = compressedDataGlobal[compressedDataOffset + compressedDataIndex + 1];
                        compressedDataIndex += 2;
                        int dataPointsStart = dataPointsIndex;
                        for (int tmpDecompIndex = 0; tmpDecompIndex < length; tmpDecompIndex++)
                        {
                            output[tid * blockSize + dataPointsIndex] = output[tid * blockSize + dataPointsStart - offset + tmpDecompIndex];
                            dataPointsIndex++;
                        }
                    }
                    else
                    {
                        uint8_t *tmpPtr = (uint8_t *)&output[tid * blockSize + dataPointsIndex];
                        for (int tmpDecompIndex = 0; tmpDecompIndex < sizeof(T); tmpDecompIndex++)
                        {
                            *(tmpPtr + tmpDecompIndex) = compressedDataGlobal[compressedDataOffset + compressedDataIndex + tmpDecompIndex];
                        }

                        compressedDataIndex += sizeof(T);
                        dataPointsIndex++;
                    }
                    if (dataPointsIndex >= blockSize)
                    {
                        return;
                    }
                }
            }
        }
    }
}

namespace gpulz {
int compress(INPUT_TYPE *deviceArray, uint32_t *dToWriteBack, uint32_t *compedSize, uint32_t fileSize, int gpuIdx, cudaStream_t stream)
{
    cudaSetDevice(gpuIdx);

    cudaStreamSynchronize(stream);

    uint32_t *flagArrSizeGlobal;
    uint32_t *flagArrOffsetGlobal;
    uint32_t *compressedDataSizeGlobal;
    uint32_t *compressedDataOffsetGlobal;
    uint8_t *tmpFlagArrGlobal;
    uint8_t *tmpCompressedDataGlobal;
    uint8_t *flagArrGlobal;
    uint8_t *compressedDataGlobal;
    uint8_t *notEmptyFlagArr;

    // calculate the padding size, unit in bytes
    uint32_t paddingSize = fileSize % BLOCK_SIZE == 0 ? 0 : BLOCK_SIZE - fileSize % BLOCK_SIZE;

    // calculate the datatype size, unit in datatype
    uint32_t datatypeSize = static_cast<uint32_t>((fileSize + paddingSize) / sizeof(INPUT_TYPE));
    uint32_t numOfBlocks = datatypeSize * sizeof(INPUT_TYPE) / BLOCK_SIZE;

    cudaMallocAsync((void **)&flagArrSizeGlobal, sizeof(uint32_t) * (numOfBlocks + 1), stream);
    cudaMallocAsync((void **)&compressedDataSizeGlobal, sizeof(uint32_t) * (numOfBlocks + 1), stream);
    cudaMallocAsync((void **)&tmpFlagArrGlobal, sizeof(uint8_t) * datatypeSize / 8, stream);
    cudaMallocAsync((void **)&tmpCompressedDataGlobal, sizeof(INPUT_TYPE) * datatypeSize, stream);

    // initialize the mem as 0
    cudaMemsetAsync(flagArrSizeGlobal, 0, sizeof(uint32_t) * (numOfBlocks + 1), stream);
    cudaMemsetAsync(compressedDataSizeGlobal, 0, sizeof(uint32_t) * (numOfBlocks + 1), stream);

    uint8_t *dOutput = (uint8_t *)(dToWriteBack + 5);

    flagArrOffsetGlobal = (uint32_t*)dOutput + 4;
    compressedDataOffsetGlobal = flagArrOffsetGlobal + numOfBlocks + 1;
    notEmptyFlagArr = (uint8_t*)(compressedDataOffsetGlobal + numOfBlocks + 1);

    uint32_t dOutputOffset = 0;

    cudaMemcpyAsync(dOutput + dOutputOffset, &fileSize, sizeof(uint32_t), cudaMemcpyHostToDevice, stream);
    dOutputOffset += sizeof(uint32_t);

    cudaMemcpyAsync(dOutput + dOutputOffset, &numOfBlocks, sizeof(uint32_t), cudaMemcpyHostToDevice, stream);
    dOutputOffset += sizeof(uint32_t);

    dim3 gridDim(numOfBlocks);
    dim3 blockDim(THREAD_SIZE);

    cudaEvent_t compStart, compStop;
    cudaEventCreate(&compStart);
    cudaEventCreate(&compStop);

    cudaEventRecord(compStart, stream);

    int minEncodeLength = sizeof(INPUT_TYPE) == 1 ? 2 : 1;

    // launch kernels
    compressKernelI<INPUT_TYPE><<<gridDim, blockDim, 0, stream>>>(deviceArray, numOfBlocks, flagArrSizeGlobal, compressedDataSizeGlobal, tmpFlagArrGlobal, tmpCompressedDataGlobal, minEncodeLength, notEmptyFlagArr);

    thrust::exclusive_scan(thrust::device.on(stream), flagArrSizeGlobal, flagArrSizeGlobal + numOfBlocks + 1, flagArrOffsetGlobal);
    thrust::exclusive_scan(thrust::device.on(stream), compressedDataSizeGlobal, compressedDataSizeGlobal + numOfBlocks + 1, compressedDataOffsetGlobal);

    cudaMemcpyAsync(dOutput + dOutputOffset, flagArrOffsetGlobal + numOfBlocks, sizeof(uint32_t), cudaMemcpyDeviceToDevice, stream);
    dOutputOffset += sizeof(uint32_t);

    cudaMemcpyAsync(dOutput + dOutputOffset, compressedDataOffsetGlobal + numOfBlocks, sizeof(uint32_t), cudaMemcpyDeviceToDevice, stream);
    dOutputOffset += sizeof(uint32_t);

    dOutputOffset += sizeof(uint32_t) * (numOfBlocks + 1);

    dOutputOffset += sizeof(uint32_t) * (numOfBlocks + 1);

    dOutputOffset += sizeof(uint8_t) * numOfBlocks;

    uint32_t *flagArrSize;
    uint32_t *compressedDateSize;

    cudaMallocHost(&flagArrSize, sizeof(uint32_t));
    cudaMallocHost(&compressedDateSize, sizeof(uint32_t));

    cudaMemcpyAsync(flagArrSize, flagArrOffsetGlobal + numOfBlocks, sizeof(uint32_t), cudaMemcpyDeviceToHost, stream);
    cudaMemcpyAsync(compressedDateSize, compressedDataOffsetGlobal + numOfBlocks, sizeof(uint32_t), cudaMemcpyDeviceToHost, stream);

    cudaStreamSynchronize(stream);

    flagArrGlobal = (uint8_t*)(dOutput + dOutputOffset);
    dOutputOffset += *flagArrSize;

    compressedDataGlobal = (uint8_t*)(dOutput + dOutputOffset);
    dOutputOffset += *compressedDateSize;

    compressKernelIII<INPUT_TYPE><<<gridDim, blockDim, 0, stream>>>(numOfBlocks, flagArrOffsetGlobal, compressedDataOffsetGlobal, tmpFlagArrGlobal, tmpCompressedDataGlobal, flagArrGlobal, compressedDataGlobal);

    cudaEventRecord(compStop, stream);

    cudaEventSynchronize(compStop);

    cudaStreamSynchronize(stream);

    *compedSize = dOutputOffset;

// #ifndef GDS_SWITCH
//     io::write_array_to_binary<uint8_t>(compressedFileName, dOutput, dOutputOffset);
// #else
//     io::cufileWrite(compressedFileName.c_str(), dOutput, dOutputOffset);
// #endif

    // float compTime = 0;
    // cudaEventElapsedTime(&compTime, compStart, compStop);
    // float compTp = float(fileSize) / 1024 / 1024 / compTime;
    // std::cout << "compression e2e throughput: " << compTp << " GB/s" << std::endl;

    cudaFree(flagArrSizeGlobal);
    cudaFree(compressedDataSizeGlobal);
    cudaFree(tmpFlagArrGlobal);
    cudaFree(tmpCompressedDataGlobal);

    cudaFreeHost(flagArrSize);
    cudaFreeHost(compressedDateSize);

    return 0;
}

int decompress(uint8_t *dInput, INPUT_TYPE *deviceOutput, int gpuIdx, cudaStream_t stream)
{
    cudaSetDevice(gpuIdx);

    cudaStreamSynchronize(stream);

// #ifndef GDS_SWITCH
//     io::read_binary_to_array<uint8_t>(compressedFileName, inputPtr, compressedFileSize);
// #else
//     io::cufileRead(compressedFileName.c_str(), inputPtr, compressedFileSize);
// #endif

    uint32_t numOfBlocks = 0;
    uint32_t flagArrSize = 0;
    uint32_t compressedDateSize = 0;
    uint32_t fileSize = 0;

    uint32_t inputPtrOffset = 0;

    cudaMemcpyAsync(&fileSize, dInput + inputPtrOffset, sizeof(uint32_t), cudaMemcpyDeviceToHost, stream);
    inputPtrOffset += sizeof(uint32_t);

    cudaMemcpyAsync(&numOfBlocks, dInput + inputPtrOffset, sizeof(uint32_t), cudaMemcpyDeviceToHost, stream);
    inputPtrOffset += sizeof(uint32_t);

    cudaMemcpyAsync(&flagArrSize, dInput + inputPtrOffset, sizeof(uint32_t), cudaMemcpyDeviceToHost, stream);
    inputPtrOffset += sizeof(uint32_t);

    cudaMemcpyAsync(&compressedDateSize, dInput + inputPtrOffset, sizeof(uint32_t), cudaMemcpyDeviceToHost, stream);
    inputPtrOffset += sizeof(uint32_t);

    uint32_t *flagArrOffsetGlobal;
    uint32_t *compressedDataOffsetGlobal;
    uint8_t *flagArrGlobal;
    uint8_t *compressedDataGlobal;
    uint8_t *notEmptyFlagArr;

    cudaStreamSynchronize(stream);

    flagArrOffsetGlobal = (uint32_t*)(dInput + inputPtrOffset);
    inputPtrOffset += sizeof(uint32_t) * (numOfBlocks + 1);

    compressedDataOffsetGlobal = (uint32_t*)(dInput + inputPtrOffset);
    inputPtrOffset += sizeof(uint32_t) * (numOfBlocks + 1);

    notEmptyFlagArr = (uint8_t*)(dInput + inputPtrOffset);
    inputPtrOffset += sizeof(uint8_t) * numOfBlocks;

    flagArrGlobal = (uint8_t*)(dInput + inputPtrOffset);
    inputPtrOffset += flagArrSize;

    compressedDataGlobal = (uint8_t*)(dInput + inputPtrOffset);
    inputPtrOffset += compressedDateSize;

    dim3 deGridDim(ceil(float(numOfBlocks) / 32));
    dim3 deBlockDim(32);

    cudaEvent_t decompStart, decompStop;
    cudaEventCreate(&decompStart);
    cudaEventCreate(&decompStop);

    cudaEventRecord(decompStart, stream);
    decompressKernel<INPUT_TYPE><<<deGridDim, deBlockDim, 0, stream>>>(deviceOutput, numOfBlocks, flagArrOffsetGlobal, compressedDataOffsetGlobal, flagArrGlobal, compressedDataGlobal, notEmptyFlagArr);
    cudaEventRecord(decompStop, stream);

    cudaEventSynchronize(decompStop);

    // float decompTime = 0;
    // cudaEventElapsedTime(&decompTime, decompStart, decompStop);
    // float decompTp = float(fileSize) / 1024 / 1024 / decompTime;
    // std::cout << "decompression e2e throughput: " << decompTp << " GB/s" << std::endl;

    return 0;
}

void sparseGpulzComp(INPUT_TYPE *deviceArray, uint32_t *dToWriteBack, uint32_t *compedSize, uint32_t fileSize, int gpuIdx, cudaStream_t stream)
{
    compress(deviceArray, dToWriteBack, compedSize, fileSize, gpuIdx, stream);
}

void sparseGpulzDecomp(uint8_t *dInput, INPUT_TYPE *deviceOutput, int gpuIdx, cudaStream_t stream)
{
    decompress(dInput, deviceOutput, gpuIdx, stream);
}
} // namespace gpulz