#include <string>
#include <stdio.h>
#include <time.h>

#include "opencv2/opencv.hpp"
#include <opencv2/core/core.hpp>
#include <opencv2/imgproc/imgproc.hpp>
#include <opencv2/highgui/highgui.hpp>

#include "common.h"
#include "gpu.h"
#include "gputimer.h"
#include "key_bindings.h"

#define MAX_FPS 60.0

__constant__ float constConvKernelMem[256];
// Create the cuda event timers 
gpuTimer timer;

using namespace std;

int main (int argc, char** argv)
{
    gpuTimer t1;
    unsigned int frameCounter=0;
    float *d_X,*d_Y,*d_gaussianKernel5x5;

    /// Pass video file as input
    // For e.g. if camera device is at /dev/video1 - pass 1
    // You can pass video file as well instead of webcam stream
    cv::VideoCapture camera("C:/Users/Alex/Videos/The Witcher 3/test.mp4");
    //cv::VideoCapture camera(1);
    
    cv::Mat frame;
    if(!camera.isOpened()) 
    {
        printf("Error .... campera not opened\n");;
        return -1;
    }
    
    // Open window for each kernel 
    cv::namedWindow("Video Feed");

    cudaMemcpyToSymbol(constConvKernelMem, gaussianKernel5x5, sizeof(gaussianKernel5x5), 0);
    const ssize_t gaussianKernel5x5Offset = 0;

    cudaMemcpyToSymbol(constConvKernelMem, sobelGradientX, sizeof(sobelGradientX), sizeof(gaussianKernel5x5));
    cudaMemcpyToSymbol(constConvKernelMem, sobelGradientY, sizeof(sobelGradientY), sizeof(gaussianKernel5x5) + sizeof(sobelGradientX));
    
    // Calculate kernel offset in contant memory
    const ssize_t sobelKernelGradOffsetX = sizeof(gaussianKernel5x5)/sizeof(float);
    const ssize_t sobelKernelGradOffsetY = sizeof(sobelGradientX)/sizeof(float) + sobelKernelGradOffsetX;
 
    // Create matrix to hold original and processed image 
    camera >> frame;
    unsigned char *d_pixelDataInput, *d_pixelDataOutput, *d_pixelBuffer;
    
    cudaMalloc((void **) &d_gaussianKernel5x5, sizeof(gaussianKernel5x5));
    cudaMalloc((void **) &d_X, sizeof(sobelGradientX));
    cudaMalloc((void **) &d_Y, sizeof(sobelGradientY));
    
    cudaMemcpy(d_gaussianKernel5x5, &gaussianKernel5x5[0], sizeof(gaussianKernel5x5), cudaMemcpyHostToDevice);
    cudaMemcpy(d_X, &sobelGradientX[0], sizeof(sobelGradientX), cudaMemcpyHostToDevice);
    cudaMemcpy(d_Y, &sobelGradientY[0], sizeof(sobelGradientY), cudaMemcpyHostToDevice);

    cv::Mat inputMat     (frame.size(), CV_8U, allocateBuffer(frame.size().width * frame.size().height, &d_pixelDataInput));
    cv::Mat outputMat    (frame.size(), CV_8U, allocateBuffer(frame.size().width * frame.size().height, &d_pixelDataOutput));
    cv::Mat bufferMat    (frame.size(), CV_8U, allocateBuffer(frame.size().width * frame.size().height, &d_pixelBuffer));

    cv::Mat inputMatCPU   (frame.size(), CV_8U);
    cv::Mat outputMatCPU  (frame.size(), CV_8U);
    cv::Mat bufferMatCPU  (frame.size(), CV_8U);
    // Create buffer to hold sobel gradients - XandY 
    unsigned char *sobelBufferX, *sobelBufferY;
    cudaMalloc(&sobelBufferX, frame.size().width * frame.size().height);
    cudaMalloc(&sobelBufferY, frame.size().width * frame.size().height);
    
    // Create buffer to hold sobel gradients - XandY 
    unsigned char *sobelBufferXCPU, *sobelBufferYCPU;
    sobelBufferXCPU = (unsigned char*)malloc(frame.size().width * frame.size().height);
    sobelBufferYCPU = (unsigned char*)malloc(frame.size().width * frame.size().height);
    
    //key codes to switch between filters
    unsigned int key_pressed = NO_FILTER;
    char charOutputBuf[255];
    string kernel_t = "No Filter";
    double tms = 0.0;
    struct timespec start, end; // variable to record cpu time
    
    // Run loop to capture images from camera or loop over single image 
    while(1)
    {
        if (key_pressed == ESCAPE)
           break;

        // Capture image frame 
        camera >> frame;
        
        // Convert frame to gray scale for further filter operation
	// Remove color channels, simplify convolution operation
        if(key_pressed == SOBEL_NAIVE_CPU || key_pressed == GAUSSIAN_NAIVE_CPU)
            cv::cvtColor(frame, inputMatCPU, CV_BGR2GRAY);
        else
	    cv::cvtColor(frame, inputMat, CV_BGR2GRAY);
       
        switch (key_pressed) {
        case NO_FILTER:
        default:
           outputMat = inputMat;
           kernel_t = "No Filter";
           break;
        case GAUSSIAN_FILTER:
           t1.start(); // timer for overall metrics
           launchGaussian_withoutPadding(d_pixelDataInput, d_pixelBuffer, frame.size(), d_gaussianKernel5x5);
           t1.stop();
           tms = t1.elapsed();
           outputMat = bufferMat;
           kernel_t = "Guassian";
           break;
        case SOBEL_FILTER:
           t1.start(); // timer for overall metrics
           launchGaussian_constantMemory(d_pixelDataInput, d_pixelDataOutput, frame.size(), gaussianKernel5x5Offset);
           launchSobel_constantMemory(d_pixelDataOutput, d_pixelBuffer, sobelBufferX, sobelBufferY, frame.size(), sobelKernelGradOffsetX, sobelKernelGradOffsetY);
           t1.stop();
           tms = t1.elapsed();
           outputMat = bufferMat;
           kernel_t = "Sobel";
           break;
        case SOBEL_NAIVE_FILTER:
           t1.start(); // timer for overall metrics
           launchGaussian_withoutPadding(d_pixelDataInput, d_pixelDataOutput, frame.size(),d_gaussianKernel5x5);
           launchSobelNaive_withoutPadding(d_pixelDataOutput, d_pixelBuffer, sobelBufferX, sobelBufferY, frame.size(), d_X, d_Y);
           t1.stop();
           tms = t1.elapsed();
           outputMat = bufferMat;
           kernel_t = "Sobel Naive";
           break;
        case SOBEL_NAIVE_PADDED_FILTER:
           t1.start(); // timer for overall metrics
           launchGaussian_withoutPadding(d_pixelDataInput, d_pixelDataOutput, frame.size(), d_gaussianKernel5x5);
           launchSobelNaive_withPadding(d_pixelDataOutput, d_pixelBuffer, sobelBufferX, sobelBufferY, frame.size(), d_X, d_Y);
           t1.stop();
           tms = t1.elapsed();
           outputMat = bufferMat;
           kernel_t = "Sobel Naive Pad";
           break;
        case SOBEL_NAIVE_CPU:
           clock_gettime(CLOCK_MONOTONIC, &start);  // start time 
           launchGaussianCPU(inputMatCPU.data, outputMatCPU.data, frame.size());
           launchSobelCPU(outputMatCPU.data, bufferMatCPU.data, sobelBufferXCPU, sobelBufferYCPU, frame.size());
           clock_gettime(CLOCK_MONOTONIC, &end);  // end time 
           tms = (NS_IN_SEC * (end.tv_sec - start.tv_sec) + end.tv_nsec - start.tv_nsec)*1.0e-6; 
           outputMatCPU = bufferMatCPU;
           kernel_t = "Sobel Naive CPU";
           break;
        case GAUSSIAN_NAIVE_CPU:
           clock_gettime(CLOCK_MONOTONIC, &start);  // start time 
           launchGaussianCPU(inputMatCPU.data, outputMatCPU.data, frame.size());
           clock_gettime(CLOCK_MONOTONIC, &end);  // end time 
           tms = (NS_IN_SEC * (end.tv_sec - start.tv_sec) + end.tv_nsec - start.tv_nsec)*1.0e-6; 
           kernel_t = "Gaussian Naive CPU";
           break;
        case SOBEL_FILTER_FLOAT:
           t1.start(); // timer for overall metrics
           launchGaussian_float(d_pixelDataInput, d_pixelDataOutput, frame.size(), gaussianKernel5x5Offset);
           launchSobel_float(d_pixelDataOutput, d_pixelBuffer, sobelBufferX, sobelBufferY, frame.size(), sobelKernelGradOffsetX, sobelKernelGradOffsetY);
           t1.stop();
           tms = t1.elapsed();
           outputMat = bufferMat;
           kernel_t = "Sobel - float";
           break;
        case SOBEL_FILTER_RESTRICT:
           t1.start(); // timer for overall metrics
           launchGaussian_restrict(d_pixelDataInput, d_pixelDataOutput, frame.size(), gaussianKernel5x5Offset);
           launchSobel_restrict(d_pixelDataOutput, d_pixelBuffer, sobelBufferX, sobelBufferY, frame.size(), sobelKernelGradOffsetX, sobelKernelGradOffsetY);
           t1.stop();
           tms = t1.elapsed();
           outputMat = bufferMat;
           kernel_t = "Sobel - restrict";
           break;
        }

        /**printf("Overall : Throughput in Megapixel per second : %.4f, Size : %d pixels, Elapsed time (in ms): %f\n",
           1.0e-6* (double)(frame.size().height*frame.size().width)/(tms*0.001),frame.size().height*frame.size().width,tms); **/
        
	 //create metric string
        frameCounter++;
        float fps = 1000.f / tms; //fps = fps > MAX_FPS ? MAX_FPS : fps;
        double mps = 1.0e-6* (double)(frame.size().height*frame.size().width) / (tms*0.001);
        snprintf(charOutputBuf, sizeof(charOutputBuf), "Frame #:%d FPS:%2.3f MPS: %.4f Kernel Type %s Kernel Time (ms): %.4f", 
           frameCounter, fps, mps, kernel_t, tms);
        string metricString = charOutputBuf;

        //update display
        if(key_pressed == SOBEL_NAIVE_CPU || key_pressed == GAUSSIAN_NAIVE_CPU)
        {
            cv::putText(outputMatCPU, metricString, cvPoint(30, 30), CV_FONT_NORMAL, 1, 255, 2, CV_AA, false);
            cv::imshow("Video Feed", outputMatCPU);
        }
        else
        {
            cv::putText(outputMat, metricString, cvPoint(30, 30), CV_FONT_NORMAL, 1, 255, 2, CV_AA, false);
            cv::imshow("Video Feed", outputMat);
        }

        int key = cv::waitKey(1);
        key_pressed = key == -1 ? key_pressed : key;
    }
    
    // Deallocate memory
    cudaFreeHost(inputMat.data);
    cudaFreeHost(outputMat.data);
    cudaFree(sobelBufferX);
    cudaFree(sobelBufferY);
    cudaFree(d_X);
    cudaFree(d_Y);
    cudaFree(d_gaussianKernel5x5);
        
    // Deallocate host memory
    free(sobelBufferXCPU);
    free(sobelBufferYCPU);

    return 0;
}

