/*
 * Copyright (C) 2023, Inria
 * GRAPHDECO research group, https://team.inria.fr/graphdeco
 * All rights reserved.
 *
 * This software is free for non-commercial, research and evaluation use 
 * under the terms of the LICENSE.md file.
 *
 * For inquiries contact  george.drettakis@inria.fr
 */

#include <math.h>
#include <torch/extension.h>
#include <cstdio>
#include <sstream>
#include <iostream>
#include <tuple>
#include <stdio.h>
#include <cuda_runtime_api.h>
#include <memory>
#include "cuda_rasterizer/config.h"
#include "cuda_rasterizer/rasterizer.h"
#include <fstream>
#include <string>
#include <functional>

std::function<char*(size_t N)> resizeFunctional(torch::Tensor& t) {
    auto lambda = [&t](size_t N) {
        t.resize_({(long long)N});
		return reinterpret_cast<char*>(t.contiguous().data_ptr());
    };
    return lambda;
}

std::tuple<int, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor>
RasterizeGaussiansCUDA(
	const torch::Tensor& background,
	const torch::Tensor& means3D,
    const torch::Tensor& colors,
    const torch::Tensor& opacity,
	const torch::Tensor& scales,
	const torch::Tensor& rotations,
	const float scale_modifier,
	const torch::Tensor& cov3D_precomp,
	const torch::Tensor& viewmatrix,
	const torch::Tensor& projmatrix,
	const torch::Tensor& projmatrix_raw,
	const float tan_fovx, 
	const float tan_fovy,
	const float kernel_size,
    const int image_height,
    const int image_width,
	const torch::Tensor& sh,
	const int degree,
	const torch::Tensor& campos,
	const bool prefiltered,
	const bool require_coord,
	const bool require_depth,
	const bool debug)
{
  if (means3D.ndimension() != 2 || means3D.size(1) != 3) {
    AT_ERROR("means3D must have dimensions (num_points, 3)");
  }
  
  const int P = means3D.size(0);
  const int H = image_height;
  const int W = image_width;

  auto int_opts = means3D.options().dtype(torch::kInt32);
  auto float_opts = means3D.options().dtype(torch::kFloat32);

  torch::Tensor out_color = torch::full({NUM_CHANNELS, H, W}, 0.0, float_opts);
  torch::Tensor out_depth = torch::full({1, H, W}, 0.0, float_opts);
  torch::Tensor out_mdepth = torch::full({1, H, W}, 0.0, float_opts);
  torch::Tensor out_coord = torch::full({3, H, W}, 0.0, float_opts);
  torch::Tensor out_mcoord = torch::full({3, H, W}, 0.0, float_opts);
  torch::Tensor out_alpha = torch::full({1, H, W}, 0.0, float_opts);
  torch::Tensor out_normal = torch::full({3, H, W}, 0.0, float_opts);
  torch::Tensor radii = torch::full({P}, 0, means3D.options().dtype(torch::kInt32));
  
  torch::Device device(torch::kCUDA);
  torch::TensorOptions options(torch::kByte);
  torch::Tensor geomBuffer = torch::empty({0}, options.device(device));
  torch::Tensor binningBuffer = torch::empty({0}, options.device(device));
  torch::Tensor imgBuffer = torch::empty({0}, options.device(device));
  std::function<char*(size_t)> geomFunc = resizeFunctional(geomBuffer);
  std::function<char*(size_t)> binningFunc = resizeFunctional(binningBuffer);
  std::function<char*(size_t)> imgFunc = resizeFunctional(imgBuffer);
  
  int rendered = 0;
  if(P != 0)
  {
	  int M = 0;
	  if(sh.size(0) != 0)
	  {
		M = sh.size(1);
      }

	  rendered = CudaRasterizer::Rasterizer::forward(
	    geomFunc,
		binningFunc,
		imgFunc,
	    P, degree, M,
		background.contiguous().data<float>(),
		W, H,
		means3D.contiguous().data<float>(),
		sh.contiguous().data_ptr<float>(),
		colors.contiguous().data<float>(), 
		opacity.contiguous().data<float>(), 
		scales.contiguous().data_ptr<float>(),
		scale_modifier,
		rotations.contiguous().data_ptr<float>(),
		cov3D_precomp.contiguous().data<float>(), 
		viewmatrix.contiguous().data<float>(), 
		projmatrix.contiguous().data<float>(),
		campos.contiguous().data<float>(),
		tan_fovx,
		tan_fovy,
		kernel_size,
		prefiltered,
		out_color.contiguous().data<float>(),
		out_coord.contiguous().data<float>(),
		out_mcoord.contiguous().data<float>(),
		out_depth.contiguous().data<float>(),
		out_mdepth.contiguous().data<float>(),
		out_alpha.contiguous().data<float>(),
		out_normal.contiguous().data<float>(),
		radii.contiguous().data<int>(),
		require_coord,
		require_depth,
		debug);
  }
  return std::make_tuple(rendered, out_color, out_coord, out_mcoord, out_alpha, out_normal, out_depth, out_mdepth, radii, geomBuffer, binningBuffer, imgBuffer);
}

