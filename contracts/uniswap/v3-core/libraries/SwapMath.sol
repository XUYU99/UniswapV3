// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import "./FullMath.sol";
import "./SqrtPriceMath.sol";
import "hardhat/console.sol";

/// @title Computes the result of a swap within ticks
/// @notice Contains methods for computing the result of a swap within a single tick price range, i.e., a single tick.
library SwapMath {
    /// @notice 在给定 swap 参数的前提下，计算某一小步交换的结果
    /// @dev 如果为 exactIn 模式，则实际输入金额加上手续费不会超过 amountRemaining
    /// @param sqrtRatioCurrentX96 当前池子的 sqrt(price)
    /// @param sqrtRatioTargetX96 当前 tick 区间的目标 sqrt(price)，价格推进不能超过这个值；同时也可用来推导交易方向
    /// @param liquidity 当前 tick 区间内的流动性
    /// @param amountRemaining 剩余待交换的数量（正值表示 exactIn，负值表示 exactOut）
    /// @param feePips 手续费率，单位为百万分之一（如 3000 表示 0.3%）
    /// @return sqrtRatioNextX96 本次交换后的 sqrt(price)，不超过目标价格
    /// @return amountIn 实际支付的 token 数量（token0 或 token1，取决于方向）
    /// @return amountOut 实际收到的 token 数量（token0 或 token1，取决于方向）
    /// @return feeAmount 本次 swap 收取的手续费数量（从输入 token 中扣除）
    function computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    )
        internal
        pure
        returns (
            uint160 sqrtRatioNextX96,
            uint256 amountIn,
            uint256 amountOut,
            uint256 feeAmount
        )
    {
        // 判断交易方向：true 表示 token0 -> token1（价格降低）
        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
        // console.log("SwapMath-computeSwapStep()-zeroForOne:");
        // 判断是 exactIn（输入确定）还是 exactOut（输出确定）
        bool exactIn = amountRemaining >= 0;

        if (exactIn) {
            // 扣除手续费后实际可用于换币的输入金额
            uint256 amountRemainingLessFee = FullMath.mulDiv(
                uint256(amountRemaining),
                1e6 - feePips,
                1e6
            );

            amountIn = zeroForOne
                ? SqrtPriceMath.getAmount0Delta(
                    sqrtRatioTargetX96,
                    sqrtRatioCurrentX96,
                    liquidity,
                    true
                )
                : SqrtPriceMath.getAmount1Delta(
                    sqrtRatioCurrentX96,
                    sqrtRatioTargetX96,
                    liquidity,
                    true
                );

            if (amountRemainingLessFee >= amountIn) {
                sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    amountRemainingLessFee,
                    zeroForOne
                );
            }
        } else {
            // exactOut 模式下，先计算目标价格最大可输出的数量
            amountOut = zeroForOne
                ? SqrtPriceMath.getAmount1Delta(
                    sqrtRatioTargetX96,
                    sqrtRatioCurrentX96,
                    liquidity,
                    false
                )
                : SqrtPriceMath.getAmount0Delta(
                    sqrtRatioCurrentX96,
                    sqrtRatioTargetX96,
                    liquidity,
                    false
                );

            if (uint256(-amountRemaining) >= amountOut) {
                sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    uint256(-amountRemaining),
                    zeroForOne
                );
            }
        }

        // 是否已经推进到了目标价格
        bool max = sqrtRatioTargetX96 == sqrtRatioNextX96;

        // 精算本次 step 实际的输入输出（避免之前的粗算不精确）
        if (zeroForOne) {
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount0Delta(
                    sqrtRatioNextX96,
                    sqrtRatioCurrentX96,
                    liquidity,
                    true
                );
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount1Delta(
                    sqrtRatioNextX96,
                    sqrtRatioCurrentX96,
                    liquidity,
                    false
                );
        } else {
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount1Delta(
                    sqrtRatioCurrentX96,
                    sqrtRatioNextX96,
                    liquidity,
                    true
                );
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount0Delta(
                    sqrtRatioCurrentX96,
                    sqrtRatioNextX96,
                    liquidity,
                    false
                );
        }

        // 若为 exactOut 模式，输出不能超过剩余目标
        if (!exactIn && amountOut > uint256(-amountRemaining)) {
            amountOut = uint256(-amountRemaining);
        }

        // 计算手续费
        if (exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96) {
            // 没推进到目标 tick，说明输入不足，手续费为剩余输入 - 实际 amountIn
            feeAmount = uint256(amountRemaining) - amountIn;
        } else {
            // 正常按比例收取手续费（向上取整）
            feeAmount = FullMath.mulDivRoundingUp(
                amountIn,
                feePips,
                1e6 - feePips
            );
        }
    }
}
