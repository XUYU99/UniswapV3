import { ethers } from "hardhat";
import { parseEther, parseUnits, Contract } from "ethers";
import {
  formatBytes32String,
  parseBytes32String,
} from "@ethersproject/strings";

import dotenv from "dotenv";
import {
  TickBitmapTestAddress,
  SwapMathTestAddress,
  TickMathTestAddress,
} from "./createTest";
dotenv.config();
// export let KOKOAddress = "0x5FbDB2315678afecb367f032d93F642f64180aa3";
// export let ACAddress = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512";
// export let V3FactoryAddress = "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0";
// export let NonfungiblePositionManagerAddress =
//   "0x5fc8d32690cc91d4c39d9d3abcbd16989f875707";
// export let poolAddress: string;
export var KOKOAddress: string,
  ACAddress: string,
  V3FactoryAddress: string,
  NFTDescriptorAddress: string,
  PositionDescriptorAddress: string,
  NonfungiblePositionManagerAddress: string,
  SwapRouterAddress: string;
export var poolAddress: string;

export async function createAndinitPool() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);
  console.log("-----------create AND init --------------");
  // 1、部署 KOKO 和 AC 代币
  const MyERC20 = await ethers.getContractFactory("MyERC20", deployer);
  const KOKO = await MyERC20.deploy("koko", "KO");
  await KOKO.waitForDeployment();
  const AC = await MyERC20.deploy("ac", "AC");
  await AC.waitForDeployment();
  KOKOAddress = await KOKO.getAddress();
  ACAddress = await AC.getAddress();

  const WETHFactory = await ethers.getContractFactory("WETH", deployer);
  const WETH = await WETHFactory.deploy();
  const WETHAddress = await WETH.getAddress();
  console.log(`✅ KOKO Token 地址: ${KOKOAddress}`);
  console.log(`✅ AC Token 地址:   ${ACAddress}`);
  console.log(`✅ WETH 地址:   ${WETHAddress}`);

  // // 部署 Mock WETH 合约
  // const WETHFactory = await ethers.getContractFactory("WETH", deployer);
  // const WETH = await WETHFactory.deploy();
  // await WETH.waitForDeployment();
  // const WETHAddress = await WETH.getAddress();

  // // 部署 Mock USDC 合约
  // const ERC20Mock = await ethers.getContractFactory("ERC20Mock", deployer);
  // const USDC = await ERC20Mock.deploy("MockUSDC", "USDC", 18);
  // await USDC.waitForDeployment();
  // const USDCAddress = await USDC.getAddress();

  // 部署 Uniswap V3 Factory
  const Factory = await ethers.getContractFactory("UniswapV3Factory", deployer);
  const V3Factory = await Factory.deploy();
  await V3Factory.waitForDeployment();
  V3FactoryAddress = await V3Factory.getAddress();

  // 部署 NFTDescriptor 库
  const NFTDescriptorFactory = await ethers.getContractFactory(
    "NFTDescriptor",
    deployer
  );
  const NFTDescriptor = await NFTDescriptorFactory.deploy();
  await NFTDescriptor.waitForDeployment();
  NFTDescriptorAddress = await NFTDescriptor.getAddress();

  // 部署 NonfungibleTokenPositionDescriptor (NFT元数据生成器)：把 LP 的参数变成描述信息（如交易对、tick 区间、手续费等级等），最终生成一段 metadata JSON 的 Base64 编码 URI
  const PositionDescriptorFactory = await ethers.getContractFactory(
    "NonfungibleTokenPositionDescriptor",
    {
      libraries: {
        NFTDescriptor: NFTDescriptorAddress,
      },
      signer: deployer,
    }
  );

  const PositionDescriptor = await PositionDescriptorFactory.deploy(
    KOKOAddress,
    formatBytes32String("ETH")
  );
  await PositionDescriptor.waitForDeployment();
  PositionDescriptorAddress = await PositionDescriptor.getAddress();

  // 部署 NonfungiblePositionManager (管理流动性头寸的主合约)
  const NonfungiblePositionManagerFactory = await ethers.getContractFactory(
    "NonfungiblePositionManager",
    deployer
  );
  const NonfungiblePositionManager =
    await NonfungiblePositionManagerFactory.deploy(
      V3FactoryAddress,
      KOKOAddress,
      PositionDescriptorAddress
    );
  await NonfungiblePositionManager.waitForDeployment();
  NonfungiblePositionManagerAddress =
    await NonfungiblePositionManager.getAddress();

  // 部署 SwapRouter
  const SwapRouterFactory = await ethers.getContractFactory(
    "SwapRouter",
    deployer
  );
  const SwapRouter = await SwapRouterFactory.deploy(
    V3FactoryAddress,
    WETHAddress
  );
  await SwapRouter.waitForDeployment();
  SwapRouterAddress = await SwapRouter.getAddress();

  // 实例化TickBitmap
  // const TickBitmapTestFactory = await ethers.getContractFactory(
  //   "TickBitmapTest",
  //   deployer
  // );
  // const TickBitmapTest = await TickBitmapTestFactory.deploy();
  // await TickBitmapTest.waitForDeployment();
  // TickBitmapTestAddress = await TickBitmapTest.getAddress();

  // const SwapMathTestFactory = await ethers.getContractFactory(
  //   "TickBitmapTest",
  //   deployer
  // );
  // const SwapMathTest = await SwapMathTestFactory.deploy();
  // await SwapMathTest.waitForDeployment();
  // SwapMathTestAddress = await SwapMathTest.getAddress();
  console.log(`✅ Uniswap V3 Factory:  ${V3FactoryAddress}`);
  console.log(`✅ NFTDescriptor 地址:  ${NFTDescriptorAddress}`);
  console.log(`✅ PositionDescriptor:  ${PositionDescriptorAddress}`);
  console.log(
    `✅ NonfungiblePositionManager:     ${NonfungiblePositionManagerAddress}`
  );
  console.log(`✅ SwapRouter 地址:  ${SwapRouterAddress}`);
  // console.log("✅ TickBitmapTest 地址:", TickBitmapTestAddress);
  // console.log("✅ SwapMathTest 地址:", SwapMathTestAddress);
  // ✅ 创建并初始化池

  // 通过 TickMath 对 tick 进行换算
  // const TickMathTestFactory = await ethers.getContractFactory(
  //   "TickMathTest2",
  //   deployer
  // );
  // const TickMathTest = await TickMathTestFactory.deploy();
  // await TickMathTest.waitForDeployment();
  // TickMathTestAddress = await TickMathTest.getAddress();

  // console.log("TickMathTest deployed to:", TickMathTestAddress);
  const TickMathTest = await ethers.getContractAt(
    "TickMathTest",
    TickMathTestAddress
  );
  const sqrtPrice = await TickMathTest.getSqrtRatioAtTick(200);
  console.log("sqrtPrice:", sqrtPrice.toString());

  const fee = 3000; // 0.3%
  const sqrtPriceX96 = BigInt(sqrtPrice); // 200

  const initPool_Tx = await NonfungiblePositionManager.connect(
    deployer
  ).createAndInitializePoolIfNecessary(
    KOKOAddress,
    ACAddress,
    fee,
    sqrtPriceX96
  );

  const receipt = await initPool_Tx.wait();
  poolAddress = await V3Factory.getPool(KOKOAddress, ACAddress, fee);
  console.log(`✅ poolAddress:  ${poolAddress}`);

  // console.log("receipt:", receipt);
  // console.log("----------- receipt end --------------");

  // if (receipt) {
  //   for (const log of receipt.logs) {
  //     try {
  //       const parsed = pool.interface.parseLog(log);
  //       // console.log("parsed:", parsed);
  //       if (parsed) {
  //         if (parsed.name === "Initialize") {
  //           console.log("sqrtPriceX96:", parsed.args.sqrtPriceX96.toString());
  //           console.log("tick:", parsed.args.tick.toString());
  //         }
  //       }
  //     } catch (_) {}
  //   }
  // }

  // const poolFactory = await ethers.getContractFactory("UniswapV3Pool");
  // const localInitCodeHash = ethers.keccak256(poolFactory.bytecode);
  // console.log("🔬 本地计算 init code hash:", localInitCodeHash);
  // console.log("✅ Pool created and initialized.");
}

// createAndinitPool().catch((err) => {
//   console.error("❌ 脚本执行失败:", err);
//   process.exit(1);
// });
