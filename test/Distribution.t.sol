// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {DistributionVault} from "../src/DistributionVault.sol";

/// @notice Rental income: the record date, and where the remainder goes.
contract DistributionTest is Base {
    function setUp() public override {
        super.setUp();
        _issue(alice, 500_000e18);
        _issue(bob, 300_000e18);
        _issue(carol, 200_000e18);
    }

    function test_Claim_PaysProRata() public {
        uint256 id = _distribute(10_000e6); // 10,000 USDC of rent

        vm.prank(alice);
        vault.claim(id);
        vm.prank(bob);
        vault.claim(id);
        vm.prank(carol);
        vault.claim(id);

        assertEq(usdc.balanceOf(alice), 5_000e6);
        assertEq(usdc.balanceOf(bob), 3_000e6);
        assertEq(usdc.balanceOf(carol), 2_000e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    /// @dev Why the record date exists. Alice sells her whole position the day
    ///      after the distribution opens and is still owed the income for the
    ///      period she held it. Bob bought after the record date and is owed
    ///      nothing for that period.
    function test_RecordDate_SellerKeepsEntitlement_BuyerGetsNothing() public {
        uint256 id = _distribute(10_000e6);

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        token.transfer(bob, 500_000e18); // alice exits entirely

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 800_000e18);

        // Entitlements still reflect the record date, not today.
        assertEq(vault.entitlement(id, alice), 5_000e6);
        assertEq(vault.entitlement(id, bob), 3_000e6);

        vm.prank(alice);
        vault.claim(id);
        assertEq(usdc.balanceOf(alice), 5_000e6);
    }

    /// @dev A holder who acquires tokens only after the record date has no
    ///      claim on that distribution at all.
    function test_RecordDate_NewHolder_HasNoClaim() public {
        address dave = makeAddr("dave");
        _onboard(dave, US);

        uint256 id = _distribute(10_000e6);

        vm.prank(alice);
        token.transfer(dave, 100_000e18);

        assertEq(vault.entitlement(id, dave), 0);
        vm.expectRevert(abi.encodeWithSelector(DistributionVault.NothingOwed.selector, id, dave));
        vm.prank(dave);
        vault.claim(id);
    }

    function test_Claim_RevertsOnSecondAttempt() public {
        uint256 id = _distribute(10_000e6);

        vm.prank(alice);
        vault.claim(id);

        vm.expectRevert(abi.encodeWithSelector(DistributionVault.AlreadyClaimed.selector, id, alice));
        vm.prank(alice);
        vault.claim(id);
    }

    function test_Claim_RevertsAfterClose() public {
        uint256 id = _distribute(10_000e6);

        vm.warp(block.timestamp + CLAIM_WINDOW + 1);
        vault.close(id);

        vm.expectRevert(abi.encodeWithSelector(DistributionVault.DistributionAlreadyClosed.selector, id));
        vm.prank(alice);
        vault.claim(id);
    }

    function test_Close_RevertsWhileWindowOpen() public {
        uint256 id = _distribute(10_000e6);
        DistributionVault.Distribution memory d = vault.distributionAt(id);

        vm.expectRevert(abi.encodeWithSelector(DistributionVault.WindowStillOpen.selector, id, d.closesAt));
        vault.close(id);
    }

    // ------------------------------------------------------------------- dust

    /// @dev Integer division cannot split 7 units across a 5:3:2 holding
    ///      without a remainder. The remainder is neither stranded nor swept.
    ///      It surfaces in undistributed() and joins the next distribution.
    function test_Dust_IsCarriedForward_NotStranded() public {
        uint256 id = _distribute(7); // 7 units against a 5:3:2 split

        assertEq(vault.entitlement(id, alice), 3); // 3.5 floored
        assertEq(vault.entitlement(id, bob), 2); // 2.1 floored
        assertEq(vault.entitlement(id, carol), 1); // 1.4 floored

        vm.prank(alice);
        vault.claim(id);
        vm.prank(bob);
        vault.claim(id);
        vm.prank(carol);
        vault.claim(id);

        // 3 + 2 + 1 = 6 paid out of 7 deposited. One unit of dust remains.
        assertEq(vault.totalPaid(), 6);
        assertEq(usdc.balanceOf(address(vault)), 1);
        assertEq(vault.undistributed(), 0); // not yet realised

        vm.warp(block.timestamp + CLAIM_WINDOW + 1);
        vault.close(id);

        assertEq(vault.undistributed(), 1); // now visible and accounted for
    }

    function test_Dust_JoinsTheNextPool() public {
        uint256 first = _distribute(7);
        vm.prank(alice);
        vault.claim(first);
        vm.prank(bob);
        vault.claim(first);
        vm.prank(carol);
        vault.claim(first);

        vm.warp(block.timestamp + CLAIM_WINDOW + 1);
        vault.close(first);
        assertEq(vault.undistributed(), 1);

        uint256 second = _distribute(10_000e6);
        DistributionVault.Distribution memory d = vault.distributionAt(second);

        assertEq(d.pool, 10_000e6 + 1); // the carried unit is included
        assertEq(vault.undistributed(), 0); // and consumed
    }

    /// @dev Unclaimed funds are the same problem as dust and take the same
    ///      path. Carol never claims, so her share rolls forward instead of
    ///      sitting in the vault or going to the issuer.
    function test_UnclaimedFunds_RollForward() public {
        uint256 id = _distribute(10_000e6);

        vm.prank(alice);
        vault.claim(id);
        vm.prank(bob);
        vault.claim(id);
        // carol does not claim

        vm.warp(block.timestamp + CLAIM_WINDOW + 1);
        vault.close(id);

        assertEq(vault.undistributed(), 2_000e6);
        assertEq(usdc.balanceOf(address(vault)), 2_000e6);
    }

    function test_CarryAlone_CanFundADistribution() public {
        uint256 first = _distribute(10_000e6);
        vm.warp(block.timestamp + CLAIM_WINDOW + 1);
        vault.close(first); // nobody claimed at all

        assertEq(vault.undistributed(), 10_000e6);

        // A distribution of zero new income still pays out the carry.
        vm.prank(issuer);
        uint256 second = vault.distribute(0);

        assertEq(vault.entitlement(second, alice), 5_000e6);
        vm.prank(alice);
        vault.claim(second);
        assertEq(usdc.balanceOf(alice), 5_000e6);
    }

    // ---------------------------------------------------------------- accounting

    function test_Accounting_VaultHoldsExactlyWhatIsOwed() public {
        _distribute(10_000e6);
        _distribute(5_000e6);

        assertEq(vault.totalDeposited(), 15_000e6);
        assertEq(usdc.balanceOf(address(vault)), vault.totalDeposited() - vault.totalPaid());

        vm.prank(alice);
        vault.claim(0);
        vm.prank(bob);
        vault.claim(1);

        assertEq(usdc.balanceOf(address(vault)), vault.totalDeposited() - vault.totalPaid());
    }
}
