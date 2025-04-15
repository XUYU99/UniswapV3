// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

/// @title Oracle
/// @notice 提供价格与流动性数据，便于系统设计中使用（例如用于 TWAP 计算）
/// @dev 存储在 oracle 数组中的每个 observation 记录了价格累积值、秒/流动性累积值等数据
library Oracle {
    // 观察数据结构
    struct Observation {
        // observation 的区块时间戳
        uint32 blockTimestamp;
        // tick 累积值（即 tick * 从池子初始化到此时的时间差）
        int56 tickCumulative;
        // 每单位流动性累计秒数（秒数 / max(1, liquidity)），采用 Q128 格式
        uint160 secondsPerLiquidityCumulativeX128;
        // 是否已经初始化
        bool initialized;
    }

    /// @notice 根据时间流逝、当前 tick 和流动性，将旧的 observation 转换为新的 observation
    /// @dev blockTimestamp 必须大于或等于 last.blockTimestamp（溢出情况也可以接受）
    /// @param last 上一次记录的 observation
    /// @param blockTimestamp 新 observation 的区块时间戳
    /// @param tick 当前激活的 tick
    /// @param liquidity 当前在区间内的流动性
    /// @return Observation 新生成的 observation
    function transform(
        Observation memory last,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity
    ) private pure returns (Observation memory) {
        uint32 delta = blockTimestamp - last.blockTimestamp; // 计算时间差
        return
            Observation({
                blockTimestamp: blockTimestamp,
                tickCumulative: last.tickCumulative + int56(tick) * delta, // 累加 tick 累积值
                secondsPerLiquidityCumulativeX128: last
                    .secondsPerLiquidityCumulativeX128 +
                    ((uint160(delta) << 128) / (liquidity > 0 ? liquidity : 1)), // 累加每单位流动性秒数
                initialized: true
            });
    }

    /// @notice 初始化观察数据数组，写入第一个 observation
    /// @param self 存储 observation 的数组
    /// @param time 初始化时的区块时间戳（uint32）
    /// @return cardinality 当前已填充的 observation 数量，返回 1
    /// @return cardinalityNext 新的 observation 数组长度，这里同样返回 1
    function initialize(
        Observation[65535] storage self,
        uint32 time
    ) internal returns (uint16 cardinality, uint16 cardinalityNext) {
        // 将第一个 observation 初始化为 time ，累积值均为 0
        self[0] = Observation({
            blockTimestamp: time,
            tickCumulative: 0,
            secondsPerLiquidityCumulativeX128: 0,
            initialized: true
        });
        return (1, 1);
    }

    /// @notice 将新的 observation 写入数组，最多每区块写入一次
    /// @dev 如果 observation 数组已满则循环覆盖，并可根据 cardinalityNext 扩大数组长度
    /// @param self 存储 observation 的数组
    /// @param index 当前最新 observation 索引
    /// @param blockTimestamp 新 observation 的时间戳
    /// @param tick 当前激活的 tick
    /// @param liquidity 当前流动性
    /// @param cardinality 当前 observation 数组中已填充的数量
    /// @param cardinalityNext 提议扩展后的 observation 数组长度
    /// @return indexUpdated 新的最新 observation 索引
    /// @return cardinalityUpdated 更新后的 observation 数量
    function write(
        Observation[65535] storage self,
        uint16 index,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity,
        uint16 cardinality,
        uint16 cardinalityNext
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        Observation memory last = self[index];

        // 如果当前区块已经写过 observation，则直接返回当前索引与数量
        if (last.blockTimestamp == blockTimestamp) return (index, cardinality);

        // 如果满足条件则提高 cardinality
        if (cardinalityNext > cardinality && index == (cardinality - 1)) {
            cardinalityUpdated = cardinalityNext;
        } else {
            cardinalityUpdated = cardinality;
        }

        // 计算下一个 observation 的索引（数组循环）
        indexUpdated = (index + 1) % cardinalityUpdated;
        // 将新的 observation 写入数组中
        self[indexUpdated] = transform(last, blockTimestamp, tick, liquidity);
    }

    /// @notice 扩展观察数组，确保可以存储更多 observation
    /// @param self 存储 observation 的数组
    /// @param current 当前 observation 数组的长度
    /// @param next 新的提议长度
    /// @return 返回扩展后的数组长度
    function grow(
        Observation[65535] storage self,
        uint16 current,
        uint16 next
    ) internal returns (uint16) {
        require(current > 0, "I");
        // 如果提议的 next 小于或等于 current，则不扩展，返回 current
        if (next <= current) return current;
        // 对于每个新增的槽位，初始化 blockTimestamp 为 1 以便后续操作
        for (uint16 i = current; i < next; i++) self[i].blockTimestamp = 1;
        return next;
    }

    /// @notice 比较两个 32 位时间戳在当前时间下的大小（处理溢出情况）
    /// @param time 当前区块时间（截断为 32 位）
    /// @param a 第一个时间戳
    /// @param b 第二个时间戳
    /// @return bool 表示 a 是否小于等于 b（按逻辑时间顺序比较）
    function lte(uint32 time, uint32 a, uint32 b) private pure returns (bool) {
        // 如果 a 和 b 都在当前时间之前，则直接比较
        if (a <= time && b <= time) return a <= b;

        uint256 aAdjusted = a > time ? a : a + 2 ** 32;
        uint256 bAdjusted = b > time ? b : b + 2 ** 32;

        return aAdjusted <= bAdjusted;
    }

    /// @notice 使用二分查找，根据目标时间在存储数组中查找两个最近的 observation（前一个和后一个）
    /// @dev 用于 observeSingle 中返回目标时间前后两个 observation
    /// @param self 存储 observation 的数组
    /// @param time 当前区块时间
    /// @param target 目标时间戳
    /// @param index 当前最新 observation 的索引
    /// @param cardinality 已填充的 observation 数量
    /// @return beforeOrAt 在目标时间之前或正好等于目标时间的 observation
    /// @return atOrAfter 在目标时间之后或正好等于目标时间的 observation
    function binarySearch(
        Observation[65535] storage self,
        uint32 time,
        uint32 target,
        uint16 index,
        uint16 cardinality
    )
        private
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        uint256 l = (index + 1) % cardinality; // 最旧的 observation 索引
        uint256 r = l + cardinality - 1; // 最新的 observation 索引
        uint256 i;
        while (true) {
            i = (l + r) / 2;

            beforeOrAt = self[i % cardinality];

            // 如果找到的 observation 未初始化，则搜索更近最新的观察值
            if (!beforeOrAt.initialized) {
                l = i + 1;
                continue;
            }

            atOrAfter = self[(i + 1) % cardinality];

            bool targetAtOrAfter = lte(time, beforeOrAt.blockTimestamp, target);

            // 判断是否找到符合条件的两个 observation
            if (targetAtOrAfter && lte(time, target, atOrAfter.blockTimestamp))
                break;

            if (!targetAtOrAfter) r = i - 1;
            else l = i + 1;
        }
    }

    /// @notice 根据目标时间，返回在目标时间之前或等于以及之后或等于的两个 observation
    /// @param self 存储 observation 的数组
    /// @param time 当前区块时间
    /// @param target 目标时间戳
    /// @param tick 当前激活 tick
    /// @param index 当前最新 observation 的索引
    /// @param liquidity 当前池子流动性
    /// @param cardinality 已填充的 observation 数量
    /// @return beforeOrAt 在目标时间之前或正好等于目标时间的 observation
    /// @return atOrAfter 在目标时间之后或正好等于目标时间的 observation
    function getSurroundingObservations(
        Observation[65535] storage self,
        uint32 time,
        uint32 target,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    )
        private
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        // 初步假设最新的 observation 就是 beforeOrAt
        beforeOrAt = self[index];

        // 如果目标时间大于或等于最新 observation 的时间，则直接返回
        if (lte(time, beforeOrAt.blockTimestamp, target)) {
            if (beforeOrAt.blockTimestamp == target) {
                // 如果目标时间与最新 observation 时间相同，则 atOrAfter 保持为空
                return (beforeOrAt, atOrAfter);
            } else {
                // 否则，使用 transform() 函数构造一个虚拟 observation 在目标时间
                return (
                    beforeOrAt,
                    transform(beforeOrAt, target, tick, liquidity)
                );
            }
        }

        // 如果目标时间在最旧 observation 之前，则将 beforeOrAt 设置为最旧 observation
        beforeOrAt = self[(index + 1) % cardinality];
        if (!beforeOrAt.initialized) beforeOrAt = self[0];

        // 保证目标时间不早于最旧 observation 时间
        require(lte(time, beforeOrAt.blockTimestamp, target), "OLD");

        // 否则进行二分查找获取紧邻目标时间的两个 observation
        return binarySearch(self, time, target, index, cardinality);
    }

    /// @dev 获取单个 observation（若目标时间落于两个 observation 之间，则返回内插结果）
    /// @param self 存储 observation 的数组
    /// @param time 当前区块时间
    /// @param secondsAgo 从当前时间回溯的秒数
    /// @param tick 当前激活的 tick
    /// @param index 当前最新 observation 的索引
    /// @param liquidity 当前池子流动性
    /// @param cardinality 已填充的 observation 数量
    /// @return tickCumulative 目标时间对应的 tick 累积值
    /// @return secondsPerLiquidityCumulativeX128 目标时间对应的每单位流动性累计秒数
    function observeSingle(
        Observation[65535] storage self,
        uint32 time,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    )
        internal
        view
        returns (
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128
        )
    {
        if (secondsAgo == 0) {
            // 如果 secondsAgo 为 0，则返回当前最新 observation（或通过 transform 调整为当前区块时间）
            Observation memory last = self[index];
            if (last.blockTimestamp != time)
                last = transform(last, time, tick, liquidity);
            return (
                last.tickCumulative,
                last.secondsPerLiquidityCumulativeX128
            );
        }

        // 计算目标 observation 的时间戳
        uint32 target = time - secondsAgo;

        // 获取目标时间上下的两个 observation
        (
            Observation memory beforeOrAt,
            Observation memory atOrAfter
        ) = getSurroundingObservations(
                self,
                time,
                target,
                tick,
                index,
                liquidity,
                cardinality
            );

        if (target == beforeOrAt.blockTimestamp) {
            // 如果目标时间正好与 beforeOrAt 的时间一致，则直接返回该 observation
            return (
                beforeOrAt.tickCumulative,
                beforeOrAt.secondsPerLiquidityCumulativeX128
            );
        } else if (target == atOrAfter.blockTimestamp) {
            // 如果目标时间正好等于 atOrAfter 的时间，则返回 atOrAfter
            return (
                atOrAfter.tickCumulative,
                atOrAfter.secondsPerLiquidityCumulativeX128
            );
        } else {
            // 否则，进行线性插值计算目标 observation
            uint32 observationTimeDelta = atOrAfter.blockTimestamp -
                beforeOrAt.blockTimestamp;
            uint32 targetDelta = target - beforeOrAt.blockTimestamp;
            return (
                beforeOrAt.tickCumulative +
                    ((atOrAfter.tickCumulative - beforeOrAt.tickCumulative) /
                        observationTimeDelta) *
                    targetDelta,
                beforeOrAt.secondsPerLiquidityCumulativeX128 +
                    uint160(
                        (uint256(
                            atOrAfter.secondsPerLiquidityCumulativeX128 -
                                beforeOrAt.secondsPerLiquidityCumulativeX128
                        ) * targetDelta) / observationTimeDelta
                    )
            );
        }
    }

    /// @notice 根据传入的秒数数组，返回每个时刻的 observation 累计值
    /// @dev 若 secondsAgos 超出最旧 observation，则 revert
    /// @param self 存储 observation 的数组
    /// @param time 当前区块时间
    /// @param secondsAgos 要回溯的秒数组，每个值代表回溯多少秒
    /// @param tick 当前激活 tick
    /// @param index 当前最新 observation 的索引
    /// @param liquidity 当前池子流动性
    /// @param cardinality 已填充的 observation 数量
    /// @return tickCumulatives 每个回溯时刻对应的 tick 累积值数组
    /// @return secondsPerLiquidityCumulativeX128s 每个回溯时刻对应的每单位流动性累计秒数数组
    function observe(
        Observation[65535] storage self,
        uint32 time,
        uint32[] memory secondsAgos,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    )
        internal
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        )
    {
        require(cardinality > 0, "I");

        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            (
                tickCumulatives[i],
                secondsPerLiquidityCumulativeX128s[i]
            ) = observeSingle(
                self,
                time,
                secondsAgos[i],
                tick,
                index,
                liquidity,
                cardinality
            );
        }
    }
}
