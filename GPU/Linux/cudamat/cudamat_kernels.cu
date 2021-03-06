#include "cudamat_kernels.cuh"
#include "float.h"

/* ------------------------- Random number generation ------------------------- */

__global__ void kSeedRandom(unsigned int* rndMults, unsigned long long* rndWords, unsigned int seed) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;

    // The initial x is the seed and the initial carry is 1
    unsigned long long rndWord = ((unsigned long long)seed << 32) + 1;
    const unsigned int rndMult = rndMults[idx];
    /*
     * Run the chain for a few steps so that all the streams have a chance
     * to differentiate. They start out generating similar random numbers
     * because all the multipliers are similar.
     */
    for(unsigned int i = 0; i < NUM_RND_BURNIN; i++) {
        rndWord = rndMult * LOW_BITS(rndWord) + HIGH_BITS(rndWord);
    }
    rndWords[idx] = rndWord;
}

__global__ void kRandomUniform(unsigned int* rndMults, unsigned long long* rndWords, float* gData, unsigned int numElements) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned long long rndWord = rndWords[idx];
    const unsigned int rndMult = rndMults[idx];

    for(unsigned int i = idx; i < numElements; i += NUM_RND_STREAMS) {
        rndWord = rndMult * LOW_BITS(rndWord) + HIGH_BITS(rndWord);
        gData[i] = (__uint2float_rn(LOW_BITS(rndWord)) + 1.0f) / 4294967296.0f;
    }
    rndWords[idx] = rndWord;
}

__global__ void kRandomGaussian(unsigned int* rndMults, unsigned long long* rndWords, float* gData, unsigned int numElements) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned long long rndWord = rndWords[idx];
    const unsigned int rndMult = rndMults[idx];

    float rnd1, rnd2, R, T;
    for(unsigned int i = idx; i < numElements; i += 2*NUM_RND_STREAMS) {
        rndWord = rndMult * LOW_BITS(rndWord) + HIGH_BITS(rndWord);
        rnd1 = (__uint2float_rn(LOW_BITS(rndWord)) + 1.0f) / 4294967296.0f;
        rndWord = rndMult * LOW_BITS(rndWord) + HIGH_BITS(rndWord);
        rnd2 = (__uint2float_rn(LOW_BITS(rndWord)) + 1.0f) / 4294967296.0f;
        T = 2 * PI * rnd2;
        R = sqrtf(-2 * __logf(rnd1));
        gData[i] = R * __cosf(T);
        if (i + NUM_RND_STREAMS < numElements)
            gData[i + NUM_RND_STREAMS] = R * __sinf(T);
    }
    rndWords[idx] = rndWord;
}

/* ------------------------- Data copying ------------------------- */

/*
Copy row slice from source to target. There is a block for every 32x32 chunk being copied.
*/
__global__ void kGetRowSlice(float* source, float* target, int start, int end, int width, int height) {
    const int row = start + blockIdx.x * 32 + threadIdx.x;
    const int start_col = blockIdx.y * 32;

    const int end_col = (start_col + 32 < width) ? start_col + 32: width;

    const int target_height = end - start;

    if (row < end) {
        for (int cur_col = start_col; cur_col < end_col; cur_col++)
            target[cur_col * target_height + row - start] = source[cur_col * height + row];
    }
}

__global__ void kSetRowSlice(float* source, float* target, int start, int end, int width, int height) {
    const int row = start + blockIdx.x * 32 + threadIdx.x;
    const int start_col = blockIdx.y * 32;

    const int end_col = (start_col + 32 < width) ? start_col + 32: width;

    const int source_height = end - start;

    if (row < end) {
        for (int cur_col = start_col; cur_col < end_col; cur_col++)
            target[cur_col * height + row] = source[cur_col * source_height + row - start];
            //source[cur_col * height + row - start] = target[cur_col * target_height + row];
    }
}

__global__ void kTranspose(float *odata, float *idata, int width, int height) {
    __shared__ float block[COPY_BLOCK_SIZE][COPY_BLOCK_SIZE+1];

    // read the matrix tile into shared memory
    unsigned int xIndex = blockIdx.x * COPY_BLOCK_SIZE + threadIdx.x;
    unsigned int yIndex = blockIdx.y * COPY_BLOCK_SIZE + threadIdx.y;

    if((xIndex < width) && (yIndex < height)) {
        unsigned int index_in = yIndex * width + xIndex;

        block[threadIdx.y][threadIdx.x] = idata[index_in];
    }

    __syncthreads();

    // write the transposed matrix tile to global memory
    xIndex = blockIdx.y * COPY_BLOCK_SIZE + threadIdx.x;
    yIndex = blockIdx.x * COPY_BLOCK_SIZE + threadIdx.y;

    if((xIndex < height) && (yIndex < width)) {
        unsigned int index_out = yIndex * height + xIndex;

        odata[index_out] = block[threadIdx.x][threadIdx.y];
    }
}

