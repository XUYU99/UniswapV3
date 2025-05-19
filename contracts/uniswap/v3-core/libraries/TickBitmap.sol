// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import "./BitMath.sol";

/// @title Packed tick initialized state library
/// @notice Stores a packed mapping of tick index to its initialized state
/// @dev The mapping uses int16 for keys since ticks are represented as int24 and there are 256 (2^8) values per word.
library TickBitmap {
    /// @notice Computes the position in the mapping where the initialized bit for a tick lives
    /// @param tick The tick for which to compute the position
    /// @return wordPos The key in the mapping containing the word in which the bit is stored
    /// @return bitPos The bit position in the word where the flag is stored
    function position(
        int24 tick
    ) internal pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(tick % 256);
    }

    /// @notice Flips the initialized state for a given tick from false to true, or vice versa
    /// @param self The mapping in which to flip the tick
    /// @param tick The tick to flip
    /// @param tickSpacing The spacing between usable ticks
    function flipTick(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing
    ) internal {
        require(tick % tickSpacing == 0); // ensure that the tick is spaced
        (int16 wordPos, uint8 bitPos) = position(tick / tickSpacing);
        uint256 mask = 1 << bitPos;
        self[wordPos] ^= mask;
    }

    /// @notice 返回与给定 tick 处于相同（或相邻）word 中的下一个已初始化的 tick
    /// @dev 每个 word 表示 256 个 tick bitmap 位，本函数只在这 256 位内查找
    /// @param self tick bitmap 的存储映射（int16 => uint256，每个 uint256 表示 256 个 tick 的初始化状态）
    /// @param tick 当前 tick 起始位置
    /// @param tickSpacing tick 间隔（决定哪些 tick 是合法的）
    /// @param lte 是否向左查找（小于等于 tick），否则向右查找（大于 tick）
    /// @return next 下一个（最多 ±256 个 tick）方向上的合法 tick（初始化或未初始化）
    /// @return initialized 返回的 tick 是否已初始化（true 表示已被添加过流动性）
    function nextInitializedTickWithinOneWord(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
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
            uint256 masked = self[wordPos] & mask;

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
            uint256 masked = self[wordPos] & mask;

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
    }

    // /// @notice 返回与给定 tick 处于相同（或相邻）word 中的下一个已初始化的 tick
    // /// @dev 每个 word 表示 256 个 tick bitmap 位，本函数只在这 256 位内查找
    // /// @param tick 当前 tick 起始位置
    // /// @param tickSpacing tick 间隔（决定哪些 tick 是合法的）
    // /// @param lte 是否向左查找（小于等于 tick），否则向右查找（大于 tick）
    // /// @return next 下一个（最多 ±256 个 tick）方向上的合法 tick（初始化或未初始化）
    // /// @return initialized 返回的 tick 是否已初始化（true 表示已被添加过流动性）
    // function nextInitializedTickWithinOneWord2(
    //     uint256 arrayWordPos,
    //     int24 tick,
    //     int24 tickSpacing,
    //     bool lte
    // ) public pure returns (int24 next, bool initialized) {
    //     // 压缩 tick，用 tickSpacing 折算成 bitmap 中的 bit 索引位置（每 tickSpacing 对应一位）
    //     int24 compressed = tick / tickSpacing;
    //     if (tick < 0 && tick % tickSpacing != 0) compressed--; // 向负无穷取整，保证精度一致

    //     if (lte) {
    //         // 向左查找（小于等于 tick）
    //         (int16 wordPos, uint8 bitPos) = position(compressed);
    //         // 生成掩码，保留 bitPos 右边及自身的所有位（右侧部分）

    //         uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
    //         //(1 << bitPos):只有 bitPos 位为 1 的值, 例子 1 << 5 = 0b0010_0000;
    //         //(1 << bitPos) - 1:例子 (1 << 5) - 1 =  0b0001_1111;
    //         //第二个(1 << bitPos): bitPos 位本身也变成 1, 例子 0b0001_1111 + 0b0010_0000 = 0b0011_1111
    //         uint256 masked = arrayWordPos & mask;

    //         // 判断是否存在被设置为 1（已初始化）的 tick
    //         initialized = masked != 0;

    //         // 如果找到了，返回最靠近当前 tick 的一个已初始化 tick
    //         // 否则返回本 word 中最右边的可能位置（未初始化）
    //         next = initialized
    //             ? (compressed -
    //                 int24(bitPos - BitMath.mostSignificantBit(masked))) *
    //                 tickSpacing
    //             : (compressed - int24(bitPos)) * tickSpacing;
    //     } else {
    //         // 向右查找（大于 tick）
    //         // 注意是 compressed + 1，跳过当前 tick 所在 word，从下一个 word 开始查
    //         (int16 wordPos, uint8 bitPos) = position(compressed + 1);
    //         // 生成掩码，保留 bitPos 左边及自身的所有位（左侧部分）
    //         uint256 mask = ~((1 << bitPos) - 1);
    //         uint256 masked = arrayWordPos & mask;

    //         // 判断是否存在被设置为 1（已初始化）的 tick
    //         initialized = masked != 0;

    //         // 如果找到了，返回最靠近当前 tick 的一个已初始化 tick
    //         // 否则返回最左边的可能位置（未初始化）
    //         next = initialized
    //             ? (compressed +
    //                 1 +
    //                 int24(BitMath.leastSignificantBit(masked) - bitPos)) *
    //                 tickSpacing
    //             : (compressed + 1 + int24(type(uint8).max - bitPos)) *
    //                 tickSpacing;
    //     }
    // }
}
