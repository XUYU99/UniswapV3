import { ethers } from "hardhat";
import { parseUnits, formatUnits } from "ethers";
import dotenv from "dotenv";
dotenv.config();

import { abi as SWAP_ROUTER_ABI } from "../artifacts/contracts/uniswap/v3-periphery/SwapRouter.sol/SwapRouter.json";
import { abi as TOKEN_ABI } from "../artifacts/contracts/token/MyERC20.sol/MyERC20.json";
import {
  KOKOAddress,
  ACAddress,
  poolAddress,
  SwapRouterAddress,
} from "./createAndinitPool";
import {
  SqrtPriceMathTestAddress,
  TickBitmapTestAddress,
  SwapMathTestAddress,
  TickMathTestAddress,
  TestUniswapV3RouterAddress,
} from "./createTest";
export async function swapExactInputSingle() {
  console.log(
    "----------------------------- swap --------------------------------"
  );
  const [deployer, account2] = await ethers.getSigners();
  const account2Address = await account2.getAddress();
  console.log("account2 Address:", account2Address);
  // 给 account2 发送一些 KOKO 代币

  const KOKO = await ethers.getContractAt("MyERC20", KOKOAddress);
  const AC = await ethers.getContractAt("MyERC20", ACAddress);
  let account2KOKOBalance = await KOKO.balanceOf(account2Address);
  let account2ACBalance = await AC.balanceOf(account2Address);

  console.log(
    "mint token前，account2 KOKO 余额:",
    formatUnits(account2KOKOBalance, 18).toString()
  );
  console.log("mint token前，account2 AC 余额:", formatUnits(0, 18).toString());
  const mintKOKOTokenTx = await KOKO.mint(account2Address, 2000);
  const mintACTokenTx = await AC.mint(account2Address, 1000);
  //   const mintTokenReceipt = await mintTokenTx.wait();
  //   const iface = new ethers.Interface(TOKEN_ABI);

  //   let from: any, to: any, value: any;
  //   if (mintTokenReceipt) {
  //     for (const log of mintTokenReceipt.logs) {
  //       try {
  //         const parsed = iface.parseLog(log);
  //         if (parsed) {
  //           if (parsed.name === "Transfer") {
  //             ({ from, to, value } = parsed.args);
  //             console.log("from:", from.toString());
  //             console.log("to:", to.toString());
  //             console.log("value:", value.toString());
  //           }
  //         }
  //       } catch (e) {
  //         // 跳过无法解析的日志
  //         continue;
  //       }
  //     }
  //   }

  // 检查 account2 的 KOKO 余额
  account2KOKOBalance = await KOKO.balanceOf(account2Address);
  console.log(
    "account2 KOKO 余额:",
    formatUnits(account2KOKOBalance, 18).toString()
  );
  account2ACBalance = await AC.balanceOf(account2Address);
  console.log(
    "account2 AC 余额:",
    formatUnits(account2ACBalance, 18).toString()
  );
  // 先授权给 SwapRouter
  const amountIn = parseUnits("6", 18); // 输入60个 KOKO
  const approveAmount = parseUnits("100", 18); // 输出0个 AC
  const approveTx1 = await KOKO.connect(account2).approve(
    SwapRouterAddress,
    approveAmount
  );
  const approveTx2 = await AC.connect(account2).approve(
    SwapRouterAddress,
    approveAmount
  );
  await approveTx1.wait();
  await approveTx2.wait();
  const allowance = await KOKO.allowance(account2Address, SwapRouterAddress);
  console.log("Allowance:", allowance.toString());
  console.log("✅ Token approved");
  // 找到 pool 实例
  const pool = await ethers.getContractAt("UniswapV3Pool", poolAddress);
  // 找 next tick
  const TickBitmapTest = await ethers.getContractAt(
    "TickBitmapTest",
    TickBitmapTestAddress
  );
  //   const flipTick1 = await TickBitmapTest.flipTick(-300);
  //   const flipTick2 = await TickBitmapTest.flipTick(300);
  //   const flipTick3 = await TickBitmapTest.flipTick(600);
  //   const flipTick4 = await TickBitmapTest.flipTick(900);
  const tickPosition = await TickBitmapTest.position(200);
  console.log("tickPosition:", tickPosition.wordPos.toString());
  const tickArray = await pool.tickBitmap(tickPosition.wordPos);
  const nextInfo = await TickBitmapTest.nextInitializedTickWithinOneWord2(
    tickArray,
    200,
    60,
    true
  );
  console.log("nextInfo22:", nextInfo.toString());
  // 数据转成 sqrit
  const TickMathTest = await ethers.getContractAt(
    "TickMathTest",
    TickMathTestAddress
  );
  const sqcur = await TickMathTest.getSqrtRatioAtTick(200);

  const sqnext = await TickMathTest.getSqrtRatioAtTick(nextInfo.next);
  console.log("sqcur:", sqcur.toString());
  console.log("sqnext:", sqnext.toString());
  // 计算 swap step
  const SwapMathTest = await ethers.getContractAt(
    "SwapMathTest",
    SwapMathTestAddress
  );

  // 查看 pool 信息
  const slot0 = await pool.slot0();
  const fee = await pool.fee();
  const liquidity = await pool.liquidity();
  const tickBitmap = await pool.tickBitmap(0); // Pass a valid BigNumberish argument, e.g., 0
  console.log("查看pool信息");
  console.log("pool-slot0-sqrtPriceX96:", slot0.sqrtPriceX96.toString());
  console.log("pool-slot0-tick:", slot0.tick.toString());
  console.log("pool-fee:", fee.toString());
  console.log("pool-liquidity:", liquidity.toString());
  console.log("pool-tickBitmap:", tickBitmap.toString());
  const amountRemaining = parseUnits("6", 18); // Example value for amountRemaining
  const feePips = 3000; // Example value for feePips

  // SqrtPriceMathTest amount0
  const SqrtPriceMathTest = await ethers.getContractAt(
    "SqrtPriceMathTest",
    SqrtPriceMathTestAddress
  );
  const sqrtRatioAX96 = sqcur;
  const sqrtRatioBX96 = sqnext;
  const liquidity22 = liquidity;
  const roundUp = true;
  const Amount0Delta = await SqrtPriceMathTest.getAmount0Delta(
    sqrtRatioAX96,
    sqrtRatioBX96,
    liquidity22,
    roundUp
  );
  console.log("Amount0Delta:", Amount0Delta.toString());
  const amountRemainingLessFee = "5982000000000000000";
  const sqrtRatioNext222 = await SqrtPriceMathTest.getNextSqrtPriceFromInput(
    slot0.sqrtPriceX96,
    liquidity,
    amountRemainingLessFee,
    true
  );
  console.log("sqrtRatioNext222:", sqrtRatioNext222.toString());
  // 执行 computeSwapStep
  console.log("计算 Swap Step");
  const swapInfo = await SwapMathTest.computeSwapStep(
    slot0.sqrtPriceX96,
    sqnext,
    liquidity,
    amountRemaining,
    feePips
  );

  console.log("swapInfo:", swapInfo.toString());

  console.log("swap 333");
  // 获取 SwapRouter 合约实例
  const SwapRouter = await ethers.getContractAt(
    "SwapRouter",
    SwapRouterAddress
  );
  // swap 前 查看余额
  const account2KOKOBalanceBefore = await KOKO.balanceOf(account2Address);
  const account2ACBalanceBefore = await AC.balanceOf(account2Address);
  console.log("swap 前： accountA KOKO 币余额 :", account2KOKOBalanceBefore);
  console.log("swap 前： accountA AC 币余额 :", account2ACBalanceBefore);

  const deadline = Math.floor(Date.now() / 1000) + 60 * 10;
  const params = {
    tokenIn: KOKOAddress,
    tokenOut: ACAddress,
    fee: 3000,
    recipient: account2Address,
    deadline,
    amountIn,
    amountOutMinimum: 0, // 可以设 slippage 保护
    sqrtPriceLimitX96: 0,
  };
  // 执行 swap
  const tx = await SwapRouter.connect(account2).exactInputSingle(params);

  //   // 执行 test  的 swap

  //   const testSwapRouter = await ethers.getContractAt(
  //     "TestUniswapV3Router",
  //     TestUniswapV3RouterAddress,
  //     account2
  //   );
  //   const testSwapRouterTx = await testSwapRouter.swapForExact1Multi(
  //     account2Address,
  //     KOKOAddress,
  //     ACAddress,
  //     600000
  //   );
  //   console.log("testSwapRouterTx:", testSwapRouterTx);

  //   const testSwapRouterReceipt = await testSwapRouterTx.wait();

  console.log("✅ Swap complete");
  const account2KOKOBalanceAfter = await KOKO.balanceOf(account2Address);
  const account2ACBalanceAfter = await AC.balanceOf(account2Address);
  console.log("swap 后： accountA KOKO 币余额 :", account2KOKOBalanceAfter);
  console.log("swap 后： accountA AC 币余额 :", account2ACBalanceAfter);
  const amountIn2 = account2KOKOBalanceBefore - account2KOKOBalanceAfter;
  console.log("swap 后： accountA swap 花费的 KOKO 币数量 :", amountIn2);
  const amountOut = account2ACBalanceAfter - account2ACBalanceBefore;
  console.log("swap 后： accountA swap 得到的 AC 币数量 :", amountOut);

  // 补码形式的 uint256
  const raw =
    "115792089237316195423570985008687907853269984665640564039451483008101348376904";
  const signed = uint256ToInt256(raw);

  console.log("amountout:", signed.toString());
}
function uint256ToInt256(value: string | bigint): bigint {
  const u = typeof value === "string" ? BigInt(value) : value;
  const UINT256_MAX = 2n ** 256n;
  const INT256_MAX = 2n ** 255n;

  return u >= INT256_MAX ? u - UINT256_MAX : u;
}
