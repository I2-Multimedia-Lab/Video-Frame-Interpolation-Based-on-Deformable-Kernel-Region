#include <stdio.h>

#include "filterinterpolation_cuda_kernel.cuh"


#include <ATen/ATen.h>
#include <ATen/NativeFunctions.h>
#include <ATen/Dispatch.h>
#include <ATen/cuda/CUDAApplyUtils.cuh>


#define min(a,b) ((a<b)?(a):(b))
#define max(a,b) ((a>b)?(a):(b))

#define DEBUG (0)
#ifndef BLOCKDIMX
#define BLOCKDIMX (32)
#endif
#ifndef BLOCKDIMY
#define BLOCKDIMY (16)
#endif
using at::Half;




//forward path of our layer
template <typename scalar_t>
__global__ void FilterInterpolationLayer_gpu_forward_kernelfunc(
		const int nElement,
		const int w, 		const int h, 		const int channel, const int filter_size,

		const int input1_b_stride, const int input1_c_stride, const int input1_h_stride, const int input1_w_stride,
		const int input2_b_stride, const int input2_c_stride, const int input2_h_stride, const int input2_w_stride,
		const int input3_b_stride, const int input3_c_stride, const int input3_h_stride, const int input3_w_stride,
        const int input4_b_stride, const int input4_c_stride, const int input4_h_stride, const int input4_w_stride,

		const scalar_t* __restrict__  input1, const scalar_t* __restrict__ input2, const scalar_t* __restrict__  input3, 
        const scalar_t* __restrict__  input4, 
        scalar_t* output

		)
{

	//blockIdx.z : batch index from 0~B-1
	//blockIdx.y : height patch index from ceil(h/16)
	//blockIdx.x : width patch index from ceil(w/32)

	//threadidx.x: width index 0~31
	//threadIdx.y: height index 0~15
	//threadIdx.z: Not used

	//only use one dimensioon of the grid and block
	const int w_i = blockIdx.x * blockDim.x + threadIdx.x;
	const int h_i = blockIdx.y * blockDim.y + threadIdx.y;
	const bool withinXbounds = w_i < w;
	const bool withinYbounds = h_i < h;

	const int batch_i = blockIdx.z;
	const int off = batch_i * input1_b_stride;


	//    __syncthreads();
//	const float fillvalue =0.0f;

	if( withinXbounds && withinYbounds) {

        if(filter_size==4 || filter_size==6){
            float fx = input2[batch_i * input2_b_stride + 0 * input2_c_stride + h_i * input2_h_stride + w_i  ];
            float fy = input2[batch_i * input2_b_stride + 1 * input2_c_stride + h_i * input2_h_stride + w_i  ];

            float x2 = (float)(w_i) + fx;
            float y2 = (float)(h_i) + fy;


            if(x2 >= 0.0f && y2 >=0.0f && x2 <= (float)(w -1) && y2 <= (float)(h-1)
                && fabs(fx) < (float)(w)/2.0f && fabs(fy) < (float)(h)/2.0f){
                int ix2_L = int(x2) + 1 - (int)(filter_size / 2);
                int iy2_T = int(y2) + 1 - (int)(filter_size / 2);
                int ix2_R = ix2_L + filter_size;
                int iy2_B = iy2_T + filter_size;

                float alpha = x2 - (int)(x2);
                float beta = y2 - (int)(y2);


                //TODO: here is a bug that if the iy2_B or ix2_R gets out of the border, than there is no enough pixels to warp the target one.
                for (int c_i = 0 ; c_i < channel ; c_i++){

                    float TL = 0.0f;
                    for(int filter_j = iy2_T; filter_j <= (int)(y2); filter_j ++){
                        int _filter_j = min(max(0, filter_j), h - 1);
                        for( int filter_i = ix2_L; filter_i <= (int) ( x2) ; filter_i ++ ){
                        int _filter_i = min(max(0, filter_i ), w - 1);
                        
                        // add deforconv offset field
                        // fracY, fracX分别表示偏移之后的坐标点
                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;
                        TL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                            input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ;

                        // TL += input1[off + c_i *  input1_c_stride +  _filter_j * input1_h_stride + _filter_i ] *
                        // 		input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ;
                        }
                    }

                    float TR = 0.0f;
                    for (int filter_j = iy2_T; filter_j <= (int) (y2); filter_j ++ ){
                        int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                    for (int filter_i =  (int) (x2) + 1 ; filter_i < ix2_R; filter_i ++ ){
                        int _filter_i = min(max(0, filter_i),w - 1);// only used for input1

                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;
                        TR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                            input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ;

                        // TR += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                        //     input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                    }
                    }

                    float BL = 0.0f;
                    for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                        int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                    for (int filter_i = ix2_L; filter_i <= (int) (x2); filter_i ++ ){
                        int _filter_i = min(max(0, filter_i),w - 1);// only used for input1

                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;
                        BL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                            input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ;

                        // BL += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                        //     input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                    }
                    }

                    float BR = 0.0f;
                    for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                        int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                    for (int filter_i = (int) (x2) + 1; filter_i < ix2_R; filter_i ++ ){
                        int _filter_i = min(max(0, filter_i),w - 1);// only used for input1

                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;
                        BR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                            input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ;

                        // BR += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                        //     input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                    }
                    }

                    output[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i ] =
                                (1-alpha)*(1-beta)*TL +
                                alpha*(1-beta)*TR +
                                (1-alpha)*beta*BL +
                                alpha*beta*BR;

    //					for( int filter_i = ix2_L; filter_i < ix2_R ; filter_i ++ ){
    //						int _filter_i = min(max(0, filter_i),w - 1);
    //						output[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i ] +=
    //							input1[off + c_i *  input1_c_stride +  _filter_j * input1_h_stride + _filter_i ] *
    //							input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] *
    ////							exp( -(fabs((float) filter_j - y2) + fabs((float) filter_i - x2)) / (float)(filter_size)); // the distance weight
    //							exp( -(fabs((float) filter_j - y2) + fabs((float) filter_i - x2)) ); // the distance weight
    //
    ////							if(w_i == 141 && h_i == 316 && c_i == 0 ){
    ////printf("gpu: %f, %f,%f,%f\n",input1[off + c_i *  input1_c_stride +  _filter_j * input1_h_stride + _filter_i ] ,
    ////input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i],
    ////exp( -(fabs((float) filter_j - y2) + fabs((float) filter_i - x2)) / (float)(filter_size)),
    ////output[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i ]
    //// );
    ////}
    //
    //					}
    //				}
                }
            } else{
                //the warping data is out of range, we fill it with zeros
                for(int c_i = 0 ;  c_i < channel; c_i ++){
                    output[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i] = input1[off + c_i* input1_c_stride+ h_i * input1_h_stride + w_i];
                }
            }

        } // end filter_size == 4



        // // filter_size == 3
        // if(filter_size==3){

        //     float fx = input2[batch_i * input2_b_stride + 0 * input2_c_stride + h_i * input2_h_stride + w_i  ];
		//     float fy = input2[batch_i * input2_b_stride + 1 * input2_c_stride + h_i * input2_h_stride + w_i  ];

        //     // flow 定位到的位置
        //     float x2 = (float)(w_i) + fx;
        //     float y2 = (float)(h_i) + fy;

        //     if(x2 >= 0.0f && y2 >=0.0f && x2 <= (float)(w -1) && y2 <= (float)(h-1)
        //         && fabs(fx) < (float)(w)/2.0f && fabs(fy) < (float)(h)/2.0f){
                
        //         // 判断定位点所处在的区域
        //         float alpha = x2 - (int)(x2);
        //         float beta = y2 - (int)(y2);

                

        //         // 根据不同区域确定四个角的位置
        //         if(alpha <= 0.5 && beta <= 0.5){
        //             int ix2_L = int(x2) - 1;
        //             int iy2_T = int(y2) - 1;
        //             int ix2_R = int(x2) + 1;
        //             int iy2_B = int(y2) + 1;
        //             // 修改系数
        //             float alpha_new = (alpha + 1)/2;
        //             float beta_new = (beta + 1)/2;

        //         }else if(alpha > 0.5 && beta <= 0.5){
        //             int ix2_L = int(x2);
        //             int iy2_T = int(y2) - 1;
        //             int ix2_R = int(x2) + 2;
        //             int iy2_B = int(y2) + 1;
        //             float alpha_new = alpha/2;
        //             float beta_new = (beta + 1)/2;

        //         }else if(alpha <= 0.5 && beta > 0.5){
        //             int ix2_L = int(x2) - 1;
        //             int iy2_T = int(y2);
        //             int ix2_R = int(x2) + 1;
        //             int iy2_B = int(y2) + 2;
        //             float alpha_new = (alpha + 1)/2;
        //             float beta_new = beta/2;

        //         }else{
        //             int ix2_L = int(x2);
        //             int iy2_T = int(y2);
        //             int ix2_R = int(x2) + 2;
        //             int iy2_B = int(y2) + 2;
        //             float alpha_new = alpha/2;
        //             float beta_new = beta/2;
        //         }


        //         for (int c_i = 0 ; c_i < channel ; c_i++){
                    

        //             float TL = 0.0f;
        //             for(int filter_j = iy2_T; filter_j <= (int)(y2); filter_j ++){
        //                 int _filter_j = min(max(0, filter_j), h - 1);
        //                 for( int filter_i = ix2_L; filter_i <= (int) ( x2) ; filter_i ++ ){
        //                 int _filter_i = min(max(0, filter_i ), w - 1);

        //                 QTL = (1 - fabs(alpha_new - _filter_i))*(1 - fabs(beta_new - _filter_j));
                        
        //                 // add deforconv offset field
        //                 // fracY, fracX分别表示偏移之后的坐标点
        //                 float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
        //                 float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
        //                 float phiY = fracY - int(fracY);
        //                 float phiX = fracX - int(fracX);
        //                 int Top = int(fracY);
        //                 int Left = int(fracX);
        //                 int Bottom = Top + 1;
        //                 int Right = Left + 1;
        //                 float PTL = (1 - phiX) * (1 - phiY);
        //                 float PTR = phiX * (1 - phiY);
        //                 float PBL = (1 - phiX) * phiY;
        //                 float PBR = phiY * phiX;
        //                 TL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
        //                     PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
        //                     input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] * QTL ;

                        
        //                 }
        //             }

        //             float TR = 0.0f;
        //             for (int filter_j = iy2_T; filter_j <= (int) (y2); filter_j ++ ){
        //                 int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
        //             for (int filter_i =  (int) (x2) + 1 ; filter_i < ix2_R; filter_i ++ ){
        //                 int _filter_i = min(max(0, filter_i),w - 1);// only used for input1

        //                 QTR = alpha_new*(1 - fabs(beta_new - _filter_j));

        //                 float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
        //                 float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
        //                 float phiY = fracY - int(fracY);
        //                 float phiX = fracX - int(fracX);
        //                 int Top = int(fracY);
        //                 int Left = int(fracX);
        //                 int Bottom = Top + 1;
        //                 int Right = Left + 1;
        //                 float PTL = (1 - phiX) * (1 - phiY);
        //                 float PTR = phiX * (1 - phiY);
        //                 float PBL = (1 - phiX) * phiY;
        //                 float PBR = phiY * phiX;
        //                 TR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
        //                     PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
        //                     input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] * QTR ;

                        
        //             }
        //             }

        //             float BL = 0.0f;
        //             for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
        //                 int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
        //             for (int filter_i = ix2_L; filter_i <= (int) (x2); filter_i ++ ){
        //                 int _filter_i = min(max(0, filter_i),w - 1);// only used for input1

        //                 QBL = (1 - fabs(alpha_new - _filter_i))*beta_new;

        //                 float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
        //                 float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
        //                 float phiY = fracY - int(fracY);
        //                 float phiX = fracX - int(fracX);
        //                 int Top = int(fracY);
        //                 int Left = int(fracX);
        //                 int Bottom = Top + 1;
        //                 int Right = Left + 1;
        //                 float PTL = (1 - phiX) * (1 - phiY);
        //                 float PTR = phiX * (1 - phiY);
        //                 float PBL = (1 - phiX) * phiY;
        //                 float PBR = phiY * phiX;
        //                 BL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
        //                     PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
        //                     input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] * QBL;


        //             }
        //             }

        //             float BR = 0.0f;
        //             for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
        //                 int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
        //             for (int filter_i = (int) (x2) + 1; filter_i < ix2_R; filter_i ++ ){
        //                 int _filter_i = min(max(0, filter_i),w - 1);// only used for input1

        //                 QBR = alpha_new*beta_new;

        //                 float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
        //                 float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
        //                 float phiY = fracY - int(fracY);
        //                 float phiX = fracX - int(fracX);
        //                 int Top = int(fracY);
        //                 int Left = int(fracX);
        //                 int Bottom = Top + 1;
        //                 int Right = Left + 1;
        //                 float PTL = (1 - phiX) * (1 - phiY);
        //                 float PTR = phiX * (1 - phiY);
        //                 float PBL = (1 - phiX) * phiY;
        //                 float PBR = phiY * phiX;
        //                 BR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
        //                     PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
        //                     input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] * QBR;


        //             }
        //             }

        //             output[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i ] =
        //                         TL + TR + BL + BR;

        //         }
                

        //     }else{
        //         //the warping data is out of range, we fill it with zeros
        //         for(int c_i = 0 ;  c_i < channel; c_i ++){
        //             output[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i] = input1[off + c_i* input1_c_stride+ h_i * input1_h_stride + w_i];
        //         }
        //     }

        // }    // end filter_size == 3
        
	}
	return ;

}


template <typename scalar_t>
__global__ void FilterInterpolationLayer_gpu_backward_kernelfunc(
		const int nElement, 	   const int w, 		const int h, 		const int channel, 	const int filter_size,
		const int input1_b_stride, const int input1_c_stride, const int input1_h_stride, const int input1_w_stride,
		const int input2_b_stride, const int input2_c_stride, const int input2_h_stride, const int input2_w_stride,
		const int input3_b_stride, const int input3_c_stride, const int input3_h_stride, const int input3_w_stride,
        const int input4_b_stride, const int input4_c_stride, const int input4_h_stride, const int input4_w_stride,

		const scalar_t* __restrict__      input1,        		const scalar_t* __restrict__      input2,		const scalar_t* __restrict__      input3,
		const scalar_t* __restrict__      input4,       
        scalar_t* gradoutput,    		scalar_t*  gradinput1,  		scalar_t*  gradinput2,  		
        scalar_t*  gradinput3,      
        scalar_t*  gradinput4
		)
		{
	//blockIdx.z : batch index from 0~B-1
	//blockIdx.y : height patch index from ceil(h/16)
	//blockIdx.x : width patch index from ceil(w/32)

	//threadidx.x: width index 0~31
	//threadIdx.y: height index 0~15
	//threadIdx.z: Not used

	const int w_i = blockIdx.x * blockDim.x + threadIdx.x;
	const int h_i = blockIdx.y * blockDim.y + threadIdx.y;
	const bool withinXbounds = w_i < w;
	const bool withinYbounds = h_i < h;

	const int batch_i = blockIdx.z;
	const int off  = batch_i * input1_b_stride;

	//    __syncthreads();

	if(withinXbounds && withinYbounds){

		float fx = input2[batch_i * input2_b_stride +  0 * input2_c_stride + h_i * input2_h_stride + w_i];
		float fy = input2[batch_i * input2_b_stride +  1 * input2_c_stride + h_i * input2_h_stride + w_i];

		float x2 = float(w_i) + fx;
		float y2 = float(h_i) + fy;

		if(x2 >= 0.0f  && y2 >= 0.0f && x2 <= (float)(w - 1) && y2 <= (float)(h -1)
            && fabs(fx) < (float)(w)/2.0f && fabs(fy) < (float)(h)/2.0f){
			int ix2_L = int(x2) + 1 - (int) (filter_size/2);
			int iy2_T = int(y2) + 1 - (int) (filter_size/2);
			int ix2_R = ix2_L + filter_size;
			int iy2_B = iy2_T + filter_size;

            float alpha = x2 - (int)(x2);
            float beta = y2  - (int)(y2);
			/***
			  Step 1: calculate the gradients for input1, i.e. the input image;
			 ***/
            /***
              STEP 3: calculate the gradients for input3, i.e. the filter
             ***/
             /***
                Step 1 and Step 3 are simultaneously computed
             ***/
			for (int c_i = 0 ; c_i < channel; c_i++){

				float gradoutput_value = gradoutput[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i];

                float TL_grad = gradoutput_value * (1-alpha ) * (1-beta);
                for(int filter_j = iy2_T; filter_j <= (int) (y2) ; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for (int filter_i = ix2_L   ; filter_i <= (int)(x2) ; filter_i ++){
                    int _filter_i = min(max(0, filter_i), w - 1);
                    atomicAdd( &gradinput1[off +c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i ],
                                TL_grad * input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                input3_c_stride + h_i * input3_h_stride + w_i]);

                    float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float phiY = fracY - int(fracY);
                    float phiX = fracX - int(fracX);
                    int Top = int(fracY);
                    int Left = int(fracX);
                    int Bottom = Top + 1;
                    int Right = Left + 1;
                    float PTL = (1 - phiX) * (1 - phiY);
                    float PTR = phiX * (1 - phiY);
                    float PBL = (1 - phiX) * phiY;
                    float PBR = phiY * phiX;
                    float BiInput = (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                         PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]);

                    
                    // atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T ) * filter_size + (filter_i - ix2_L)) *
                    //                                                     input3_c_stride + h_i * input3_h_stride + w_i],
                    //             TL_grad * input1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i]);
                    atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T ) * filter_size + (filter_i - ix2_L)) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                TL_grad * BiInput);
                    }
                }

                float TR_grad= gradoutput_value * alpha * ( 1- beta);
                for (int filter_j = iy2_T; filter_j <= (int) (y2); filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                for (int filter_i =  (int) (x2) + 1 ; filter_i < ix2_R; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1

                    atomicAdd( &gradinput1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i ],
                                TR_grad * input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                input3_c_stride + h_i * input3_h_stride + w_i]);

                    float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float phiY = fracY - int(fracY);
                    float phiX = fracX - int(fracX);
                    int Top = int(fracY);
                    int Left = int(fracX);
                    int Bottom = Top + 1;
                    int Right = Left + 1;
                    float PTL = (1 - phiX) * (1 - phiY);
                    float PTR = phiX * (1 - phiY);
                    float PBL = (1 - phiX) * phiY;
                    float PBR = phiY * phiX;
                    float BiInput = (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                         PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]);
                    
                    // atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T ) * filter_size + (filter_i - ix2_L)) *
                    //                                                     input3_c_stride + h_i * input3_h_stride + w_i],
                    //             TR_grad * input1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i]);

                    atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T ) * filter_size + (filter_i - ix2_L)) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                TR_grad * BiInput);
                    }
                    }

                   float BL_grad = gradoutput_value * ( 1 - alpha ) * beta;
                   for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                        int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                        for (int filter_i = ix2_L; filter_i <= (int) (x2); filter_i ++ ){
                            int _filter_i = min(max(0, filter_i),w - 1);// only used for input1

                        atomicAdd( &gradinput1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i ],
                                    BL_grad * input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                    input3_c_stride + h_i * input3_h_stride + w_i]);

                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;
                        float BiInput = (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]);

                        // atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T ) * filter_size + (filter_i - ix2_L)) *
                        //                                                     input3_c_stride + h_i * input3_h_stride + w_i],
                        //             BL_grad * input1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i]);

                        atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T ) * filter_size + (filter_i - ix2_L)) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                BL_grad * BiInput);

                    }
                    }

                float BR_grad = gradoutput_value * alpha * beta;
                 for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                    for (int filter_i = (int) (x2) + 1; filter_i < ix2_R; filter_i ++ ){
                        int _filter_i = min(max(0, filter_i),w - 1);// only used for input1
                        atomicAdd( &gradinput1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i ],
                                    BR_grad * input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                    input3_c_stride + h_i * input3_h_stride + w_i]);

                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;
                        float BiInput = (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]);

                        // atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T ) * filter_size + (filter_i - ix2_L)) *
                        //                                                     input3_c_stride + h_i * input3_h_stride + w_i],
                        //             BR_grad * input1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i]);

                        atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T ) * filter_size + (filter_i - ix2_L)) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                BR_grad * BiInput);
                        }
                }
