import { ethers } from "hardhat";
import { parseEther, parseUnits, formatUnits, Contract } from "ethers";

import dotenv from "dotenv";
dotenv.config();
import { abi as NFPM_ABI } from "../artifacts/contracts/uniswap/v3-periphery/NonfungiblePositionManager.sol/NonfungiblePositionManager.json";
// 从其他文件中引入已部署的合约地址
import {
  KOKOAddress,
  ACAddress,
  V3FactoryAddress,
  NFTDescriptorAddress,
  PositionDescriptorAddress,
  NonfungiblePositionManagerAddress,
  poolAddress,
} from "./createAndinitPool";

import { TickBitmapTestAddress } from "./createTest";

export async function mintLiquidity() {
  console.log(
    "----------------------------- mint --------------------------------"
  );
  // 1、获取部署者账户,以及已部署合约地址
  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();
  // console.log("Deployer:", deployerAddress);
  // console.log("KOKOAddress:", KOKOAddress);
  // console.log("ACAddress:", ACAddress);
  // console.log("V3FactoryAddress:", V3FactoryAddress);
  // console.log(
  //   "NonfungiblePositionManagerAddress:",
  //   NonfungiblePositionManagerAddress
  // );
  // console.log("poolAddress:", poolAddress);
  // --------------------- 1、获取合约实例 ----------------------
  // 获取 NonfungiblePositionManager 和 pool 合约实例
  const NonfungiblePositionManager = await ethers.getContractAt(
    "NonfungiblePositionManager",
    NonfungiblePositionManagerAddress
  );
  // console.log(
  //   "mintLiquidity-NonfungiblePositionManagerAddress:",
  //   NonfungiblePositionManagerAddress
  // );
  const pool = await ethers.getContractAt("UniswapV3Pool", poolAddress);

  // 获取 ERC20 Token 合约实例
  const KOKO = await ethers.getContractAt("MyERC20", KOKOAddress);
  const AC = await ethers.getContractAt("MyERC20", ACAddress);

  // 设置希望添加的流动性 Token 数量（KOKO: 100个，AC: 500个）
  const amount0Desired = ethers.parseUnits("100.0", 18);
  const amount1Desired = ethers.parseUnits("500", 18);

  // 授权 PositionManager 操作用户的代币（KOKO & AC）
  await KOKO.approve(NonfungiblePositionManagerAddress, amount0Desired);
  await AC.approve(NonfungiblePositionManagerAddress, amount1Desired);
  // 查看余额
  console.log(
    "mint 前: accountA KOKO 币余额 :",
    formatUnits(await KOKO.balanceOf(deployerAddress), 18).toString()
  );
  console.log(
    "mint 前: aaccountA AC币余额 :",
    formatUnits(await AC.balanceOf(deployerAddress), 18).toString()
  );
  // （可选）获取池子合约地址并确认是否已部署
  // const V3Factory = await ethers.getContractAt(
  //   "UniswapV3Factory",
  //   V3FactoryAddress
  // );
  // const poolAddress = await V3Factory.getPool(KOKOAddress, ACAddress, fee);
  // const code = await ethers.provider.getCode(poolAddress);
  // console.log("Pool 合约代码长度:", code.length, code === "0x" ? "❌ 尚未部署池子" : "✅ 已部署");

  // --------------------- 2、mint ----------------------
  // 设置 mint 参数
  const fee = 3000;
  const amount0Min = 0; // slippage下限
  const amount1Min = 0;
  const tickLower = 120; // tick 区间下限 !!! tick 要是 spacing 的倍数
  const tickUpper = 300; // tick 区间上限
  const deadline = Math.floor(Date.now() / 1000) + 60 * 10; // 当前时间 + 10 分钟
  // 调用 mint() 创建流动性头寸并铸造 LP NFT
  const tx = await NonfungiblePositionManager.mint({
    token0: KOKOAddress,
    token1: ACAddress,
    fee,
    tickLower,
    tickUpper,
    amount0Desired,
    amount1Desired,
    amount0Min,
    amount1Min,
    recipient: deployerAddress,
    deadline,
  });

  const receipt = await tx.wait();
  // --------------------- 3、mint 返回信息----------------------
  let tokenId: any, liquidity: any, amount0: any, amount1: any;
  // 解析事件
  const iface = new ethers.Interface(NFPM_ABI);
  if (receipt) {
    for (const log of receipt.logs) {
      try {
        const parsed = iface.parseLog(log);
        if (parsed) {
          if (parsed.name === "IncreaseLiquidity") {
            ({ tokenId, liquidity, amount0, amount1 } = parsed.args);
            console.log("Token ID:", tokenId.toString());
            console.log("Liquidity:", liquidity.toString());
            console.log("amount0:", formatUnits(amount0, 18).toString());
            console.log("amount1:", formatUnits(amount1, 18).toString());
          }
        }
      } catch (e) {
        // 跳过无法解析的日志
        continue;
      }
    }

    // --------------------- 4、查看mint后状态 ----------------------
    // === 1️⃣ 获取 NFT TokenId 持仓信息 ===
    const position = await NonfungiblePositionManager.positions(tokenId);

    console.log(" Position Info:");
    console.log({
      token0: position.token0,
      token1: position.token1,
      fee: position.fee,
      tickLower: position.tickLower,
      tickUpper: position.tickUpper,
      liquidity: position.liquidity.toString(),
      tokensOwed0: position.tokensOwed0.toString(),
      tokensOwed1: position.tokensOwed1.toString(),
    });
    // === 2️⃣ 获取流动池状态信息 ===
    const [liquidity2, slot0] = await Promise.all([
      pool.liquidity(),
      pool.slot0(),
    ]);

    console.log(" Pool State:");
    console.log({
      sqrtPriceX96: slot0.sqrtPriceX96.toString(),
      tick: slot0.tick,
      observationIndex: slot0.observationIndex,
      liquidity: liquidity2.toString(),
    });

    console.log("✅ mintLiquidity successfull.");
    const TickBitmapTest = await ethers.getContractAt(
      "TickBitmapTest",
      TickBitmapTestAddress
    );
    const isInitialized = await TickBitmapTest.isInitialized2(
      tickLower,
      60,
      poolAddress
    );
    console.log("nextInfo:", isInitialized.toString());
    const tickInfoLower = await pool.ticks(tickLower);
    const tickInfoUpper = await pool.ticks(tickUpper);
    if (tickInfoLower.liquidityGross > 0 || tickInfoUpper.liquidityGross > 0) {
      console.log(
        "✅ tick 已成功初始化",
        tickInfoLower.liquidityGross.toString(),
        tickInfoUpper.liquidityGross.toString()
      );
    }
    console.log(
      "mint 后: accountA KOKO 币余额 :",
      formatUnits(await KOKO.balanceOf(deployerAddress), 18).toString()
    );
    console.log(
      "mint 后: accountA AC 币余额 :",
      formatUnits(await AC.balanceOf(deployerAddress), 18).toString()
    );
  }
}
