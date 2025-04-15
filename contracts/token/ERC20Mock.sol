// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20Mock is ERC20 {
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) ERC20(name, symbol) {
        _mint(msg.sender, 10000 * (10 ** uint256(decimals())));
        _setupDecimals(decimals_);
    }

    function _setupDecimals(uint8 decimals_) internal override {
        assembly {
            sstore(0x0, decimals_)
        }
    }
}