//				for ( int filter_j = iy2_T; filter_j < iy2_B ; filter_j ++ ){
//					int _filter_j = min(max(0, filter_j),  h - 1);
//					for( int filter_i = ix2_L; filter_i< ix2_R ; filter_i++){
//						int _filter_i = min(max(0,filter_i), w - 1);
//						atomicAdd( & gradinput1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i],
//								gradoutput_value *
//								input3 [batch_i * input3_b_stride + ((filter_j  - iy2_T) * filter_size + (filter_i - ix2_L))* input3_c_stride + h_i * input3_h_stride + w_i] *
////								exp( -(fabs((float)filter_j - y2) + fabs((float)filter_i - x2))/(float)filter_size)
//                                exp( -(fabs((float)filter_j - y2) + fabs((float)filter_i - x2)))
//
//							 );
//					}
//				}

			}

			/***
			  Step 2: calculate the gradients for input2, i.e., the optical flow,
			  STEP 2.1: for the x/horizonotal direction.
			 ***/
            float gamma  =  1.0f - beta; //iy2_B - y2;   beta = y2  - (int)(y2)
			float bot_diff = 0.0f;
			for(int c_i =0 ; c_i< channel; c_i ++ ){
				float gradoutput_value = gradoutput[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i];

                float TL = 0.0f;
                for(int filter_j = iy2_T; filter_j <= (int)(y2); filter_j ++){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for( int filter_i = ix2_L; filter_i <= (int) ( x2) ; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i ), w - 1);

                    float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float phiY = fracY - int(fracY);
                    float phiX = fracX - int(fracX);
                    int Top = int(fracY);
                    int Left = int(fracX);
                    int Bottom = Top + 1;
                    int Right = Left + 1;
                    float PTL = (1 - phiX) * (1 - phiY);
                    float PTR = phiX * (1 - phiY);
                    float PBL = (1 - phiX) * phiY;
                    float PBR = phiY * phiX;
                    TL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
							input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ;

                    // TL += input1[off + c_i *  input1_c_stride +  _filter_j * input1_h_stride + _filter_i ] *
					// 		input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ;
                    }
                }

                float TR = 0.0f;
                for (int filter_j = iy2_T; filter_j <= (int) (y2); filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                for (int filter_i =  (int) (x2) + 1 ; filter_i < ix2_R; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1

                    float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float phiY = fracY - int(fracY);
                    float phiX = fracX - int(fracX);
                    int Top = int(fracY);
                    int Left = int(fracX);
                    int Bottom = Top + 1;
                    int Right = Left + 1;
                    float PTL = (1 - phiX) * (1 - phiY);
                    float PTR = phiX * (1 - phiY);
                    float PBL = (1 - phiX) * phiY;
                    float PBR = phiY * phiX;
                    TR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                        input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];

                    // TR += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                    //     input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                }
                }

                float BL = 0.0f;
                for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                for (int filter_i = ix2_L; filter_i <= (int) (x2); filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1

                    float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float phiY = fracY - int(fracY);
                    float phiX = fracX - int(fracX);
                    int Top = int(fracY);
                    int Left = int(fracX);
                    int Bottom = Top + 1;
                    int Right = Left + 1;
                    float PTL = (1 - phiX) * (1 - phiY);
                    float PTR = phiX * (1 - phiY);
                    float PBL = (1 - phiX) * phiY;
                    float PBR = phiY * phiX;
                    BL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                        input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];

                    // BL += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                    //     input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                }
                }

                float BR = 0.0f;
                for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                for (int filter_i = (int) (x2) + 1; filter_i < ix2_R; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1

                    float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float phiY = fracY - int(fracY);
                    float phiX = fracX - int(fracX);
                    int Top = int(fracY);
                    int Left = int(fracX);
                    int Bottom = Top + 1;
                    int Right = Left + 1;
                    float PTL = (1 - phiX) * (1 - phiY);
                    float PTR = phiX * (1 - phiY);
                    float PBL = (1 - phiX) * phiY;
                    float PBR = phiY * phiX;

                    BR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                        input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];

                    // BR += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                    //     input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                }
                }

	            float temp = 0.0f;
                temp += gamma * (TR - TL);
                temp += (1-gamma) * (BR - BL);
                bot_diff += gradoutput_value * temp;
//				for( int filter_j = iy2_T; filter_j< iy2_B; filter_j++){
//					int _filter_j = min(max(0, filter_j) , h - 1);
//					for( int filter_i = ix2_L; filter_i< ix2_R; filter_i ++){
//						int _filter_i = min(max(0,filter_i), w-1);
//
//						bot_diff +=
//							gradoutput_value *
//							input1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
//							input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))* input3_c_stride + h_i * input3_h_stride + w_i   ] *
////							exp( - ( fabs((float) filter_j - y2 ) + fabs((float) filter_i - x2))/ (float)filter_size) *
////							((float) filter_i > x2 ? 1.0f : -1.0f) / (float)filter_size;
//                        	exp( - ( fabs((float) filter_j - y2 ) + fabs((float) filter_i - x2))) *
//							((float) filter_i > x2 ? 1.0f : -1.0f);
//					}
//				}
			}
			//the gradients of the x direction/ horizontal direction
			gradinput2[batch_i * input2_b_stride + 0 * input2_c_stride + h_i * input2_h_stride + w_i] = bot_diff;

			/***
			  STEP 2.2: for the y/vertical direction.
			 ***/
            gamma =  1.0f - alpha; //ix2_R -x2;   alpha = x2 - (int)(x2)
			bot_diff = 0.0f;
			for(int c_i = 0 ; c_i < channel; c_i ++ ){
				float gradoutput_value = gradoutput [ off + c_i * input1_c_stride + h_i * input1_h_stride +w_i];

                float TL = 0.0f;
                for(int filter_j = iy2_T; filter_j <= (int)(y2); filter_j ++){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for( int filter_i = ix2_L; filter_i <= (int) ( x2) ; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i ), w - 1);

                    float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float phiY = fracY - int(fracY);
                    float phiX = fracX - int(fracX);
                    int Top = int(fracY);
                    int Left = int(fracX);
                    int Bottom = Top + 1;
                    int Right = Left + 1;
                    float PTL = (1 - phiX) * (1 - phiY);
                    float PTR = phiX * (1 - phiY);
                    float PBL = (1 - phiX) * phiY;
                    float PBR = phiY * phiX;

                    TL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
							input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ;

                    // TL += input1[off + c_i *  input1_c_stride +  _filter_j * input1_h_stride + _filter_i ] *
					// 		input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ;
                    }
                }

                float TR = 0.0f;
                for (int filter_j = iy2_T; filter_j <= (int) (y2); filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                for (int filter_i =  (int) (x2) + 1 ; filter_i < ix2_R; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1

                    float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float phiY = fracY - int(fracY);
                    float phiX = fracX - int(fracX);
                    int Top = int(fracY);
                    int Left = int(fracX);
                    int Bottom = Top + 1;
                    int Right = Left + 1;
                    float PTL = (1 - phiX) * (1 - phiY);
                    float PTR = phiX * (1 - phiY);
                    float PBL = (1 - phiX) * phiY;
                    float PBR = phiY * phiX;

                    TR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                        input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];

                    // TR += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                    //     input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                }
                }

                float BL = 0.0f;
                for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                for (int filter_i = ix2_L; filter_i <= (int) (x2); filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1

                    float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float phiY = fracY - int(fracY);
                    float phiX = fracX - int(fracX);
                    int Top = int(fracY);
                    int Left = int(fracX);
                    int Bottom = Top + 1;
                    int Right = Left + 1;
                    float PTL = (1 - phiX) * (1 - phiY);
                    float PTR = phiX * (1 - phiY);
                    float PBL = (1 - phiX) * phiY;
                    float PBR = phiY * phiX;

                    BL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                        input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];

                    // BL += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                    //     input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                }
                }

                float BR = 0.0f;
                for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                for (int filter_i = (int) (x2) + 1; filter_i < ix2_R; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1

                    float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float phiY = fracY - int(fracY);
                    float phiX = fracX - int(fracX);
                    int Top = int(fracY);
                    int Left = int(fracX);
                    int Bottom = Top + 1;
                    int Right = Left + 1;
                    float PTL = (1 - phiX) * (1 - phiY);
                    float PTR = phiX * (1 - phiY);
                    float PBL = (1 - phiX) * phiY;
                    float PBR = phiY * phiX;

                    BR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                        input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];

                    // BR += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                    //     input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                }
                }

                float temp = 0.0f;
                temp += gamma * (BL - TL);
                temp += (1.0f - gamma) * ( BR - TR);
                bot_diff += gradoutput_value * temp;

