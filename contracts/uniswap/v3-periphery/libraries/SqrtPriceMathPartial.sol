// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import "contracts/uniswap/v3-core/libraries/FullMath.sol";
import "contracts/uniswap/v3-core/libraries/UnsafeMath.sol";
import "contracts/uniswap/v3-core/libraries/FixedPoint96.sol";

/// @title Functions based on Q64.96 sqrt price and liquidity
/// @notice Exposes two functions from @uniswap/v3-core SqrtPriceMath
/// that use square root of price as a Q64.96 and liquidity to compute deltas
library SqrtPriceMathPartial {
    /// @notice 获取两个价格之间的 token0 差值（amount0 delta）
    /// @dev 计算公式为 liquidity / sqrt(lower) - liquidity / sqrt(upper)，
    /// 即 liquidity * (sqrt(upper) - sqrt(lower)) / (sqrt(upper) * sqrt(lower))
    /// @param sqrtRatioAX96 一个平方根价格
    /// @param sqrtRatioBX96 另一个平方根价格
    /// @param liquidity 可用的流动性数量
    /// @param roundUp 是否向上取整
    /// @return amount0 在指定两个价格之间提供指定流动性所需的 token0 数量

    function getAmount0Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount0) {
        // 保证价格顺序从小到大
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        // numerator1 = liquidity × 2^96（精度提升为 Q128.96）
        uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;

        // numerator2 = √P_upper - √P_lower
        uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;

        require(sqrtRatioAX96 > 0);

        // 最终计算：如果向上取整
        return
            roundUp
                ? UnsafeMath.divRoundingUp(
                    FullMath.mulDivRoundingUp(
                        numerator1,
                        numerator2,
                        sqrtRatioBX96
                    ),
                    sqrtRatioAX96
                ) // 否则普通计算
                : FullMath.mulDiv(numerator1, numerator2, sqrtRatioBX96) /
                    sqrtRatioAX96;
    }

    /// @notice Gets the amount1 delta between two prices
    /// @dev Calculates liquidity * (sqrt(upper) - sqrt(lower))
    /// @param sqrtRatioAX96 A sqrt price
    /// @param sqrtRatioBX96 Another sqrt price
    /// @param liquidity The amount of usable liquidity
    /// @param roundUp Whether to round the amount up, or down
    /// @return amount1 Amount of token1 required to cover a position of size liquidity between the two passed prices
    function getAmount1Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return
            roundUp
                ? FullMath.mulDivRoundingUp(
                    liquidity,
                    sqrtRatioBX96 - sqrtRatioAX96,
                    FixedPoint96.Q96
                )
                : FullMath.mulDiv(
                    liquidity,
                    sqrtRatioBX96 - sqrtRatioAX96,
                    FixedPoint96.Q96
                );
    }
}
