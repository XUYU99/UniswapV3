// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "contracts/uniswap/v3-core/libraries/SafeCast.sol";
import "contracts/uniswap/v3-core/libraries/TickMath.sol";
import "contracts/uniswap/v3-core/interfaces/IUniswapV3Pool.sol";

import "./interfaces/ISwapRouter.sol";
import "./base/PeripheryImmutableState.sol";
import "./base/PeripheryValidation.sol";
import "./base/PeripheryPaymentsWithFee.sol";
import "./base/Multicall.sol";
import "./base/SelfPermit.sol";
import "./libraries/Path.sol";
import "./libraries/PoolAddress.sol";
import "./libraries/CallbackValidation.sol";
import "./interfaces/external/IWETH9.sol";

import "hardhat/console.sol";

/// @title Uniswap V3 Swap Router
/// @notice 无状态执行 Uniswap V3 交易的路由器
contract SwapRouter is
    ISwapRouter,
    PeripheryImmutableState,
    PeripheryValidation,
    PeripheryPaymentsWithFee,
    Multicall,
    SelfPermit
{
    using Path for bytes;
    using SafeCast for uint256;

    // 默认缓存值，用于精确输出交易时缓存输入金额
    uint256 private constant DEFAULT_AMOUNT_IN_CACHED = type(uint256).max;

    // 缓存变量，用于 exactOutput 交易中记录实际消耗的 tokenIn 数量
    uint256 private amountInCached = DEFAULT_AMOUNT_IN_CACHED;

    constructor(
        address _factory,
        address _WETH9
    ) PeripheryImmutableState(_factory, _WETH9) {}

    /// @dev 根据 token 对和手续费获取池地址
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) private view returns (IUniswapV3Pool) {
        return
            IUniswapV3Pool(
                PoolAddress.computeAddress(
                    factory,
                    PoolAddress.getPoolKey(tokenA, tokenB, fee)
                )
            );
    }

    struct SwapCallbackData {
        bytes path; // 路径编码（包括 tokenA、fee、tokenB）
        address payer; // 付款地址
    }

    /// @inheritdoc IUniswapV3SwapCallback
    /// @notice swap 操作的回调函数，在 swap 调用时由池合约调用此函数
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external override {
        // console.log(
        //     "SwapRouter-uniswapV3SwapCallback()-amount0Delta: %s, amount1Delta: %s",
        //     uint256(amount0Delta),
        //     uint256(amount1Delta)
        // );
        console.log("SwapRouter-uniswapV3SwapCallback()");
        console.logInt(amount0Delta);
        console.logInt(amount1Delta);
        require(amount0Delta > 0 || amount1Delta > 0, "Zero swap delta");
        SwapCallbackData memory data = abi.decode(_data, (SwapCallbackData));
        (address tokenIn, address tokenOut, uint24 fee) = data
            .path
            .decodeFirstPool();

        // 校验调用者是否合法池合约
        CallbackValidation.verifyCallback(factory, tokenIn, tokenOut, fee);

        // 判断支付方向
        (bool isExactInput, uint256 amountToPay) = amount0Delta > 0
            ? (tokenIn < tokenOut, uint256(amount0Delta))
            : (tokenOut < tokenIn, uint256(amount1Delta));

        if (isExactInput) {
            // 精确输入：直接付款
            pay(tokenIn, data.payer, msg.sender, amountToPay);
        } else {
            // 精确输出逻辑
            if (data.path.hasMultiplePools()) {
                // 多跳路径时，递归进行下一跳 exactOutputInternal
                data.path = data.path.skipToken();
                exactOutputInternal(amountToPay, msg.sender, 0, data);
            } else {
                // 最后一跳，记录实际输入金额并付款
                amountInCached = amountToPay;
                tokenIn = tokenOut; // 因 exact output 是反向的
                pay(tokenIn, data.payer, msg.sender, amountToPay);
            }
        }
    }

    /// @dev 内部执行单次精确输入交易
    function exactInputInternal(
        uint256 amountIn,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) private returns (uint256 amountOut) {
        // console.log("SwapRouter-exactInputInternal()-111");
        if (recipient == address(0)) recipient = address(this);
        (address tokenIn, address tokenOut, uint24 fee) = data
            .path
            .decodeFirstPool();
        bool zeroForOne = tokenIn < tokenOut;
        // console.log(
        //     "SwapRouter-exactInputInternal()-tokenIn",
        //     address(tokenIn),
        //     address(tokenOut),
        //     bool(zeroForOne)
        // );
        // 调用池合约 swap 函数
        (int256 amount0, int256 amount1) = getPool(tokenIn, tokenOut, fee).swap(
            recipient,
            zeroForOne,
            amountIn.toInt256(),
            sqrtPriceLimitX96 == 0
                ? (
                    zeroForOne
                        ? TickMath.MIN_SQRT_RATIO + 1
                        : TickMath.MAX_SQRT_RATIO - 1
                )
                : sqrtPriceLimitX96,
            abi.encode(data)
        );
        console.log(
            "SwapRouter-exactInputInternal()-tokenIn",
            uint256(amount0),
            uint256(amount1),
            bool(zeroForOne)
        );
        // console.log("SwapRouter-exactInputInternal()-222");

        // 计算实际收到的 tokenOut 数量（为正）
        return uint256(-(zeroForOne ? amount1 : amount0));
    }

    /// @inheritdoc ISwapRouter
    /// @notice 精确输入单池交换
    function exactInputSingle(
        ExactInputSingleParams calldata params
    )
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        // console.log("SwapRouter-exactInputSingle()-111");
        amountOut = exactInputInternal(
            params.amountIn,
            params.recipient,
            params.sqrtPriceLimitX96,
            SwapCallbackData({
                path: abi.encodePacked(
                    params.tokenIn,
                    params.fee,
                    params.tokenOut
                ),
                payer: msg.sender
            })
        );
        require(amountOut >= params.amountOutMinimum, "Too little received");
    }

    /// @inheritdoc ISwapRouter
    /// @notice 精确输入多池交换（支持路径）
    function exactInput(
        ExactInputParams memory params
    )
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        address payer = msg.sender;
        while (true) {
            bool hasMultiplePools = params.path.hasMultiplePools();
            params.amountIn = exactInputInternal(
                params.amountIn,
                hasMultiplePools ? address(this) : params.recipient,
                0,
                SwapCallbackData({
                    path: params.path.getFirstPool(),
                    payer: payer
                })
            );
            if (hasMultiplePools) {
                payer = address(this);
                params.path = params.path.skipToken();
            } else {
                amountOut = params.amountIn;
                break;
            }
        }
        require(amountOut >= params.amountOutMinimum, "Too little received");
    }

    /// @dev 内部执行精确输出交易
    function exactOutputInternal(
        uint256 amountOut,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) private returns (uint256 amountIn) {
        if (recipient == address(0)) recipient = address(this);
        (address tokenOut, address tokenIn, uint24 fee) = data
            .path
            .decodeFirstPool();
        bool zeroForOne = tokenIn < tokenOut;

        (int256 amount0Delta, int256 amount1Delta) = getPool(
            tokenIn,
            tokenOut,
            fee
        ).swap(
                recipient,
                zeroForOne,
                -amountOut.toInt256(),
                sqrtPriceLimitX96 == 0
                    ? (
                        zeroForOne
                            ? TickMath.MIN_SQRT_RATIO + 1
                            : TickMath.MAX_SQRT_RATIO - 1
                    )
                    : sqrtPriceLimitX96,
                abi.encode(data)
            );

        uint256 amountOutReceived;
        (amountIn, amountOutReceived) = zeroForOne
            ? (uint256(amount0Delta), uint256(-amount1Delta))
            : (uint256(amount1Delta), uint256(-amount0Delta));

        if (sqrtPriceLimitX96 == 0) require(amountOutReceived == amountOut);
    }

    /// @inheritdoc ISwapRouter
    /// @notice 精确输出单池交换
    function exactOutputSingle(
        ExactOutputSingleParams calldata params
    )
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        amountIn = exactOutputInternal(
            params.amountOut,
            params.recipient,
            params.sqrtPriceLimitX96,
            SwapCallbackData({
                path: abi.encodePacked(
                    params.tokenOut,
                    params.fee,
                    params.tokenIn
                ),
                payer: msg.sender
            })
        );
        require(amountIn <= params.amountInMaximum, "Too much requested");
        amountInCached = DEFAULT_AMOUNT_IN_CACHED;
    }

    /// @inheritdoc ISwapRouter
    /// @notice 精确输出多池交换（支持路径）
    function exactOutput(
        ExactOutputParams calldata params
    )
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        exactOutputInternal(
            params.amountOut,
            params.recipient,
            0,
            SwapCallbackData({path: params.path, payer: msg.sender})
        );
        amountIn = amountInCached;
        require(amountIn <= params.amountInMaximum, "Too much requested");
        amountInCached = DEFAULT_AMOUNT_IN_CACHED;
    }
}
