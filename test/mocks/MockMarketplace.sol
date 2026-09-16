// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The shape every open venue shares: the seller approves this contract
///         and it moves the asset to whoever pays. Seaport and AMM routers both
///         work this way, so this is the pattern a permissioned token blocks.
contract MockMarketplace {
    function fill(IERC20 asset, address seller, address buyer, uint256 amount) external {
        asset.transferFrom(seller, buyer, amount);
    }
}
