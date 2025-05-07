import { ethers } from "hardhat";
import { parseEther, parseUnits, Contract } from "ethers";
import {
  formatBytes32String,
  parseBytes32String,
} from "@ethersproject/strings";

import dotenv from "dotenv";
dotenv.config();

import { createAndinitPool } from "./createAndinitPool";
import { mintLiquidity } from "./mintLiquidity";

async function TestInit() {
  const [deployer] = await ethers.getSigners();

  // 调用 createAndinitPool 函数
  await createAndinitPool();

  // 调用 mintLiquidity 函数
  await mintLiquidity();
}

TestInit().catch((err) => {
  console.error("❌ 脚本执行失败:", err);
  process.exit(1);
});
