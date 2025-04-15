// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import "./LowGasSafeMath.sol";
import "./SafeCast.sol";

import "./TickMath.sol";
import "./LiquidityMath.sol";

/// @title Tick 库
/// @notice 包含用于管理 tick 状态及相关计算的函数
library Tick {
    using LowGasSafeMath for int256;
    using SafeCast for int256;

    // 每个已初始化 tick 存储的结构体信息
    struct Info {
        uint128 liquidityGross; // 当前 tick 被所有头寸引用的总流动性
        int128 liquidityNet; // 从左向右穿过 tick 增加/减少的净流动性
        uint256 feeGrowthOutside0X128; // 当前 tick 另一侧的 token0 累积手续费增长量（Q128.128）
        uint256 feeGrowthOutside1X128; // 当前 tick 另一侧的 token1 累积手续费增长量（Q128.128）
        int56 tickCumulativeOutside; // 当前 tick 另一侧的 tick × 时间 累积值
        uint160 secondsPerLiquidityOutsideX128; // 当前 tick 另一侧的单位流动性所经过的秒数（Q128.128）
        uint32 secondsOutside; // 当前 tick 另一侧累计经过的秒数
        bool initialized; // tick 是否已初始化，相当于 liquidityGross != 0
    }

    /// @notice 根据 tickSpacing 计算每个 tick 允许的最大流动性
    /// @dev 在池子构造时执行
    /// @param tickSpacing tick 间距，如 3 表示每隔 3 个 tick 初始化一次
    /// @return 每个 tick 可容纳的最大流动性
    function tickSpacingToMaxLiquidityPerTick(
        int24 tickSpacing
    ) internal pure returns (uint128) {
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        uint24 numTicks = uint24((maxTick - minTick) / tickSpacing) + 1;
        return type(uint128).max / numTicks;
    }

    /// @notice 计算某区间内累计手续费增长量
    /// @param self 已初始化 tick 的映射
    /// @param tickLower 区间下边界 tick
    /// @param tickUpper 区间上边界 tick
    /// @param tickCurrent 当前池子 tick 值
    /// @param feeGrowthGlobal0X128 全局累计手续费（token0）
    /// @param feeGrowthGlobal1X128 全局累计手续费（token1）
    /// @return feeGrowthInside0X128 token0 在区间内的累计手续费增长
    /// @return feeGrowthInside1X128 token1 在区间内的累计手续费增长
    function getFeeGrowthInside(
        mapping(int24 => Tick.Info) storage self,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    )
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        Info storage lower = self[tickLower];
        Info storage upper = self[tickUpper];

        // 计算区间下侧的手续费
        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        if (tickCurrent >= tickLower) {
            feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lower.feeGrowthOutside1X128;
        } else {
            feeGrowthBelow0X128 =
                feeGrowthGlobal0X128 -
                lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 =
                feeGrowthGlobal1X128 -
                lower.feeGrowthOutside1X128;
        }

        // 计算区间上侧的手续费
        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;
        if (tickCurrent < tickUpper) {
            feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = upper.feeGrowthOutside1X128;
        } else {
            feeGrowthAbove0X128 =
                feeGrowthGlobal0X128 -
                upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 =
                feeGrowthGlobal1X128 -
                upper.feeGrowthOutside1X128;
        }

        // 区间内部手续费增长 = 全局 - 下侧 - 上侧
        feeGrowthInside0X128 =
            feeGrowthGlobal0X128 -
            feeGrowthBelow0X128 -
            feeGrowthAbove0X128;
        feeGrowthInside1X128 =
            feeGrowthGlobal1X128 -
            feeGrowthBelow1X128 -
            feeGrowthAbove1X128;
    }

    /// @notice 更新某个 tick，并返回该 tick 是否发生初始化状态翻转
    /// @param self 已初始化 tick 的映射
    /// @param tick 要更新的 tick
    /// @param tickCurrent 当前池子的 tick
    /// @param liquidityDelta 添加（或移除）的流动性数量
    /// @param feeGrowthGlobal0X128 全局 token0 手续费增长
    /// @param feeGrowthGlobal1X128 全局 token1 手续费增长
    /// @param secondsPerLiquidityCumulativeX128 全局单位流动性时间增长
    /// @param tickCumulative 当前 tick × 运行秒数
    /// @param time 当前区块时间戳
    /// @param upper 是否为 upper tick（true 表示是上边界）
    /// @param maxLiquidity 单个 tick 可容纳的最大流动性
    /// @return flipped tick 是否发生初始化状态翻转
    function update(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        int24 tickCurrent,
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time,
        bool upper,
        uint128 maxLiquidity
    ) internal returns (bool flipped) {
        Tick.Info storage info = self[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        uint128 liquidityGrossAfter = LiquidityMath.addDelta(
            liquidityGrossBefore,
            liquidityDelta
        );

        require(liquidityGrossAfter <= maxLiquidity, "LO");

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            // 假设所有历史增长都发生在 tick 之下
            if (tick <= tickCurrent) {
                info.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
                info
                    .secondsPerLiquidityOutsideX128 = secondsPerLiquidityCumulativeX128;
                info.tickCumulativeOutside = tickCumulative;
                info.secondsOutside = time;
            }
            info.initialized = true;
        }

        info.liquidityGross = liquidityGrossAfter;

        // 根据是 upper 还是 lower，更新 net 流动性方向
        info.liquidityNet = upper
            ? int256(info.liquidityNet).sub(liquidityDelta).toInt128()
            : int256(info.liquidityNet).add(liquidityDelta).toInt128();
    }

    /// @notice 清除 tick 状态（用于彻底移除）
    /// @param self 已初始化 tick 的映射
    /// @param tick 要清除的 tick
    function clear(
        mapping(int24 => Tick.Info) storage self,
        int24 tick
    ) internal {
        delete self[tick];
    }

    /// @notice 当价格穿越 tick 时调用，执行 tick 状态的镜像操作
    /// @param self 已初始化 tick 的映射
    /// @param tick 当前要穿越的目标 tick
    /// @param feeGrowthGlobal0X128 当前全局 token0 手续费增长
    /// @param feeGrowthGlobal1X128 当前全局 token1 手续费增长
    /// @param secondsPerLiquidityCumulativeX128 当前单位流动性时间累计值
    /// @param tickCumulative 当前 tick × 累计时间
    /// @param time 当前区块时间戳
    /// @return liquidityNet 穿越该 tick 时净变动的流动性
    function cross(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time
    ) internal returns (int128 liquidityNet) {
        Tick.Info storage info = self[tick];
        info.feeGrowthOutside0X128 =
            feeGrowthGlobal0X128 -
            info.feeGrowthOutside0X128;
        info.feeGrowthOutside1X128 =
            feeGrowthGlobal1X128 -
            info.feeGrowthOutside1X128;
        info.secondsPerLiquidityOutsideX128 =
            secondsPerLiquidityCumulativeX128 -
            info.secondsPerLiquidityOutsideX128;
        info.tickCumulativeOutside =
            tickCumulative -
            info.tickCumulativeOutside;
        info.secondsOutside = time - info.secondsOutside;
        liquidityNet = info.liquidityNet;
    }
}