void launchGaussian_float(unsigned char *dIn, unsigned char *dOut, cv::Size size,ssize_t offset)
{
    dim3 blocksPerGrid(size.width / 16, size.height / 16);
    dim3 threadsPerBlock(16, 16);
    
    timer.start();
    {
         matrixConvGPU_float <<<blocksPerGrid,threadsPerBlock>>>(dIn,size.width, size.height, 0, 0, offset, 5, 5, dOut);
    }
    timer.stop();
    cudaThreadSynchronize();
    double tms = timer.elapsed(); 
    //printf("Gaussian : Throughput in Megapixel per second : %.4f, Size : %d pixels, Elapsed time (in ms): %f\n",1.0e-6* (double)(size.height*size.width)/(tms*0.001),size.height*size.width,tms);
}

void launchGaussian_restrict(unsigned char *dIn, unsigned char *dOut, cv::Size size,ssize_t offset)
{
    dim3 blocksPerGrid(size.width / 16, size.height / 16);
    dim3 threadsPerBlock(16, 16);
    
    timer.start();
    {
         matrixConvGPU_restrict <<<blocksPerGrid,threadsPerBlock>>>(dIn,size.width, size.height, 0, 0, offset, 5, 5, dOut);
    }
    timer.stop();
    cudaThreadSynchronize();
    double tms = timer.elapsed(); 
    //printf("Gaussian : Throughput in Megapixel per second : %.4f, Size : %d pixels, Elapsed time (in ms): %f\n",1.0e-6* (double)(size.height*size.width)/(tms*0.001),size.height*size.width,tms);
}

