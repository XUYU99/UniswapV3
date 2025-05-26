// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import "./LowGasSafeMath.sol";
import "./SafeCast.sol";

import "./TickMath.sol";
import "./LiquidityMath.sol";

/// @title Tick
/// @notice 包含管理 tick 状态与相关计算的函数库
library Tick {
    using LowGasSafeMath for int256;
    using SafeCast for int256;

    // 每个初始化的 tick 存储的信息结构体
    struct Info {
        // 参考该 tick 的 position 总流动性
        uint128 liquidityGross;
        // 跨越 tick（从左到右/右到左）时添加（或移除）的净流动性
        int128 liquidityNet;
        // tick 另一侧的手续费累计增长（相对于当前 tick 的位置）
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        // tick 另一侧的 tick 累积值
        int56 tickCumulativeOutside;
        // tick 另一侧的 secondsPerLiquidity 累积值（Q128.128 精度）
        uint160 secondsPerLiquidityOutsideX128;
        // tick 另一侧流动性存在的时间（秒）
        uint32 secondsOutside;
        // 是否已初始化（即 liquidityGross ≠ 0），用于优化 SSTORE 成本
        bool initialized;
    }

    /// @notice 根据 tickSpacing 推导每个 tick 最大可分配流动性
    /// @dev 在 pool 构造函数中调用
    /// @param tickSpacing tick 间隔（如为 3 表示只能初始化 ..., -6, -3, 0, 3, 6...）
    /// @return 每个 tick 允许的最大流动性值
    function tickSpacingToMaxLiquidityPerTick(
        int24 tickSpacing
    ) internal pure returns (uint128) {
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        uint24 numTicks = uint24((maxTick - minTick) / tickSpacing) + 1;
        return type(uint128).max / numTicks;
    }

    /// @notice 获取某 LP 所在 tick 区间内的累计手续费增长值
    /// @param self 所有已初始化 tick 的映射
    /// @param tickLower LP 设置的区间下限
    /// @param tickUpper LP 设置的区间上限
    /// @param tickCurrent 当前池子的 tick 值
    /// @param feeGrowthGlobal0X128 全局 token0 的总手续费增长（单位流动性）
    /// @param feeGrowthGlobal1X128 全局 token1 的总手续费增长（单位流动性）
    /// @return feeGrowthInside0X128 LP 区间内的 token0 累积手续费增长（单位流动性）
    /// @return feeGrowthInside1X128 LP 区间内的 token1 累积手续费增长（单位流动性）
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

        // 计算 lower 处以下的 fee 增长（如果当前 tick 在区间内，则为原始值，否则用全局值减去）
        // tickCurrent < tickLower 的时候，lower.feeGrowthOutside0X128是tick右边的部分
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

        // 计算 upper 处以上的 fee 增长
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

        // 得出 LP 区间内的 fee 增长值
        feeGrowthInside0X128 =
            feeGrowthGlobal0X128 -
            feeGrowthBelow0X128 -
            feeGrowthAbove0X128;
        feeGrowthInside1X128 =
            feeGrowthGlobal1X128 -
            feeGrowthBelow1X128 -
            feeGrowthAbove1X128;
    }

    /// @notice 更新指定 tick 的状态，返回是否发生了初始化状态翻转
    /// @param self 所有已初始化 tick 的映射
    /// @param tick 要更新的 tick
    /// @param tickCurrent 当前池子的 tick
    /// @param liquidityDelta 要添加/移除的流动性值（左进右出为加，右进左出为减）
    /// @param feeGrowthGlobal0X128 当前全局 token0 的累计手续费增长
    /// @param feeGrowthGlobal1X128 当前全局 token1 的累计手续费增长
    /// @param secondsPerLiquidityCumulativeX128 当前池子的 seconds/liquidity 累计值
    /// @param tickCumulative 当前 tick 累积值
    /// @param time 当前区块时间戳
    /// @param upper 是否为 LP 的 upper tick（控制 liquidityNet 增减方向）
    /// @param maxLiquidity 每个 tick 最大流动性限制
    /// @return flipped 表示是否发生了 tick 初始化状态变化
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

        // 获取该 tick 原本的总流动性（所有 LP 在此 tick 上的流动性总和）
        uint128 liquidityGrossBefore = info.liquidityGross;

        // 根据传入的流动性变化量（liquidityDelta），计算更新后的总流动性
        // 如果是添加流动性，则加上；如果是移除流动性，则减去
        uint128 liquidityGrossAfter = LiquidityMath.addDelta(
            liquidityGrossBefore,
            liquidityDelta
        );
        require(liquidityGrossAfter <= maxLiquidity, "LO");

        // 如果 liquidityGross 发生从 0 ↔ 非 0 状态切换，视为 flipped
        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        // 如果是第一次初始化该 tick，记录它当前的外部状态快照
        if (liquidityGrossBefore == 0) {
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

        // 更新总流动性
        info.liquidityGross = liquidityGrossAfter;

        // 根据是 upper 还是 lower tick，更新净流动性变化
        info.liquidityNet = upper
            ? int256(info.liquidityNet).sub(liquidityDelta).toInt128()
            : int256(info.liquidityNet).add(liquidityDelta).toInt128();
    }

    /// @notice 清除某个 tick 的所有记录数据
    /// @param self 所有已初始化 tick 的映射
    /// @param tick 要清除的 tick
    function clear(
        mapping(int24 => Tick.Info) storage self,
        int24 tick
    ) internal {
        delete self[tick];
    }

    function cross(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time
    ) internal returns (int128 liquidityNet) {
        // 获取 tick 对应的结构体信息
        Tick.Info storage info = self[tick];

        // 以下四项操作是“反转 outside”，用于后续计算 inside 区域时方便
        // 因为 crossing tick 表示 inside/outside 的角色互换

        // 反转该 tick 的 token0 手续费增长（用于 inside 计算）
        info.feeGrowthOutside0X128 =
            feeGrowthGlobal0X128 -
            info.feeGrowthOutside0X128;

        // 反转该 tick 的 token1 手续费增长
        info.feeGrowthOutside1X128 =
            feeGrowthGlobal1X128 -
            info.feeGrowthOutside1X128;

        // 反转 secondsPerLiquidity（秒数 / 流动性）用于时间加权计算
        info.secondsPerLiquidityOutsideX128 =
            secondsPerLiquidityCumulativeX128 -
            info.secondsPerLiquidityOutsideX128;

        // 反转 tick 累积值（用于 TWAP 均值计算）
        info.tickCumulativeOutside =
            tickCumulative -
            info.tickCumulativeOutside;

        // 更新 secondsOutside：当前时间戳减去记录的值，表示该 tick 曾经在 outside 的总时长
        info.secondsOutside = time - info.secondsOutside;

        // 返回该 tick 的 liquidityNet，用于全局 liquidity 更新：
        // - 如果是价格从左向右穿越 tick，表示 tick liquidity 被激活，要加上；
        // - 如果是从右向左穿越，表示 tick liquidity 被移除，要减去。
        liquidityNet = info.liquidityNet;
    }
}
