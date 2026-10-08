// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {BaseTest, BaskVault, MockToken} from "./Base.t.sol";

contract RevisionTest is BaseTest {
    function _retire(uint256 index) private {
        vm.prank(OWNER);
        vault.closeAsset(address(tokens[index]));
        _run(_data(BaskVault.Action.Retire, address(tokens[index])));
    }

    function _expectRetiredBacking(uint256 index) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                BaskVault.DepositUnavailable.selector, BaskVault.Reason.RetiredBacking, address(tokens[index])
            )
        );
    }

    function testRetiredBackingCannotBeAcquiredByNewDepositor() public {
        _depositAll(100e18);
        _retire(0);
        tokens[1].mint(bob, 300e18);
        vm.prank(bob);
        tokens[1].approve(address(vault), 300e18);

        address[] memory selected = _one(address(tokens[1]));
        (BaskVault.Reason reason, address fault) = vault.depositStatus(selected);
        assertEq(uint256(reason), uint256(BaskVault.Reason.RetiredBacking));
        assertEq(fault, address(tokens[0]));
        _expectRetiredBacking(0);
        vault.previewDeposit(selected, _amount(300e18));
        _expectRetiredBacking(0);
        vm.prank(bob);
        vault.deposit(selected, _amount(300e18), bob, 0, vm.getBlockTimestamp());

        assertEq(vault.totalSupply(), 300e18);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(tokens[1].balanceOf(bob), 300e18);
        for (uint256 i; i < 3; ++i) {
            assertEq(vault.managed(address(tokens[i])), 100e18);
        }
        uint256[] memory legs = _redeem(30e18);
        for (uint256 i; i < 3; ++i) {
            assertEq(legs[i], 10e18);
        }
    }

    function testFuzzRetiredBackingCheckUsesAccountingEvenWhenUnreadable(uint8 index, bool fees) public {
        index = uint8(bound(index, 0, 2));
        if (fees) _feeOn();
        _depositAll(100e18);
        _retire(index);
        tokens[index].setReadMode(MockToken.ReadMode.BurnGas);
        feeds[index].setMode(2);
        address[] memory selected = _one(address(tokens[(uint256(index) + 1) % 3]));
        (BaskVault.Reason reason, address fault) = vault.depositStatus(selected);
        assertEq(uint256(reason), uint256(BaskVault.Reason.RetiredBacking));
        assertEq(fault, address(tokens[index]));
        _expectRetiredBacking(index);
        vm.prank(alice);
        vault.deposit(selected, _amount(1e18), alice, 0, vm.getBlockTimestamp());

        uint256[] memory legs = _redeem(30e18);
        assertGt(legs[index], 0);
        assertEq(vault.owed(alice, address(tokens[index])), legs[index]);
    }

    function testEmptyRetiredAssetStillSkipsDepositChecks() public {
        _retire(0);
        tokens[0].setReadMode(MockToken.ReadMode.BurnGas);
        feeds[0].setMode(2);
        vm.prank(alice);
        uint256 shares = vault.deposit(_one(address(tokens[1])), _amount(100e18), alice, 0, vm.getBlockTimestamp());
        assertEq(shares, 100e18 - 1e15);
        vault.removeAsset(address(tokens[0]));
        assertEq(vault.assetCount(), 2);
    }

    function testOnlyCompleteRecognizedLossClearsRetiredBacking() public {
        _depositAll(100e18);
        _retire(0);
        tokens[0].confiscate(address(vault), 99e18);
        vault.flagDeficit(address(tokens[0]));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.recognizeLoss(address(tokens[0]));
        _refresh();
        assertEq(vault.managed(address(tokens[0])), 1e18);
        _expectRetiredBacking(0);
        vault.previewDeposit(_one(address(tokens[1])), _amount(100e18));

        tokens[0].confiscate(address(vault), 1e18);
        vault.flagDeficit(address(tokens[0]));
        _expectRetiredBacking(0);
        vault.previewDeposit(_one(address(tokens[1])), _amount(100e18));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.recognizeLoss(address(tokens[0]));
        _refresh();
        tokens[0].setReadMode(MockToken.ReadMode.BurnGas);
        feeds[0].setMode(2);
        (uint256 shares,,, uint256 nav) = vault.previewDeposit(_one(address(tokens[1])), _amount(100e18));
        assertEq(nav, 200e18);
        assertEq(shares, 150e18);
        vm.prank(alice);
        vault.deposit(_one(address(tokens[1])), _amount(100e18), alice, shares, vm.getBlockTimestamp());
        uint256[] memory legs = _redeem(shares);
        assertEq(legs[0], 0);
        assertLe(legs[1] + legs[2], 100e18);
    }

    function testRetiredDebtWithoutManagedDoesNotBlockDepositOrClaim() public {
        _depositAll(100e18);
        tokens[0].setMode(MockToken.TransferMode.Blocked);
        _redeem(30e18);
        _retire(0);
        assertEq(vault.totalOwed(address(tokens[0])), 10e18);
        tokens[0].confiscate(address(vault), 90e18);
        vault.flagDeficit(address(tokens[0]));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.recognizeLoss(address(tokens[0]));
        _refresh();
        assertEq(vault.managed(address(tokens[0])), 0);
        tokens[0].setReadMode(MockToken.ReadMode.BurnGas);
        vm.prank(alice);
        vault.deposit(_one(address(tokens[1])), _amount(1e18), alice, 0, vm.getBlockTimestamp());
        tokens[0].setReadMode(MockToken.ReadMode.Normal);
        tokens[0].setMode(MockToken.TransferMode.Normal);
        vm.prank(alice);
        vault.claim(_one(address(tokens[0])), bob);
        assertEq(tokens[0].balanceOf(bob), 10e18);
        assertEq(vault.totalOwed(address(tokens[0])), 0);
        vault.removeAsset(address(tokens[0]));
    }

    function testPermanentSharesKeepResidualAndRetiredDepositRestriction() public {
        _depositAll(100e18);
        _retire(0);
        _redeem(vault.balanceOf(alice));
        assertEq(vault.totalSupply(), 1e15);
        assertEq(vault.balanceOf(address(0xdEaD)), 1e15);
        assertEq(vault.managed(address(tokens[0])), 333333333333334);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, address(tokens[0])));
        vault.removeAsset(address(tokens[0]));
        // A surplus in another asset must not reopen the dilution path.
        tokens[1].mint(address(vault), 1e18);
        _run(_data(BaskVault.Action.Resync, address(tokens[1])));
        _expectRetiredBacking(0);
        vault.previewDeposit(_one(address(tokens[1])), _amount(1e18));
    }

    function testZeroNAVRequiresBackingEvenWhenOnlyPermanentSharesRemain() public {
        _deposit(100e18);
        tokens[0].confiscate(address(vault), 100e18);
        vault.flagDeficit(address(tokens[0]));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.recognizeLoss(address(tokens[0]));
        _refresh();
        _redeem(vault.balanceOf(alice));
        assertEq(vault.totalSupply(), 1e15);
        vm.expectRevert(BaskVault.ZeroNAV.selector);
        vm.prank(alice);
        vault.deposit(_one(address(tokens[1])), _amount(1e18), alice, 0, vm.getBlockTimestamp());
        tokens[1].mint(address(vault), 1e18);
        _run(_data(BaskVault.Action.Resync, address(tokens[1])));
        vm.prank(alice);
        uint256 shares = vault.deposit(_one(address(tokens[1])), _amount(1e18), alice, 0, vm.getBlockTimestamp());
        assertEq(shares, 1e15);
    }

    function testFuzzRedeemToVaultCannotBurnSharesOrCreateDebt(bool deferred, bool fees) public {
        if (deferred) _setting(BaskVault.Setting.DirectLimit, 0);
        if (fees) _feeOn();
        _deposit(100e18);
        uint256 supply = vault.totalSupply();
        uint256 shares = vault.balanceOf(alice);
        uint256 feeShares = vault.balanceOf(recipient);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vm.prank(alice);
        vault.redeem(1e18, address(vault), new uint256[](0), vm.getBlockTimestamp());
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.balanceOf(recipient), feeShares);
        assertEq(vault.managed(address(tokens[0])), 100e18);
        assertEq(tokens[0].balanceOf(address(vault)), 100e18);
        assertEq(vault.owed(address(vault), address(tokens[0])), 0);
        assertEq(vault.totalOwed(address(tokens[0])), 0);
    }

    function testRemovalCannotSilentlyDropTrailingMinimum() public {
        vm.prank(alice);
        vault.deposit(_one(address(tokens[2])), _amount(100e18), alice, 0, vm.getBlockTimestamp());
        _retire(0);
        tokens[2].confiscate(address(vault), 60e18);
        uint256[] memory mins = new uint256[](3);
        mins[2] = 50e18;
        vm.expectRevert(BaskVault.Slippage.selector);
        vm.prank(alice);
        vault.redeem(50e18, alice, mins, vm.getBlockTimestamp());
        vm.prank(bob);
        vault.removeAsset(address(tokens[0]));
        assertEq(vault.assets(0), address(tokens[2]));
        vm.expectRevert(BaskVault.Slippage.selector);
        vm.prank(alice);
        vault.redeem(50e18, alice, mins, vm.getBlockTimestamp());
        assertEq(vault.totalSupply(), 100e18);
        assertEq(vault.managed(address(tokens[2])), 100e18);
        assertEq(tokens[2].balanceOf(address(vault)), 40e18);
        // Caller can deliberately lower the minimum in the current registry order.
        mins[0] = 20e18;
        mins[2] = 0;
        vm.prank(alice);
        uint256[] memory legs = vault.redeem(50e18, alice, mins, vm.getBlockTimestamp());
        assertEq(legs.length, 2);
        assertEq(legs[0], 20e18);
    }

    function testMultipleRemovalsCannotDropEarlierTrailingMinimum() public {
        vm.prank(alice);
        vault.deposit(_one(address(tokens[2])), _amount(100e18), alice, 0, vm.getBlockTimestamp());
        _retire(0);
        _retire(1);
        uint256[] memory mins = new uint256[](4);
        mins[2] = 50e18;
        vault.removeAsset(address(tokens[0]));
        vault.removeAsset(address(tokens[1]));
        vm.expectRevert(BaskVault.Slippage.selector);
        vm.prank(alice);
        vault.redeem(50e18, alice, mins, vm.getBlockTimestamp());
        // Even with no deficit, the removed position's nonzero floor cannot be ignored.
        mins[0] = mins[2];
        mins[2] = 0;
        vm.prank(alice);
        uint256[] memory legs = vault.redeem(50e18, alice, mins, vm.getBlockTimestamp());
        assertEq(legs[0], 50e18);
    }

    function testGuardianExecutionRechecksPendingOwner() public {
        BaskVault.ProposalData memory d;
        d.action = BaskVault.Action.Guardian;
        d.target = bob;
        uint256 id = _propose(d);
        vm.prank(OWNER);
        vault.transferOwnership(bob);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vm.prank(OWNER);
        vault.executeProposal(id);
        assertEq(vault.guardian(), GUARDIAN);
        assertEq(vault.pendingOwner(), bob);
        assertEq(uint256(vault.proposalStatus(id)), uint256(BaskVault.ProposalState.Ready));
        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(vault.owner(), bob);
        // The same target is now the current owner and remains ineligible.
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vm.prank(bob);
        vault.executeProposal(id);
    }

    function testUnrelatedGuardianReplacementPreservesOwnershipHandover() public {
        vm.prank(OWNER);
        vault.transferOwnership(alice);
        BaskVault.ProposalData memory d;
        d.action = BaskVault.Action.Guardian;
        d.target = bob;
        _run(d);
        assertEq(vault.pendingOwner(), alice);
        vm.prank(alice);
        vault.acceptOwnership();
        assertEq(vault.owner(), alice);
        assertEq(vault.guardian(), bob);
    }
}
