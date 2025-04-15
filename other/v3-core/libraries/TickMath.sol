// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0 <0.8.0;

/// @title Tick 与平方根价格转换的数学库
/// @notice 用于计算 tick 与 sqrtPriceX96 之间的转换，其中价格单位为 1.0001，每个 tick 表示价格变动 0.01%
/// 支持的价格范围在 2**-128 到 2**128 之间，使用定点数 Q64.96 表示
library TickMath {
    /// @dev 允许传入 getSqrtRatioAtTick 的最小 tick，等于 log_1.0001(2**-128)
    int24 internal constant MIN_TICK = -887272;
    /// @dev 允许传入 getSqrtRatioAtTick 的最大 tick，等于 log_1.0001(2**128)
    int24 internal constant MAX_TICK = -MIN_TICK;

    /// @dev tick 为 MIN_TICK 时，对应的最小 sqrtPriceX96 值
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /// @dev tick 为 MAX_TICK 时，对应的最大 sqrtPriceX96 值
    uint160 internal constant MAX_SQRT_RATIO =
        1461446703485210103287273052203988822378723970342;

    /// @notice 计算 sqrt(1.0001^tick) * 2^96
    /// @dev tick 的绝对值不能超过 MAX_TICK，否则抛出异常
    /// @param tick 输入的价格刻度
    /// @return sqrtPriceX96 输出的 Q64.96 格式的价格平方根
    function getSqrtRatioAtTick(
        int24 tick
    ) internal pure returns (uint160 sqrtPriceX96) {
        // 获取 tick 的绝对值
        uint256 absTick = tick < 0
            ? uint256(-int256(tick))
            : uint256(int256(tick));
        require(absTick <= uint256(MAX_TICK), "T");
        // 初始化 ratio，按二进制位分解 tick 并乘上预计算常数
        uint256 ratio = absTick & 0x1 != 0
            ? 0xfffcb933bd6fad37aa2d162d1a594001
            : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0)
            ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0)
            ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0)
            ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0)
            ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0)
            ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0)
            ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0)
            ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0)
            ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0)
            ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0)
            ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0)
            ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0)
            ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0)
            ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0)
            ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0)
            ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0)
            ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0)
            ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0)
            ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0)
            ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        // 如果 tick 为正数，需要取倒数
        if (tick > 0) ratio = type(uint256).max / ratio;
        // 将结果从 Q128.128 转换为 Q64.96，向上取整确保一致性
        sqrtPriceX96 = uint160(
            (ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1)
        );
        // console.log("TickMath-getSqrtRatioAtTick()-end");
    }

    /// @notice 计算满足 getRatioAtTick(tick) <= ratio 的最大 tick 值
    /// @dev 如果 sqrtPriceX96 小于 MIN_SQRT_RATIO 则抛出异常，因为 MIN_SQRT_RATIO 是 getRatioAtTick 可能返回的最低值
    /// @param sqrtPriceX96 用于计算 tick 的平方根价格，格式为 Q64.96
    /// @return tick 对应于输入价格小于或等于的最大 tick 值
    function getTickAtSqrtRatio(
        uint160 sqrtPriceX96
    ) internal pure returns (int24 tick) {
        // 检查输入的平方根价格是否在有效范围内：[MIN_SQRT_RATIO, MAX_SQRT_RATIO)
        // 注意：第二个不等式为 <，因为价格永远无法达到最大 tick 对应的价格
        require(
            sqrtPriceX96 >= MIN_SQRT_RATIO && sqrtPriceX96 < MAX_SQRT_RATIO,
            "R"
        );

        // 将 Q64.96 格式的平方根价格转换为更高精度的比率（左移 32 位，相当于乘以 2^32）
        uint256 ratio = uint256(sqrtPriceX96) << 32;

        uint256 r = ratio;
        uint256 msb = 0;

        assembly {
            // 如果 r 大于 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF，则左移 7 位
            let f := shl(7, gt(r, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            // 如果 r 大于 0xFFFFFFFFFFFFFFFF，则左移 6 位
            let f := shl(6, gt(r, 0xFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            // 如果 r 大于 0xFFFFFFFF，则左移 5 位
            let f := shl(5, gt(r, 0xFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            // 如果 r 大于 0xFFFF，则左移 4 位
            let f := shl(4, gt(r, 0xFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            // 如果 r 大于 0xFF，则左移 3 位
            let f := shl(3, gt(r, 0xFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            // 如果 r 大于 0xF，则左移 2 位
            let f := shl(2, gt(r, 0xF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            // 如果 r 大于 0x3，则左移 1 位
            let f := shl(1, gt(r, 0x3))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            // 如果 r 大于 0x1，则设置 f 为 1
            let f := gt(r, 0x1)
            msb := or(msb, f)
        }

        // 根据 msb 的值调整 r，使得 r 的二进制表示为 127 位有效数字
        if (msb >= 128) r = ratio >> (msb - 127);
        else r = ratio << (127 - msb);

        // 初始化 log_2 为整数部分 (msb - 128) 左移 64 位，用于存储对数的固定点表示
        int256 log_2 = (int256(msb) - 128) << 64;

        // 以下通过一系列的平方和右移操作，迭代地计算二进制对数的分数部分
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(63, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(62, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(61, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(60, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(59, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(58, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(57, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(56, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(55, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(54, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(53, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(52, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(51, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(50, f))
        }

        // 计算 log_sqrt10001，使用固定常数进行缩放（此处为 128.128 格式）
        int256 log_sqrt10001 = log_2 * 255738958999603826347141; // 128.128 数值

        // 根据 log_sqrt10001 计算 tick 的下界和上界
        int24 tickLow = int24(
            (log_sqrt10001 - 3402992956809132418596140100660247210) >> 128
        );
        int24 tickHi = int24(
            (log_sqrt10001 + 291339464771989622907027621153398088495) >> 128
        );

        // 如果 tickLow 与 tickHi 相等则返回该值，否则根据 getSqrtRatioAtTick 比较确认最终返回 tickHi 或 tickLow
        tick = tickLow == tickHi
            ? tickLow
            : getSqrtRatioAtTick(tickHi) <= sqrtPriceX96
            ? tickHi
            : tickLow;
    }
}