void launchGaussian_constantMemory(unsigned char *dIn, unsigned char *dOut, cv::Size size,ssize_t offset)
{
    dim3 blocksPerGrid(size.width / 16, size.height / 16);
    dim3 threadsPerBlock(16, 16);
    
    timer.start();
    {
         matrixConvGPU_constantMemory <<<blocksPerGrid,threadsPerBlock>>>(dIn,size.width, size.height, 0, 0, offset, 5, 5, dOut);
    }
    timer.stop();
    cudaThreadSynchronize();
    double tms = timer.elapsed(); 
    //printf("Gaussian : Throughput in Megapixel per second : %.4f, Size : %d pixels, Elapsed time (in ms): %f\n",1.0e-6* (double)(size.height*size.width)/(tms*0.001),size.height*size.width,tms);
}

void launchGaussian_withoutPadding(unsigned char *dIn, unsigned char *dOut, cv::Size size, const float *kernel)
{
    dim3 blocksPerGrid(size.width / 16, size.height / 16);
    dim3 threadsPerBlock(16, 16);
    
    timer.start();
    {
         matrixConvGPUNaive_withoutPadding <<<blocksPerGrid,threadsPerBlock>>>(dIn,size.width, size.height, 5, 5, dOut, kernel);
    }
    timer.stop();
    cudaThreadSynchronize();
    double tms = timer.elapsed(); 
    //printf("Gaussian : Throughput in Megapixel per second : %.4f, Size : %d pixels, Elapsed time (in ms): %f\n",1.0e-6* (double)(size.height*size.width)/(tms*0.001),size.height*size.width,tms);
}

