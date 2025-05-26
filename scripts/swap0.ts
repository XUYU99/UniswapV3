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
  NonfungiblePositionManagerAddress,
} from "./createAndinitPool";
import {
  SqrtPriceMathTestAddress,
  TickBitmapTestAddress,
  SwapMathTestAddress,
  TickMathTestAddress,
  TestUniswapV3RouterAddress,
  FullMathTestAddress,
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

  const approveAmount = parseUnits("1000", 18); // 输出0个 AC
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

  // 设置 swap 入参 ,想用 160 个 amount0 换 amount1
  const amountIn = parseUnits("160", 18); // 输入60个 KOKO
  // const amountRemaining = parseUnits("160", 18);
  const feePips = 3000;
  // ------------------------------ 验证 swap 步骤-----------------------------
  console.log("--------------- 验证 swap 步骤------------");
  // 查看 pool 信息
  const pool = await ethers.getContractAt("UniswapV3Pool", poolAddress);
  const slot0 = await pool.slot0();
  const TickCur = slot0.tick.toString();
  const fee = await pool.fee();
  const liquidity = await pool.liquidity();
  const tickBitmap = await pool.tickBitmap(0); // Pass a valid BigNumberish argument, e.g., 0
  console.log("查看pool信息");
  console.log("pool-slot0:", slot0.toString());
  console.log("pool-slot0-tick:", TickCur.toString());
  console.log("pool-fee:", fee.toString());
  console.log("pool-liquidity:", liquidity.toString());
  console.log("pool-tickBitmap:", tickBitmap.toString());
  console.log("第一次 Swap Step");
  // 找 next tick
  const TickBitmapTest = await ethers.getContractAt(
    "TickBitmapTest",
    TickBitmapTestAddress
  );
  const tickPosition = await TickBitmapTest.position(TickCur);
  console.log("tickPosition:", tickPosition.wordPos.toString());
  const tickArray = await pool.tickBitmap(tickPosition.wordPos);
  const nextInfo = await TickBitmapTest.nextInitializedTickWithinOneWord2(
    tickArray,
    200,
    60,
    true
  );
  console.log("200 next Tick, isInitialized:", nextInfo.toString());
  // 数据转成 sqrt
  const TickMathTest = await ethers.getContractAt(
    "TickMathTest",
    TickMathTestAddress
  );
  const sqcur = await TickMathTest.getSqrtRatioAtTick(200);

  const sqnext = await TickMathTest.getSqrtRatioAtTick(nextInfo.next);
  console.log("200 tick sqcur:", sqcur.toString());
  console.log("下一个tick 的 sqnext:", sqnext.toString());
  // 计算 swap step
  const SwapMathTest = await ethers.getContractAt(
    "SwapMathTest",
    SwapMathTestAddress
  );

  // 计算 amountIn TC
  const SqrtPriceMathTest = await ethers.getContractAt(
    "SqrtPriceMathTest",
    SqrtPriceMathTestAddress
  );
  const sqrtRatioAX96 = sqcur;
  const sqrtRatioBX96 = sqnext;
  const liquidity22 = liquidity;
  const roundUp = true;
  const Amount0Delta = await SqrtPriceMathTest.getAmount0Delta(
    sqcur,
    sqnext,
    liquidity22,
    roundUp
  );
  console.log(
    "nextTick 到 curTick 的 amountIn TC Amount0Delta:",
    Amount0Delta.toString()
  );
  // const amountRemainingLessFee = "5982000000000000000";
  // const sqrtRatioNext = await SqrtPriceMathTest.getNextSqrtPriceFromInput(
  //   slot0.sqrtPriceX96,
  //   liquidity,
  //   amountRemainingLessFee,
  //   true
  // );
  // console.log(
  //   "扣除手续费后的amountIn 会推动价格到 sqrtRatioNext:",
  //   sqrtRatioNext.toString()
  // );
  // // 因为 sqrtRatioNext 没有达到 下一个tick 的 sqrtRatioTarget，所以需要计算 amountIn , 不然就直接用前面的Amount0Delta
  // const sqrtRatioNextX96 = sqrtRatioNext;
  // const sqrtRatioCurrentX96 = sqcur;
  // const amountIn222 = await SqrtPriceMathTest.getAmount0Delta(
  //   sqrtRatioNextX96,
  //   sqrtRatioCurrentX96,
  //   liquidity,
  //   true
  // );
  // console.log("amountIn:", amountIn222.toString());
  // const amountOut222 = await SqrtPriceMathTest.getAmount1Delta(
  //   sqrtRatioNextX96,
  //   sqrtRatioCurrentX96,
  //   liquidity,
  //   false
  // );
  // console.log("amountOut:", amountOut222.toString());
  // 执行 computeSwapStep

  const swapInfo = await SwapMathTest.computeSwapStep(
    slot0.sqrtPriceX96,
    sqnext,
    liquidity,
    amountIn,
    feePips
  );
  console.log(
    "第一次 swapInfo2 (return sqrtRatioNextX96,amountIn,amountOut,feeAmount) :",
    swapInfo.toString()
  );
  console.log("第二次 Swap Step");
  const liquidity2 = 199710149825819669480855n;
  const sqcur2 = await TickMathTest.getSqrtRatioAtTick(120);
  const nextInfo2 = await TickBitmapTest.nextInitializedTickWithinOneWord2(
    tickArray,
    119,
    60,
    true
  );
  console.log("119 next Tick, isInitialized:", nextInfo2.toString());
  const sqnext2 = await TickMathTest.getSqrtRatioAtTick(nextInfo2.next);
  console.log("119 tick sqcur2:", sqcur2.toString());
  console.log("下一个tick 的 sqnext2:", sqnext2.toString());
  const amountRemaining2 =
    amountIn - (80360763004124708836n + 241807712148820589n);
  console.log(
    "第一次 swap 完成后的 amountRemaining2 :",
    amountRemaining2.toString()
  );
  const amountSubFee2 = (amountRemaining2 * (10n ** 6n - 3000n)) / 10n ** 6n;
  console.log(
    "第一次完成后剩下的 amountSpecifiedRemaining1 扣掉手续费后的 amountSubFee:",
    amountSubFee2.toString()
  );
  const SqUpdate = await SqrtPriceMathTest.getNextSqrtPriceFromInput(
    sqcur2,
    liquidity2,
    amountSubFee2,
    true
  );
  const amount0Step2 = await SqrtPriceMathTest.getAmount0Delta(
    SqUpdate,
    sqcur2,
    liquidity2,
    true
  );
  console.log("amount0Step2 (amountIn):", amount0Step2.toString());
  console.log("第二次 swap 的 SqUpdate:", SqUpdate.toString());
  const swapInfo2 = await SwapMathTest.computeSwapStep(
    sqcur2,
    sqnext2,
    liquidity2,
    amountRemaining2,
    feePips
  );

  console.log(
    "第二次 swapInfo2 (return sqrtRatioNextX96,amountIn,amountOut,feeAmount) :",
    swapInfo2.toString()
  );
  const amountSpecifiedRemaining =
    amountIn - (80360763004124708836n + 241807712148820589n);
  console.log("amountSpecifiedRemaining:", amountSpecifiedRemaining);
  const amountSpecifiedRemaining2 =
    amountSpecifiedRemaining - (79159236995875291163n + 238192287851179412n);
  console.log("amountSpecifiedRemaining2:", amountSpecifiedRemaining2);
  const amountInFinall =
    80360763004124708836n +
    241807712148820589n +
    79159236995875291163n +
    238192287851179412n;
  console.log("amountInFinall:", amountInFinall.toString());
  console.log("--------------- 验证 end ------------");
  // 获取 SwapRouter 合约实例
  const SwapRouter = await ethers.getContractAt(
    "SwapRouter",
    SwapRouterAddress
  );
  // swap 前 查看余额
  const account2KOKOBalanceBefore = await KOKO.balanceOf(account2Address);
  const account2ACBalanceBefore = await AC.balanceOf(account2Address);
  // console.log("swap 前： accountA KOKO 币余额 :", account2KOKOBalanceBefore);
  // console.log("swap 前： accountA AC 币余额 :", account2ACBalanceBefore);

  const deadline = Math.floor(Date.now() / 1000) + 60 * 10;
  const params = {
    tokenIn: KOKOAddress,
    tokenOut: ACAddress,
    fee: feePips,
    recipient: account2Address,
    deadline,
    amountIn,
    amountOutMinimum: 0, // 可以设 slippage 保护
    sqrtPriceLimitX96: 0,
  };
  // 执行 swap
  const tx = await SwapRouter.connect(account2).exactInputSingle(params);

  console.log("✅ Swap complete, swap 后:");
  // 查看 pool 信息
  const slot0_2 = await pool.slot0();
  console.log("查看pool_slot0:", slot0_2.toString());
  console.log("查看pool_slot0-tickCur:", slot0_2.tick.toString());
  const account2KOKOBalanceAfter = await KOKO.balanceOf(account2Address);
  const account2ACBalanceAfter = await AC.balanceOf(account2Address);
  // console.log("swap 后： accountA KOKO 币余额 :", account2KOKOBalanceAfter);
  // console.log("accountA AC 币余额 :", account2ACBalanceAfter);
  const amountIn2 = account2KOKOBalanceBefore - account2KOKOBalanceAfter;
  console.log("saccountA swap 花费的 KOKO 币数量 :", amountIn2);
  const amountOut = account2ACBalanceAfter - account2ACBalanceBefore;
  console.log("accountA swap 得到的 AC 币数量 :", amountOut);
  const NonfungiblePositionManager = await ethers.getContractAt(
    "NonfungiblePositionManager",
    NonfungiblePositionManagerAddress
  );
  const position = await NonfungiblePositionManager.positions(1);
  console.log("Liquidity:", position.liquidity.toString());
  console.log("TokensOwed0:", position.tokensOwed0.toString());
  console.log("TokensOwed1:", position.tokensOwed1.toString());
  // const FullMathTest = await ethers.getContractAt(
  //   "FullMathTest",
  //   FullMathTestAddress
  // );
  // const num1 = await FullMathTest.mulDivRoundingUp(liquidity, 1e6 - 3000, 1e6);
  // console.log("num1:", num1.toString());
}
function uint256ToInt256(value: string | bigint): bigint {
  const u = typeof value === "string" ? BigInt(value) : value;
  const UINT256_MAX = 2n ** 256n;
  const INT256_MAX = 2n ** 255n;

  return u >= INT256_MAX ? u - UINT256_MAX : u;
}
