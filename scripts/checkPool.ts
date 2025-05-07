import { ethers } from "ethers";
import dotenv from "dotenv";
dotenv.config();
import { abi as NFPM_ABI } from "../artifacts/contracts/uniswap/v3-periphery/NonfungiblePositionManager.sol/NonfungiblePositionManager.json";
import { abi as POOL_ABI } from "../artifacts/contracts/uniswap/v3-core/UniswapV3Pool.sol/UniswapV3Pool.json";

import {
  KOKOAddress,
  ACAddress,
  V3FactoryAddress,
  NFTDescriptorAddress,
  PositionDescriptorAddress,
  NonfungiblePositionManagerAddress,
  poolAddress,
} from "./createAndinitPool";
// === 配置 ===
const HARDHAT_RPC_URL = process.env.HARDHAT_RPC_URL || "";
const PRIVATE_KEY0 = process.env.PRIVATE_KEY0 || "";
if (!HARDHAT_RPC_URL) {
  throw new Error(
    "HARDHAT_RPC_URL is not defined in the environment variables."
  );
}
const provider = new ethers.JsonRpcProvider(HARDHAT_RPC_URL);
// const NFPM_ADDRESS = "<NonfungiblePositionManager address>";
// const POOL_ADDRESS = "<UniswapV3Pool address>";
console.log("HARDHAT_RPC_URL:", HARDHAT_RPC_URL);
console.log("PRIVATE_KEY0:", PRIVATE_KEY0);
const wallet = new ethers.Wallet(PRIVATE_KEY0, provider);
console.log("111");

const NonfungiblePositionManager = new ethers.Contract(
  NonfungiblePositionManagerAddress,
  NFPM_ABI,
  provider
);
const pool = new ethers.Contract(poolAddress, POOL_ABI, provider);
console.log("222");

// === 1️⃣ 获取 NFT TokenId 持仓信息 ===
export async function getPosition(tokenId: number) {
  const position = await NonfungiblePositionManager.positions(tokenId);

  console.log("✅ Position Info:");
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
}

// === 2️⃣ 获取流动池状态信息 ===
export async function getPoolState() {
  const [liquidity, slot0] = await Promise.all([
    pool.liquidity(),
    pool.slot0(),
  ]);

  console.log("✅ Pool State:");
  console.log({
    sqrtPriceX96: slot0.sqrtPriceX96.toString(),
    tick: slot0.tick,
    observationIndex: slot0.observationIndex,
    liquidity: liquidity.toString(),
  });
}

// === 示例入口 ===
async function main() {
  const tokenId = 1234; // 你mint返回的 NFT ID
  await getPosition(tokenId);
  await getPoolState();
}

// main().catch(console.error);