void launchSobel_float(unsigned char *dIn, unsigned char *dOut, unsigned char *dGradX, unsigned char *dGradY, cv::Size size,ssize_t offsetX,ssize_t offsetY)
{
    dim3 blocksPerGrid(size.width / 16, size.height / 16);
    dim3 threadsPerBlock(16, 16);
    
    // pythagoran kernel launch paramters
    dim3 blocksPerGridP(size.width * size.height / 256);
    dim3 threadsPerBlockP(256, 1);
     
    timer.start();
    {
        matrixConvGPU_float<<<blocksPerGrid,threadsPerBlock>>>(dIn, size.width, size.height, 2, 2, offsetX, 3, 3, dGradX);
        matrixConvGPU_float<<<blocksPerGrid,threadsPerBlock>>>(dIn, size.width, size.height, 2, 2, offsetY, 3, 3, dGradY);
        sobelGradientKernel_float<<<blocksPerGridP,threadsPerBlockP>>>(dGradX, dGradY, dOut);
    }
    timer.stop();
    cudaThreadSynchronize();
    double tms = timer.elapsed(); 
    //printf("Sobel (using constant memory) : Throughput in Megapixel per second : %.4f, Size : %d pixels, Elapsed time (in ms): %f\n",1.0e-6* (double)(size.height*size.width)/(tms*0.001),size.height*size.width,tms);
}

