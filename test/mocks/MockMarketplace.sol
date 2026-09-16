// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The shape every open venue shares: the seller approves this
///         contract, and it moves the asset to whoever pays. Seaport and every
///         AMM router do exactly this. It is the pattern a permissioned token
///         has to defeat.
contract MockMarketplace {
    function fill(IERC20 asset, address seller, address buyer, uint256 amount) external {
        asset.transferFrom(seller, buyer, amount);
    }
}