/* ------------------------- Mathematical operations ------------------------- */

__global__ void kLessThan(float* mat1, float* mat2, float* target, unsigned int len) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < len; i += numThreads) {
        target[i] = mat1[i] < mat2[i];
    }
}

__global__ void kLessThanScalar(float* mat, float val, float* target, unsigned int len) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < len; i += numThreads) {
        target[i] = mat[i] < val;
    }
}

__global__ void kGreaterThan(float* mat1, float* mat2, float* target, unsigned int len) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < len; i += numThreads) {
        target[i] = mat1[i] > mat2[i];
    }
}

__global__ void kGreaterThanScalar(float* mat, float val, float* target, unsigned int len) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < len; i += numThreads) {
        target[i] = mat[i] > val;
    }
}

__global__ void kMaxColumnwise(float* mat, float* target, unsigned int width, unsigned int height) {
    __shared__ float max_vals[32];
    float cur_max = -FLT_MAX;
    float val = 0;
 
    for (unsigned int i = threadIdx.x; i < height; i += 32) {
        val = mat[blockIdx.x * height + i];

        if (val > cur_max)
            cur_max = val;
    }

    max_vals[threadIdx.x] = cur_max;

    __syncthreads();

    if (threadIdx.x == 0) {
        cur_max = -FLT_MAX;

        for (unsigned int i = 0; i < 32; i++)
            if (max_vals[i] > cur_max)
                cur_max = max_vals[i];

        target[blockIdx.x] = cur_max;
    }
}

__global__ void kSign(float* mat, float* target, unsigned int len) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < len; i += numThreads) {
        target[i] = mat[i] ? copysignf(1., mat[i]) : 0.;
    }
}

__global__ void kApplySigmoid(float* mat, float* target, unsigned int len) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < len; i += numThreads) {
        target[i] = 1 / (1 + __expf(-mat[i]));
    }
}

__global__ void kApplySoftmax(float* mat, float* target, unsigned int len, unsigned int width) {
    const unsigned int row = blockIdx.x * blockDim.x + threadIdx.x;
    //const unsigned int numThreads = blockDim.x * gridDim.x;
	const unsigned int rows = len/width;
	float max_value = -FLT_MAX;
	float value = 0;
	float sum = 0;

	//get max value of each row
    for (unsigned int i = 0; i < width && row < rows; i++)
	{
       value = mat[(width*row)+ i];
	   if(max_value < value)
			max_value = value;
    }
		
	for (unsigned int i = 0; i < width && row < rows; i++)
	{
	   target[(row*width)+i] = __expf(mat[(row*width)+i] - max_value);
    }
	
	for (unsigned int i = 0; i < width && row < rows; i++)
	{
	   sum += target[(row*width)+i];
    }
	
	for (unsigned int i = 0; i < width && row < rows; i++)
	{
	   target[(row*width)+i] /= sum;
    }
	
}

__global__ void kApplySparseDot(float* mat, float* target, unsigned int dense_len, unsigned int dense_columns, float* data, float* ptr, float* indices, unsigned int sparse_rows, unsigned int sparse_columns){
	const unsigned int MAX_ROW_THREADS = 4096;
	const unsigned int col_dense = threadIdx.x;
	
	unsigned int from = 0;
	unsigned int to = 0;
	float dense_matrix_value = 0.0;
	unsigned int column = 0;
	float sparse_matrix_value = 0.0;
	float sum_for_target_matrix_element = 0.0;
	
   for (unsigned int row =  blockIdx.x; row < sparse_rows; row += MAX_ROW_THREADS)
   {
	   from = ptr[row];
	   to = ptr[row + 1];	   
	   for (unsigned int current_pointer = from; current_pointer < to; current_pointer++) 
	   { 
		  sparse_matrix_value = data[current_pointer];
		  column = indices[current_pointer];
		  dense_matrix_value = mat[col_dense+ (column*dense_columns)];
		  sum_for_target_matrix_element += sparse_matrix_value*dense_matrix_value;		  
		  
	   }
	   
	   target[(row*dense_columns) + col_dense] = sum_for_target_matrix_element;
	   sum_for_target_matrix_element = 0;
   }    
	
}