void launchSobel_restrict(unsigned char *dIn, unsigned char *dOut, unsigned char *dGradX, unsigned char *dGradY, cv::Size size,ssize_t offsetX,ssize_t offsetY)
{
    dim3 blocksPerGrid(size.width / 16, size.height / 16);
    dim3 threadsPerBlock(16, 16);
    
    // pythagoran kernel launch paramters
    dim3 blocksPerGridP(size.width * size.height / 256);
    dim3 threadsPerBlockP(256, 1);
     
    timer.start();
    {
        matrixConvGPU_restrict<<<blocksPerGrid,threadsPerBlock>>>(dIn, size.width, size.height, 2, 2, offsetX, 3, 3, dGradX);
        matrixConvGPU_restrict<<<blocksPerGrid,threadsPerBlock>>>(dIn, size.width, size.height, 2, 2, offsetY, 3, 3, dGradY);
        sobelGradientKernel_restrict<<<blocksPerGridP,threadsPerBlockP>>>(dGradX, dGradY, dOut);
    }
    timer.stop();
    cudaThreadSynchronize();
    double tms = timer.elapsed(); 
    //printf("Sobel (using constant memory) : Throughput in Megapixel per second : %.4f, Size : %d pixels, Elapsed time (in ms): %f\n",1.0e-6* (double)(size.height*size.width)/(tms*0.001),size.height*size.width,tms);
}

void launchSobel_constantMemory(unsigned char *dIn, unsigned char *dOut, unsigned char *dGradX, unsigned char *dGradY, cv::Size size,ssize_t offsetX,ssize_t offsetY)
{
    dim3 blocksPerGrid(size.width / 16, size.height / 16);
    dim3 threadsPerBlock(16, 16);
    
    // pythagoran kernel launch paramters
    dim3 blocksPerGridP(size.width * size.height / 256);
    dim3 threadsPerBlockP(256, 1);
     
    timer.start();
    {
        matrixConvGPU_constantMemory<<<blocksPerGrid,threadsPerBlock>>>(dIn, size.width, size.height, 2, 2, offsetX, 3, 3, dGradX);
        matrixConvGPU_constantMemory<<<blocksPerGrid,threadsPerBlock>>>(dIn, size.width, size.height, 2, 2, offsetY, 3, 3, dGradY);
        sobelGradientKernel<<<blocksPerGridP,threadsPerBlockP>>>(dGradX, dGradY, dOut);
    }
    timer.stop();
    cudaThreadSynchronize();
    double tms = timer.elapsed(); 
    //printf("Sobel (using constant memory) : Throughput in Megapixel per second : %.4f, Size : %d pixels, Elapsed time (in ms): %f\n",1.0e-6* (double)(size.height*size.width)/(tms*0.001),size.height*size.width,tms);
}

