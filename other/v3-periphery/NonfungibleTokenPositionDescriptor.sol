// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "contracts/uniswap/v2-core/interfaces/IUniswapV3Pool.sol";
import "../lib/contracts/libraries/SafeERC20Namer.sol";

import "./libraries/ChainId.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/INonfungibleTokenPositionDescriptor.sol";
import "./interfaces/IERC20Metadata.sol";
import "./libraries/PoolAddress.sol";
import "./libraries/NFTDescriptor.sol";
import "./libraries/TokenRatioSortOrder.sol";

/// @title NFT头寸元数据描述器合约
/// @notice 返回符合 ERC721 tokenURI 标准的 LP NFT 元数据 JSON 字符串
contract NonfungibleTokenPositionDescriptor is
    INonfungibleTokenPositionDescriptor
{
    // 预设在以太坊主网上的常见稳定币地址，用于排序优先级判断
    // address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    // address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    // address private constant TBTC = 0x8dAEBADE922dF735c38C80C7eBD708Af50815fAa;
    // address private constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // 记录 WETH 地址
    address public immutable WETH9;
    // 用于处理 ETH 显示名称的字节型标签（如 "ETH"）
    bytes32 public immutable nativeCurrencyLabelBytes;

    constructor(address _WETH9, bytes32 _nativeCurrencyLabelBytes) {
        WETH9 = _WETH9;
        nativeCurrencyLabelBytes = _nativeCurrencyLabelBytes;
    }

    /// @notice 将 nativeCurrencyLabelBytes 转换成字符串（如 "ETH"）
    function nativeCurrencyLabel() public view returns (string memory) {
        uint256 len = 0;
        while (len < 32 && nativeCurrencyLabelBytes[len] != 0) {
            len++;
        }
        bytes memory b = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            b[i] = nativeCurrencyLabelBytes[i];
        }
        return string(b);
    }

    /// @notice 实现 INonfungibleTokenPositionDescriptor 中的 tokenURI 接口
    /// @dev 生成指定 positionId 对应的元数据 JSON 字符串
    function tokenURI(
        INonfungiblePositionManager positionManager,
        uint256 tokenId
    ) external view override returns (string memory) {
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            ,
            ,
            ,
            ,

        ) = positionManager.positions(tokenId); // 获取头寸信息

        // 计算对应的 UniswapV3Pool 地址
        IUniswapV3Pool pool = IUniswapV3Pool(
            PoolAddress.computeAddress(
                positionManager.factory(),
                PoolAddress.PoolKey({token0: token0, token1: token1, fee: fee})
            )
        );

        // 判断是否需要翻转 token 顺序（base/quote）
        bool _flipRatio = flipRatio(token0, token1, ChainId.get());
        address quoteTokenAddress = !_flipRatio ? token1 : token0;
        address baseTokenAddress = !_flipRatio ? token0 : token1;

        // 获取当前价格 tick
        (, int24 tick, , , , , ) = pool.slot0();

        // 构造 JSON 元数据字符串
        return
            NFTDescriptor.constructTokenURI(
                NFTDescriptor.ConstructTokenURIParams({
                    tokenId: tokenId,
                    quoteTokenAddress: quoteTokenAddress,
                    baseTokenAddress: baseTokenAddress,
                    quoteTokenSymbol: quoteTokenAddress == WETH9
                        ? nativeCurrencyLabel()
                        : SafeERC20Namer.tokenSymbol(quoteTokenAddress),
                    baseTokenSymbol: baseTokenAddress == WETH9
                        ? nativeCurrencyLabel()
                        : SafeERC20Namer.tokenSymbol(baseTokenAddress),
                    quoteTokenDecimals: IERC20Metadata(quoteTokenAddress)
                        .decimals(),
                    baseTokenDecimals: IERC20Metadata(baseTokenAddress)
                        .decimals(),
                    flipRatio: _flipRatio,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    tickCurrent: tick,
                    tickSpacing: pool.tickSpacing(),
                    fee: fee,
                    poolAddress: address(pool)
                })
            );
    }

    /// @notice 比较两个 token 的优先级，用于决定 base/quote 谁在前
    function flipRatio(
        address token0,
        address token1,
        uint256 chainId
    ) public view returns (bool) {
        return
            tokenRatioPriority(token0, chainId) >
            tokenRatioPriority(token1, chainId);
    }

    /// @notice 返回 token 的排序优先级（数值越大，越靠近 quote 方向）
    function tokenRatioPriority(
        address token,
        uint256 chainId
    ) public view returns (int256) {
        // if (token == WETH9) return TokenRatioSortOrder.DENOMINATOR;
        // if (chainId == 1) {
        //     if (token == USDC) return TokenRatioSortOrder.NUMERATOR_MOST;
        //     else if (token == USDT) return TokenRatioSortOrder.NUMERATOR_MORE;
        //     else if (token == DAI) return TokenRatioSortOrder.NUMERATOR;
        //     else if (token == TBTC) return TokenRatioSortOrder.DENOMINATOR_MORE;
        //     else if (token == WBTC) return TokenRatioSortOrder.DENOMINATOR_MOST;
        //     else return 0;
        // }
        return 0;
    }
}
