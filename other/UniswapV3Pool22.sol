// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

// 引入 Uniswap V3 池子的接口
import "./interfaces/IUniswapV3Pool.sol";

// 引入防委托调用（No Delegate Call）的逻辑
import "./NoDelegateCall.sol";

// 引入多个数学及安全库
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

// 引入池子部署及工厂接口
import "./interfaces/IUniswapV3PoolDeployer.sol";
import "./interfaces/IUniswapV3Factory.sol";
// 引入最小化 ERC20 接口
import "./interfaces/IERC20Minimal.sol";
// 引入回调接口
import "./interfaces/callback/IUniswapV3MintCallback.sol";
import "./interfaces/callback/IUniswapV3SwapCallback.sol";
import "./interfaces/callback/IUniswapV3FlashCallback.sol";
import "hardhat/console.sol";

/// @title UniswapV3Pool 合约
/// @notice 实现 Uniswap V3 池子核心逻辑，包括 swap、mint、burn、flash、观察价格变化等功能
contract UniswapV3Pool22 is IUniswapV3Pool, NoDelegateCall {
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

    // 定义存储槽结构，保存池子当前状态
    struct Slot0 {
        // 当前价格的 sqrt(P) 以 Q64.96 格式表示
        uint160 sqrtPriceX96;
        // 当前 tick
        int24 tick;
        // 最近一次观察的索引
        uint16 observationIndex;
        // 当前存储的观察数量上限
        uint16 observationCardinality;
        // 下一次增加观察数量的上限（在 observations.write 中触发）
        uint16 observationCardinalityNext;
        // 当前协议费（占比，用整数分母表示，如 1/x）
        uint8 feeProtocol;
        // 池子是否解锁
        bool unlocked;
    }
    /// @inheritdoc IUniswapV3PoolState
    Slot0 public override slot0;

    /// @inheritdoc IUniswapV3PoolState
    uint256 public override feeGrowthGlobal0X128; // 全局 token0 手续费增长累计值
    /// @inheritdoc IUniswapV3PoolState
    uint256 public override feeGrowthGlobal1X128; // 全局 token1 手续费增长累计值

    // 定义协议手续费结构（以 token0 和 token1 单位保存）
    struct ProtocolFees {
        uint128 token0;
        uint128 token1;
    }
    /// @inheritdoc IUniswapV3PoolState
    ProtocolFees public override protocolFees;

    /// @inheritdoc IUniswapV3PoolState
    uint128 public override liquidity; // 当前处于活跃状态的总流动性

    /// @inheritdoc IUniswapV3PoolState
    mapping(int24 => Tick.Info) public override ticks; // tick 映射：记录每个 tick 的信息
    /// @inheritdoc IUniswapV3PoolState
    mapping(int16 => uint256) public override tickBitmap; // 用于标识某区间内哪些 tick 已被初始化
    /// @inheritdoc IUniswapV3PoolState
    mapping(bytes32 => Position.Info) public override positions; // 头寸映射
    /// @inheritdoc IUniswapV3PoolState
    Oracle.Observation[65535] public override observations; // 价格观测数组

    /// @dev 互斥锁：防止重入，同时也防止池未初始化前执行函数
    modifier lock() {
        require(slot0.unlocked, "LOK");
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    /// @dev 限制只能由工厂拥有者调用（通过 IUniswapV3Factory.owner() 检查）
    modifier onlyFactoryOwner() {
        require(msg.sender == IUniswapV3Factory(factory).owner());
        _;
    }

    /// @notice 构造函数，池子部署时由 UniswapV3PoolDeployer 调用，参数来自部署者
    constructor() {
        // 通过调用部署合约时传入的参数获得 factory、token0、token1、fee 和 tickSpacing
        int24 _tickSpacing;
        (factory, token0, token1, fee, _tickSpacing) = IUniswapV3PoolDeployer(
            msg.sender
        ).parameters();
        tickSpacing = _tickSpacing;

        // 根据 tickSpacing 计算每个 tick 最大流动性
        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(
            _tickSpacing
        );
    }

    /// @dev 检查 tick 参数有效性，必须 tickLower < tickUpper 且在允许范围内
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper, "TLU");
        require(tickLower >= TickMath.MIN_TICK, "TLM");
        require(tickUpper <= TickMath.MAX_TICK, "TUM");
    }

    /// @dev 返回 32 位的当前区块时间戳（取模 2^32）
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // 期望截断为 32 位
    }

    /// @dev 获取池子中 token0 的余额（采用 staticcall 优化 gas）
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

    /// @dev 获取池子中 token1 的余额（同样采用 staticcall 优化）
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
        // 检查传入的 tick 是否有效
        checkTicks(tickLower, tickUpper);

        int56 tickCumulativeLower;
        int56 tickCumulativeUpper;
        uint160 secondsPerLiquidityOutsideLowerX128;
        uint160 secondsPerLiquidityOutsideUpperX128;
        uint32 secondsOutsideLower;
        uint32 secondsOutsideUpper;

        {
            // 从 ticks 映射中获取下界和上界 tick 的外侧手续费数据
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
            require(initializedLower, "Lower tick not initialized");

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
            require(initializedUpper, "Upper tick not initialized");
        }

        Slot0 memory _slot0 = slot0;

        if (_slot0.tick < tickLower) {
            // 当前价格在头寸下界左侧
            return (
                tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityOutsideLowerX128 -
                    secondsPerLiquidityOutsideUpperX128,
                secondsOutsideLower - secondsOutsideUpper
            );
        } else if (_slot0.tick < tickUpper) {
            // 当前价格在头寸范围内
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
            // 当前价格在头寸上界右侧
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
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext; // 保存之前的卡片数
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
    /// @dev 此函数不加锁，因为初始化前池子必须处于解锁状态
    function initialize(uint160 sqrtPriceX96) external override {
        require(slot0.sqrtPriceX96 == 0, "AI");

        // 根据传入的 sqrtPriceX96 计算初始 tick
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
        console.log("UniswapV3Pool-initialize()-tick:");
        console.logInt(int256(tick)); // 强制转换 tick 为 int256 类型进行输出
        // 初始化观察数组
        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(
            _blockTimestamp()
        );
        console.log(
            "UniswapV3Pool-initialize()-cardinality_and_cardinalityNext:",
            uint256(cardinality),
            uint256(cardinalityNext)
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
        // console.log("UniswapV3Pool-initialize()-slot0:", slot0);
        emit Initialize(sqrtPriceX96, tick);
    }

    // 定义修改 position 的参数结构体
    struct ModifyPositionParams {
        // 头寸所有者地址
        address owner;
        // 头寸价格范围下界
        int24 tickLower;
        // 头寸价格范围上界
        int24 tickUpper;
        // 流动性增量（正为增加，负为减少）
        int128 liquidityDelta;
    }

    /// @dev 修改头寸的内部函数
    /// @param params 头寸的参数及流动性增量
    /// @return position 头寸存储结构的引用
    /// @return amount0 token0 的变化量（负数表示池子支付给头寸所有者）
    /// @return amount1 token1 的变化量（负数表示池子支付给头寸所有者）
    function _modifyPosition(
        ModifyPositionParams memory params
    )
        private
        noDelegateCall
        returns (Position.Info storage position, int256 amount0, int256 amount1)
    {
        // 检查传入的 tick 参数是否有效
        checkTicks(params.tickLower, params.tickUpper);

        Slot0 memory _slot0 = slot0; // 加载当前槽状态以节省 gas

        // 更新头寸，并计算流动性变化对应的 token 数量变化
        position = _updatePosition(
            params.owner,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta,
            _slot0.tick
        );

        if (params.liquidityDelta != 0) {
            if (_slot0.tick < params.tickLower) {
                // 当前 tick 低于头寸下界：此时头寸仅依赖 token0
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            } else if (_slot0.tick < params.tickUpper) {
                // 当前 tick 在头寸区间内：头寸同时依赖 token0 和 token1

                // 记录观察数据，更新 Oracle 观察记录
                uint128 liquidityBefore = liquidity; // 提前加载流动性以节省 gas

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

                // 计算 token0 和 token1 对应的数量变化（均衡调仓公式）
                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    _slot0.sqrtPriceX96,
                    params.liquidityDelta
                );

                liquidity = LiquidityMath.addDelta(
                    liquidityBefore,
                    params.liquidityDelta
                );
            } else {
                // 当前 tick 高于头寸上界：此时头寸仅依赖 token1
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }
    }

    /// @dev 更新头寸信息，并计算对应的手续费增长，更新 tick 数据
    /// @param owner 头寸所有者
    /// @param tickLower 头寸下界
    /// @param tickUpper 头寸上界
    /// @param liquidityDelta 流动性变化
    /// @param tick 当前全局价格 tick
    function _updatePosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tick
    ) private returns (Position.Info storage position) {
        // 获取该头寸（通过 owner, tickLower, tickUpper 的唯一标识）
        position = positions.get(owner, tickLower, tickUpper);

        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128; // 加载全局 token0 手续费累计，用于后续计算
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128; // 加载全局 token1 手续费累计

        // 如果流动性变化不为 0，则更新对应的 tick 数据
        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) {
            uint32 time = _blockTimestamp();
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

            // 更新头寸下界 tick 的状态（包括手续费成长和流动性）
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
            // 更新头寸上界 tick 的状态（传入 true 表示上界）
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

            // 如果 tick 数据状态发生翻转，则更新 tickBitmap 标识
            if (flippedLower) {
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }
        }

        // 计算头寸区间内的手续费增长
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = ticks
            .getFeeGrowthInside(
                tickLower,
                tickUpper,
                tick,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128
            );

        // 更新该头寸存储的数据（流动性变化以及内部手续费增长）
        position.update(
            liquidityDelta,
            feeGrowthInside0X128,
            feeGrowthInside1X128
        );

        // 若流动性减少（burn），若 tick 被完全释放（归零），清理对应的 tick 数据以节省 gas
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
    /// @dev mint 函数增加流动性，将对应的 token 数量存入池中
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        require(amount > 0);
        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: recipient,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(amount).toInt128()
            })
        );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(
            amount0,
            amount1,
            data
        );
        if (amount0 > 0)
            require(balance0Before.add(amount0) <= balance0(), "M0");
        if (amount1 > 0)
            require(balance1Before.add(amount1) <= balance1(), "M1");

        emit Mint(
            msg.sender,
            recipient,
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
        // 无需检查 tick，有效位置的 tokensOwed 已记录为非零
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
    /// @dev burn 函数减少流动性，将对应的 token 数额返回给头寸所有者，同时累积应得手续费
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
        // 记录输入 token 的协议手续费参数
        uint8 feeProtocol;
        // 交易开始时的流动性
        uint128 liquidityStart;
        // 当前区块时间戳
        uint32 blockTimestamp;
        // 如果跨越一个已初始化的 tick，则缓存计算后的 tick 累计值
        int56 tickCumulative;
        // 如果跨越一个已初始化的 tick，则缓存计算后的每单位流动性累计秒数
        uint160 secondsPerLiquidityCumulativeX128;
        // 标志：是否已经计算最新观察数据
        bool computedLatestObservation;
    }

    // 交换状态，记录 swap 过程中的状态变量，最终写入 storage
    struct SwapState {
        // 剩余未交换的输入或输出 token 数量
        int256 amountSpecifiedRemaining;
        // 已交换的 token 数量（正表示 input 已支付，负表示输出已收取）
        int256 amountCalculated;
        // 当前价格对应的 √P
        uint160 sqrtPriceX96;
        // 当前 tick 值（与当前价格对应）
        int24 tick;
        // 当前激活流动性对应的全局手续费增长记录（输入 token 对应）
        uint256 feeGrowthGlobalX128;
        // 协议手续费支付的 token 数量
        uint128 protocolFee;
        // 当前区间内的有效流动性
        uint128 liquidity;
    }

    struct StepComputations {
        // 本步开始时的 √P
        uint160 sqrtPriceStartX96;
        // 本步目标 tick
        int24 tickNext;
        // 目标 tick 是否已初始化
        bool initialized;
        // 目标 tick 对应的 √P
        uint160 sqrtPriceNextX96;
        // 本步消耗的输入 token 数量
        uint256 amountIn;
        // 本步获得的输出 token 数量
        uint256 amountOut;
        // 本步支付的手续费数量
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
        require(amountSpecified != 0, "AS");

        Slot0 memory slot0Start = slot0;

        require(slot0Start.unlocked, "LOK");
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 &&
                    sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 &&
                    sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            "SPL"
        );

        slot0.unlocked = false;

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

        bool exactInput = amountSpecified > 0;

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

        // 当剩余待交换数量不为 0 且未达到价格限制时，持续执行 swap
        while (
            state.amountSpecifiedRemaining != 0 &&
            state.sqrtPriceX96 != sqrtPriceLimitX96
        ) {
            StepComputations memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) = tickBitmap
                .nextInitializedTickWithinOneWord(
                    state.tick,
                    tickSpacing,
                    zeroForOne
                );

            // 限制 tick 范围，防止超出允许的最小/最大 tick
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // 获取目标 tick 对应的 √P
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // 计算本步交易时的各项数据（例如消耗的输入、获得的输出和手续费）
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

            // 如果协议手续费开启，则计算并扣除相应手续费
            if (cache.feeProtocol > 0) {
                uint256 delta = step.feeAmount / cache.feeProtocol;
                step.feeAmount -= delta;
                state.protocolFee += uint128(delta);
            }

            // 更新全局手续费增长记录，每单位流动性增长一定数额的手续费
            if (state.liquidity > 0)
                state.feeGrowthGlobalX128 += FullMath.mulDiv(
                    step.feeAmount,
                    FixedPoint128.Q128,
                    state.liquidity
                );

            // 如果达到目标 tick，则更新当前 tick，否则更新当前 price 后重新计算当前 tick
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
                        (
                            zeroForOne
                                ? state.feeGrowthGlobalX128
                                : feeGrowthGlobal0X128
                        ),
                        (
                            zeroForOne
                                ? feeGrowthGlobal1X128
                                : state.feeGrowthGlobalX128
                        ),
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

        // 更新 tick 并写入 Oracle 观察数据（如果 tick 发生变化）
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
            // 否则只更新价格
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // 如果流动性发生改变，则更新状态变量 liquidity
        if (cache.liquidityStart != state.liquidity)
            liquidity = state.liquidity;

        // 更新全局手续费增长，如果协议手续费开启，则累加协议手续费
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
        }

        // 计算最终 swap 返回的金额
        (amount0, amount1) = zeroForOne == exactInput
            ? (
                amountSpecified - state.amountSpecifiedRemaining,
                state.amountCalculated
            )
            : (
                state.amountCalculated,
                amountSpecified - state.amountSpecifiedRemaining
            );

        // 根据 swap 方向，进行相应的转账和回调
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

        emit Swap(
            msg.sender,
            recipient,
            amount0,
            amount1,
            state.sqrtPriceX96,
            state.liquidity,
            state.tick
        );
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
            if (amount0 == protocolFees.token0) amount0--; // 避免槽位被清空以节省 gas
            protocolFees.token0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            if (amount1 == protocolFees.token1) amount1--; // 避免槽位被清空以节省 gas
            protocolFees.token1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit CollectProtocol(msg.sender, recipient, amount0, amount1);
    }
}