void launchSobelNaive_withoutPadding(unsigned char *dIn, unsigned char *dOut, unsigned char *dGradX, unsigned char *dGradY, cv::Size size, const float *d_X,const float *d_Y)
{
    dim3 blocksPerGrid(size.width / 16, size.height / 16);
    dim3 threadsPerBlock(16, 16);
    
    // Dimension for Sobel gradient kernel 
    dim3 blocksPerGridP(size.width * size.height / 256);
    dim3 threadsPerBlockP(256, 1);
     
    timer.start();
    {
        matrixConvGPUNaive_withoutPadding<<<blocksPerGrid,threadsPerBlock>>>(dIn, size.width, size.height, 3, 3, dGradX,d_X);
        matrixConvGPUNaive_withoutPadding<<<blocksPerGrid,threadsPerBlock>>>(dIn, size.width, size.height, 3, 3, dGradY,d_Y);
        sobelGradientKernel<<<blocksPerGridP,threadsPerBlockP>>>(dGradX, dGradY, dOut);
    }
    timer.stop();
    cudaThreadSynchronize();
    double tms = timer.elapsed(); 
    //printf("Sobel Naive (without padding): Throughput in Megapixel per second : %.4f, Size : %d pixels, Elapsed time (in ms): %f\n",1.0e-6* (double)(size.height*size.width)/(tms*0.001),size.height*size.width,tms);
}

void launchSobelNaive_withPadding(unsigned char *dIn, unsigned char *dOut, unsigned char *dGradX, unsigned char *dGradY, cv::Size size, const float *d_X,const float *d_Y)
{
    dim3 blocksPerGrid(size.width / 16, size.height / 16);
    dim3 threadsPerBlock(16, 16);
    
    // Dimension for Sobel gradient kernel 
    dim3 blocksPerGridP(size.width * size.height / 256);
    dim3 threadsPerBlockP(256, 1);
     
    timer.start();
    {
        matrixConvGPUNaive_withPadding<<<blocksPerGrid,threadsPerBlock>>>(dIn, size.width, size.height, 2, 2, 3, 3, dGradX,d_X);
        matrixConvGPUNaive_withPadding<<<blocksPerGrid,threadsPerBlock>>>(dIn, size.width, size.height, 2, 2, 3, 3, dGradY,d_Y);
        sobelGradientKernel<<<blocksPerGridP,threadsPerBlockP>>>(dGradX, dGradY, dOut);
    }
    timer.stop();
    cudaThreadSynchronize();
    double tms = timer.elapsed(); 
    //printf("Sobel Naive (with padding): Throughput in Megapixel per second : %.4f, Size : %d pixels, Elapsed time (in ms): %f\n",1.0e-6* (double)(size.height*size.width)/(tms*0.001),size.height*size.width,tms);
}

// Allocate buffer 
// Return ptr to shared mem
unsigned char* allocateBuffer(unsigned int size, unsigned char **dPtr)
{
    unsigned char *ptr = NULL;
    cudaSetDeviceFlags(cudaDeviceMapHost);
    cudaHostAlloc(&ptr, size, cudaHostAllocMapped);
    cudaHostGetDevicePointer(dPtr, ptr, 0);
    return ptr;
}

// Used for Sobel edge detection
// Calculate gradient value from gradientX and gradientY  
// Calculate G = sqrt(Gx^2 * Gy^2)
__global__ void sobelGradientKernel(unsigned char *gX, unsigned char *gY, unsigned char *dOut)
{
    int idx = (blockIdx.x * blockDim.x) + threadIdx.x;

    float x = float(gX[idx]);
    float y = float(gY[idx]);

    dOut[idx] = (unsigned char) sqrtf(x*x + y*y);
}

__global__ void sobelGradientKernel_float(unsigned char *gX, unsigned char *gY, unsigned char *dOut)
{
    int idx = (int)(((float)blockIdx.x * (float)blockDim.x) + (float)threadIdx.x);

    float x = float(gX[idx]);
    float y = float(gY[idx]);

    dOut[idx] = (unsigned char) sqrtf(x*x + y*y);
}

__global__ void sobelGradientKernel_restrict(unsigned char* __restrict__ gX, unsigned char* __restrict__ gY, unsigned char *dOut)
{
    int idx = (int)(((float)blockIdx.x * (float)blockDim.x) + (float)threadIdx.x);

    float x = float(gX[idx]);
    float y = float(gY[idx]);

    dOut[idx] = (unsigned char) sqrtf(x*x + y*y);
}

