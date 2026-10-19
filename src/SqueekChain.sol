// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SqueekChain
/// @notice Fixed-supply SQK token with 18 decimals and ordinary ERC-20 transfers.
/// @dev The constructor caller receives the entire supply. In a factory deployment,
///      the factory receives it and is responsible for the subsequent distribution.
contract SqueekChain is ERC20 {
    /// @notice One billion SQK, expressed in the token's smallest units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("SqueekChain", "SQK") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
