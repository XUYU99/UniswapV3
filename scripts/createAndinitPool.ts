import { ethers } from "hardhat";
import { parseEther, parseUnits, Contract } from "ethers";
import {
  formatBytes32String,
  parseBytes32String,
} from "@ethersproject/strings";

import dotenv from "dotenv";
dotenv.config();

async function createAndinitPool() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  // 部署两个 ERC20 代币：KOKO 和 AC
  const MyERC20 = await ethers.getContractFactory("MyERC20", deployer);
  const KOKO = await MyERC20.deploy("koko", "KO");
  await KOKO.waitForDeployment();
  const AC = await MyERC20.deploy("ac", "AC");
  await AC.waitForDeployment();
  const KOKOAddress = await KOKO.getAddress();
  const ACAddress = await AC.getAddress();

  console.log(`✅ KOKO Token 地址: ${KOKOAddress}`);
  console.log(`✅ AC Token 地址:   ${ACAddress}`);

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
  const V3FactoryAddress = await V3Factory.getAddress();

  // 部署 NFTDescriptor 库
  const NFTDescriptorFactory = await ethers.getContractFactory(
    "NFTDescriptor",
    deployer
  );
  const NFTDescriptor = await NFTDescriptorFactory.deploy();
  await NFTDescriptor.waitForDeployment();
  const NFTDescriptorAddress = await NFTDescriptor.getAddress();

  // 使用 NFTDescriptor 作为库部署 NonfungibleTokenPositionDescriptor
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
  const PositionDescriptorAddress = await PositionDescriptor.getAddress();

  // 部署 NonfungiblePositionManager
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
  const NonfungiblePositionManagerAddress =
    await NonfungiblePositionManager.getAddress();

  console.log(`✅ KOKO 地址:           ${KOKOAddress}`);
  console.log(`✅ AC 地址:           ${ACAddress}`);
  console.log(`✅ Uniswap V3 Factory:  ${V3FactoryAddress}`);
  console.log(`✅ NFTDescriptor 地址:  ${NFTDescriptorAddress}`);
  console.log(`✅ PositionDescriptor:  ${PositionDescriptorAddress}`);
  console.log(
    `✅ NonfungiblePositionManager:     ${NonfungiblePositionManagerAddress}`
  );

  // ✅ 创建并初始化池（可选）
  const fee = 3000; // 0.3%
  const sqrtPriceX96 = BigInt("79228162514264337593543950336"); // 即 2^96
  // √1 = 1 → 2^96 = 79228162514264337593543950336
  const initPool_Tx = await NonfungiblePositionManager.connect(
    deployer
  ).createAndInitializePoolIfNecessary(
    KOKOAddress,
    ACAddress,
    fee,
    sqrtPriceX96
  );

  const receipt = await initPool_Tx.wait();
  console.log("receipt:", receipt);
  console.log("----------- receipt end --------------");
  const poolAddress = await V3Factory.getPool(KOKOAddress, ACAddress, fee);
  console.log("poolAddress:", poolAddress);
  const pool = await ethers.getContractAt("IUniswapV3Pool", poolAddress);

  if (receipt) {
    for (const log of receipt.logs) {
      try {
        const parsed = pool.interface.parseLog(log);
        // console.log("parsed:", parsed);
        if (parsed) {
          if (parsed.name === "Initialize") {
            console.log("sqrtPriceX96:", parsed.args.sqrtPriceX96.toString());
            console.log("tick:", parsed.args.tick.toString());
          }
        }
      } catch (_) {}
    }
  }

  console.log("✅ Pool created and initialized.");
}

createAndinitPool().catch((err) => {
  console.error("❌ 脚本执行失败:", err);
  process.exit(1);
});