//				for( int filter_j = iy2_T; filter_j < iy2_B; filter_j ++ ){
//					int _filter_j = min(max(0, filter_j), h - 1);
//					for( int filter_i = ix2_L; filter_i < ix2_R; filter_i ++){
//						int _filter_i = min(max(0, filter_i), w - 1);
//
//						bot_diff +=
//							gradoutput_value *
//							input1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
//							input3 [batch_i * input3_b_stride +((filter_j - iy2_T) * filter_size + ( filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i ] *
////							exp( - (fabs((float) filter_j - y2) + fabs((float) filter_i - x2))/ (float)filter_size  ) *
////							((float) filter_j > y2 ? 1.0f : - 1.0f ) / (float)filter_size;
//							exp( - (fabs((float) filter_j - y2) + fabs((float) filter_i - x2))  ) *
//							((float) filter_j > y2 ? 1.0f : - 1.0f );
//					}
//				}
			}
			gradinput2[batch_i * input2_b_stride + 1 * input2_c_stride + h_i * input2_h_stride + w_i]= bot_diff;
			/***
			  STEP 3: calculate the gradients for input3, i.e. the filter
			 ***/
//			for(int c_i  = 0 ; c_i <channel ; c_i ++ ){
//				float gradoutput_value = gradoutput[ off + c_i * input1_c_stride + h_i * input1_h_stride + w_i ];
//				for( int filter_j=  iy2_T ; filter_j < iy2_B; filter_j ++ ){
//					int _filter_j = min(max(0, filter_j), h -1 );
//					for ( int filter_i  = ix2_L; filter_i < ix2_R; filter_i ++ ){
//						int _filter_i  = min(max(0, filter_i ), w - 1);
//
//						gradinput3 [  batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L  ) ) * input3_c_stride + h_i * input3_h_stride + w_i] +=
//							gradoutput_value *
//							input1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
////							exp( -(fabs((float) filter_j - y2 ) + fabs((float) filter_i - x2))/ (float)filter_size);
//							exp( -(fabs((float) filter_j - y2 ) + fabs((float) filter_i - x2)));
//					}
//				}
//			}

            /***
                SETP 4: calculate the gradients for input4, i.e. the deconv offset field
            ***/
           /***
                SETP 4.1: y方向上
            ***/
        //    float bot_diff = 0.0f;
            for(int c_i =0 ; c_i< channel; c_i ++ ){
				float gradoutput_value = gradoutput[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i];
                
                float TL_Krd = (1-alpha) * (1-beta);
                for(int filter_j = iy2_T; filter_j <= (int)(y2); filter_j ++){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for( int filter_i = ix2_L; filter_i <= (int) ( x2) ; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i ), w - 1);

                    float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float phiY = fracY - int(fracY);
                    float phiX = fracX - int(fracX);
                    int Top = int(fracY);
                    int Left = int(fracX);
                    int Bottom = Top + 1;
                    int Right = Left + 1;
                    float PTL = (1 - phiX) * (1 - phiY);
                    float PTR = phiX * (1 - phiY);
                    float PBL = (1 - phiX) * phiY;
                    float PBR = phiY * phiX;

                    float BiInput = - (1 - phiX) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + 
                            (1 - phiX) * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] -
                            phiX * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            phiX * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right];

                    atomicAdd( & gradinput4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                        input4_c_stride + h_i * input4_h_stride + w_i],
                                gradoutput_value * TL_Krd * BiInput * input3[batch_i * input3_b_stride + 
                                                                        ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i]);
                    }
                }


                float TR_Krd =  alpha * ( 1- beta);
                for (int filter_j = iy2_T; filter_j <= (int) (y2); filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                    for (int filter_i =  (int) (x2) + 1 ; filter_i < ix2_R; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1
                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;

                        float BiInput = - (1 - phiX) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + 
                            (1 - phiX) * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] -
                            phiX * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            phiX * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right];

                        atomicAdd( & gradinput4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                        input4_c_stride + h_i * input4_h_stride + w_i],
                                gradoutput_value * TR_Krd * BiInput * input3[batch_i * input3_b_stride + 
                                                                        ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i]);
                    }
                }

                float BL_Krd = ( 1 - alpha ) * beta;
                for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                    for (int filter_i = ix2_L; filter_i <= (int) (x2); filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1
                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;

                        float BiInput = - (1 - phiX) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + 
                            (1 - phiX) * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] -
                            phiX * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            phiX * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right];

                        atomicAdd( & gradinput4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                        input4_c_stride + h_i * input4_h_stride + w_i],
                                gradoutput_value * BL_Krd * BiInput * input3[batch_i * input3_b_stride + 
                                                                        ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i]);
                    }
                }

                float BR_Krd = alpha * beta;
                for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                    for (int filter_i = (int) (x2) + 1; filter_i < ix2_R; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1
                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;

                        float BiInput = - (1 - phiX) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + 
                            (1 - phiX) * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] -
                            phiX * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            phiX * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right];

                        atomicAdd( & gradinput4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                        input4_c_stride + h_i * input4_h_stride + w_i],
                                gradoutput_value * BR_Krd * BiInput * input3[batch_i * input3_b_stride + 
                                                                        ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i]);
                    }
                }

            }    // end step 4.1 for(channel)
                
            /***
                 STEP 4.2 x方向上
            ***/
            for(int c_i =0 ; c_i< channel; c_i ++ ){
				float gradoutput_value = gradoutput[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i];

                float TL_Krd = (1-alpha) * (1-beta);
                for(int filter_j = iy2_T; filter_j <= (int)(y2); filter_j ++){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for( int filter_i = ix2_L; filter_i <= (int) ( x2) ; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i ), w - 1);

                    float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                    float phiY = fracY - int(fracY);
                    float phiX = fracX - int(fracX);
                    int Top = int(fracY);
                    int Left = int(fracX);
                    int Bottom = Top + 1;
                    int Right = Left + 1;
                    float PTL = (1 - phiX) * (1 - phiY);
                    float PTR = phiX * (1 - phiY);
                    float PBL = (1 - phiX) * phiY;
                    float PBR = phiY * phiX;

                    float BiInput = - (1 - phiY) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + 
                                (1 - phiY) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] -
                                phiY * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] +
                                phiY * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right];

                    atomicAdd( & gradinput4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) *
                                                                        input4_c_stride + h_i * input4_h_stride + w_i],
                                gradoutput_value * TL_Krd * BiInput * input3[batch_i * input3_b_stride + 
                                                                        ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i]);
                    }
                }


                float TR_Krd =  alpha * ( 1- beta);
                for (int filter_j = iy2_T; filter_j <= (int) (y2); filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                    for (int filter_i =  (int) (x2) + 1 ; filter_i < ix2_R; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1
                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;

                        float BiInput = - (1 - phiY) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + 
                                (1 - phiY) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] -
                                phiY * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] +
                                phiY * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right];

                        atomicAdd( & gradinput4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) *
                                                                        input4_c_stride + h_i * input4_h_stride + w_i],
                                gradoutput_value * TR_Krd * BiInput * input3[batch_i * input3_b_stride + 
                                                                        ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i]);
                    }
                }

                float BL_Krd = ( 1 - alpha ) * beta;
                for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                    for (int filter_i = ix2_L; filter_i <= (int) (x2); filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1
                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;

                        float BiInput = - (1 - phiY) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + 
                                (1 - phiY) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] -
                                phiY * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] +
                                phiY * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right];

                        atomicAdd( & gradinput4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) *
                                                                        input4_c_stride + h_i * input4_h_stride + w_i],
                                gradoutput_value * BL_Krd * BiInput * input3[batch_i * input3_b_stride + 
                                                                        ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i]);
                    }
                }

                float BR_Krd = alpha * beta;
                for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                    for (int filter_i = (int) (x2) + 1; filter_i < ix2_R; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1
                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;

                        float BiInput = - (1 - phiY) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + 
                                (1 - phiY) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] -
                                phiY * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] +
                                phiY * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right];

                        atomicAdd( & gradinput4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) *
                                                                        input4_c_stride + h_i * input4_h_stride + w_i],
                                gradoutput_value * BR_Krd * BiInput * input3[batch_i * input3_b_stride + 
                                                                        ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i]);
                    }
                }

            }   // end step 4.2 for(channel)
		}
	}
	return ;

}


int FilterInterpolationLayer_gpu_forward_kernel(
		cudaStream_t stream,
		const int nElement,
		const int w, 		const int h, 		const int channel, 		const int batch, const  int filter_size,

		const int input1_b_stride, const int input1_c_stride, const int input1_h_stride, const int input1_w_stride,
		const int input2_b_stride, const int input2_c_stride, const int input2_h_stride, const int input2_w_stride,
		const int input3_b_stride, const int input3_c_stride, const int input3_h_stride, const int input3_w_stride,
        const int input4_b_stride, const int input4_c_stride, const int input4_h_stride, const int input4_w_stride,

		at::Tensor&  input1,    		at::Tensor&  input2,    	at::Tensor&  input3, 	
        at::Tensor&  input4,     
        at::Tensor&  output

		)
{
	int error = 1 ;

	dim3 grid;
	dim3 block;


	//		blockthread = 128;
	//the threadIdx.x is sheduled first, then threadIdx.y, threadIdx.z
	//the three channels are processsed in one kernel
	block  = dim3(BLOCKDIMX,BLOCKDIMY,1);
	grid = dim3( (w + BLOCKDIMX - 1)/ BLOCKDIMX, (h + BLOCKDIMY - 1) / BLOCKDIMY, batch);
    if(BLOCKDIMX != 32 || BLOCKDIMY != 16||DEBUG)
        printf("BLOCKDIMX revised to %d, BLOCKDIMY revised to %d \n", BLOCKDIMX,BLOCKDIMY);
	//extract the data of CudaTensor and use kernel to calculate.
		AT_DISPATCH_FLOATING_TYPES(input1.type(), "DepthFlowProjection_gpu_backward", ([&] {
FilterInterpolationLayer_gpu_forward_kernelfunc<<<grid,block,0, stream >>>(
			nElement, //to let the nummous
			w,h,channel,filter_size,
			input1_b_stride,input1_c_stride,input1_h_stride,input1_w_stride,
			input2_b_stride,input2_c_stride,input2_h_stride,input2_w_stride,
			input3_b_stride,input3_c_stride,input3_h_stride,input3_w_stride,
            input4_b_stride,input4_c_stride,input4_h_stride,input4_w_stride,

			input1.data<scalar_t>(),input2.data<scalar_t>(),input3.data<scalar_t>(), 
            input4.data<scalar_t>(),
            output.data<scalar_t>()
			);
 					}));

	//			THCudaCheck(cudaGetLastError());
	cudaError_t err = cudaGetLastError();

	if (err != cudaSuccess) {
		printf("gpuerror in BilinearSampler.updateOutput: %s\n", cudaGetErrorString(err));
		//THError("aborting");
		return error;
	}

	error = 0;
	return error;

}