//naive without padding
__global__ void matrixConvGPUNaive_withoutPadding(unsigned char *dIn, int width, int height, int kernelW, int kernelH, unsigned char *dOut, const float *kernel) 
{
    // Pixel location 
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    float accum = 0.0;
    // Calculate radius along X and Y axis
    // We can also use one kernel variable instead - kernel radius
    int   kernelRadiusW = kernelW/2;
    int   kernelRadiusH = kernelH/2;

    // Determine pixels to operate 
    if(x >= kernelRadiusW && y >= kernelRadiusH &&
       x < (blockDim.x * gridDim.x) - kernelRadiusW &&
       y < (blockDim.y * gridDim.y)-kernelRadiusH)
    {
        for(int i = -kernelRadiusH; i <= kernelRadiusH; i++)  // Along Y axis
        {
            for(int j = -kernelRadiusW; j <= kernelRadiusW; j++) // Along X axis
            {
                // calculate weight 
                int jj = (j+kernelRadiusW);
                int ii = (i+kernelRadiusH);
                float w  = kernel[(ii * kernelW) + jj];
        
                accum += w * float(dIn[((y+i) * width) + (x+j)]);
            }
        }
    }
    
    dOut[(y * width) + x] = (unsigned char)accum;
}

//Naive with padding
__global__ void matrixConvGPUNaive_withPadding(unsigned char *dIn, int width, int height, int paddingX, int paddingY, int kernelW, int kernelH, unsigned char *dOut, const float *kernel)
{
    // Pixel location 
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;

    float accum = 0.0;
    // Calculate radius along X and Y axis
    // We can also use one kernel variable instead - kernel radius
    int   kernelRadiusW = kernelW/2;
    int   kernelRadiusH = kernelH/2;

    // Determine pixels to operate 
    if(x >= (kernelRadiusW + paddingX) && y >= (kernelRadiusH + paddingY) &&
       x < ((blockDim.x * gridDim.x) - kernelRadiusW - paddingX) &&
       y < ((blockDim.y * gridDim.y) - kernelRadiusH - paddingY))
    {
        for(int i = -kernelRadiusH; i <= kernelRadiusH; i++)  // Along Y axis
        {
            for(int j = -kernelRadiusW; j <= kernelRadiusW; j++) // Along X axis
            {
                // calculate weight 
                int jj = (j+kernelRadiusW);
                int ii = (i+kernelRadiusH);
                float w  = kernel[(ii * kernelW) + jj];
        
                accum += w * float(dIn[((y+i) * width) + (x+j)]);
            }
        }
    }
    
    dOut[(y * width) + x] = (unsigned char)accum;
}

//Constant memory
__global__ void matrixConvGPU_constantMemory(unsigned char *dIn, int width, int height, int paddingX, int paddingY, ssize_t kernelOffset, int kernelW, int kernelH, unsigned char *dOut)
{
    // Calculate our pixel's location
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    // Calculate radius along X and Y axis
    // We can also use one kernel variable instead - kernel radius
    float accum = 0.0;
    int   kernelRadiusW = kernelW/2;
    int   kernelRadiusH = kernelH/2;

    // Determine pixels to operate 
    if(x >= (kernelRadiusW + paddingX) && y >= (kernelRadiusH + paddingY) &&
       x < ((blockDim.x * gridDim.x) - kernelRadiusW - paddingX) &&
       y < ((blockDim.y * gridDim.y) - kernelRadiusH - paddingY))
    {
        for(int i = -kernelRadiusH; i <= kernelRadiusH; i++) // Along Y axis
        {
            for(int j = -kernelRadiusW; j <= kernelRadiusW; j++) //Along X axis
            {
                // Sample the weight for this location
                int jj = (j+kernelRadiusW);
                int ii = (i+kernelRadiusH);
                float w  = constConvKernelMem[(ii * kernelW) + jj + kernelOffset]; //kernel from constant memory
                 
                accum += w * float(dIn[((y+i) * width) + (x+j)]);
            }
        }
    }
    
    dOut[(y * width) + x] = (unsigned char) accum;
}

