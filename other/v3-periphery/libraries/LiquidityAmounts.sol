// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

// Import libraries from Uniswap V3 core that are used in liquidity calculations.
// 导入 Uniswap V3 核心库中用于流动性计算的工具库。
import "contracts/uniswap/v2-core/libraries/FullMath.sol";
import "contracts/uniswap/v2-core/libraries/FixedPoint96.sol";

/// @title LiquidityAmounts
/// @notice Provides functions for computing liquidity amounts from token amounts and prices
/// @dev This library provides methods for calculating liquidity that can be obtained given token amounts and a price range.
// @title 流动性数量计算函数库
// @notice 提供从 token 数量与价格计算流动性的相关函数
library LiquidityAmounts {
    /// @notice Downcasts uint256 to uint128
    /// @param x The uint256 to be downcasted
    /// @return y The passed value, downcasted to uint128
    // @notice 将 uint256 数值向下转换为 uint128
    // @param x 需要转换的 uint256 数值
    // @return y 转换后的 uint128 数值，要求转换后数值不丢失
    function toUint128(uint256 x) private pure returns (uint128 y) {
        require((y = uint128(x)) == x);
    }

    /// @notice Computes the amount of liquidity received for a given amount of token0 and price range
    /// @dev Calculates: liquidity = amount0 * (sqrt(upper) * sqrt(lower)) / (sqrt(upper) - sqrt(lower))
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary (in Q64.96 format)
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary (in Q64.96 format)
    /// @param amount0 The amount of token0 being sent in
    /// @return liquidity The computed amount of liquidity
    // @notice 根据传入 token0 数量和价格区间计算所获得的流动性数量
    // @dev 计算公式：流动性 = amount0 * (sqrt(上界) * sqrt(下界)) / (sqrt(上界) - sqrt(下界))
    // @param sqrtRatioAX96 表示区间第一边界的 sqrt(price)，Q64.96 格式
    // @param sqrtRatioBX96 表示区间第二边界的 sqrt(price)，Q64.96 格式
    // @param amount0 供入的 token0 数量
    // @return liquidity 计算得到的流动性数量（uint128 类型）
    function getLiquidityForAmount0(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0
    ) internal pure returns (uint128 liquidity) {
        // Ensure that sqrtRatioAX96 is below sqrtRatioBX96; if not, swap them.
        // 确保 sqrtRatioAX96 小于 sqrtRatioBX96，不然交换顺序。
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        // Compute intermediate = (sqrtRatioAX96 * sqrtRatioBX96) / FixedPoint96.Q96.
        // 计算中间值 = (sqrtRatioAX96 * sqrtRatioBX96) / FixedPoint96.Q96
        uint256 intermediate = FullMath.mulDiv(
            sqrtRatioAX96,
            sqrtRatioBX96,
            FixedPoint96.Q96
        );
        // Liquidity = amount0 * intermediate / (sqrtRatioBX96 - sqrtRatioAX96)
        // 流动性 = amount0 * (中间值) / (sqrtRatioBX96 - sqrtRatioAX96)
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
    /// @dev Calculates: liquidity = amount1 / (sqrt(upper) - sqrt(lower)).
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary (in Q64.96 format)
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary (in Q64.96 format)
    /// @param amount1 The amount of token1 being sent in
    /// @return liquidity The computed amount of liquidity
    // @notice 根据 token1 数量和价格区间计算流动性数量
    // @dev 计算公式：流动性 = amount1 / (sqrt(上界) - sqrt(下界))
    // @param sqrtRatioAX96 区间下边界的 sqrt(price)
    // @param sqrtRatioBX96 区间上边界的 sqrt(price)
    // @param amount1 供入的 token1 数量
    // @return liquidity 计算得到的流动性数量
    function getLiquidityForAmount1(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        // Ensure ordering of the bounds
        // 保证 sqrtRatioAX96 小于 sqrtRatioBX96
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        // Liquidity = amount1 * FixedPoint96.Q96 / (sqrtRatioBX96 - sqrtRatioAX96)
        // 计算流动性 = amount1 * FixedPoint96.Q96 / (sqrtRatioBX96 - sqrtRatioAX96)
        return
            toUint128(
                FullMath.mulDiv(
                    amount1,
                    FixedPoint96.Q96,
                    sqrtRatioBX96 - sqrtRatioAX96
                )
            );
    }

    /// @notice Computes the maximum liquidity received for given amounts of token0 and token1, given the current pool price and the tick boundaries
    /// @param sqrtRatioX96 A sqrt price representing the current pool price (in Q64.96 format)
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param amount0 The amount of token0 being sent in
    /// @param amount1 The amount of token1 being sent in
    /// @return liquidity The maximum liquidity that can be provided with the given amounts
    // @notice 根据当前价格和价格区间，计算给定 token0 和 token1 数量所能获得的最大流动性
    // @param sqrtRatioX96 当前价格的 sqrt(price)（Q64.96 格式）
    // @param sqrtRatioAX96 区间下边界的 sqrt(price)
    // @param sqrtRatioBX96 区间上边界的 sqrt(price)
    // @param amount0 供入的 token0 数量
    // @param amount1 供入的 token1 数量
    // @return liquidity 可获得的最大流动性
    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        // Ensure that sqrtRatioAX96 is the lower bound and sqrtRatioBX96 is the upper bound.
        // 保证价格边界顺序正确，如果不正确则交换。
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        // 如果当前价格低于区间下界，则仅使用 token0。
        if (sqrtRatioX96 <= sqrtRatioAX96) {
            liquidity = getLiquidityForAmount0(
                sqrtRatioAX96,
                sqrtRatioBX96,
                amount0
            );
            // 如果当前价格在价格区间内，则 token0 与 token1 同时有用，选择较小的流动性。
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
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
        } else {
            // 如果当前价格高于区间上界，则仅使用 token1。
            liquidity = getLiquidityForAmount1(
                sqrtRatioAX96,
                sqrtRatioBX96,
                amount1
            );
        }
    }

    /// @notice Computes the amount of token0 corresponding to a given liquidity amount in a price range.
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary.
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary.
    /// @param liquidity The liquidity being valued.
    /// @return amount0 The corresponding amount of token0.
    // @notice 计算给定流动性在指定价格区间内对应的 token0 数量
    // @param sqrtRatioAX96 区间下边界的 sqrt(price)
    // @param sqrtRatioBX96 区间上边界的 sqrt(price)
    // @param liquidity 流动性数量
    // @return amount0 对应的 token0 数量
    function getAmount0ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        // 确保价格顺序正确
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        // 计算公式: amount0 = liquidity * (sqrt(upper) - sqrt(lower)) * 2^96 / (sqrt(upper) * sqrt(lower))
        return
            FullMath.mulDiv(
                uint256(liquidity) << FixedPoint96.RESOLUTION,
                sqrtRatioBX96 - sqrtRatioAX96,
                sqrtRatioBX96
            ) / sqrtRatioAX96;
    }

    /// @notice Computes the amount of token1 corresponding to a given liquidity amount in a price range.
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary.
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary.
    /// @param liquidity The liquidity being valued.
    /// @return amount1 The corresponding amount of token1.
    // @notice 计算给定流动性在指定价格区间内对应的 token1 数量
    // @param sqrtRatioAX96 区间下边界的 sqrt(price)
    // @param sqrtRatioBX96 区间上边界的 sqrt(price)
    // @param liquidity 流动性数量
    // @return amount1 对应的 token1 数量
    function getAmount1ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        // 确保价格边界顺序正确
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        // 计算公式: amount1 = liquidity * (sqrt(upper) - sqrt(lower)) / 2^96
        return
            FullMath.mulDiv(
                liquidity,
                sqrtRatioBX96 - sqrtRatioAX96,
                FixedPoint96.Q96
            );
    }

    /// @notice Computes both token0 and token1 amounts corresponding to a given liquidity amount.
    /// @param sqrtRatioX96 A sqrt price representing the current pool price.
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary.
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary.
    /// @param liquidity The liquidity being valued.
    /// @return amount0 The corresponding amount of token0.
    /// @return amount1 The corresponding amount of token1.
    // @notice 根据当前池价和区间边界，计算给定流动性所对应的 token0 与 token1 数量
    // @param sqrtRatioX96 当前价格的 sqrt(price)
    // @param sqrtRatioAX96 区间下界的 sqrt(price)
    // @param sqrtRatioBX96 区间上界的 sqrt(price)
    // @param liquidity 流动性数量
    // @return amount0 对应的 token0 数量
    // @return amount1 对应的 token1 数量
    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        // 确保边界排序正确
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        // 如果当前价格低于区间下界，则所有流动性对应于 token0
        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = getAmount0ForLiquidity(
                sqrtRatioAX96,
                sqrtRatioBX96,
                liquidity
            );
            // 如果当前价格处于区间内部，则 token0 与 token1 都会部分被使用，取二者中较小者
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
            // 如果当前价格高于区间上界，则所有流动性对应于 token1
            amount1 = getAmount1ForLiquidity(
                sqrtRatioAX96,
                sqrtRatioBX96,
                liquidity
            );
        }
    }
}
