// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {BaseTest, BaskVault, MockToken, MockFeed, MockPool} from "./Base.t.sol";

contract AdversarialTest is BaseTest {
    function testFuzzBrokenTransferNeverBlocksOtherLegs(uint8 modeSeed) public {
        _depositAll(100e18);
        uint256 mode = bound(uint256(modeSeed), 1, 11);
        // NoReturn and ShortCredit debit the exact amount and therefore satisfy the specified payment contract.
        tokens[0].setMode(MockToken.TransferMode(mode));
        uint256 before = tokens[1].balanceOf(alice);
        uint256[] memory result = _redeem(30e18);
        assertEq(result[0], 10e18);
        assertEq(tokens[1].balanceOf(alice), before + 10e18);
        assertEq(vault.managed(address(tokens[0])), 90e18);
        uint256 debt = vault.owed(alice, address(tokens[0]));
        assertEq(tokens[0].balanceOf(address(vault)), 90e18 + debt);
        if (
            mode == uint256(MockToken.TransferMode.Blocked) || mode == uint256(MockToken.TransferMode.FalseReturn)
                || mode == uint256(MockToken.TransferMode.ExtraDebit) || mode == uint256(MockToken.TransferMode.NoMove)
                || mode == uint256(MockToken.TransferMode.ReturnBomb) || mode == uint256(MockToken.TransferMode.BurnGas)
                || mode == uint256(MockToken.TransferMode.Malformed)
        ) assertEq(debt, 10e18);
        tokens[0].setMode(MockToken.TransferMode.Normal);
        vm.prank(alice);
        vault.claim(_one(address(tokens[0])), bob);
        assertEq(vault.owed(alice, address(tokens[0])), 0);
        assertEq(tokens[0].balanceOf(bob), debt);
    }

    function testPausedTokenDefersAndOtherLegsProceed() public {
        _depositAll(100e18);
        tokens[0].setPause(true);
        _redeem(30e18);
        assertEq(vault.owed(alice, address(tokens[0])), 10e18);
        assertEq(vault.owed(alice, address(tokens[1])), 0);
        vm.prank(alice);
        vm.expectRevert(BaskVault.PaymentFailed.selector);
        vault.claim(_one(address(tokens[0])), bob);
        assertEq(vault.owed(alice, address(tokens[0])), 10e18);
        tokens[0].setPause(false);
        vm.prank(alice);
        vault.claim(_one(address(tokens[0])), bob);
        assertEq(tokens[0].balanceOf(bob), 10e18);
    }

    function testFuzzUnreadableBalanceUsesManaged(uint8 readSeed) public {
        _deposit(100e18);
        MockToken.ReadMode mode = MockToken.ReadMode(bound(uint256(readSeed), 1, 3));
        tokens[0].setReadMode(mode);
        _status(BaskVault.Reason.Unreadable, address(tokens[0]));
        (uint256[] memory preview,) = vault.previewRedeem(40e18);
        assertEq(preview[0], 40e18);
        _redeem(40e18);
        assertEq(vault.owed(alice, address(tokens[0])), 40e18);
        assertEq(vault.managed(address(tokens[0])), 60e18);
        tokens[0].setReadMode(MockToken.ReadMode.Normal);
        vm.prank(alice);
        vault.claim(_one(address(tokens[0])), bob);
        assertEq(tokens[0].balanceOf(bob), 40e18);
    }

    function testBalanceReturnBombCopiesOnlyWord() public {
        _deposit(100e18);
        tokens[0].setReadMode(MockToken.ReadMode.ReturnBomb);
        uint256[] memory amounts = _redeem(40e18);
        assertEq(amounts[0], 40e18);
        assertEq(vault.owed(alice, address(tokens[0])), 0);
    }

    function testUpgradeToNoCodeStillRedeemsAsDebt() public {
        _depositAll(100e18);
        vm.etch(address(tokens[0]), hex"");
        _redeem(30e18);
        assertEq(vault.owed(alice, address(tokens[0])), 10e18);
    }

    function testReentrantDepositRedeemClaimAndRoleChangesFail() public {
        _depositAll(100e18);
        tokens[0].setMode(MockToken.TransferMode.Reenter);
        tokens[0].setCallback(
            address(vault), abi.encodeCall(vault.redeem, (1, bob, new uint256[](0), vm.getBlockTimestamp()))
        );
        _redeem(30e18);
        assertFalse(tokens[0].reentrySucceeded());
        tokens[0].setCallback(address(vault), abi.encodeCall(vault.claim, (_one(address(tokens[0])), bob)));
        _deposit(1e18);
        assertFalse(tokens[0].reentrySucceeded());
        // Even a token that becomes owner cannot mutate the registry during a token callback.
        vm.prank(OWNER);
        vault.transferOwnership(address(tokens[0]));
        vm.prank(address(tokens[0]));
        vault.acceptOwnership();
        tokens[0].setCallback(address(vault), abi.encodeCall(vault.closeAsset, (address(tokens[1]))));
        _redeem(3e18);
        assertFalse(tokens[0].reentrySucceeded());
        assertTrue(vault.asset(address(tokens[1])).open);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.pay(address(tokens[0]), bob, 1);
    }

    function testFeeOnTransferAndFalseDepositAreAtomic() public {
        tokens[0].setMode(MockToken.TransferMode.ShortCredit);
        vm.expectRevert(BaskVault.PaymentFailed.selector);
        _deposit(100e18);
        assertEq(tokens[0].balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), 0);
        tokens[0].setMode(MockToken.TransferMode.FalseReturn);
        vm.expectRevert(BaskVault.PaymentFailed.selector);
        _deposit(100e18);
        assertEq(tokens[0].balanceOf(address(vault)), 0);
        tokens[0].setMode(MockToken.TransferMode.NoReturn);
        _deposit(100e18);
        _redeem(50e18);
        assertEq(vault.owed(alice, address(tokens[0])), 0);
    }

    function testClaimHasNoPayGasLimitAndPausesDoNotApply() public {
        _deposit(100e18);
        _setting(BaskVault.Setting.PayGas, 20_000);
        tokens[0].setCost(100_000);
        tokens[0].setMode(MockToken.TransferMode.Expensive);
        _redeem(50e18);
        assertEq(vault.owed(alice, address(tokens[0])), 50e18);
        vm.prank(GUARDIAN);
        vault.setDepositsPaused(true);
        vm.prank(OWNER);
        vault.closeAsset(address(tokens[0]));
        feeds[0].setMode(2);
        vm.prank(alice);
        vault.claim(_one(address(tokens[0])), bob);
        assertEq(tokens[0].balanceOf(bob), 50e18);
    }

    function testAllLossDoesNotBlockRedeemAndPreventsDepositAtZeroNAV() public {
        _deposit(100e18);
        tokens[0].confiscate(address(vault), 100e18);
        vault.flagDeficit(address(tokens[0]));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.recognizeLoss(address(tokens[0]));
        _refresh();
        vm.expectRevert(BaskVault.ZeroNAV.selector);
        _deposit(1e18);
        _redeem(50e18);
        assertEq(vault.totalSupply(), 50e18);
    }

    function testMinOutputForZeroLegRevertsOnlyByUserChoice() public {
        _deposit(100e18);
        tokens[0].confiscate(address(vault), 100e18);
        vm.prank(alice);
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.redeem(50e18, alice, _amount(1), vm.getBlockTimestamp());
        _redeem(50e18);
        assertEq(vault.managed(address(tokens[0])), 100e18);
    }

    function testDepositInputCannotConsumeUnderfundedOwed() public {
        _deposit(100e18);
        _setting(BaskVault.Setting.DirectLimit, 0);
        _redeem(50e18);
        tokens[0].confiscate(address(vault), 100e18);
        vault.flagDeficit(address(tokens[0]));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.recognizeLoss(address(tokens[0]));
        _refresh();
        _status(BaskVault.Reason.Deficit, address(tokens[0]));
    }

    function testClaimCannotBeBlockedByBalanceGasSetting() public {
        _deposit(100e18);
        _setting(BaskVault.Setting.DirectLimit, 0);
        _setting(BaskVault.Setting.BalanceGas, 20_000);
        tokens[0].setReadMode(MockToken.ReadMode.Expensive);
        _redeem(50e18);
        assertEq(vault.owed(alice, address(tokens[0])), 50e18);
        vm.prank(alice);
        vault.claim(_one(address(tokens[0])), bob);
        assertEq(tokens[0].balanceOf(bob), 50e18);
        assertEq(vault.owed(alice, address(tokens[0])), 0);
    }

    function testDepositSettingsAndGovernanceCannotVetoExit() public {
        _depositAll(100e18);
        _setting(BaskVault.Setting.FreshCount, 10);
        _setting(BaskVault.Setting.HoursTo, 1);
        _setting(BaskVault.Setting.FeedGas, 20_000);
        _setting(BaskVault.Setting.PauseGas, 20_000);
        _setting(BaskVault.Setting.PoolGas, 20_000);
        _setting(BaskVault.Setting.MaxAge, 1 hours);
        _setting(BaskVault.Setting.NoPoolAge, 1 hours);
        _setting(BaskVault.Setting.Band, 2);
        _setting(BaskVault.Setting.PoolDeviation, 50);
        vm.prank(GUARDIAN);
        vault.setDepositsPaused(true);
        vm.prank(OWNER);
        vault.lowerNAVCap(0);
        for (uint256 i; i < 3; ++i) {
            vm.prank(GUARDIAN);
            vault.closeAsset(address(tokens[i]));
            feeds[i].setMode(2);
            tokens[i].setPause(true);
        }
        _redeem(30e18);
        for (uint256 i; i < 3; ++i) {
            assertEq(vault.owed(alice, address(tokens[i])), 10e18);
            tokens[i].setPause(false);
            vm.prank(alice);
            vault.claim(_one(address(tokens[i])), bob);
            assertEq(tokens[i].balanceOf(bob), 10e18);
        }
    }
}