__global__ void matrixConvGPU_float(unsigned char *dIn, int width, int height, int paddingX, int paddingY, ssize_t kernelOffset, int kernelW, int kernelH, unsigned char *dOut)
{
    // Calculate our pixel's location
    float x = ((float)blockIdx.x * (float)blockDim.x) + (float)threadIdx.x;
    float y = ((float)blockIdx.y * (float)blockDim.y) + (float)threadIdx.y;

    // Calculate radius along X and Y axis
    // We can also use one kernel variable instead - kernel radius
    float accum = 0.0;
    int   kernelRadiusW = kernelW/2;
    int   kernelRadiusH = kernelH/2;

    // Determine pixels to operate 
    if(x >= ((float)kernelRadiusW + (float)paddingX) && y >= ((float)kernelRadiusH + (float)paddingY) &&
       x < (((float)blockDim.x * (float)gridDim.x) - (float)kernelRadiusW - (float)paddingX) &&
       y < (((float)blockDim.y * (float)gridDim.y) - (float)kernelRadiusH - (float)paddingY))
    {
        for(int i = -kernelRadiusH; i <= kernelRadiusH; i++) // Along Y axis
        {
            for(int j = -kernelRadiusW; j <= kernelRadiusW; j++) //Along X axis
            {
                // Sample the weight for this location
                float jj = ((float)j+(float)kernelRadiusW);
                float ii = ((float)i+(float)kernelRadiusH);
                float w  = constConvKernelMem[(int)((ii * (float)kernelW) + jj + (float)kernelOffset)]; //kernel from constant memory
                 
                accum += w * float(dIn[(int)(((y+(float)i) * (float)width) + (x+(float)j))]);
            }
        }
    }
    
    dOut[(int)((y * (float)width) + x)] = (unsigned char) accum;
}

__global__ void matrixConvGPU_restrict(unsigned char* __restrict__ dIn, int width, int height, int paddingX, int paddingY, ssize_t kernelOffset, int kernelW, int kernelH, unsigned char* __restrict__ dOut)
{
    // Calculate our pixel's location
    float x = ((float)blockIdx.x * (float)blockDim.x) + (float)threadIdx.x;
    float y = ((float)blockIdx.y * (float)blockDim.y) + (float)threadIdx.y;

    // Calculate radius along X and Y axis
    // We can also use one kernel variable instead - kernel radius
    float accum = 0.0;
    int   kernelRadiusW = kernelW/2;
    int   kernelRadiusH = kernelH/2;

    // Determine pixels to operate 
    if(x >= ((float)kernelRadiusW + (float)paddingX) && y >= ((float)kernelRadiusH + (float)paddingY) &&
       x < (((float)blockDim.x * (float)gridDim.x) - (float)kernelRadiusW - (float)paddingX) &&
       y < (((float)blockDim.y * (float)gridDim.y) - (float)kernelRadiusH - (float)paddingY))
    {
        for(int i = -kernelRadiusH; i <= kernelRadiusH; i++) // Along Y axis
        {
            for(int j = -kernelRadiusW; j <= kernelRadiusW; j++) //Along X axis
            {
                // Sample the weight for this location
                float jj = ((float)j+(float)kernelRadiusW);
                float ii = ((float)i+(float)kernelRadiusH);
                float w  = constConvKernelMem[(int)((ii * (float)kernelW) + jj + (float)kernelOffset)]; //kernel from constant memory
                 
                accum += w * float(dIn[(int)(((y+(float)i) * (float)width) + (x+(float)j))]);
            }
        }
    }
    
    dOut[(int)((y * (float)width) + x)] = (unsigned char) accum;
}