int FilterInterpolationLayer_gpu_backward_kernel(
		cudaStream_t stream,
		const int nElement,
		const int w,    		const int h,    		const int channel,  		const int batch,    		const int filter_size,

		const int input1_b_stride, const int input1_c_stride, const int input1_h_stride, const int input1_w_stride,
		const int input2_b_stride, const int input2_c_stride, const int input2_h_stride, const int input2_w_stride,
		const int input3_b_stride, const int input3_c_stride, const int input3_h_stride, const int input3_w_stride,
        const int input4_b_stride, const int input4_c_stride, const int input4_h_stride, const int input4_w_stride,

		at::Tensor&  input1,        		at::Tensor&  input2,		at::Tensor&  input3,       
        at::Tensor&  input4, 

		at::Tensor&  gradoutput,    		at::Tensor&  gradinput1,  		at::Tensor&  gradinput2,  		at::Tensor&  gradinput3,         
        at::Tensor&  gradinput4
		)
{

	int error = 1 ;

	dim3 grid;
	dim3 block;


	//blockthread = 128;
	//the threadIdx.x is sheduled first, then threadIdx.y, threadIdx.z
	//the three channels are processsed in one kernel
	block  = dim3(BLOCKDIMX,BLOCKDIMY,1);
	grid = dim3( (w + BLOCKDIMX - 1)/ BLOCKDIMX, (h + BLOCKDIMY - 1) / BLOCKDIMY, batch);
    if(BLOCKDIMX != 32 || BLOCKDIMY != 16||DEBUG)
        printf("BLOCKDIMX revised to %d, BLOCKDIMY revised to %d \n", BLOCKDIMX,BLOCKDIMY);

//    cudaMemset((void*)gradinput1, 0, input1_b_stride * batch * sizeof(float));
//    cudaMemset((void*)gradinput2, 0, input2_b_stride * batch * sizeof(float));
//    cudaMemset((void*)gradinput3, 0, input3_b_stride * batch * sizeof(float));

			AT_DISPATCH_FLOATING_TYPES(input1.type(), "DepthFlowProjection_gpu_backward", ([&] {
FilterInterpolationLayer_gpu_backward_kernelfunc <<<grid,block,0, stream>>>(
			nElement, //to let the nummous
			w,h,channel,filter_size,
			input1_b_stride,input1_c_stride,input1_h_stride,input1_w_stride,
			input2_b_stride,input2_c_stride,input2_h_stride,input2_w_stride,
			input3_b_stride,input3_c_stride,input3_h_stride,input3_w_stride,
            input4_b_stride,input4_c_stride,input4_h_stride,input4_w_stride,


			input1.data<scalar_t>(), 			input2.data<scalar_t>(),         input3.data<scalar_t>(),  		
            input4.data<scalar_t>(),	
            gradoutput.data<scalar_t>(),
			gradinput1.data<scalar_t>(), 			gradinput2.data<scalar_t>(),     gradinput3.data<scalar_t>(),           
            gradinput4.data<scalar_t>()
			);
 					}));

	cudaError_t err = cudaGetLastError();

	if (err != cudaSuccess) {
		printf("gpuerror in BilinearSampler.updateGradInput %s\n", cudaGetErrorString(err));
		//THError("aborting");
		return error;
	}

	error = 0;
	return error;

}







// add deformable conv

template <typename scalar_t>
__global__ void FilterInterpolationLayer_gpu_forward_kernelfunc_deforconv(
		const int nElement,
		const int w, 		const int h, 		const int channel, const int filter_size,

		const int input1_b_stride, const int input1_c_stride, const int input1_h_stride, const int input1_w_stride,
		const int input2_b_stride, const int input2_c_stride, const int input2_h_stride, const int input2_w_stride,
		const int input3_b_stride, const int input3_c_stride, const int input3_h_stride, const int input3_w_stride,
        const int input4_b_stride, const int input4_c_stride, const int input4_h_stride, const int input4_w_stride,

		const scalar_t* __restrict__  input1, const scalar_t* __restrict__ input2, const scalar_t* __restrict__  input3, 
        const scalar_t* __restrict__  input4, 
        scalar_t* output

		)
{

	//blockIdx.z : batch index from 0~B-1
	//blockIdx.y : height patch index from ceil(h/16)
	//blockIdx.x : width patch index from ceil(w/32)

	//threadidx.x: width index 0~31
	//threadIdx.y: height index 0~15
	//threadIdx.z: Not used

	//only use one dimensioon of the grid and block
	const int w_i = blockIdx.x * blockDim.x + threadIdx.x;
	const int h_i = blockIdx.y * blockDim.y + threadIdx.y;
	const bool withinXbounds = w_i < w;
	const bool withinYbounds = h_i < h;

	const int batch_i = blockIdx.z;
	const int off = batch_i * input1_b_stride;


	//    __syncthreads();
//	const float fillvalue =0.0f;

	if( withinXbounds && withinYbounds) {

            
        float fx = input2[batch_i * input2_b_stride + 0 * input2_c_stride + h_i * input2_h_stride + w_i  ];
        float fy = input2[batch_i * input2_b_stride + 1 * input2_c_stride + h_i * input2_h_stride + w_i  ];

        // flow 定位到的位置
        float x2 = (float)(w_i) + fx;
        float y2 = (float)(h_i) + fy;


        if(x2 >= 0.0f && y2 >=0.0f && x2 <= (float)(w -1) && y2 <= (float)(h-1)
            && fabs(fx) < (float)(w)/2.0f && fabs(fy) < (float)(h)/2.0f){
            int ix2_L = int(x2) + 1 - (int)(filter_size / 2);
            int iy2_T = int(y2) + 1 - (int)(filter_size / 2);
            int ix2_R = ix2_L + filter_size;
            int iy2_B = iy2_T + filter_size;

            float alpha = x2 - (int)(x2);
            float beta = y2 - (int)(y2);


            //TODO: here is a bug that if the iy2_B or ix2_R gets out of the border, than there is no enough pixels to warp the target one.
            for (int c_i = 0 ; c_i < channel ; c_i++){

                float TL = 0.0f;
                float TR = 0.0f;
                float BL = 0.0f;
                float BR = 0.0f;

                for(int filter_j = iy2_T; filter_j < iy2_B; filter_j++){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for(int filter_i = ix2_L; filter_i < ix2_R; filter_i++){
                        int _filter_i = min(max(0, filter_i),w - 1);
                        
                        // fracY, fracX分别表示偏移之后的坐标点
                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                        // 插值计算偏移后的分像素像素值
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;

                        // 判断是属于TL、TR、BL、BR中的哪类
                        //TL
                        if(fracX <= x2 && fracY <= y2){
                            TL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                                input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ; 
                        }

                        //TR
                        if(fracX > x2 && fracY <= y2){
                            TR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                                input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ;

                        }

                        //BL
                        if(fracX <= x2 && fracY > y2){
                            BL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                                input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ;
                        }

                        //BR
                        if(fracX > x2 && fracY > y2){
                            BR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                                input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ;
                        }

                        
                    }
                }

                output[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i ] =
                            (1-alpha)*(1-beta)*TL +
                            alpha*(1-beta)*TR +
                            (1-alpha)*beta*BL +
                            alpha*beta*BR;

            }
        } else{
            //the warping data is out of range, we fill it with zeros
            for(int c_i = 0 ;  c_i < channel; c_i ++){
                output[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i] = input1[off + c_i* input1_c_stride+ h_i * input1_h_stride + w_i];
            }
        }



        

		
	}
	return ;

}


template <typename scalar_t>
__global__ void FilterInterpolationLayer_gpu_backward_kernelfunc_deforconv(
		const int nElement, 	   const int w, 		const int h, 		const int channel, 	const int filter_size,
		const int input1_b_stride, const int input1_c_stride, const int input1_h_stride, const int input1_w_stride,
		const int input2_b_stride, const int input2_c_stride, const int input2_h_stride, const int input2_w_stride,
		const int input3_b_stride, const int input3_c_stride, const int input3_h_stride, const int input3_w_stride,
        const int input4_b_stride, const int input4_c_stride, const int input4_h_stride, const int input4_w_stride,

		const scalar_t* __restrict__      input1,        		const scalar_t* __restrict__      input2,		const scalar_t* __restrict__      input3,
		const scalar_t* __restrict__      input4,       
        scalar_t* gradoutput,    		scalar_t*  gradinput1,  		scalar_t*  gradinput2,  		
        scalar_t*  gradinput3,      
        scalar_t*  gradinput4
		)
		{
	//blockIdx.z : batch index from 0~B-1
	//blockIdx.y : height patch index from ceil(h/16)
	//blockIdx.x : width patch index from ceil(w/32)

	//threadidx.x: width index 0~31
	//threadIdx.y: height index 0~15
	//threadIdx.z: Not used

	const int w_i = blockIdx.x * blockDim.x + threadIdx.x;
	const int h_i = blockIdx.y * blockDim.y + threadIdx.y;
	const bool withinXbounds = w_i < w;
	const bool withinYbounds = h_i < h;

	const int batch_i = blockIdx.z;
	const int off  = batch_i * input1_b_stride;

	//    __syncthreads();

	if(withinXbounds && withinYbounds){

		float fx = input2[batch_i * input2_b_stride +  0 * input2_c_stride + h_i * input2_h_stride + w_i];
		float fy = input2[batch_i * input2_b_stride +  1 * input2_c_stride + h_i * input2_h_stride + w_i];

		float x2 = float(w_i) + fx;
		float y2 = float(h_i) + fy;

		if(x2 >= 0.0f  && y2 >= 0.0f && x2 <= (float)(w - 1) && y2 <= (float)(h -1)
            && fabs(fx) < (float)(w)/2.0f && fabs(fy) < (float)(h)/2.0f){
			int ix2_L = int(x2) + 1 - (int) (filter_size/2);
			int iy2_T = int(y2) + 1 - (int) (filter_size/2);
			int ix2_R = ix2_L + filter_size;
			int iy2_B = iy2_T + filter_size;


            float alpha = x2 - (int)(x2);
            float beta = y2  - (int)(y2);
			
            for (int c_i = 0 ; c_i < channel; c_i++){

				float gradoutput_value = gradoutput[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i];

                for(int filter_j = iy2_T; filter_j < iy2_B ; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for (int filter_i = ix2_L; filter_i < ix2_R ; filter_i ++){
                        int _filter_i = min(max(0, filter_i), w - 1);

                        // 判断是属于TL、TR、BL、BR的哪一类
                        
                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                        
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;
                        float BiInput = (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                        PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]);
                        // TL
                        if(fracX <= x2 && fracY <= y2){
                            
                            float TL_grad = gradoutput_value * (1-alpha ) * (1-beta);
                            atomicAdd( &gradinput1[off +c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i ],
                                    TL_grad * input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                input3_c_stride + h_i * input3_h_stride + w_i]);

                            atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T ) * filter_size + (filter_i - ix2_L)) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                TL_grad * BiInput);
                        }
                        // TR
                        if(fracX > x2 && fracY <= y2){
                            float TR_grad = gradoutput_value * alpha * ( 1- beta);
                            atomicAdd( &gradinput1[off +c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i ],
                                    TR_grad * input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                input3_c_stride + h_i * input3_h_stride + w_i]);

                            atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T ) * filter_size + (filter_i - ix2_L)) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                TR_grad * BiInput);
                        }
                        // BL
                        if(fracX <= x2 && fracY > y2){
                            
                            float BL_grad = gradoutput_value * ( 1 - alpha ) * beta;
                            atomicAdd( &gradinput1[off +c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i ],
                                    BL_grad * input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                input3_c_stride + h_i * input3_h_stride + w_i]);

                            atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T ) * filter_size + (filter_i - ix2_L)) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                BL_grad * BiInput);                                    
                        }
                        // BR 
                        if(fracX > x2 && fracY > y2){
                            float BR_grad = gradoutput_value * alpha * beta;
                            atomicAdd( &gradinput1[off +c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i ],
                                    BR_grad * input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                input3_c_stride + h_i * input3_h_stride + w_i]);

                            atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T ) * filter_size + (filter_i - ix2_L)) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                BR_grad * BiInput);                                      
                        }

                        /***
			                Step 1: calculate the gradients for input1, i.e. the input image;
			             ***/
                        

                        /***
                            STEP 3: calculate the gradients for input3, i.e. the filter
                        ***/
                        
                    }
                }

            }


            /***
			  Step 2: calculate the gradients for input2, i.e., the optical flow,
			  
			 ***/

            // STEP 2.1: for the x/horizonotal direction.
            float gamma = 1.0f - beta;   // beta = y2 - (int)y2
            float bot_diff = 0.0f;
            for(int c_i =0 ; c_i< channel; c_i ++ ){
                float gradoutput_value = gradoutput[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i];

                float TL = 0.0f;
                float TR = 0.0f;
                float BL = 0.0f;
                float BR = 0.0f;
                for(int filter_j = iy2_T; filter_j < iy2_B; filter_j++){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for(int filter_i = ix2_L; filter_i < ix2_R; filter_i++){
                        int _filter_i = min(max(0, filter_i ), w - 1);

                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                        
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;

                        // TL
                        if(fracX <= x2 && fracY <= y2){
                            // float TL_gamma = - gamma;
                            TL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                    PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
							        input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ;
                        }
                        // TR
                        if(fracX > x2 && fracY <= y2){
                            // float TR_gamma = gamma;
                            TR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                    PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                                    input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                        }
                        // BL
                        if(fracX <= x2 && fracY > y2){
                            // float BL_gamma = - (1 - gamma);
                            BL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                    PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                                    input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                        }
                        // BR 
                        if(fracX > x2 && fracY > y2){
                            // float BR_gamma = 1 - gamma;
                            BR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                    PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                                    input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                        }

                    }

                }

                float temp = 0.0f;
                temp += gamma * (TR - TL);
                temp += (1-gamma) * (BR - BL);
                bot_diff += gradoutput_value * temp;
                
            }
            
            gradinput2[batch_i * input2_b_stride + 0 * input2_c_stride + h_i * input2_h_stride + w_i] = bot_diff;

            
			// STEP 2.2: for the y/vertical direction.
            gamma = 1.0f - alpha;
            bot_diff = 0.0f;
            for(int c_i = 0 ; c_i < channel; c_i ++ ){
                float gradoutput_value = gradoutput[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i];

                float TL = 0.0f;
                float TR = 0.0f;
                float BL = 0.0f;
                float BR = 0.0f;
                for(int filter_j = iy2_T; filter_j < iy2_B; filter_j++){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for(int filter_i = ix2_L; filter_i < ix2_R; filter_i++){
                        int _filter_i = min(max(0, filter_i ), w - 1);

                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                        
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;

                        // TL
                        if(fracX <= x2 && fracY <= y2){
                            // float TL_gamma = - gamma;
                            TL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                    PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
							        input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ;
                        }
                        // TR
                        if(fracX > x2 && fracY <= y2){
                            // float TR_gamma = - (1 - gamma);
                            TR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                    PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                                    input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                        }
                        // BL
                        if(fracX <= x2 && fracY > y2){
                            // float BL_gamma = gamma;
                            BL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                    PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                                    input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                        }
                        // BR 
                        if(fracX > x2 && fracY > y2){
                            // float BR_gamma = 1 - gamma;
                            BR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                    PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]) *
                                    input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                        }

                    }

                }

                float temp = 0.0f;
                temp += gamma * (BL - TL);
                temp += (1.0f - gamma) * ( BR - TR);
                bot_diff += gradoutput_value * temp;

            }

            gradinput2[batch_i * input2_b_stride + 1 * input2_c_stride + h_i * input2_h_stride + w_i]= bot_diff;
            
            /***
                SETP 4: calculate the gradients for input4, i.e. the deconv offset field
            ***/
           /***
                SETP 4.1: Y方向上求导  gradinput4 channel 0-15  共filtersize * filtersize个channel
            ***/
            for(int c_i =0 ; c_i< channel; c_i ++ ){
		    	float gradoutput_value = gradoutput[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i];

                for (int filter_j = iy2_T; filter_j < iy2_B; filter_j++){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for(int filter_i = ix2_L; filter_i < ix2_R; filter_i++){
                        int _filter_i = min(max(0, filter_i ), w - 1);

                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;

                        float BiInput = - (1 - phiX) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + 
                            (1 - phiX) * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] -
                            phiX * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            phiX * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right];

                        // TL
                        if(fracX <= x2 && fracY <= y2){
                            float TL_Krd = (1-alpha) * (1-beta);
                            atomicAdd( & gradinput4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                        input4_c_stride + h_i * input4_h_stride + w_i],
                                gradoutput_value * TL_Krd * BiInput * input3[batch_i * input3_b_stride + 
                                                                        ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i]);
                            
                        }
                        // TR
                        if(fracX > x2 && fracY <= y2){
                            float TR_Krd =  alpha * ( 1- beta);
                            atomicAdd( & gradinput4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                        input4_c_stride + h_i * input4_h_stride + w_i],
                                gradoutput_value * TR_Krd * BiInput * input3[batch_i * input3_b_stride + 
                                                                        ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i]);
                            
                        }
                        // BL
                        if(fracX <= x2 && fracY > y2){
                            float BL_Krd = ( 1 - alpha ) * beta;
                            atomicAdd( & gradinput4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                        input4_c_stride + h_i * input4_h_stride + w_i],
                                gradoutput_value * BL_Krd * BiInput * input3[batch_i * input3_b_stride + 
                                                                        ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i]);
                            
                        }
                        // BR 
                        if(fracX > x2 && fracY > y2){
                            float BR_Krd = alpha * beta;
                            atomicAdd( & gradinput4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                        input4_c_stride + h_i * input4_h_stride + w_i],
                                gradoutput_value * BR_Krd * BiInput * input3[batch_i * input3_b_stride + 
                                                                        ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i]);
                            
                        }
                    }

                }
            
            
            }   // end step 4.1 for(channel)
            /***
                 STEP 4.2 X方向上  gradinput4 channel 16-31  共filtersize * filtersize个channel
            ***/
           for(int c_i =0 ; c_i< channel; c_i ++ ){
				float gradoutput_value = gradoutput[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i];

                for(int filter_j = iy2_T; filter_j < iy2_B; filter_j++){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for(int filter_i = ix2_L; filter_i < ix2_R; filter_i++){
                        int _filter_i = min(max(0, filter_i ), w - 1);

                        float fracY = _filter_j + input4[batch_i * input4_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input4_c_stride + h_i * input4_h_stride + w_i];
                        float fracX = _filter_i + input4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input4_c_stride + h_i * input4_h_stride + w_i];

                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;

                        float BiInput = - (1 - phiY) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + 
                                (1 - phiY) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] -
                                phiY * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] +
                                phiY * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right];

                        // TL
                        if(fracX <= x2 && fracY <= y2){
                            float TL_Krd = (1-alpha) * (1-beta);
                            atomicAdd( & gradinput4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) *
                                                                        input4_c_stride + h_i * input4_h_stride + w_i],
                                gradoutput_value * TL_Krd * BiInput * input3[batch_i * input3_b_stride + 
                                                                        ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i]);
                            
                        }
                        // TR
                        if(fracX > x2 && fracY <= y2){
                            float TR_Krd =  alpha * ( 1- beta);
                            atomicAdd( & gradinput4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) *
                                                                        input4_c_stride + h_i * input4_h_stride + w_i],
                                gradoutput_value * TR_Krd * BiInput * input3[batch_i * input3_b_stride + 
                                                                        ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i]);
                            
                        }
                        // BL
                        if(fracX <= x2 && fracY > y2){
                            float BL_Krd = ( 1 - alpha ) * beta;
                            atomicAdd( & gradinput4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) *
                                                                        input4_c_stride + h_i * input4_h_stride + w_i],
                                gradoutput_value * BL_Krd * BiInput * input3[batch_i * input3_b_stride + 
                                                                        ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i]);
                            
                        }
                        // BR 
                        if(fracX > x2 && fracY > y2){
                            float BR_Krd = alpha * beta;
                            atomicAdd( & gradinput4[batch_i * input4_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) *
                                                                        input4_c_stride + h_i * input4_h_stride + w_i],
                                gradoutput_value * BR_Krd * BiInput * input3[batch_i * input3_b_stride + 
                                                                        ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i]);
                            
                        }
                    }
                }
           }  // end step 4.2 for(channel)

		}
	}
	return ;

}

