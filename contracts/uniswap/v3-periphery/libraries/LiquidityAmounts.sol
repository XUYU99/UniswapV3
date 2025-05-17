// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import "contracts/uniswap/v3-core/libraries/FullMath.sol";
import "contracts/uniswap/v3-core/libraries/FixedPoint96.sol";

// import "hardhat/console.sol";

/// @title Liquidity amount functions
/// @notice Provides functions for computing liquidity amounts from token amounts and prices
library LiquidityAmounts {
    /// @notice Downcasts uint256 to uint128
    /// @param x The uint258 to be downcasted
    /// @return y The passed value, downcasted to uint128
    function toUint128(uint256 x) private pure returns (uint128 y) {
        require((y = uint128(x)) == x);
    }

    /// 根据提供的 token0 数量和价格区间，计算可以获得的流动性
    /// 使用公式：流动性 liquidity = amount0 × (sqrt(upper) × sqrt(lower)) / (sqrt(upper) - sqrt(lower))
    /// @param sqrtRatioAX96 tick 边界 A 的平方根价格（Q64.96 格式）
    /// @param sqrtRatioBX96 tick 边界 B 的平方根价格（Q64.96 格式）
    /// @param amount0 提供的 token0 数量
    /// @return liquidity 返回可获得的流动性数量
    function getLiquidityForAmount0(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0
    ) internal pure returns (uint128 liquidity) {
        // 若价格顺序错误，则交换上下边界
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        // intermediate = sqrtA * sqrtB / Q96，用于提升精度
        uint256 intermediate = FullMath.mulDiv(
            sqrtRatioAX96,
            sqrtRatioBX96,
            FixedPoint96.Q96
        );

        // 最终 liquidity = amount0 × intermediate / (sqrtB - sqrtA)
        return
            toUint128(
                FullMath.mulDiv(
                    amount0,
                    intermediate,
                    sqrtRatioBX96 - sqrtRatioAX96
                )
            );
    }

    /// @notice Computes the amount of liquidity received for a given amount of token1 and price range
    /// @dev Calculates amount1 / (sqrt(upper) - sqrt(lower)).
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param amount1 The amount1 being sent in
    /// @return liquidity The amount of returned liquidity
    function getLiquidityForAmount1(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        // console.log(
        //     "LiquidityAmount-getLiquidityForAmount1: ",
        //     uint256(amount1),
        //     uint256(sqrtRatioBX96),
        //     uint256(sqrtRatioAX96)
        // );
        return
            toUint128(
                FullMath.mulDiv(
                    amount1,
                    FixedPoint96.Q96,
                    sqrtRatioBX96 - sqrtRatioAX96
                )
            );
    }

    // xyt-test
    // function getAmount1Delta(
    //     uint160 sqrtRatioAX96,
    //     uint160 sqrtRatioBX96,
    //     uint128 liquidity,
    //     bool roundUp
    // ) internal pure returns (uint256 amount1) {
    //     if (sqrtRatioAX96 > sqrtRatioBX96)
    //         (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
    //     amount1 = roundUp
    //         ? FullMath.mulDivRoundingUp(
    //             liquidity,
    //             sqrtRatioBX96 - sqrtRatioAX96,
    //             FixedPoint96.Q96
    //         )
    //         : FullMath.mulDiv(
    //             liquidity,
    //             sqrtRatioBX96 - sqrtRatioAX96,
    //             FixedPoint96.Q96
    //         );
    //     console.log(
    //         "LiquidityAmount-getAmount1Delta: ",
    //         uint256(amount1),
    //         uint256(sqrtRatioBX96),
    //         uint256(sqrtRatioAX96)
    //     );
    //     return amount1;

    // }

    /// @notice 基于给定的 token0、token1 数量、当前池子价格和 tick 边界价格，计算可获得的最大流动性
    /// @param sqrtRatioX96 A sqrt price representing the current pool prices
    /// @param sqrtRatioX96 当前池子的平方根价格（Q64.96 格式）
    /// @param sqrtRatioAX96 第一个 tick 边界的平方根价格
    /// @param sqrtRatioBX96 第二个 tick 边界的平方根价格
    /// @param amount0 提供的 token0 数量
    /// @param amount1 提供的 token1 数量
    /// @return liquidity 可获得的最大流动性数量
    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        // 如果输入的 tick 边界顺序反了，交换顺序，确保 sqrtRatioAX96 < sqrtRatioBX96
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        // 当前价格小于等于最小 tick（价格在区间左边） → 只能用 token0 提供流动性
        if (sqrtRatioX96 <= sqrtRatioAX96) {
            liquidity = getLiquidityForAmount0(
                sqrtRatioAX96,
                sqrtRatioBX96,
                amount0
            );
            // console.log(
            //     "LiquidityAmount-liquidity-111: ",
            //     uint256(sqrtRatioAX96),
            //     uint256(sqrtRatioBX96),
            //     uint256(liquidity)
            // );
        }
        // 当前价格位于两个 tick 之间 → 同时用 token0 和 token1 提供流动性，取最小的那一侧
        else if (sqrtRatioX96 < sqrtRatioBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(
                sqrtRatioX96,
                sqrtRatioBX96,
                amount0
            );
            uint128 liquidity1 = getLiquidityForAmount1(
                sqrtRatioAX96,
                sqrtRatioX96,
                amount1
            );

            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
            // console.log(
            //     "LiquidityAmount-liquidity0-222: ",
            //     uint256(liquidity0),
            //     uint256(liquidity1)
            // );
        }
        // 当前价格高于右边界 tick（价格在区间右边） → 只能用 token1 提供流动性
        else {
            liquidity = getLiquidityForAmount1(
                sqrtRatioAX96,
                sqrtRatioBX96,
                amount1
            );
        }
    }

    /// @notice Computes the amount of token0 for a given amount of liquidity and a price range
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount0 The amount of token0
    function getAmount0ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return
            FullMath.mulDiv(
                uint256(liquidity) << FixedPoint96.RESOLUTION,
                sqrtRatioBX96 - sqrtRatioAX96,
                sqrtRatioBX96
            ) / sqrtRatioAX96;
    }

    /// @notice Computes the amount of token1 for a given amount of liquidity and a price range
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount1 The amount of token1
    function getAmount1ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return
            FullMath.mulDiv(
                liquidity,
                sqrtRatioBX96 - sqrtRatioAX96,
                FixedPoint96.Q96
            );
    }

    /// @notice Computes the token0 and token1 value for a given amount of liquidity, the current
    /// pool prices and the prices at the tick boundaries
    /// @param sqrtRatioX96 A sqrt price representing the current pool prices
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount0 The amount of token0
    /// @return amount1 The amount of token1
    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = getAmount0ForLiquidity(
                sqrtRatioAX96,
                sqrtRatioBX96,
                liquidity
            );
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = getAmount0ForLiquidity(
                sqrtRatioX96,
                sqrtRatioBX96,
                liquidity
            );
            amount1 = getAmount1ForLiquidity(
                sqrtRatioAX96,
                sqrtRatioX96,
                liquidity
            );
        } else {
            amount1 = getAmount1ForLiquidity(
                sqrtRatioAX96,
                sqrtRatioBX96,
                liquidity
            );
        }
    }
}