std::tuple<torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor>
 RasterizeGaussiansBackwardCUDA(
 	const torch::Tensor& background,
	const torch::Tensor& means3D,
	const torch::Tensor& radii,
    const torch::Tensor& colors,
	const torch::Tensor& scales,
	const torch::Tensor& rotations,
	const float scale_modifier,
	const torch::Tensor& cov3D_precomp,
	const torch::Tensor& viewmatrix,
    const torch::Tensor& projmatrix,
    const torch::Tensor& projmatrix_raw,
	const float tan_fovx,
	const float tan_fovy,
	const float kernel_size,
    const torch::Tensor& dL_dout_color,
	const torch::Tensor& dL_dout_coord,
	const torch::Tensor& dL_dout_mcoord,
	const torch::Tensor& dL_dout_depth,
	const torch::Tensor& dL_dout_mdepth,
	const torch::Tensor& dL_dout_alpha,
	const torch::Tensor& dL_dout_normal,
	const torch::Tensor& normalmap,
	const torch::Tensor& sh,
	const int degree,
	const torch::Tensor& campos,
	const torch::Tensor& geomBuffer,
	const int R,
	const torch::Tensor& binningBuffer,
	const torch::Tensor& imageBuffer,
	const torch::Tensor& alphas,
	const bool require_coord,
	const bool require_depth,
	const bool debug) 
{
  const int P = means3D.size(0);
  const int H = dL_dout_color.size(1);
  const int W = dL_dout_color.size(2);
  
  int M = 0;
  if(sh.size(0) != 0)
  {	
	M = sh.size(1);
  }

  torch::Tensor dL_dmeans3D = torch::zeros({P, 3}, means3D.options());
  torch::Tensor dL_dview_points = torch::zeros({P, 3}, means3D.options());
  torch::Tensor dL_dmeans2D = torch::zeros({P, 3}, means3D.options());
  torch::Tensor dL_dcolors = torch::zeros({P, NUM_CHANNELS}, means3D.options());
  torch::Tensor dL_dts = torch::zeros({P, 1}, means3D.options());
  torch::Tensor dL_dcamera_planes = torch::zeros({P, 6}, means3D.options());
  torch::Tensor dL_dray_planes = torch::zeros({P, 2}, means3D.options());
  torch::Tensor dL_dnormals = torch::zeros({P, 3}, means3D.options());
  torch::Tensor dL_dconic = torch::zeros({P, 2, 2}, means3D.options());
  torch::Tensor dL_dopacity = torch::zeros({P, 1}, means3D.options());
  torch::Tensor dL_dcov3D = torch::zeros({P, 6}, means3D.options());
  torch::Tensor dL_dsh = torch::zeros({P, M, 3}, means3D.options());
  torch::Tensor dL_dscales = torch::zeros({P, 3}, means3D.options());
  torch::Tensor dL_drotations = torch::zeros({P, 4}, means3D.options());
  torch::Tensor dL_dtau = torch::zeros({P,6}, means3D.options());
  
  if(P != 0)
  {  
	  CudaRasterizer::Rasterizer::backward(P, degree, M, R,
	  background.contiguous().data<float>(),
	  W, H, 
	  means3D.contiguous().data<float>(),
	  sh.contiguous().data<float>(),
	  colors.contiguous().data<float>(),
	  alphas.contiguous().data<float>(),
	  scales.data_ptr<float>(),
	  scale_modifier,
	  rotations.data_ptr<float>(),
	  cov3D_precomp.contiguous().data<float>(),
	  viewmatrix.contiguous().data<float>(),
	  projmatrix.contiguous().data<float>(),
      projmatrix_raw.contiguous().data<float>(),
	  campos.contiguous().data<float>(),
	  tan_fovx,
	  tan_fovy,
	  kernel_size,
	  radii.contiguous().data<int>(),
	  normalmap.contiguous().data<float>(),
	  reinterpret_cast<char*>(geomBuffer.contiguous().data_ptr()),
	  reinterpret_cast<char*>(binningBuffer.contiguous().data_ptr()),
	  reinterpret_cast<char*>(imageBuffer.contiguous().data_ptr()),
	  dL_dout_color.contiguous().data<float>(),
	  dL_dout_coord.contiguous().data<float>(),
	  dL_dout_mcoord.contiguous().data<float>(),
	  dL_dout_depth.contiguous().data<float>(),
	  dL_dout_mdepth.contiguous().data<float>(),
	  dL_dout_alpha.contiguous().data<float>(),
	  dL_dout_normal.contiguous().data<float>(),
	  dL_dmeans2D.contiguous().data<float>(),
	  dL_dview_points.contiguous().data<float>(),
	  dL_dconic.contiguous().data<float>(),  
	  dL_dopacity.contiguous().data<float>(),
	  dL_dcolors.contiguous().data<float>(),
	  dL_dts.contiguous().data<float>(),
	  dL_dcamera_planes.contiguous().data<float>(),
	  dL_dray_planes.contiguous().data<float>(),
	  dL_dnormals.contiguous().data<float>(),
	  dL_dmeans3D.contiguous().data<float>(),
	  dL_dcov3D.contiguous().data<float>(),
	  dL_dsh.contiguous().data<float>(),
	  dL_dscales.contiguous().data<float>(),
	  dL_drotations.contiguous().data<float>(),
      dL_dtau.contiguous().data<float>(),
	  require_coord,
	  require_depth,
	  debug);
  }

  return std::make_tuple(dL_dmeans2D, dL_dcolors, dL_dopacity, dL_dmeans3D, dL_dcov3D, dL_dsh, dL_dscales, dL_drotations, dL_dtau);
}

