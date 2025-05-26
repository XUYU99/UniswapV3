function calculateNextPrice(
  liquidity: bigint,
  sqCur: bigint,
  amountSubFee: bigint
): bigint {
  const Q96 = BigInt(2) ** BigInt(96); // 2^96

  const numerator = liquidity * Q96 * sqCur;
  const denominator = liquidity * Q96 + amountSubFee * sqCur;

  if (denominator === BigInt(0)) {
    throw new Error("Denominator is zero, invalid input.");
  }

  // 向上取整公式：(a + b - 1n) / b
  return (numerator + denominator - BigInt(1)) / denominator;
}

// 示例用法：
const liquidity = BigInt("199710149825819669480855");
const sqCur = BigInt("79704936542881920863903188246"); // 2^96
const amountSubFee =
  160000000000000000000n - (80360763004124708836n + 241807712148820589n);
const nextPrice = calculateNextPrice(liquidity, sqCur, amountSubFee);
console.log("amountSubFee:", amountSubFee.toString());
console.log("nextPrice:", nextPrice.toString());
