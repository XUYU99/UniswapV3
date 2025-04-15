// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import "./FullMath.sol";
import "./FixedPoint128.sol";
import "./LiquidityMath.sol";

/// @title Position 库
/// @notice 表示某个地址在特定 tick 区间内的流动性头寸
/// @dev Position 会存储跟踪其应得手续费的状态
library Position {
    // 每个用户头寸存储的信息结构体
    struct Info {
        uint128 liquidity; // 当前头寸持有的流动性数量
        uint256 feeGrowthInside0LastX128; // 上次更新时，tick 区间内 token0 的手续费增长值
        uint256 feeGrowthInside1LastX128; // 上次更新时，tick 区间内 token1 的手续费增长值
        uint128 tokensOwed0; // 尚未领取的 token0 手续费
        uint128 tokensOwed1; // 尚未领取的 token1 手续费
    }

    /// @notice 根据 owner 和 tick 区间返回对应的 Position 信息
    /// @param self 储存所有用户头寸的 mapping
    /// @param owner 头寸所有者地址
    /// @param tickLower 头寸的下边界 tick
    /// @param tickUpper 头寸的上边界 tick
    /// @return position 对应头寸的 Info 引用
    function get(
        mapping(bytes32 => Info) storage self,
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (Position.Info storage position) {
        position = self[
            keccak256(abi.encodePacked(owner, tickLower, tickUpper))
        ];
    }

    /// @notice 将新产生的手续费记入头寸中
    /// @param self 要更新的单个头寸信息
    /// @param liquidityDelta 由于该次操作导致的流动性变动
    /// @param feeGrowthInside0X128 当前 tick 区间内 token0 的全时段手续费增长值
    /// @param feeGrowthInside1X128 当前 tick 区间内 token1 的全时段手续费增长值
    function update(
        Info storage self,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) internal {
        Info memory _self = self;

        uint128 liquidityNext;
        if (liquidityDelta == 0) {
            require(_self.liquidity > 0, "NP"); // 禁止对 0 流动性的头寸进行无意义更新
            liquidityNext = _self.liquidity;
        } else {
            liquidityNext = LiquidityMath.addDelta(
                _self.liquidity,
                liquidityDelta
            );
        }

        // 计算新增的手续费
        uint128 tokensOwed0 = uint128(
            FullMath.mulDiv(
                feeGrowthInside0X128 - _self.feeGrowthInside0LastX128,
                _self.liquidity,
                FixedPoint128.Q128
            )
        );
        uint128 tokensOwed1 = uint128(
            FullMath.mulDiv(
                feeGrowthInside1X128 - _self.feeGrowthInside1LastX128,
                _self.liquidity,
                FixedPoint128.Q128
            )
        );

        // 更新头寸数据
        if (liquidityDelta != 0) self.liquidity = liquidityNext;
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;
        if (tokensOwed0 > 0 || tokensOwed1 > 0) {
            // 溢出是可接受的，用户必须在达到 uint128 最大值前领取手续费
            self.tokensOwed0 += tokensOwed0;
            self.tokensOwed1 += tokensOwed1;
        }
    }
}