int FilterInterpolationLayer_gpu_forward_kernel_deforconv(
		cudaStream_t stream,
		const int nElement,
		const int w, 		const int h, 		const int channel, 		const int batch, const  int filter_size,

		const int input1_b_stride, const int input1_c_stride, const int input1_h_stride, const int input1_w_stride,
		const int input2_b_stride, const int input2_c_stride, const int input2_h_stride, const int input2_w_stride,
		const int input3_b_stride, const int input3_c_stride, const int input3_h_stride, const int input3_w_stride,
        const int input4_b_stride, const int input4_c_stride, const int input4_h_stride, const int input4_w_stride,

		at::Tensor&  input1,    		at::Tensor&  input2,    	at::Tensor&  input3, 	
        at::Tensor&  input4,     
        at::Tensor&  output

		)
{
	int error = 1 ;

	dim3 grid;
	dim3 block;


	//		blockthread = 128;
	//the threadIdx.x is sheduled first, then threadIdx.y, threadIdx.z
	//the three channels are processsed in one kernel
	block  = dim3(BLOCKDIMX,BLOCKDIMY,1);
	grid = dim3( (w + BLOCKDIMX - 1)/ BLOCKDIMX, (h + BLOCKDIMY - 1) / BLOCKDIMY, batch);
    if(BLOCKDIMX != 32 || BLOCKDIMY != 16||DEBUG)
        printf("BLOCKDIMX revised to %d, BLOCKDIMY revised to %d \n", BLOCKDIMX,BLOCKDIMY);
	//extract the data of CudaTensor and use kernel to calculate.
		AT_DISPATCH_FLOATING_TYPES(input1.type(), "DepthFlowProjection_gpu_backward", ([&] {
FilterInterpolationLayer_gpu_forward_kernelfunc_deforconv <<<grid,block,0, stream >>>(
			nElement, //to let the nummous
			w,h,channel,filter_size,
			input1_b_stride,input1_c_stride,input1_h_stride,input1_w_stride,
			input2_b_stride,input2_c_stride,input2_h_stride,input2_w_stride,
			input3_b_stride,input3_c_stride,input3_h_stride,input3_w_stride,
            input4_b_stride,input4_c_stride,input4_h_stride,input4_w_stride,

			input1.data<scalar_t>(),input2.data<scalar_t>(),input3.data<scalar_t>(), 
            input4.data<scalar_t>(),
            output.data<scalar_t>()
			);
 					}));

	//			THCudaCheck(cudaGetLastError());
	cudaError_t err = cudaGetLastError();

	if (err != cudaSuccess) {
		printf("gpuerror in BilinearSampler.updateOutput: %s\n", cudaGetErrorString(err));
		//THError("aborting");
		return error;
	}

	error = 0;
	return error;

}

int FilterInterpolationLayer_gpu_backward_kernel_deforconv(
		cudaStream_t stream,
		const int nElement,
		const int w,    		const int h,    		const int channel,  		const int batch,    		const int filter_size,

		const int input1_b_stride, const int input1_c_stride, const int input1_h_stride, const int input1_w_stride,
		const int input2_b_stride, const int input2_c_stride, const int input2_h_stride, const int input2_w_stride,
		const int input3_b_stride, const int input3_c_stride, const int input3_h_stride, const int input3_w_stride,
        const int input4_b_stride, const int input4_c_stride, const int input4_h_stride, const int input4_w_stride,

		at::Tensor&  input1,        		at::Tensor&  input2,		at::Tensor&  input3,       
        at::Tensor&  input4, 

		at::Tensor&  gradoutput,    		at::Tensor&  gradinput1,  		at::Tensor&  gradinput2,  		at::Tensor&  gradinput3,         
        at::Tensor&  gradinput4
		)
{

	int error = 1 ;

	dim3 grid;
	dim3 block;


	//blockthread = 128;
	//the threadIdx.x is sheduled first, then threadIdx.y, threadIdx.z
	//the three channels are processsed in one kernel
	block  = dim3(BLOCKDIMX,BLOCKDIMY,1);
	grid = dim3( (w + BLOCKDIMX - 1)/ BLOCKDIMX, (h + BLOCKDIMY - 1) / BLOCKDIMY, batch);
    if(BLOCKDIMX != 32 || BLOCKDIMY != 16||DEBUG)
        printf("BLOCKDIMX revised to %d, BLOCKDIMY revised to %d \n", BLOCKDIMX,BLOCKDIMY);

//    cudaMemset((void*)gradinput1, 0, input1_b_stride * batch * sizeof(float));
//    cudaMemset((void*)gradinput2, 0, input2_b_stride * batch * sizeof(float));
//    cudaMemset((void*)gradinput3, 0, input3_b_stride * batch * sizeof(float));

			AT_DISPATCH_FLOATING_TYPES(input1.type(), "DepthFlowProjection_gpu_backward", ([&] {
FilterInterpolationLayer_gpu_backward_kernelfunc_deforconv <<<grid,block,0, stream>>>(
			nElement, //to let the nummous
			w,h,channel,filter_size,
			input1_b_stride,input1_c_stride,input1_h_stride,input1_w_stride,
			input2_b_stride,input2_c_stride,input2_h_stride,input2_w_stride,
			input3_b_stride,input3_c_stride,input3_h_stride,input3_w_stride,
            input4_b_stride,input4_c_stride,input4_h_stride,input4_w_stride,


			input1.data<scalar_t>(), 			input2.data<scalar_t>(),         input3.data<scalar_t>(),  		
            input4.data<scalar_t>(),	
            gradoutput.data<scalar_t>(),
			gradinput1.data<scalar_t>(), 			gradinput2.data<scalar_t>(),     gradinput3.data<scalar_t>(),           
            gradinput4.data<scalar_t>()
			);
 					}));

	cudaError_t err = cudaGetLastError();

	if (err != cudaSuccess) {
		printf("gpuerror in BilinearSampler.updateGradInput %s\n", cudaGetErrorString(err));
		//THError("aborting");
		return error;
	}

	error = 0;
	return error;

}





//    add deformable conv with no kernel filter

template <typename scalar_t>
__global__ void FilterInterpolationLayer_gpu_forward_kernelfunc_nofilterwithdeforconv(
		const int nElement,
		const int w, 		const int h, 		const int channel, const int filter_size,

		const int input1_b_stride, const int input1_c_stride, const int input1_h_stride, const int input1_w_stride,
		const int input2_b_stride, const int input2_c_stride, const int input2_h_stride, const int input2_w_stride,
		const int input3_b_stride, const int input3_c_stride, const int input3_h_stride, const int input3_w_stride,

		const scalar_t* __restrict__  input1, const scalar_t* __restrict__ input2, const scalar_t* __restrict__  input3, 
        scalar_t* output

		)
{

	//only use one dimensioon of the grid and block
	const int w_i = blockIdx.x * blockDim.x + threadIdx.x;
	const int h_i = blockIdx.y * blockDim.y + threadIdx.y;
	const bool withinXbounds = w_i < w;
	const bool withinYbounds = h_i < h;

	const int batch_i = blockIdx.z;
	const int off = batch_i * input1_b_stride;


	//    __syncthreads();
//	const float fillvalue =0.0f;

	if( withinXbounds && withinYbounds) {

		float fx = input2[batch_i * input2_b_stride + 0 * input2_c_stride + h_i * input2_h_stride + w_i  ];
		float fy = input2[batch_i * input2_b_stride + 1 * input2_c_stride + h_i * input2_h_stride + w_i  ];

		float x2 = (float)(w_i) + fx;
		float y2 = (float)(h_i) + fy;


		if(x2 >= 0.0f && y2 >=0.0f && x2 <= (float)(w -1) && y2 <= (float)(h-1)
            && fabs(fx) < (float)(w)/2.0f && fabs(fy) < (float)(h)/2.0f){
			int ix2_L = int(x2) + 1 - (int)(filter_size / 2);
			int iy2_T = int(y2) + 1 - (int)(filter_size / 2);
			int ix2_R = ix2_L + filter_size;
			int iy2_B = iy2_T + filter_size;

            float alpha = x2 - (int)(x2);
            float beta = y2 - (int)(y2);


			//TODO: here is a bug that if the iy2_B or ix2_R gets out of the border, than there is no enough pixels to warp the target one.
			for (int c_i = 0 ; c_i < channel ; c_i++){

                float TL = 0.0f;
                float TR = 0.0f;
                float BL = 0.0f;
                float BR = 0.0f;

                for(int filter_j = iy2_T; filter_j < iy2_B; filter_j++){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for(int filter_i = ix2_L; filter_i < ix2_R; filter_i++){
                        int _filter_i = min(max(0, filter_i),w - 1);
                        
                        // fracY, fracX分别表示偏移之后的坐标点
                        float fracY = _filter_j + input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                        float fracX = _filter_i + input3[batch_i * input3_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input3_c_stride + h_i * input3_h_stride + w_i];
                        // 插值计算偏移后的分像素像素值
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;

                        // 判断是属于TL、TR、BL、BR中的哪类
                        //TL
                        if(fracX <= x2 && fracY <= y2){
                            TL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]); 
                        }

                        //TR
                        if(fracX > x2 && fracY <= y2){
                            TR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]);
 
                        }

                        //BL
                        if(fracX <= x2 && fracY > y2){
                            BL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]);
                        }

                        //BR
                        if(fracX > x2 && fracY > y2){
                            BR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]);
                        }

                        
                    }
                }

                output[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i ] =
                            (1-alpha)*(1-beta)*TL +
							alpha*(1-beta)*TR +
							(1-alpha)*beta*BL +
							alpha*beta*BR;

			}
		} else{
			//the warping data is out of range, we fill it with zeros
			for(int c_i = 0 ;  c_i < channel; c_i ++){
				output[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i] = input1[off + c_i* input1_c_stride+ h_i * input1_h_stride + w_i];
			}
		}
	}
	return ;

}


