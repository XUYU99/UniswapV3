import { ethers } from "hardhat";
import { parseEther, parseUnits, Contract } from "ethers";
import {
  formatBytes32String,
  parseBytes32String,
} from "@ethersproject/strings";

import dotenv from "dotenv";
dotenv.config();

async function mintLiquidity() {
  const [deployer] = await ethers.getSigners();
  const deployerAddress = await deployer.getAddress();
  console.log("Deployer:", deployerAddress);
  const KOKOAddress = "0x5FbDB2315678afecb367f032d93F642f64180aa3";
  const ACAddress = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512";
  const fee = 3000; // 0.3%
  const amount0Desired = ethers.parseUnits("1.0", 18); // 1 KOKOToken
  const amount1Desired = ethers.parseUnits("500", 18); // 500 ACToken
  const amount0Min = 0;
  const amount1Min = 0;
  const tickLower = -60000;
  const tickUpper = 60000;
  const deadline = Math.floor(Date.now() / 1000) + 60 * 10;

  // 获取合约实例（NonfungiblePositionManager）
  const PositionManager = await ethers.getContractAt(
    "NonfungiblePositionManager",
    "0x5fc8d32690cc91d4c39d9d3abcbd16989f875707"
  );
  const PositionManagerAddress = await PositionManager.getAddress();
  console.log("mintLiquidity-PositionManagerAddress:", PositionManagerAddress);
  // 授权 KOKOToken 和 ACToken 给 manager 使用
  const KOKO = await ethers.getContractAt("MyERC20", KOKOAddress);
  const AC = await ethers.getContractAt("MyERC20", ACAddress);

  await KOKO.approve(PositionManagerAddress, amount0Desired);
  await AC.approve(PositionManagerAddress, amount1Desired);

  console.log("✅ Tokens approved.");
  const V3Factory = await ethers.getContractAt(
    "UniswapV3Factory",
    "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0"
  );
  const poolAddress = await V3Factory.getPool(KOKOAddress, ACAddress, fee);
  console.log("poolAddress:", poolAddress);
  const code = await ethers.provider.getCode(poolAddress);
  console.log(
    "Pool 合约代码长度:",
    code.length,
    code === "0x" ? "❌ 尚未部署池子" : "✅ 已部署"
  );
  // 调用 mint()
  const tx = await PositionManager.mint({
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

  if (receipt) {
    for (const log of receipt.logs) {
      try {
        const parsed = PositionManager.interface.parseLog(log);
        console.log("parsed:", parsed);
        if (parsed) {
          if (parsed.name === "Initialize") {
            console.log("sqrtPriceX96:", parsed.args.sqrtPriceX96.toString());
            console.log("tick:", parsed.args.tick.toString());
          }
        }
      } catch (_) {}
    }
  }
  console.log("✅ mintLiquidity successfull.");
}

mintLiquidity().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