torch::Tensor markVisible(
		torch::Tensor& means3D,
		torch::Tensor& viewmatrix,
		torch::Tensor& projmatrix)
{ 
  const int P = means3D.size(0);
  
  torch::Tensor present = torch::full({P}, false, means3D.options().dtype(at::kBool));
 
  if(P != 0)
  {
	CudaRasterizer::Rasterizer::markVisible(P,
		means3D.contiguous().data<float>(),
		viewmatrix.contiguous().data<float>(),
		projmatrix.contiguous().data<float>(),
		present.contiguous().data<bool>());
  }
  
  return present;
}

std::tuple<int, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor, torch::Tensor>
IntegrateGaussiansToPointsCUDA(
	const torch::Tensor& background,
	const torch::Tensor& points3D,
	const torch::Tensor& means3D,
    const torch::Tensor& colors,
    const torch::Tensor& opacity,
	const torch::Tensor& scales,
	const torch::Tensor& rotations,
	const float scale_modifier,
	const torch::Tensor& cov3D_precomp,
	const torch::Tensor& view2gaussian_precomp,
	const torch::Tensor& viewmatrix,
	const torch::Tensor& projmatrix,
	const float tan_fovx, 
	const float tan_fovy,
	const float kernel_size,
	const torch::Tensor& subpixel_offset,
    const int image_height,
    const int image_width,
	const torch::Tensor& sh,
	const int degree,
	const torch::Tensor& campos,
	const bool prefiltered,
	const bool debug)
{
  if (means3D.ndimension() != 2 || means3D.size(1) != 3) {
    AT_ERROR("means3D must have dimensions (num_points, 3)");
  }
  if (points3D.ndimension() != 2 || points3D.size(1) != 3) {
    AT_ERROR("points3D must have dimensions (num_points, 3)");
  }

  const int PN = points3D.size(0);
  const int P = means3D.size(0);
  const int H = image_height;
  const int W = image_width;

  auto int_opts = means3D.options().dtype(torch::kInt32);
  auto float_opts = means3D.options().dtype(torch::kFloat32);

  torch::Tensor out_color = torch::full({9, H, W}, 0.0, float_opts);
  torch::Tensor accum_alpha = torch::full({1, H, W}, 0.0, float_opts);
  torch::Tensor radii = torch::full({P}, 0, means3D.options().dtype(torch::kInt32));
  torch::Tensor out_alpha_integrated = torch::full({PN}, 1.0, float_opts);
  torch::Tensor out_color_integrated = torch::full({PN, 3}, 0.0, float_opts);
  torch::Tensor out_coordinate2d = torch::full({PN, 2}, 0.0, float_opts);
  torch::Tensor out_sdf = torch::full({PN}, -1000.0, float_opts);
  torch::Tensor invraycov = torch::full({P, 6}, 0.0, float_opts);
  torch::Tensor condition = torch::full({PN}, 0.0, means3D.options().dtype(torch::kBool));
  
  torch::Device device(torch::kCUDA);
  torch::TensorOptions options(torch::kByte);
  torch::Tensor geomBuffer = torch::empty({0}, options.device(device));
  torch::Tensor binningBuffer = torch::empty({0}, options.device(device));
  torch::Tensor imgBuffer = torch::empty({0}, options.device(device));
  torch::Tensor pointBuffer = torch::empty({0}, options.device(device));
  torch::Tensor point_binningBuffer = torch::empty({0}, options.device(device));
  
  std::function<char*(size_t)> geomFunc = resizeFunctional(geomBuffer);
  std::function<char*(size_t)> binningFunc = resizeFunctional(binningBuffer);
  std::function<char*(size_t)> imgFunc = resizeFunctional(imgBuffer);
  std::function<char*(size_t)> pointFunc = resizeFunctional(pointBuffer);
  std::function<char*(size_t)> point_binningFunc = resizeFunctional(point_binningBuffer);
  
//   if (DEBUG_INTEGRATE && PRINT_INTEGRATE_INFO){
// 		printf("IntegrateGaussiansToPointsCUDA\n");
// 		printf("P: %d\n", P);
// 		printf("PN: %d\n", PN);
//   }
  
  int rendered = 0;
  if(P != 0 && PN != 0)
  {
	  int M = 0;
	  if(sh.size(0) != 0)
	  {
		M = sh.size(1);
      }

	  rendered = CudaRasterizer::Rasterizer::integrate(
	    geomFunc,
		binningFunc,
		imgFunc,
		pointFunc,
		point_binningFunc,
	    PN, P, degree, M,
		background.contiguous().data<float>(),
		W, H,
		points3D.contiguous().data<float>(),
		means3D.contiguous().data<float>(),
		sh.contiguous().data_ptr<float>(),
		colors.contiguous().data<float>(), 
		opacity.contiguous().data<float>(), 
		scales.contiguous().data_ptr<float>(),
		scale_modifier,
		rotations.contiguous().data_ptr<float>(),
		cov3D_precomp.contiguous().data<float>(), 
		view2gaussian_precomp.contiguous().data<float>(), 
		viewmatrix.contiguous().data<float>(), 
		projmatrix.contiguous().data<float>(),
		campos.contiguous().data<float>(),
		tan_fovx,
		tan_fovy,
		kernel_size,
		subpixel_offset.contiguous().data<float>(),
		prefiltered,
		out_color.contiguous().data<float>(),
		accum_alpha.contiguous().data<float>(),
		invraycov.contiguous().data<float>(),
		radii.contiguous().data<int>(),
		out_alpha_integrated.contiguous().data<float>(),
		out_color_integrated.contiguous().data<float>(),
		out_coordinate2d.contiguous().data<float>(),
		out_sdf.contiguous().data<float>(),
		condition.contiguous().data<bool>(),
		debug);
  }
  return std::make_tuple(rendered, out_color, out_alpha_integrated, out_color_integrated, out_coordinate2d, out_sdf, radii, geomBuffer, binningBuffer, imgBuffer);
}