// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;

import "../libraries/TickBitmap.sol";
import "../interfaces/IUniswapV3Pool.sol";

contract TickBitmapTest {
    using TickBitmap for mapping(int16 => uint256);

    mapping(int16 => uint256) public bitmap;

    function position(
        int24 tick
    ) public pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(tick % 256);
    }

    function flipTick(int24 tick) external {
        bitmap.flipTick(tick, 60);
    }

    function getGasCostOfFlipTick(int24 tick) external returns (uint256) {
        uint256 gasBefore = gasleft();
        bitmap.flipTick(tick, 1);
        return gasBefore - gasleft();
    }

    function nextInitializedTickWithinOneWord(
        int24 tick,
        bool lte
    ) external view returns (int24 next, bool initialized) {
        return bitmap.nextInitializedTickWithinOneWord(tick, 60, lte);
    }

    function nextInitializedTickWithinOneWord2(
        uint256 arrayWordPos,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) external pure returns (int24 next, bool initialized) {
        // 压缩 tick，用 tickSpacing 折算成 bitmap 中的 bit 索引位置（每 tickSpacing 对应一位）
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // 向负无穷取整，保证精度一致

        if (lte) {
            // 向左查找（小于等于 tick）
            (int16 wordPos, uint8 bitPos) = position(compressed);
            // 生成掩码，保留 bitPos 右边及自身的所有位（右侧部分）

            uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
            //(1 << bitPos):只有 bitPos 位为 1 的值, 例子 1 << 5 = 0b0010_0000;
            //(1 << bitPos) - 1:例子 (1 << 5) - 1 =  0b0001_1111;
            //第二个(1 << bitPos): bitPos 位本身也变成 1, 例子 0b0001_1111 + 0b0010_0000 = 0b0011_1111
            uint256 masked = arrayWordPos & mask;

            // 判断是否存在被设置为 1（已初始化）的 tick
            initialized = masked != 0;

            // 如果找到了，返回最靠近当前 tick 的一个已初始化 tick
            // 否则返回本 word 中最右边的可能位置（未初始化）
            next = initialized
                ? (compressed -
                    int24(bitPos - BitMath.mostSignificantBit(masked))) *
                    tickSpacing
                : (compressed - int24(bitPos)) * tickSpacing;
        } else {
            // 向右查找（大于 tick）
            // 注意是 compressed + 1，跳过当前 tick 所在 word，从下一个 word 开始查
            (int16 wordPos, uint8 bitPos) = position(compressed + 1);
            // 生成掩码，保留 bitPos 左边及自身的所有位（左侧部分）
            uint256 mask = ~((1 << bitPos) - 1);
            uint256 masked = arrayWordPos & mask;

            // 判断是否存在被设置为 1（已初始化）的 tick
            initialized = masked != 0;

            // 如果找到了，返回最靠近当前 tick 的一个已初始化 tick
            // 否则返回最左边的可能位置（未初始化）
            next = initialized
                ? (compressed +
                    1 +
                    int24(BitMath.leastSignificantBit(masked) - bitPos)) *
                    tickSpacing
                : (compressed + 1 + int24(type(uint8).max - bitPos)) *
                    tickSpacing;
        }

        return (next, initialized);
    }

    function getGasCostOfNextInitializedTickWithinOneWord(
        int24 tick,
        bool lte
    ) external view returns (uint256) {
        uint256 gasBefore = gasleft();
        bitmap.nextInitializedTickWithinOneWord(tick, 1, lte);
        return gasBefore - gasleft();
    }

    // returns whether the given tick is initialized
    function isInitialized(int24 tick) external view returns (bool) {
        (int24 next, bool initialized) = bitmap
            .nextInitializedTickWithinOneWord(tick, 60, true);
        return next == tick ? initialized : false;
    }

    function isInitialized2(
        int24 tick,
        int24 tickSpacing,
        address pool
    ) public view returns (bool) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // 向下取整对齐

        int16 wordPos = int16(compressed >> 8); // bitmap 的位置
        uint8 bitPos = uint8(uint256(uint24(compressed % 256))); // bitmap 中的 bit 索引

        uint256 word = IUniswapV3Pool(pool).tickBitmap(wordPos);
        return (word & (1 << bitPos)) != 0;
    }
}