__global__ void kApplySparseMul(float* mat, float* target, unsigned int dense_len, unsigned int dense_columns, float* data, float* ptr, float* indices){
	const unsigned int MAX_ROW_THREADS = 4096;
	const unsigned int MAX_COL_THREADS = 512;
	const unsigned int sparse_rows = dense_len/ dense_columns;
	
	unsigned int from = 0;
	unsigned int to = 0;
	float dense_matrix_value = 0.0;
	unsigned int column = 0;
	float sparse_matrix_value = 0.0;
	
   for (unsigned int row =  blockIdx.x; row < sparse_rows + 1; row += MAX_ROW_THREADS)
   {
	   from = ptr[row];
	   to = ptr[row + 1];	   
	   for (unsigned int current_pointer = from + threadIdx.x; current_pointer < to; current_pointer+=MAX_COL_THREADS) 
	   { 
		  sparse_matrix_value = data[current_pointer];
		  column = indices[current_pointer];
		  dense_matrix_value = mat[column+ (row*dense_columns)];
		  target[(row*dense_columns) + column] = dense_matrix_value*sparse_matrix_value;	  
		  
	   }
	   
	  
   }    
   
   
   //target[threadIdx.x] = threadIdx.x;
	
}
__global__ void kLog(float* mat, float* target, unsigned int len) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < len; i += numThreads) {
        target[i] = __logf(mat[i]);
    }
}

__global__ void kExp(float* mat, float* target, unsigned int len) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < len; i += numThreads) {
        target[i] = __expf(mat[i]);
    }
}

__global__ void kSqrt(float* mat, float* target, unsigned int len) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < len; i += numThreads) {
        target[i] = sqrt(mat[i]);
    }
}

__global__ void kPow(float* mat, float pow, float* target, unsigned int len) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < len; i += numThreads) {
        target[i] = __powf(mat[i], pow);
    }
}

__global__ void kReciprocal(float* mat, float* target, unsigned int len) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < len; i += numThreads)
        target[i] = 1. / mat[i];
}

__global__ void kAddColVector(float* mat, float* vec, float* tgtMat, unsigned int width,
                              unsigned int height) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < width * height; i += numThreads) {
        tgtMat[i] = mat[i] + vec[i % height];
    }
}

__global__ void kAddRowVector(float* mat, float* vec, float* tgtMat, unsigned int width, unsigned int height) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < width * height; i += numThreads) {
        tgtMat[i] = mat[i] + vec[i / height];
    }
}

__global__ void kAddColMult(float* mat, float* vec, float* tgtMat, float mult,
                            unsigned int width, unsigned int height) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < width * height; i += numThreads) {
        tgtMat[i] = mat[i] + mult * vec[i % height];
    }
}

__global__ void kMultByColVector(float* mat, float* vec, float* tgtMat, unsigned int width, unsigned int height) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < width * height; i += numThreads) {
        tgtMat[i] = mat[i] * vec[i % height];
    }
}

__global__ void kMultByRowVector(float* mat, float* vec, float* tgtMat, unsigned int width, unsigned int height) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < width * height; i += numThreads) {
        tgtMat[i] = mat[i] * vec[i / height];
    }
}

__global__ void kAdd(float* a, float* b, float* dest, unsigned int numEls) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < numEls; i += numThreads) {
        dest[i] = a[i] + b[i];
    }
}

__global__ void kSubtract(float* a, float* b, float* dest, unsigned int numEls) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < numEls; i += numThreads) {
        dest[i] = a[i] - b[i];
    }
}

__global__ void kDivide(float* a, float* b, float* dest, unsigned int numEls) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < numEls; i += numThreads) {
        dest[i] = a[i] / b[i];
    }
}

__global__ void kMult(float* a, float* b, float* dest, unsigned int numEls) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < numEls; i += numThreads) {
        dest[i] = a[i] * b[i];
    }
}

__global__ void kMultScalar(float* mat, float alpha, float* dest, unsigned int len) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < len; i += numThreads) {
        dest[i] = alpha * mat[i];
    }
}

__global__ void kAssignScalar(float* dest, float alpha, unsigned int len) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < len; i += numThreads) {
        dest[i] = alpha;
    }
}

__global__ void kDivideScalar(float* mat, float alpha, float* dest, unsigned int len) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < len; i += numThreads) {
        dest[i] = mat[i] / alpha;
    }
}

__global__ void kAddScalar(float* a, float alpha, float* dest, unsigned int numEls) {
    const unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const unsigned int numThreads = blockDim.x * gridDim.x;

    for (unsigned int i = idx; i < numEls; i += numThreads) {
        dest[i] = a[i] + alpha;
    }
}
