// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import "./FullMath.sol";
import "./FixedPoint128.sol";
import "./LiquidityMath.sol";

// import "hardhat/console.sol";

/// @title Position
/// @notice Positions represent an owner address' liquidity between a lower and upper tick boundary
/// @dev Positions store additional state for tracking fees owed to the position
library Position {
    // info stored for each user's position
    struct Info {
        // the amount of liquidity owned by this position
        uint128 liquidity;
        // fee growth per unit of liquidity as of the last update to liquidity or fees owed
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // the fees owed to the position owner in token0/token1
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /// @notice Returns the Info struct of a position, given an owner and position boundaries
    /// @param self The mapping containing all user positions
    /// @param owner The address of the position owner
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @return position The position info struct of the given owners' position
    function get(
        mapping(bytes32 => Info) storage self,
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (Position.Info storage position) {
        position = self[
            keccak256(abi.encodePacked(owner, tickLower, tickUpper))
        ];
        // console.log(
        //     "Position.get(owner, tickLower, tickUpper)-position.liquidity:",
        //     uint256(position.liquidity)
        // );
        // console.log(
        //     "Position.get(owner, tickLower, tickUpper)-position.feeGrowthInside0LastX128: %s",
        //     position.feeGrowthInside0LastX128
        // );
    }

    /// @notice 将已累积的手续费计入用户的头寸中
    /// @param self 要更新的头寸对象（Position.Info）
    /// @param liquidityDelta 头寸变动导致的流动性变化值（可以为正或负）
    /// @param feeGrowthInside0X128 该头寸 tick 区间内 token0 的累计单位手续费增长
    /// @param feeGrowthInside1X128 该头寸 tick 区间内 token1 的累计单位手续费增长
    function update(
        Info storage self,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) internal {
        // 将当前头寸复制为临时变量，减少 SLOAD（gas 优化）
        Info memory _self = self;

        uint128 liquidityNext;
        if (liquidityDelta == 0) {
            // 不允许对 liquidity 为 0 的头寸进行 “poke” 操作（即无流动性但试图更新）
            require(_self.liquidity > 0, "NP");
            liquidityNext = _self.liquidity;
        } else {
            // 根据 delta 计算更新后的流动性（增加或减少）
            liquidityNext = LiquidityMath.addDelta(
                _self.liquidity,
                liquidityDelta
            );
        }

        // 计算从上次记录以来所累积的 token0 手续费
        uint128 tokensOwed0 = uint128(
            FullMath.mulDiv(
                feeGrowthInside0X128 - _self.feeGrowthInside0LastX128,
                _self.liquidity,
                FixedPoint128.Q128
            )
        );

        // 计算从上次记录以来所累积的 token1 手续费
        uint128 tokensOwed1 = uint128(
            FullMath.mulDiv(
                feeGrowthInside1X128 - _self.feeGrowthInside1LastX128,
                _self.liquidity,
                FixedPoint128.Q128
            )
        );

        // 更新头寸状态
        if (liquidityDelta != 0) self.liquidity = liquidityNext;

        // 更新手续费增长快照（记录“当前时刻”的增长值）
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;

        if (tokensOwed0 > 0 || tokensOwed1 > 0) {
            // 可以接受 overflow，反正超过 uint128 最大值前必须领取掉收益
            self.tokensOwed0 += tokensOwed0;
            self.tokensOwed1 += tokensOwed1;
        }
    }
}
