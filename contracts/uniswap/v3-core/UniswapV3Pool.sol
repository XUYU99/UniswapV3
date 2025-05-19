// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import "./interfaces/IUniswapV3Pool.sol";

import "./NoDelegateCall.sol";

import "./libraries/LowGasSafeMath.sol";
import "./libraries/SafeCast.sol";
import "./libraries/Tick.sol";
import "./libraries/TickBitmap.sol";
import "./libraries/Position.sol";
import "./libraries/Oracle.sol";

import "./libraries/FullMath.sol";
import "./libraries/FixedPoint128.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/TickMath.sol";
import "./libraries/LiquidityMath.sol";
import "./libraries/SqrtPriceMath.sol";
import "./libraries/SwapMath.sol";

import "./interfaces/IUniswapV3PoolDeployer.sol";
import "./interfaces/IUniswapV3Factory.sol";
import "./interfaces/IERC20Minimal.sol";
import "./interfaces/callback/IUniswapV3MintCallback.sol";
import "./interfaces/callback/IUniswapV3SwapCallback.sol";
import "./interfaces/callback/IUniswapV3FlashCallback.sol";

import "hardhat/console.sol";

contract UniswapV3Pool is IUniswapV3Pool, NoDelegateCall {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];

    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override factory;
    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override token0;
    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override token1;
    /// @inheritdoc IUniswapV3PoolImmutables
    uint24 public immutable override fee;

    /// @inheritdoc IUniswapV3PoolImmutables
    int24 public immutable override tickSpacing;

    /// @inheritdoc IUniswapV3PoolImmutables
    uint128 public immutable override maxLiquidityPerTick;

    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }
    /// @inheritdoc IUniswapV3PoolState
    Slot0 public override slot0;

    /// @inheritdoc IUniswapV3PoolState
    uint256 public override feeGrowthGlobal0X128;
    /// @inheritdoc IUniswapV3PoolState
    uint256 public override feeGrowthGlobal1X128;

    // accumulated protocol fees in token0/token1 units
    struct ProtocolFees {
        uint128 token0;
        uint128 token1;
    }
    /// @inheritdoc IUniswapV3PoolState
    ProtocolFees public override protocolFees;

    /// @inheritdoc IUniswapV3PoolState
    uint128 public override liquidity;

    /// @inheritdoc IUniswapV3PoolState
    mapping(int24 => Tick.Info) public override ticks;
    /// @inheritdoc IUniswapV3PoolState
    mapping(int16 => uint256) public override tickBitmap;
    /// @inheritdoc IUniswapV3PoolState
    mapping(bytes32 => Position.Info) public override positions;
    /// @inheritdoc IUniswapV3PoolState
    Oracle.Observation[65535] public override observations;

    /// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
    /// to a function before the pool is initialized. The reentrancy guard is required throughout the contract because
    /// we use balance checks to determine the payment status of interactions such as mint, swap and flash.
    modifier lock() {
        require(slot0.unlocked, "LOK");
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    /// @dev Prevents calling a function from anyone except the address returned by IUniswapV3Factory#owner()
    modifier onlyFactoryOwner() {
        require(msg.sender == IUniswapV3Factory(factory).owner());
        _;
    }

    constructor() {
        int24 _tickSpacing;
        (factory, token0, token1, fee, _tickSpacing) = IUniswapV3PoolDeployer(
            msg.sender
        ).parameters();
        tickSpacing = _tickSpacing;

        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(
            _tickSpacing
        );
    }

    /// @dev Common checks for valid tick inputs.
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper, "TLU");
        require(tickLower >= TickMath.MIN_TICK, "TLM");
        require(tickUpper <= TickMath.MAX_TICK, "TUM");
    }

    /// @dev Returns the block timestamp truncated to 32 bits, i.e. mod 2**32. This method is overridden in tests.
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }

    /// @dev Get the pool's balance of token0
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    function balance0() private view returns (uint256) {
        (bool success, bytes memory data) = token0.staticcall(
            abi.encodeWithSelector(
                IERC20Minimal.balanceOf.selector,
                address(this)
            )
        );
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @dev Get the pool's balance of token1
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) = token1.staticcall(
            abi.encodeWithSelector(
                IERC20Minimal.balanceOf.selector,
                address(this)
            )
        );
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    function snapshotCumulativesInside(
        int24 tickLower,
        int24 tickUpper
    )
        external
        view
        override
        noDelegateCall
        returns (
            int56 tickCumulativeInside,
            uint160 secondsPerLiquidityInsideX128,
            uint32 secondsInside
        )
    {
        checkTicks(tickLower, tickUpper);

        int56 tickCumulativeLower;
        int56 tickCumulativeUpper;
        uint160 secondsPerLiquidityOutsideLowerX128;
        uint160 secondsPerLiquidityOutsideUpperX128;
        uint32 secondsOutsideLower;
        uint32 secondsOutsideUpper;

        {
            Tick.Info storage lower = ticks[tickLower];
            Tick.Info storage upper = ticks[tickUpper];
            bool initializedLower;
            (
                tickCumulativeLower,
                secondsPerLiquidityOutsideLowerX128,
                secondsOutsideLower,
                initializedLower
            ) = (
                lower.tickCumulativeOutside,
                lower.secondsPerLiquidityOutsideX128,
                lower.secondsOutside,
                lower.initialized
            );
            require(initializedLower);

            bool initializedUpper;
            (
                tickCumulativeUpper,
                secondsPerLiquidityOutsideUpperX128,
                secondsOutsideUpper,
                initializedUpper
            ) = (
                upper.tickCumulativeOutside,
                upper.secondsPerLiquidityOutsideX128,
                upper.secondsOutside,
                upper.initialized
            );
            require(initializedUpper);
        }

        Slot0 memory _slot0 = slot0;

        if (_slot0.tick < tickLower) {
            return (
                tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityOutsideLowerX128 -
                    secondsPerLiquidityOutsideUpperX128,
                secondsOutsideLower - secondsOutsideUpper
            );
        } else if (_slot0.tick < tickUpper) {
            uint32 time = _blockTimestamp();
            (
                int56 tickCumulative,
                uint160 secondsPerLiquidityCumulativeX128
            ) = observations.observeSingle(
                    time,
                    0,
                    _slot0.tick,
                    _slot0.observationIndex,
                    liquidity,
                    _slot0.observationCardinality
                );
            return (
                tickCumulative - tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityCumulativeX128 -
                    secondsPerLiquidityOutsideLowerX128 -
                    secondsPerLiquidityOutsideUpperX128,
                time - secondsOutsideLower - secondsOutsideUpper
            );
        } else {
            return (
                tickCumulativeUpper - tickCumulativeLower,
                secondsPerLiquidityOutsideUpperX128 -
                    secondsPerLiquidityOutsideLowerX128,
                secondsOutsideUpper - secondsOutsideLower
            );
        }
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    function observe(
        uint32[] calldata secondsAgos
    )
        external
        view
        override
        noDelegateCall
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        )
    {
        return
            observations.observe(
                _blockTimestamp(),
                secondsAgos,
                slot0.tick,
                slot0.observationIndex,
                liquidity,
                slot0.observationCardinality
            );
    }

    /// @inheritdoc IUniswapV3PoolActions
    function increaseObservationCardinalityNext(
        uint16 observationCardinalityNext
    ) external override lock noDelegateCall {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext; // for the event
        uint16 observationCardinalityNextNew = observations.grow(
            observationCardinalityNextOld,
            observationCardinalityNext
        );
        slot0.observationCardinalityNext = observationCardinalityNextNew;
        if (observationCardinalityNextOld != observationCardinalityNextNew)
            emit IncreaseObservationCardinalityNext(
                observationCardinalityNextOld,
                observationCardinalityNextNew
            );
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev not locked because it initializes unlocked
    function initialize(uint160 sqrtPriceX96) external override {
        require(slot0.sqrtPriceX96 == 0, "AI");

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(
            _blockTimestamp()
        );

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext,
            feeProtocol: 0,
            unlocked: true
        });

        emit Initialize(sqrtPriceX96, tick);
    }

    struct ModifyPositionParams {
        // the address that owns the position
        address owner;
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any change in liquidity
        int128 liquidityDelta;
    }

    /// @dev Effect some changes to a position
    /// 修改某个 LP 的头寸（Position），增减其流动性，并计算对应所需的 token 数量
    /// @param params the position details and the change to the position's liquidity to effect
    /// 包含 LP 地址、tick 区间、流动性变化值的参数结构体
    /// @return position a storage pointer referencing the position with the given owner and tick range
    /// 返回该 LP 在指定 tick 区间的头寸存储指针
    /// @return amount0 the amount of token0 owed to the pool, negative if the pool should pay the recipient
    /// 所需的 token0 数量（负数表示用户从池中领取）
    /// @return amount1 the amount of token1 owed to the pool, negative if the pool should pay the recipient
    /// 所需的 token1 数量（负数表示用户从池中领取）
    function _modifyPosition(
        ModifyPositionParams memory params
    )
        private
        noDelegateCall
        returns (Position.Info storage position, int256 amount0, int256 amount1)
    {
        // 校验 tick 区间是否合法
        checkTicks(params.tickLower, params.tickUpper);

        // 加载当前全局状态（slot0）以节省 gas
        Slot0 memory _slot0 = slot0;

        // 获取并更新某个 LP 在指定 tick 区间的position头寸信息，根据 liquidityDelta 增减流动性
        position = _updatePosition(
            params.owner,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta,
            _slot0.tick
        );

        // 如果流动性有变化，则需要计算对应的 token0/token1 数量
        if (params.liquidityDelta != 0) {
            if (_slot0.tick < params.tickLower) {
                // token0 在价格上涨后更值钱，必须提前补足
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            } else if (_slot0.tick < params.tickUpper) {
                // 当前价格位于 tick 区间内部 → 新流动性立即生效

                uint128 liquidityBefore = liquidity; // 记录原有总流动性

                // 写入一次预言机观测（oracle observation）
                (
                    slot0.observationIndex,
                    slot0.observationCardinality
                ) = observations.write(
                    _slot0.observationIndex,
                    _blockTimestamp(),
                    _slot0.tick,
                    liquidityBefore,
                    _slot0.observationCardinality,
                    _slot0.observationCardinalityNext
                );

                // 计算 token0 所需数量：当前 √P → 上限 √P
                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                // 计算 token1 所需数量：下限 √P → 当前 √P
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    _slot0.sqrtPriceX96,
                    params.liquidityDelta
                );

                // 更新全局流动性
                liquidity = LiquidityMath.addDelta(
                    liquidityBefore,
                    params.liquidityDelta
                );
            } else {
                // 当前价格高于 tick 区间 → 流动性暂未生效 → 用户需准备 token1
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                // console.log("UniswapV3pool-mint()-amount1:", uint256(amount1));
            }
        }
    }

    // function test001(
    //     int24 testtickLower,
    //     int24 testtickUpper,
    //     int128 testliquidityDelta
    // ) public returns (int256 amount0, int256 amount1) {
    //     Slot0 memory _slot0 = slot0;
    //     if (testliquidityDelta != 0) {
    //         if (_slot0.tick > testtickUpper) {
    //             amount1 = SqrtPriceMath.getAmount1Delta(
    //                 TickMath.getSqrtRatioAtTick(testtickLower),
    //                 TickMath.getSqrtRatioAtTick(testtickUpper),
    //                 testliquidityDelta
    //             );
    //         }
    //     }
    // }

    /// @dev Gets and updates a position with the given liquidity delta
    /// 获取并更新某个 LP 在指定 tick 区间的头寸信息，根据 liquidityDelta 增减流动性
    /// @param owner 头寸所属 LP 地址
    /// @param tickLower 流动性区间的下边界 tick
    /// @param tickUpper 流动性区间的上边界 tick
    /// @param tick 当前池子的 tick 值（为了节省 SLOAD 直接传入）
    function _updatePosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tick
    ) private returns (Position.Info storage position) {
        // 通过 owner + tickLower + tickUpper 获取 position 结构
        position = positions.get(owner, tickLower, tickUpper);

        // 提前 SLOAD 全局手续费变量以节省 gas
        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128;
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128;
        // console.log(uint256(_feeGrowthGlobal0X128));
        // 如果有流动性变化（添加或移除），则需要更新 tick 状态
        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) {
            uint32 time = _blockTimestamp();

            // 获取当前价格和流动性对应的累积观测值（用于更新 tick 内部指标）
            (
                int56 tickCumulative,
                uint160 secondsPerLiquidityCumulativeX128
            ) = observations.observeSingle(
                    time,
                    0,
                    slot0.tick,
                    slot0.observationIndex,
                    liquidity,
                    slot0.observationCardinality
                );

            // 更新 tickLower 的数据（记录该位置上的流动性变化）
            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                false,
                maxLiquidityPerTick
            );

            // 更新 tickUpper 的数据
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                true,
                maxLiquidityPerTick
            );
            // console.log("flippedLower: ", flippedLower);
            // 如果该 tick 首次被激活或被清除，则更新 tick bitmap
            if (flippedLower) {
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }
        }

        // 计算该 position 在当前 tick 中的 feeGrowthInside（手续费增长）
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = ticks
            .getFeeGrowthInside(
                tickLower,
                tickUpper,
                tick,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128
            );

        // 更新 position 的流动性和已累计手续费指标
        position.update(
            liquidityDelta,
            feeGrowthInside0X128,
            feeGrowthInside1X128
        );

        // 如果减少了流动性并导致某 tick 的流动性为 0，则清除该 tick 的记录
        if (liquidityDelta < 0) {
            if (flippedLower) {
                ticks.clear(tickLower);
            }
            if (flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev noDelegateCall 是通过内部调用 _modifyPosition 间接实现的
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        require(amount > 0);

        // 调用 _modifyPosition，更新 LP 的 position 状态并计算应提供的 token0、token1 数量
        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: recipient,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(amount).toInt128()
            })
        );

        // 将 int 转为 uint，负数理论上不会出现（否则会 revert）
        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        // 记录 token0/token1 添加前的余额（用于校验实际是否转账成功）
        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();

        // 回调 msg.sender，要求其调用 uniswapV3MintCallback 并转入对应的 token0 和 token1
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(
            amount0,
            amount1,
            data
        );

        // 校验：确保用户实际转入的 token0 ≥ 要求数量
        if (amount0 > 0)
            require(balance0Before.add(amount0) <= balance0(), "M0");
        // 校验：确保用户实际转入的 token1 ≥ 要求数量
        if (amount1 > 0)
            require(balance1Before.add(amount1) <= balance1(), "M1");

        // 触发 Mint 事件（用于链上追踪）
        emit Mint(
            msg.sender, // 调用者（一般是 PositionManager）
            recipient, // 流动性接收者
            tickLower,
            tickUpper,
            amount,
            amount0,
            amount1
        );
    }

    /// @inheritdoc IUniswapV3PoolActions
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock returns (uint128 amount0, uint128 amount1) {
        // we don't need to checkTicks here, because invalid positions will never have non-zero tokensOwed{0,1}
        Position.Info storage position = positions.get(
            msg.sender,
            tickLower,
            tickUpper
        );

        amount0 = amount0Requested > position.tokensOwed0
            ? position.tokensOwed0
            : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1
            ? position.tokensOwed1
            : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit Collect(
            msg.sender,
            recipient,
            tickLower,
            tickUpper,
            amount0,
            amount1
        );
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev noDelegateCall is applied indirectly via _modifyPosition
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        (
            Position.Info storage position,
            int256 amount0Int,
            int256 amount1Int
        ) = _modifyPosition(
                ModifyPositionParams({
                    owner: msg.sender,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -int256(amount).toInt128()
                })
            );

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + uint128(amount0),
                position.tokensOwed1 + uint128(amount1)
            );
        }

        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

    struct SwapCache {
        // 输入 token 的协议手续费比率（单位：万分比）
        uint8 feeProtocol;
        // 本次 swap 开始时的全局流动性值
        uint128 liquidityStart;
        // 当前区块的时间戳
        uint32 blockTimestamp;
        // 当前累计 tick 值（仅在跨越已初始化 tick 时计算）
        int56 tickCumulative;
        // 当前单位流动性的累计秒数（仅在跨越已初始化 tick 时计算），Q128.128 精度
        uint160 secondsPerLiquidityCumulativeX128;
        // 是否已经计算并缓存了上述两个累加器值
        bool computedLatestObservation;
    }

    // 交换过程中的顶层状态，交换完成后结果将被写入存储
    struct SwapState {
        // 仍需交换的输入/输出资产数量（正值表示输入，负值表示输出）
        int256 amountSpecifiedRemaining;
        // 已完成交换的输出/输入资产数量（与上面方向相反）
        int256 amountCalculated;
        // 当前价格的平方根（Q64.96 格式）
        uint160 sqrtPriceX96;
        // 当前价格对应的 tick 值
        int24 tick;
        // 输入 token 的全局手续费累积值（用于 LP 分润，Q128.128 格式）
        uint256 feeGrowthGlobalX128;
        // 协议从输入 token 中抽取的手续费（非 LP 的那部分）
        uint128 protocolFee;
        // 当前价格区间内的可用流动性
        uint128 liquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    /// @inheritdoc IUniswapV3PoolActions
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    )
        external
        override
        noDelegateCall
        returns (int256 amount0, int256 amount1)
    {
        // console.log("UniswapV3pool-swap()");
        // 要求交换数量不能为0
        require(amountSpecified != 0, "AS");

        // 加载当前slot0状态（价格、tick等）
        Slot0 memory slot0Start = slot0;

        // 检查是否处于解锁状态
        require(slot0Start.unlocked, "LOK");

        // 校验价格限制（必须是朝着价格限制的方向进行交换）
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 &&
                    sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 &&
                    sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            "SPL"
        );

        // 锁定池子，防止重入
        slot0.unlocked = false;

        // 初始化缓存
        SwapCache memory cache = SwapCache({
            liquidityStart: liquidity,
            blockTimestamp: _blockTimestamp(),
            feeProtocol: zeroForOne
                ? (slot0Start.feeProtocol % 16)
                : (slot0Start.feeProtocol >> 4),
            secondsPerLiquidityCumulativeX128: 0,
            tickCumulative: 0,
            computedLatestObservation: false
        });

        // 判断是 exactInput（输入固定）还是 exactOutput（输出固定）
        bool exactInput = amountSpecified > 0;

        // 初始化状态变量
        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0Start.sqrtPriceX96,
            tick: slot0Start.tick,
            feeGrowthGlobalX128: zeroForOne
                ? feeGrowthGlobal0X128
                : feeGrowthGlobal1X128,
            protocolFee: 0,
            liquidity: cache.liquidityStart
        });
        // 主循环：逐步推进 swap，直到完成或到达价格边界
        while (
            state.amountSpecifiedRemaining != 0 &&
            state.sqrtPriceX96 != sqrtPriceLimitX96
        ) {
            StepComputations memory step;
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            // 找到当前tick附近的下一个已初始化tick
            (step.tickNext, step.initialized) = tickBitmap
                .nextInitializedTickWithinOneWord(
                    state.tick,
                    tickSpacing,
                    zeroForOne
                );
            // 等效于：            // (step.tickNext, step.initialized) = TickBitmap
            //     .nextInitializedTickWithinOneWord(
            //         tickBitmap,
            //         state.tick,
            //         tickSpacing,
            //         zeroForOne
            //     );

            // 限定tick范围不能超过MIN/MAX
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // 计算 tickNext 对应的价格
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // 计算在目标 tick/价格 或 剩余 amount 范围内能完成的 swap 步骤
            (
                state.sqrtPriceX96,
                step.amountIn,
                step.amountOut,
                step.feeAmount
            ) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (
                    zeroForOne
                        ? step.sqrtPriceNextX96 < sqrtPriceLimitX96
                        : step.sqrtPriceNextX96 > sqrtPriceLimitX96
                )
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            // 根据 exactInput/exactOutput 更新 swap 进度
            if (exactInput) {
                state.amountSpecifiedRemaining -= (step.amountIn +
                    step.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated.sub(
                    step.amountOut.toInt256()
                );
            } else {
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated.add(
                    (step.amountIn + step.feeAmount).toInt256()
                );
            }

            // 如果协议手续费生效，扣除相应部分
            if (cache.feeProtocol > 0) {
                uint256 delta = step.feeAmount / cache.feeProtocol;
                step.feeAmount -= delta;
                state.protocolFee += uint128(delta);
            }

            // 更新全局手续费增长量
            if (state.liquidity > 0)
                state.feeGrowthGlobalX128 += FullMath.mulDiv(
                    step.feeAmount,
                    FixedPoint128.Q128,
                    state.liquidity
                );

            // 如果价格到达了下一个tick，执行tick切换
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                if (step.initialized) {
                    if (!cache.computedLatestObservation) {
                        (
                            cache.tickCumulative,
                            cache.secondsPerLiquidityCumulativeX128
                        ) = observations.observeSingle(
                            cache.blockTimestamp,
                            0,
                            slot0Start.tick,
                            slot0Start.observationIndex,
                            cache.liquidityStart,
                            slot0Start.observationCardinality
                        );
                        cache.computedLatestObservation = true;
                    }
                    int128 liquidityNet = ticks.cross(
                        step.tickNext,
                        zeroForOne
                            ? state.feeGrowthGlobalX128
                            : feeGrowthGlobal0X128,
                        zeroForOne
                            ? feeGrowthGlobal1X128
                            : state.feeGrowthGlobalX128,
                        cache.secondsPerLiquidityCumulativeX128,
                        cache.tickCumulative,
                        cache.blockTimestamp
                    );
                    if (zeroForOne) liquidityNet = -liquidityNet;
                    state.liquidity = LiquidityMath.addDelta(
                        state.liquidity,
                        liquidityNet
                    );
                }
                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        // 如果 tick 有变化，写入 oracle 数据，否则只更新价格
        if (state.tick != slot0Start.tick) {
            (
                uint16 observationIndex,
                uint16 observationCardinality
            ) = observations.write(
                    slot0Start.observationIndex,
                    cache.blockTimestamp,
                    slot0Start.tick,
                    cache.liquidityStart,
                    slot0Start.observationCardinality,
                    slot0Start.observationCardinalityNext
                );
            (
                slot0.sqrtPriceX96,
                slot0.tick,
                slot0.observationIndex,
                slot0.observationCardinality
            ) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // 更新全局流动性
        if (cache.liquidityStart != state.liquidity)
            liquidity = state.liquidity;

        // 更新全局手续费增长与协议手续费
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
        }

        // 计算最终 amount0 和 amount1
        (amount0, amount1) = zeroForOne == exactInput
            ? (
                amountSpecified - state.amountSpecifiedRemaining,
                state.amountCalculated
            )
            : (
                state.amountCalculated,
                amountSpecified - state.amountSpecifiedRemaining
            );

        // token 转账：从用户收款 / 向用户付款
        if (zeroForOne) {
            if (amount1 < 0)
                TransferHelper.safeTransfer(
                    token1,
                    recipient,
                    uint256(-amount1)
                );
            uint256 balance0Before = balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
                amount0,
                amount1,
                data
            );
            require(balance0Before.add(uint256(amount0)) <= balance0(), "IIA");
        } else {
            if (amount0 < 0)
                TransferHelper.safeTransfer(
                    token0,
                    recipient,
                    uint256(-amount0)
                );
            uint256 balance1Before = balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
                amount0,
                amount1,
                data
            );
            require(balance1Before.add(uint256(amount1)) <= balance1(), "IIA");
        }

        // 触发 Swap 事件
        emit Swap(
            msg.sender,
            recipient,
            amount0,
            amount1,
            state.sqrtPriceX96,
            state.liquidity,
            state.tick
        );

        // 解锁池子
        slot0.unlocked = true;
    }

    /// @inheritdoc IUniswapV3PoolActions
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override lock noDelegateCall {
        uint128 _liquidity = liquidity;
        require(_liquidity > 0, "L");

        uint256 fee0 = FullMath.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = FullMath.mulDivRoundingUp(amount1, fee, 1e6);
        uint256 balance0Before = balance0();
        uint256 balance1Before = balance1();

        if (amount0 > 0)
            TransferHelper.safeTransfer(token0, recipient, amount0);
        if (amount1 > 0)
            TransferHelper.safeTransfer(token1, recipient, amount1);

        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(
            fee0,
            fee1,
            data
        );

        uint256 balance0After = balance0();
        uint256 balance1After = balance1();

        require(balance0Before.add(fee0) <= balance0After, "F0");
        require(balance1Before.add(fee1) <= balance1After, "F1");

        // sub is safe because we know balanceAfter is gt balanceBefore by at least fee
        uint256 paid0 = balance0After - balance0Before;
        uint256 paid1 = balance1After - balance1Before;

        if (paid0 > 0) {
            uint8 feeProtocol0 = slot0.feeProtocol % 16;
            uint256 fees0 = feeProtocol0 == 0 ? 0 : paid0 / feeProtocol0;
            if (uint128(fees0) > 0) protocolFees.token0 += uint128(fees0);
            feeGrowthGlobal0X128 += FullMath.mulDiv(
                paid0 - fees0,
                FixedPoint128.Q128,
                _liquidity
            );
        }
        if (paid1 > 0) {
            uint8 feeProtocol1 = slot0.feeProtocol >> 4;
            uint256 fees1 = feeProtocol1 == 0 ? 0 : paid1 / feeProtocol1;
            if (uint128(fees1) > 0) protocolFees.token1 += uint128(fees1);
            feeGrowthGlobal1X128 += FullMath.mulDiv(
                paid1 - fees1,
                FixedPoint128.Q128,
                _liquidity
            );
        }

        emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    function setFeeProtocol(
        uint8 feeProtocol0,
        uint8 feeProtocol1
    ) external override lock onlyFactoryOwner {
        require(
            (feeProtocol0 == 0 || (feeProtocol0 >= 4 && feeProtocol0 <= 10)) &&
                (feeProtocol1 == 0 || (feeProtocol1 >= 4 && feeProtocol1 <= 10))
        );
        uint8 feeProtocolOld = slot0.feeProtocol;
        slot0.feeProtocol = feeProtocol0 + (feeProtocol1 << 4);
        emit SetFeeProtocol(
            feeProtocolOld % 16,
            feeProtocolOld >> 4,
            feeProtocol0,
            feeProtocol1
        );
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    function collectProtocol(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    )
        external
        override
        lock
        onlyFactoryOwner
        returns (uint128 amount0, uint128 amount1)
    {
        amount0 = amount0Requested > protocolFees.token0
            ? protocolFees.token0
            : amount0Requested;
        amount1 = amount1Requested > protocolFees.token1
            ? protocolFees.token1
            : amount1Requested;

        if (amount0 > 0) {
            if (amount0 == protocolFees.token0) amount0--; // ensure that the slot is not cleared, for gas savings
            protocolFees.token0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            if (amount1 == protocolFees.token1) amount1--; // ensure that the slot is not cleared, for gas savings
            protocolFees.token1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit CollectProtocol(msg.sender, recipient, amount0, amount1);
    }
}
