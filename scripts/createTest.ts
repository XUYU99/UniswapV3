import { ethers } from "hardhat";
import { parseEther, parseUnits, Contract } from "ethers";

import dotenv from "dotenv";
dotenv.config();

export var SqrtPriceMathTestAddress: string,
  TickBitmapTestAddress: string,
  SwapMathTestAddress: string,
  TickMathTestAddress: string,
  TestUniswapV3RouterAddress: string;
export async function createTest() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);
  console.log("-----------create AND init --------------");
  // 实例化 SqrtPriceMathTest
  const SqrtPriceMathTestFactory = await ethers.getContractFactory(
    "SqrtPriceMathTest",
    deployer
  );
  const SqrtPriceMathTest = await SqrtPriceMathTestFactory.deploy();
  await SqrtPriceMathTest.waitForDeployment();
  SqrtPriceMathTestAddress = await SqrtPriceMathTest.getAddress();
  // 实例化 TickBitmapTest
  const TickBitmapTestFactory = await ethers.getContractFactory(
    "TickBitmapTest",
    deployer
  );
  const TickBitmapTest = await TickBitmapTestFactory.deploy();
  await TickBitmapTest.waitForDeployment();
  TickBitmapTestAddress = await TickBitmapTest.getAddress();
  // 实例化 SwapMathTest
  const SwapMathTestFactory = await ethers.getContractFactory(
    "SwapMathTest",
    deployer
  );
  const SwapMathTest = await SwapMathTestFactory.deploy();
  await SwapMathTest.waitForDeployment();
  SwapMathTestAddress = await SwapMathTest.getAddress();

  // 实例化 TickMathTest
  const TickMathTestFactory = await ethers.getContractFactory(
    "TickMathTest",
    deployer
  );
  const TickMathTest = await TickMathTestFactory.deploy();
  await TickMathTest.waitForDeployment();
  TickMathTestAddress = await TickMathTest.getAddress();

  // 实例化 TestUniswapV3Router
  const TestUniswapV3RouterFactory = await ethers.getContractFactory(
    "TestUniswapV3Router",
    deployer
  );
  const TestUniswapV3Router = await TestUniswapV3RouterFactory.deploy();
  await TestUniswapV3Router.waitForDeployment();
  TestUniswapV3RouterAddress = await TestUniswapV3Router.getAddress();

  console.log("✅ TickBitmapTest 地址:", TickBitmapTestAddress);
  console.log("✅ SwapMathTest 地址:", SwapMathTestAddress);
  console.log("✅ TickMathTest 地址:", TickMathTestAddress);
  console.log("✅ SwapMathTest 地址:", SwapMathTestAddress);
  console.log("✅ TestUniswapV3Router 地址:", TestUniswapV3RouterAddress);
}
