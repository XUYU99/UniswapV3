import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv";

dotenv.config();

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.7.6", // 如果你用的是 Uniswap V3 推荐版本
        settings: {
          optimizer: {
            enabled: true,
            runs: 200, // 推荐值，越高代表部署越大，调用更便宜
          },
          metadata: {
            bytecodeHash: "none", // optional：确保字节码不因元数据差异而不同
          },
        },
      },
      {
        version: "0.6.12", // ✅ 如果有少数合约使用 0.6.x（如旧 OpenZeppelin）
        settings: {
          optimizer: { enabled: true, runs: 200 },
        },
      },
      {
        version: "0.5.16", // ✅ 添加此项用于编译 Uniswap V2 Core
        settings: {
          optimizer: { enabled: true, runs: 200 },
        },
      },
    ],
  },
  networks: {
    hardhat: {
      allowUnlimitedContractSize: false,
    },
    mainnet: {
      url: `https://mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
    },
    sepolia: {
      url: `https://sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`,
    },
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
};

export default config;
