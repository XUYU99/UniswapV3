import { ethers } from "hardhat";
import { parseEther, parseUnits, Contract } from "ethers";
import {
  formatBytes32String,
  parseBytes32String,
} from "@ethersproject/strings";

import dotenv from "dotenv";
dotenv.config();
import { createTest } from "./createTest";
import { createAndinitPool } from "./createAndinitPool";
import { mintLiquidity } from "./mintLiquidity";
import { addLiquidity } from "./addLiquidity";
import { swapExactInputSingle } from "./swap";
async function TestInit() {
  await createTest();

  // 调用 createAndinitPool 函数
  await createAndinitPool();

  // 调用 mintLiquidity 函数
  await mintLiquidity();
  await addLiquidity(0, 60);
  await addLiquidity(600, 900);

  await swapExactInputSingle();
}

TestInit().catch((err) => {
  console.error("❌ 脚本执行失败:", err);
  process.exit(1);
});