template <typename scalar_t>
__global__ void FilterInterpolationLayer_gpu_backward_kernelfunc_nofilterwithdeforconv(
		const int nElement, 	   const int w, 		const int h, 		const int channel, 	const int filter_size,
		const int input1_b_stride, const int input1_c_stride, const int input1_h_stride, const int input1_w_stride,
		const int input2_b_stride, const int input2_c_stride, const int input2_h_stride, const int input2_w_stride,
		const int input3_b_stride, const int input3_c_stride, const int input3_h_stride, const int input3_w_stride,

		const scalar_t* __restrict__      input1,        		const scalar_t* __restrict__      input2,		const scalar_t* __restrict__      input3,   
        scalar_t* gradoutput,    		scalar_t*  gradinput1,  		scalar_t*  gradinput2,  		
        scalar_t*  gradinput3
		)
		{

	const int w_i = blockIdx.x * blockDim.x + threadIdx.x;
	const int h_i = blockIdx.y * blockDim.y + threadIdx.y;
	const bool withinXbounds = w_i < w;
	const bool withinYbounds = h_i < h;

	const int batch_i = blockIdx.z;
	const int off  = batch_i * input1_b_stride;

	//    __syncthreads();

	if(withinXbounds && withinYbounds){

		float fx = input2[batch_i * input2_b_stride +  0 * input2_c_stride + h_i * input2_h_stride + w_i];
		float fy = input2[batch_i * input2_b_stride +  1 * input2_c_stride + h_i * input2_h_stride + w_i];

		float x2 = float(w_i) + fx;
		float y2 = float(h_i) + fy;

		if(x2 >= 0.0f  && y2 >= 0.0f && x2 <= (float)(w - 1) && y2 <= (float)(h -1)
            && fabs(fx) < (float)(w)/2.0f && fabs(fy) < (float)(h)/2.0f){
			int ix2_L = int(x2) + 1 - (int) (filter_size/2);
			int iy2_T = int(y2) + 1 - (int) (filter_size/2);
			int ix2_R = ix2_L + filter_size;
			int iy2_B = iy2_T + filter_size;

            float alpha = x2 - (int)(x2);
            float beta = y2  - (int)(y2);
			/***
			  Step 1: calculate the gradients for input1, i.e. the input image;
			 ***/
             /***
                Step 1 and Step 3 are simultaneously computed
             ***/
			for (int c_i = 0 ; c_i < channel; c_i++){

				float gradoutput_value = gradoutput[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i];

                for(int filter_j = iy2_T; filter_j < iy2_B ; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for (int filter_i = ix2_L; filter_i < ix2_R ; filter_i ++){
                        int _filter_i = min(max(0, filter_i), w - 1);

                        // 判断是属于TL、TR、BL、BR的哪一类
                        
                        float fracY = _filter_j + input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                        float fracX = _filter_i + input3[batch_i * input3_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input3_c_stride + h_i * input3_h_stride + w_i];
                        
                        // TL
                        if(fracX <= x2 && fracY <= y2){
                            
                            float TL_grad = gradoutput_value * (1-alpha ) * (1-beta);
                            atomicAdd( &gradinput1[off +c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i ], TL_grad);

                        }
                        // TR
                        if(fracX > x2 && fracY <= y2){
                            float TR_grad = gradoutput_value * alpha * ( 1- beta);
                            atomicAdd( &gradinput1[off +c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i ], TR_grad);

                        }
                        // BL
                        if(fracX <= x2 && fracY > y2){
                            
                            float BL_grad = gradoutput_value * ( 1 - alpha ) * beta;
                            atomicAdd( &gradinput1[off +c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i ], BL_grad);
                                 
                        }
                        // BR 
                        if(fracX > x2 && fracY > y2){
                            float BR_grad = gradoutput_value * alpha * beta;
                            atomicAdd( &gradinput1[off +c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i ], BR_grad);
                                   
                        }

                    }
                }

            }

			/***
			  Step 2: calculate the gradients for input2, i.e., the optical flow,
			  STEP 2.1: for the x/horizonotal direction.
			 ***/
            float gamma  =  1.0f - beta; //iy2_B - y2;   beta = y2  - (int)(y2)
			float bot_diff = 0.0f;
			for(int c_i =0 ; c_i< channel; c_i ++ ){
                float gradoutput_value = gradoutput[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i];

                float TL = 0.0f;
                float TR = 0.0f;
                float BL = 0.0f;
                float BR = 0.0f;
                for(int filter_j = iy2_T; filter_j < iy2_B; filter_j++){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for(int filter_i = ix2_L; filter_i < ix2_R; filter_i++){
                        int _filter_i = min(max(0, filter_i ), w - 1);

                        float fracY = _filter_j + input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                        float fracX = _filter_i + input3[batch_i * input3_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input3_c_stride + h_i * input3_h_stride + w_i];
                        
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;

                        // TL
                        if(fracX <= x2 && fracY <= y2){
                            // float TL_gamma = - gamma;
                            TL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                    PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]);
                        }
                        // TR
                        if(fracX > x2 && fracY <= y2){
                            // float TR_gamma = gamma;
                            TR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                    PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]);
                        }
                        // BL
                        if(fracX <= x2 && fracY > y2){
                            // float BL_gamma = - (1 - gamma);
                            BL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                    PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]);
                        }
                        // BR 
                        if(fracX > x2 && fracY > y2){
                            // float BR_gamma = 1 - gamma;
                            BR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                    PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]);
                        }

                    }

                }

                float temp = 0.0f;
                temp += gamma * (TR - TL);
                temp += (1-gamma) * (BR - BL);
                bot_diff += gradoutput_value * temp;
                
            }
            
            gradinput2[batch_i * input2_b_stride + 0 * input2_c_stride + h_i * input2_h_stride + w_i] = bot_diff;

			/***
			  STEP 2.2: for the y/vertical direction.
			 ***/
            gamma =  1.0f - alpha; //ix2_R -x2;   alpha = x2 - (int)(x2)
			bot_diff = 0.0f;
			            for(int c_i = 0 ; c_i < channel; c_i ++ ){
                float gradoutput_value = gradoutput[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i];

                float TL = 0.0f;
                float TR = 0.0f;
                float BL = 0.0f;
                float BR = 0.0f;
                for(int filter_j = iy2_T; filter_j < iy2_B; filter_j++){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for(int filter_i = ix2_L; filter_i < ix2_R; filter_i++){
                        int _filter_i = min(max(0, filter_i ), w - 1);

                        float fracY = _filter_j + input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                        float fracX = _filter_i + input3[batch_i * input3_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input3_c_stride + h_i * input3_h_stride + w_i];
                        
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;

                        // TL
                        if(fracX <= x2 && fracY <= y2){
                            // float TL_gamma = - gamma;
                            TL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                    PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]);
                        }
                        // TR
                        if(fracX > x2 && fracY <= y2){
                            // float TR_gamma = - (1 - gamma);
                            TR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                    PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]);
                        }
                        // BL
                        if(fracX <= x2 && fracY > y2){
                            // float BL_gamma = gamma;
                            BL += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                    PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]);
                        }
                        // BR 
                        if(fracX > x2 && fracY > y2){
                            // float BR_gamma = 1 - gamma;
                            BR += (PTL * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + PTR * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                                    PBL * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] + PBR * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right]);
                        }

                    }

                }

                float temp = 0.0f;
                temp += gamma * (BL - TL);
                temp += (1.0f - gamma) * ( BR - TR);
                bot_diff += gradoutput_value * temp;

            }

            gradinput2[batch_i * input2_b_stride + 1 * input2_c_stride + h_i * input2_h_stride + w_i]= bot_diff;


            /***
                SETP 4: calculate the gradients for input4, i.e. the deconv offset field
            ***/
           /***
                SETP 4.1: y方向上
            ***/
        //    float bot_diff = 0.0f;
            for(int c_i =0 ; c_i< channel; c_i ++ ){
		    	float gradoutput_value = gradoutput[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i];

                for (int filter_j = iy2_T; filter_j < iy2_B; filter_j++){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for(int filter_i = ix2_L; filter_i < ix2_R; filter_i++){
                        int _filter_i = min(max(0, filter_i ), w - 1);

                        float fracY = _filter_j + input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                        float fracX = _filter_i + input3[batch_i * input3_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input3_c_stride + h_i * input3_h_stride + w_i];
                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;

                        float BiInput = - (1 - phiX) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + 
                            (1 - phiX) * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] -
                            phiX * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] +
                            phiX * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right];

                        // TL
                        if(fracX <= x2 && fracY <= y2){
                            float TL_Krd = (1-alpha) * (1-beta);
                            atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                gradoutput_value * TL_Krd * BiInput);
                            
                        }
                        // TR
                        if(fracX > x2 && fracY <= y2){
                            float TR_Krd =  alpha * ( 1- beta);
                            atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                gradoutput_value * TR_Krd * BiInput);
                            
                        }
                        // BL
                        if(fracX <= x2 && fracY > y2){
                            float BL_Krd = ( 1 - alpha ) * beta;
                            atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                gradoutput_value * BL_Krd * BiInput);
                            
                        }
                        // BR 
                        if(fracX > x2 && fracY > y2){
                            float BR_Krd = alpha * beta;
                            atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                gradoutput_value * BR_Krd * BiInput);
                            
                        }
                    }

                }
            
            
            }   // end step 4.1 for(channel)
                
            /***
                 STEP 4.2 x方向上
            ***/
            for(int c_i =0 ; c_i< channel; c_i ++ ){
				float gradoutput_value = gradoutput[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i];

                for(int filter_j = iy2_T; filter_j < iy2_B; filter_j++){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for(int filter_i = ix2_L; filter_i < ix2_R; filter_i++){
                        int _filter_i = min(max(0, filter_i ), w - 1);

                        float fracY = _filter_j + input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                        float fracX = _filter_i + input3[batch_i * input3_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) * input3_c_stride + h_i * input3_h_stride + w_i];

                        float phiY = fracY - int(fracY);
                        float phiX = fracX - int(fracX);
                        int Top = int(fracY);
                        int Left = int(fracX);
                        int Bottom = Top + 1;
                        int Right = Left + 1;
                        float PTL = (1 - phiX) * (1 - phiY);
                        float PTR = phiX * (1 - phiY);
                        float PBL = (1 - phiX) * phiY;
                        float PBR = phiY * phiX;

                        float BiInput = - (1 - phiY) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Left] + 
                                (1 - phiY) * input1[off + c_i * input1_c_stride + Top * input1_h_stride + Right] -
                                phiY * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Left] +
                                phiY * input1[off + c_i * input1_c_stride + Bottom * input1_h_stride + Right];

                        // TL
                        if(fracX <= x2 && fracY <= y2){
                            float TL_Krd = (1-alpha) * (1-beta);
                            atomicAdd( & gradinput3[batch_i * input3_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                gradoutput_value * TL_Krd * BiInput);
                            
                        }
                        // TR
                        if(fracX > x2 && fracY <= y2){
                            float TR_Krd =  alpha * ( 1- beta);
                            atomicAdd( & gradinput3[batch_i * input3_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                gradoutput_value * TR_Krd * BiInput);
                            
                        }
                        // BL
                        if(fracX <= x2 && fracY > y2){
                            float BL_Krd = ( 1 - alpha ) * beta;
                            atomicAdd( & gradinput3[batch_i * input3_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                gradoutput_value * BL_Krd * BiInput);
                            
                        }
                        // BR 
                        if(fracX > x2 && fracY > y2){
                            float BR_Krd = alpha * beta;
                            atomicAdd( & gradinput3[batch_i * input3_b_stride + (filter_size * filter_size + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                gradoutput_value * BR_Krd * BiInput);
                            
                        }
                    }
                }
           }  // end step 4.2 for(channel)
		}
	}
	return ;

}



