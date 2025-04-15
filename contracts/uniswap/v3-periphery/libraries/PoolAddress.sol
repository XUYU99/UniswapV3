// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;
import "hardhat/console.sol";

/// @title 提供从 factory、代币和手续费推导池地址的函数库
library PoolAddress {
    // 初始化代码哈希，用于 CREATE2 地址计算（Uniswap V3 Pool 的部署代码哈希）
    bytes32 internal constant POOL_INIT_CODE_HASH =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    /// @notice 表示池子的唯一标识键（token0、token1 和 fee 的组合）
    struct PoolKey {
        address token0;
        address token1;
        uint24 fee;
    }

    /// @notice 返回 PoolKey：排序后的 token0 和 token1 以及手续费
    /// @param tokenA 未排序的第一个代币地址
    /// @param tokenB 未排序的第二个代币地址
    /// @param fee 池子的手续费级别
    /// @return PoolKey 返回包含排序后的 token0 和 token1 的池子标识信息
    function getPoolKey(
        address tokenA,
        address tokenB,
        uint24 fee
    ) internal pure returns (PoolKey memory) {
        // 保证 token0 始终小于 token1，以确保池子唯一性（tokenA/tokenB 与 tokenB/tokenA 是同一个池）
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        return PoolKey({token0: tokenA, token1: tokenB, fee: fee});
    }

    /// @notice 通过 factory 地址和 PoolKey 计算池子的确定性地址
    /// @param factory Uniswap V3 工厂合约地址
    /// @param key 由 token0、token1 和 fee 组成的池子标识
    /// @return pool 返回计算出的池子合约地址
    function computeAddress(
        address factory,
        PoolKey memory key
    ) internal pure returns (address pool) {
        require(key.token0 < key.token1); // 再次校验 token 顺序，确保唯一性

        // 使用 CREATE2 地址推导公式计算池子的地址
        pool = address(
            uint256(
                keccak256(
                    abi.encodePacked(
                        hex"ff", // 固定前缀
                        factory, // 工厂合约地址
                        keccak256(
                            abi.encode(key.token0, key.token1, key.fee) // 池子的 salt = keccak(token0, token1, fee)
                        ),
                        POOL_INIT_CODE_HASH // 池子合约初始化代码的哈希
                    )
                )
            )
        );
        console.log("PoolAddress.computeAddress(factory, key)-pool: %s", pool);
    }
}
