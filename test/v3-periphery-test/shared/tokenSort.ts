export function compareToken(
  a: { address: string },
  b: { address: string }
): -1 | 1 {
  return a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1;
}

// export function sortedTokens(
//   a: { address: string },
//   b: { address: string }
// ): [typeof a, typeof b] | [typeof b, typeof a] {
//   return compareToken(a, b) < 0 ? [a, b] : [b, a]
// }
export function sortedTokens(tokenA: string, tokenB: string): [string, string] {
  return tokenA.toLowerCase() < tokenB.toLowerCase()
    ? [tokenA, tokenB]
    : [tokenB, tokenA];
}