int FilterInterpolationLayer_gpu_forward_kernel_nofilterwithdeforconv(
		cudaStream_t stream,
		const int nElement,
		const int w, 		const int h, 		const int channel, 		const int batch, const  int filter_size,

		const int input1_b_stride, const int input1_c_stride, const int input1_h_stride, const int input1_w_stride,
		const int input2_b_stride, const int input2_c_stride, const int input2_h_stride, const int input2_w_stride,
		const int input3_b_stride, const int input3_c_stride, const int input3_h_stride, const int input3_w_stride,

		at::Tensor&  input1,    		at::Tensor&  input2,    	at::Tensor&  input3, 	 
        at::Tensor&  output

		)
{
	int error = 1 ;

	dim3 grid;
	dim3 block;


	//		blockthread = 128;
	//the threadIdx.x is sheduled first, then threadIdx.y, threadIdx.z
	//the three channels are processsed in one kernel
	block  = dim3(BLOCKDIMX,BLOCKDIMY,1);
	grid = dim3( (w + BLOCKDIMX - 1)/ BLOCKDIMX, (h + BLOCKDIMY - 1) / BLOCKDIMY, batch);
    if(BLOCKDIMX != 32 || BLOCKDIMY != 16||DEBUG)
        printf("BLOCKDIMX revised to %d, BLOCKDIMY revised to %d \n", BLOCKDIMX,BLOCKDIMY);
	//extract the data of CudaTensor and use kernel to calculate.
		AT_DISPATCH_FLOATING_TYPES(input1.type(), "DepthFlowProjection_gpu_backward", ([&] {
FilterInterpolationLayer_gpu_forward_kernelfunc_nofilterwithdeforconv <<<grid,block,0, stream >>>(
			nElement, //to let the nummous
			w,h,channel,filter_size,
			input1_b_stride,input1_c_stride,input1_h_stride,input1_w_stride,
			input2_b_stride,input2_c_stride,input2_h_stride,input2_w_stride,
			input3_b_stride,input3_c_stride,input3_h_stride,input3_w_stride,

			input1.data<scalar_t>(),input2.data<scalar_t>(),input3.data<scalar_t>(), 
            output.data<scalar_t>()
			);
 					}));

	//			THCudaCheck(cudaGetLastError());
	cudaError_t err = cudaGetLastError();

	if (err != cudaSuccess) {
		printf("gpuerror in BilinearSampler.updateOutput: %s\n", cudaGetErrorString(err));
		//THError("aborting");
		return error;
	}

	error = 0;
	return error;

}


int FilterInterpolationLayer_gpu_backward_kernel_nofilterwithdeforconv(
		cudaStream_t stream,
		const int nElement,
		const int w,    		const int h,    		const int channel,  		const int batch,    		const int filter_size,

		const int input1_b_stride, const int input1_c_stride, const int input1_h_stride, const int input1_w_stride,
		const int input2_b_stride, const int input2_c_stride, const int input2_h_stride, const int input2_w_stride,
		const int input3_b_stride, const int input3_c_stride, const int input3_h_stride, const int input3_w_stride,

		at::Tensor&  input1,        		at::Tensor&  input2,		at::Tensor&  input3,       

		at::Tensor&  gradoutput,    		at::Tensor&  gradinput1,  		at::Tensor&  gradinput2,  		at::Tensor&  gradinput3
		)
{

	int error = 1 ;

	dim3 grid;
	dim3 block;


	//blockthread = 128;
	//the threadIdx.x is sheduled first, then threadIdx.y, threadIdx.z
	//the three channels are processsed in one kernel
	block  = dim3(BLOCKDIMX,BLOCKDIMY,1);
	grid = dim3( (w + BLOCKDIMX - 1)/ BLOCKDIMX, (h + BLOCKDIMY - 1) / BLOCKDIMY, batch);
    if(BLOCKDIMX != 32 || BLOCKDIMY != 16||DEBUG)
        printf("BLOCKDIMX revised to %d, BLOCKDIMY revised to %d \n", BLOCKDIMX,BLOCKDIMY);

//    cudaMemset((void*)gradinput1, 0, input1_b_stride * batch * sizeof(float));
//    cudaMemset((void*)gradinput2, 0, input2_b_stride * batch * sizeof(float));
//    cudaMemset((void*)gradinput3, 0, input3_b_stride * batch * sizeof(float));

			AT_DISPATCH_FLOATING_TYPES(input1.type(), "DepthFlowProjection_gpu_backward", ([&] {
FilterInterpolationLayer_gpu_backward_kernelfunc_nofilterwithdeforconv <<<grid,block,0, stream>>>(
			nElement, //to let the nummous
			w,h,channel,filter_size,
			input1_b_stride,input1_c_stride,input1_h_stride,input1_w_stride,
			input2_b_stride,input2_c_stride,input2_h_stride,input2_w_stride,
			input3_b_stride,input3_c_stride,input3_h_stride,input3_w_stride,


			input1.data<scalar_t>(), 			input2.data<scalar_t>(),         input3.data<scalar_t>(),  			
            gradoutput.data<scalar_t>(),
			gradinput1.data<scalar_t>(), 			gradinput2.data<scalar_t>(),     gradinput3.data<scalar_t>()
			);
 					}));

	cudaError_t err = cudaGetLastError();

	if (err != cudaSuccess) {
		printf("gpuerror in BilinearSampler.updateGradInput %s\n", cudaGetErrorString(err));
		//THError("aborting");
		return error;
	}

	error = 0;
	return error;

}



//ori version
template <typename scalar_t>
__global__ void FilterInterpolationLayer_gpu_forward_kernelfunc_ori(
		const int nElement,
		const int w, 		const int h, 		const int channel, const int filter_size,

		const int input1_b_stride, const int input1_c_stride, const int input1_h_stride, const int input1_w_stride,
		const int input2_b_stride, const int input2_c_stride, const int input2_h_stride, const int input2_w_stride,
		const int input3_b_stride, const int input3_c_stride, const int input3_h_stride, const int input3_w_stride,

		const scalar_t* __restrict__    input1,    		const scalar_t* __restrict__    input2,    	const scalar_t* __restrict__    input3, 	scalar_t*   output

		)
{

	//blockIdx.z : batch index from 0~B-1
	//blockIdx.y : height patch index from ceil(h/16)
	//blockIdx.x : width patch index from ceil(w/32)

	//threadidx.x: width index 0~31
	//threadIdx.y: height index 0~15
	//threadIdx.z: Not used

	//only use one dimensioon of the grid and block
	const int w_i = blockIdx.x * blockDim.x + threadIdx.x;
	const int h_i = blockIdx.y * blockDim.y + threadIdx.y;
	const bool withinXbounds = w_i < w;
	const bool withinYbounds = h_i < h;

	const int batch_i = blockIdx.z;
	const int off = batch_i * input1_b_stride;


	//    __syncthreads();
//	const float fillvalue =0.0f;

	if( withinXbounds && withinYbounds) {

		float fx = input2[batch_i * input2_b_stride + 0 * input2_c_stride + h_i * input2_h_stride + w_i  ];
		float fy = input2[batch_i * input2_b_stride + 1 * input2_c_stride + h_i * input2_h_stride + w_i  ];

		float x2 = (float)(w_i) + fx;
		float y2 = (float)(h_i) + fy;


		if(x2 >= 0.0f && y2 >=0.0f && x2 <= (float)(w -1) && y2 <= (float)(h-1)
            && fabs(fx) < (float)(w)/2.0f && fabs(fy) < (float)(h)/2.0f){
			int ix2_L = int(x2) + 1 - (int)(filter_size / 2);
			int iy2_T = int(y2) + 1 - (int)(filter_size / 2);
			int ix2_R = ix2_L + filter_size;
			int iy2_B = iy2_T + filter_size;

            float alpha = x2 - (int)(x2);
            float beta = y2 - (int)(y2);


			//TODO: here is a bug that if the iy2_B or ix2_R gets out of the border, than there is no enough pixels to warp the target one.
			for (int c_i = 0 ; c_i < channel ; c_i++){

                float TL = 0.0f;
                for(int filter_j = iy2_T; filter_j <= (int)(y2); filter_j ++){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for( int filter_i = ix2_L; filter_i <= (int) ( x2) ; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i ), w - 1);
                    TL += input1[off + c_i *  input1_c_stride +  _filter_j * input1_h_stride + _filter_i ] *
							input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ;
                    }
                }

                float TR = 0.0f;
                for (int filter_j = iy2_T; filter_j <= (int) (y2); filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                for (int filter_i =  (int) (x2) + 1 ; filter_i < ix2_R; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1
                    TR += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                        input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                }
                }

                float BL = 0.0f;
                for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                for (int filter_i = ix2_L; filter_i <= (int) (x2); filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1
                    BL += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                        input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                }
                }

                float BR = 0.0f;
                for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                for (int filter_i = (int) (x2) + 1; filter_i < ix2_R; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1
                    BR += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                        input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                }
                }

                output[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i ] =
                            (1-alpha)*(1-beta)*TL +
							alpha*(1-beta)*TR +
							(1-alpha)*beta*BL +
							alpha*beta*BR;

//					for( int filter_i = ix2_L; filter_i < ix2_R ; filter_i ++ ){
//						int _filter_i = min(max(0, filter_i),w - 1);
//						output[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i ] +=
//							input1[off + c_i *  input1_c_stride +  _filter_j * input1_h_stride + _filter_i ] *
//							input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] *
////							exp( -(fabs((float) filter_j - y2) + fabs((float) filter_i - x2)) / (float)(filter_size)); // the distance weight
//							exp( -(fabs((float) filter_j - y2) + fabs((float) filter_i - x2)) ); // the distance weight
//
////							if(w_i == 141 && h_i == 316 && c_i == 0 ){
////printf("gpu: %f, %f,%f,%f\n",input1[off + c_i *  input1_c_stride +  _filter_j * input1_h_stride + _filter_i ] ,
////input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i],
////exp( -(fabs((float) filter_j - y2) + fabs((float) filter_i - x2)) / (float)(filter_size)),
////output[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i ]
//// );
////}
//
//					}
//				}
			}
		} else{
			//the warping data is out of range, we fill it with zeros
			for(int c_i = 0 ;  c_i < channel; c_i ++){
				output[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i] = input1[off + c_i* input1_c_stride+ h_i * input1_h_stride + w_i];
			}
		}
	}
	return ;

}


template <typename scalar_t>
__global__ void FilterInterpolationLayer_gpu_backward_kernelfunc_ori(
		const int nElement, 	   const int w, 		const int h, 		const int channel, 	const int filter_size,
		const int input1_b_stride, const int input1_c_stride, const int input1_h_stride, const int input1_w_stride,
		const int input2_b_stride, const int input2_c_stride, const int input2_h_stride, const int input2_w_stride,
		const int input3_b_stride, const int input3_c_stride, const int input3_h_stride, const int input3_w_stride,

		const scalar_t* __restrict__      input1,        		const scalar_t* __restrict__      input2,		const scalar_t* __restrict__      input3,
		scalar_t* gradoutput,    		scalar_t*  gradinput1,  		scalar_t*  gradinput2,  		scalar_t*  gradinput3
		)
		{
	//blockIdx.z : batch index from 0~B-1
	//blockIdx.y : height patch index from ceil(h/16)
	//blockIdx.x : width patch index from ceil(w/32)

	//threadidx.x: width index 0~31
	//threadIdx.y: height index 0~15
	//threadIdx.z: Not used

	const int w_i = blockIdx.x * blockDim.x + threadIdx.x;
	const int h_i = blockIdx.y * blockDim.y + threadIdx.y;
	const bool withinXbounds = w_i < w;
	const bool withinYbounds = h_i < h;

	const int batch_i = blockIdx.z;
	const int off  = batch_i * input1_b_stride;

	//    __syncthreads();

	if(withinXbounds && withinYbounds){

		float fx = input2[batch_i * input2_b_stride +  0 * input2_c_stride + h_i * input2_h_stride + w_i];
		float fy = input2[batch_i * input2_b_stride +  1 * input2_c_stride + h_i * input2_h_stride + w_i];

		float x2 = float(w_i) + fx;
		float y2 = float(h_i) + fy;

		if(x2 >= 0.0f  && y2 >= 0.0f && x2 <= (float)(w - 1) && y2 <= (float)(h -1)
            && fabs(fx) < (float)(w)/2.0f && fabs(fy) < (float)(h)/2.0f){
			int ix2_L = int(x2) + 1 - (int) (filter_size/2);
			int iy2_T = int(y2) + 1 - (int) (filter_size/2);
			int ix2_R = ix2_L + filter_size;
			int iy2_B = iy2_T + filter_size;

            float alpha = x2 - (int)(x2);
            float beta = y2  - (int)(y2);
			/***
			  Step 1: calculate the gradients for input1, i.e. the input image;
			 ***/
            /***
              STEP 3: calculate the gradients for input3, i.e. the filter
             ***/
             /***
                Step 1 and Step 3 are simultaneously computed
             ***/
			for (int c_i = 0 ; c_i < channel; c_i++){

				float gradoutput_value = gradoutput[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i];

                float TL_grad = gradoutput_value * (1-alpha ) * (1-beta);
                for(int filter_j = iy2_T; filter_j <= (int) (y2) ; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for (int filter_i = ix2_L   ; filter_i <= (int)(x2) ; filter_i ++){
                    int _filter_i = min(max(0, filter_i), w - 1);
                    atomicAdd( &gradinput1[off +c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i ],
                                TL_grad * input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                input3_c_stride + h_i * input3_h_stride + w_i]);
                    atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T ) * filter_size + (filter_i - ix2_L)) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                TL_grad * input1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i]);

                    }
                }

                float TR_grad= gradoutput_value * alpha * ( 1- beta);
                for (int filter_j = iy2_T; filter_j <= (int) (y2); filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                for (int filter_i =  (int) (x2) + 1 ; filter_i < ix2_R; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1

                    atomicAdd( &gradinput1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i ],
                                TR_grad * input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                input3_c_stride + h_i * input3_h_stride + w_i]);
                    atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T ) * filter_size + (filter_i - ix2_L)) *
                                                                        input3_c_stride + h_i * input3_h_stride + w_i],
                                TR_grad * input1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i]);

                    }
                    }

                   float BL_grad = gradoutput_value * ( 1 - alpha ) * beta;
                   for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                        int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                        for (int filter_i = ix2_L; filter_i <= (int) (x2); filter_i ++ ){
                            int _filter_i = min(max(0, filter_i),w - 1);// only used for input1

                        atomicAdd( &gradinput1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i ],
                                    BL_grad * input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                    input3_c_stride + h_i * input3_h_stride + w_i]);
                        atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T ) * filter_size + (filter_i - ix2_L)) *
                                                                            input3_c_stride + h_i * input3_h_stride + w_i],
                                    BL_grad * input1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i]);

                    }
                    }

                float BR_grad = gradoutput_value * alpha * beta;
                 for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                    for (int filter_i = (int) (x2) + 1; filter_i < ix2_R; filter_i ++ ){
                        int _filter_i = min(max(0, filter_i),w - 1);// only used for input1
                        atomicAdd( &gradinput1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i ],
                                    BR_grad * input3[batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) *
                                                                    input3_c_stride + h_i * input3_h_stride + w_i]);
                        atomicAdd( & gradinput3[batch_i * input3_b_stride + ((filter_j - iy2_T ) * filter_size + (filter_i - ix2_L)) *
                                                                            input3_c_stride + h_i * input3_h_stride + w_i],
                                    BR_grad * input1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i]);
                        }
                }
//				for ( int filter_j = iy2_T; filter_j < iy2_B ; filter_j ++ ){
//					int _filter_j = min(max(0, filter_j),  h - 1);
//					for( int filter_i = ix2_L; filter_i< ix2_R ; filter_i++){
//						int _filter_i = min(max(0,filter_i), w - 1);
//						atomicAdd( & gradinput1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i],
//								gradoutput_value *
//								input3 [batch_i * input3_b_stride + ((filter_j  - iy2_T) * filter_size + (filter_i - ix2_L))* input3_c_stride + h_i * input3_h_stride + w_i] *
////								exp( -(fabs((float)filter_j - y2) + fabs((float)filter_i - x2))/(float)filter_size)
//                                exp( -(fabs((float)filter_j - y2) + fabs((float)filter_i - x2)))
//
//							 );
//					}
//				}

			}

			/***
			  Step 2: calculate the gradients for input2, i.e., the optical flow,
			  STEP 2.1: for the x/horizonotal direction.
			 ***/
            float gamma  =  1.0f - beta; //iy2_B - y2;
			float bot_diff = 0.0f;
			for(int c_i =0 ; c_i< channel; c_i ++ ){
				float gradoutput_value = gradoutput[off + c_i * input1_c_stride + h_i * input1_h_stride + w_i];

    float TL = 0.0f;
                for(int filter_j = iy2_T; filter_j <= (int)(y2); filter_j ++){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for( int filter_i = ix2_L; filter_i <= (int) ( x2) ; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i ), w - 1);
                    TL += input1[off + c_i *  input1_c_stride +  _filter_j * input1_h_stride + _filter_i ] *
							input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ;
                    }
                }

                float TR = 0.0f;
                for (int filter_j = iy2_T; filter_j <= (int) (y2); filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                for (int filter_i =  (int) (x2) + 1 ; filter_i < ix2_R; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1
                    TR += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                        input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                }
                }

                float BL = 0.0f;
                for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                for (int filter_i = ix2_L; filter_i <= (int) (x2); filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1
                    BL += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                        input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                }
                }

                float BR = 0.0f;
                for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                for (int filter_i = (int) (x2) + 1; filter_i < ix2_R; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1
                    BR += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                        input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                }
                }

	            float temp = 0.0f;
                temp += gamma * (TR - TL);
                temp += (1-gamma) * (BR - BL);
                bot_diff += gradoutput_value * temp;
//				for( int filter_j = iy2_T; filter_j< iy2_B; filter_j++){
//					int _filter_j = min(max(0, filter_j) , h - 1);
//					for( int filter_i = ix2_L; filter_i< ix2_R; filter_i ++){
//						int _filter_i = min(max(0,filter_i), w-1);
//
//						bot_diff +=
//							gradoutput_value *
//							input1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
//							input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L))* input3_c_stride + h_i * input3_h_stride + w_i   ] *
////							exp( - ( fabs((float) filter_j - y2 ) + fabs((float) filter_i - x2))/ (float)filter_size) *
////							((float) filter_i > x2 ? 1.0f : -1.0f) / (float)filter_size;
//                        	exp( - ( fabs((float) filter_j - y2 ) + fabs((float) filter_i - x2))) *
//							((float) filter_i > x2 ? 1.0f : -1.0f);
//					}
//				}
			}
			//the gradients of the x direction/ horizontal direction
			gradinput2[batch_i * input2_b_stride + 0 * input2_c_stride + h_i * input2_h_stride + w_i] = bot_diff;

			/***
			  STEP 2.2: for the x/horizonotal direction.
			 ***/
            gamma =  1.0f - alpha; //ix2_R -x2;
			bot_diff = 0.0f;
			for(int c_i = 0 ; c_i < channel; c_i ++ ){
				float gradoutput_value = gradoutput [ off + c_i * input1_c_stride + h_i * input1_h_stride +w_i];

                float TL = 0.0f;
                for(int filter_j = iy2_T; filter_j <= (int)(y2); filter_j ++){
                    int _filter_j = min(max(0, filter_j), h - 1);
                    for( int filter_i = ix2_L; filter_i <= (int) ( x2) ; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i ), w - 1);
                    TL += input1[off + c_i *  input1_c_stride +  _filter_j * input1_h_stride + _filter_i ] *
							input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i] ;
                    }
                }

                float TR = 0.0f;
                for (int filter_j = iy2_T; filter_j <= (int) (y2); filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                for (int filter_i =  (int) (x2) + 1 ; filter_i < ix2_R; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1
                    TR += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                        input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                }
                }

                float BL = 0.0f;
                for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                for (int filter_i = ix2_L; filter_i <= (int) (x2); filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1
                    BL += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                        input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                }
                }

                float BR = 0.0f;
                for (int filter_j = (int) (y2) + 1; filter_j < iy2_B; filter_j ++ ){
                    int _filter_j = min(max(0, filter_j),h - 1); // only used for input1
                for (int filter_i = (int) (x2) + 1; filter_i < ix2_R; filter_i ++ ){
                    int _filter_i = min(max(0, filter_i),w - 1);// only used for input1
                    BR += input1 [off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
                        input3 [batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i];
                }
                }

                float temp = 0.0f;
                temp += gamma * (BL - TL);
                temp += (1.0f - gamma) * ( BR - TR);
                bot_diff += gradoutput_value * temp;

//				for( int filter_j = iy2_T; filter_j < iy2_B; filter_j ++ ){
//					int _filter_j = min(max(0, filter_j), h - 1);
//					for( int filter_i = ix2_L; filter_i < ix2_R; filter_i ++){
//						int _filter_i = min(max(0, filter_i), w - 1);
//
//						bot_diff +=
//							gradoutput_value *
//							input1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
//							input3 [batch_i * input3_b_stride +((filter_j - iy2_T) * filter_size + ( filter_i - ix2_L)) * input3_c_stride + h_i * input3_h_stride + w_i ] *
////							exp( - (fabs((float) filter_j - y2) + fabs((float) filter_i - x2))/ (float)filter_size  ) *
////							((float) filter_j > y2 ? 1.0f : - 1.0f ) / (float)filter_size;
//							exp( - (fabs((float) filter_j - y2) + fabs((float) filter_i - x2))  ) *
//							((float) filter_j > y2 ? 1.0f : - 1.0f );
//					}
//				}
			}
			gradinput2[batch_i * input2_b_stride + 1 * input2_c_stride + h_i * input2_h_stride + w_i]= bot_diff;
			/***
			  STEP 3: calculate the gradients for input3, i.e. the filter
			 ***/
//			for(int c_i  = 0 ; c_i <channel ; c_i ++ ){
//				float gradoutput_value = gradoutput[ off + c_i * input1_c_stride + h_i * input1_h_stride + w_i ];
//				for( int filter_j=  iy2_T ; filter_j < iy2_B; filter_j ++ ){
//					int _filter_j = min(max(0, filter_j), h -1 );
//					for ( int filter_i  = ix2_L; filter_i < ix2_R; filter_i ++ ){
//						int _filter_i  = min(max(0, filter_i ), w - 1);
//
//						gradinput3 [  batch_i * input3_b_stride + ((filter_j - iy2_T) * filter_size + (filter_i - ix2_L  ) ) * input3_c_stride + h_i * input3_h_stride + w_i] +=
//							gradoutput_value *
//							input1[off + c_i * input1_c_stride + _filter_j * input1_h_stride + _filter_i] *
////							exp( -(fabs((float) filter_j - y2 ) + fabs((float) filter_i - x2))/ (float)filter_size);
//							exp( -(fabs((float) filter_j - y2 ) + fabs((float) filter_i - x2)));
//					}
//				}
//			}
		}
	}
	return ;

}


int FilterInterpolationLayer_gpu_forward_kernel_ori(
		cudaStream_t stream,
		const int nElement,
		const int w, 		const int h, 		const int channel, 		const int batch, const  int filter_size,

		const int input1_b_stride, const int input1_c_stride, const int input1_h_stride, const int input1_w_stride,
		const int input2_b_stride, const int input2_c_stride, const int input2_h_stride, const int input2_w_stride,
		const int input3_b_stride, const int input3_c_stride, const int input3_h_stride, const int input3_w_stride,

		at::Tensor&  input1,    		at::Tensor&  input2,    	at::Tensor&  input3, 	at::Tensor&  output

		)
{
	int error = 1 ;

	dim3 grid;
	dim3 block;


	//		blockthread = 128;
	//the threadIdx.x is sheduled first, then threadIdx.y, threadIdx.z
	//the three channels are processsed in one kernel
	block  = dim3(BLOCKDIMX,BLOCKDIMY,1);
	grid = dim3( (w + BLOCKDIMX - 1)/ BLOCKDIMX, (h + BLOCKDIMY - 1) / BLOCKDIMY, batch);
    if(BLOCKDIMX != 32 || BLOCKDIMY != 16||DEBUG)
        printf("BLOCKDIMX revised to %d, BLOCKDIMY revised to %d \n", BLOCKDIMX,BLOCKDIMY);
	//extract the data of CudaTensor and use kernel to calculate.
		AT_DISPATCH_FLOATING_TYPES(input1.type(), "DepthFlowProjection_gpu_backward", ([&] {
FilterInterpolationLayer_gpu_forward_kernelfunc_ori <<<grid,block,0, stream >>>(
			nElement, //to let the nummous
			w,h,channel,filter_size,
			input1_b_stride,input1_c_stride,input1_h_stride,input1_w_stride,
			input2_b_stride,input2_c_stride,input2_h_stride,input2_w_stride,
			input3_b_stride,input3_c_stride,input3_h_stride,input3_w_stride,

			input1.data<scalar_t>(),input2.data<scalar_t>(),input3.data<scalar_t>(), output.data<scalar_t>()
			);
 					}));

	//			THCudaCheck(cudaGetLastError());
	cudaError_t err = cudaGetLastError();

	if (err != cudaSuccess) {
		printf("gpuerror in BilinearSampler.updateOutput: %s\n", cudaGetErrorString(err));
		//THError("aborting");
		return error;
	}

	error = 0;
	return error;

}

int FilterInterpolationLayer_gpu_backward_kernel_ori(
		cudaStream_t stream,
		const int nElement,
		const int w,    		const int h,    		const int channel,  		const int batch,    		const int filter_size,

		const int input1_b_stride, const int input1_c_stride, const int input1_h_stride, const int input1_w_stride,
		const int input2_b_stride, const int input2_c_stride, const int input2_h_stride, const int input2_w_stride,
		const int input3_b_stride, const int input3_c_stride, const int input3_h_stride, const int input3_w_stride,

		at::Tensor&  input1,        		at::Tensor&  input2,		at::Tensor&  input3,

		at::Tensor&  gradoutput,    		at::Tensor&  gradinput1,  		at::Tensor&  gradinput2,  		at::Tensor&  gradinput3
		)
{

	int error = 1 ;

	dim3 grid;
	dim3 block;


	//blockthread = 128;
	//the threadIdx.x is sheduled first, then threadIdx.y, threadIdx.z
	//the three channels are processsed in one kernel
	block  = dim3(BLOCKDIMX,BLOCKDIMY,1);
	grid = dim3( (w + BLOCKDIMX - 1)/ BLOCKDIMX, (h + BLOCKDIMY - 1) / BLOCKDIMY, batch);
    if(BLOCKDIMX != 32 || BLOCKDIMY != 16||DEBUG)
        printf("BLOCKDIMX revised to %d, BLOCKDIMY revised to %d \n", BLOCKDIMX,BLOCKDIMY);

//    cudaMemset((void*)gradinput1, 0, input1_b_stride * batch * sizeof(float));
//    cudaMemset((void*)gradinput2, 0, input2_b_stride * batch * sizeof(float));
//    cudaMemset((void*)gradinput3, 0, input3_b_stride * batch * sizeof(float));

			AT_DISPATCH_FLOATING_TYPES(input1.type(), "DepthFlowProjection_gpu_backward", ([&] {
FilterInterpolationLayer_gpu_backward_kernelfunc_ori <<<grid,block,0, stream>>>(
			nElement, //to let the nummous
			w,h,channel,filter_size,
			input1_b_stride,input1_c_stride,input1_h_stride,input1_w_stride,
			input2_b_stride,input2_c_stride,input2_h_stride,input2_w_stride,
			input3_b_stride,input3_c_stride,input3_h_stride,input3_w_stride,


			input1.data<scalar_t>(), 			input2.data<scalar_t>(),         input3.data<scalar_t>(),  			gradoutput.data<scalar_t>(),
			gradinput1.data<scalar_t>(), 			gradinput2.data<scalar_t>(),     gradinput3.data<scalar_t>()
			);
 					}));

	cudaError_t err = cudaGetLastError();

	if (err != cudaSuccess) {
		printf("gpuerror in BilinearSampler.updateGradInput %s\n", cudaGetErrorString(err));
		//THError("aborting");
		return error;
	}

	error = 0;
	return error;

}