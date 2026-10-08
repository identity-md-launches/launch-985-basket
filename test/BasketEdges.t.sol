// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest, BaskVault, MockToken, MockFeed} from "./Base.t.sol";
import {ReentryProbe} from "./mocks/ReentryProbe.sol";

contract BasketEdgesTest is BaseTest {
    function test_ReentrantRedeemRejectsAnOtherwiseAuthorizedShareholder() public {
        _deposit(100e18);
        ReentryProbe probe = new ReentryProbe();
        vm.prank(alice);
        vault.transfer(address(probe), 10e18);
        probe.configure(
            address(vault), abi.encodeCall(vault.redeem, (5e18, bob, new uint256[](0), vm.getBlockTimestamp()))
        );
        // Establish that the identical caller and payload succeed outside a callback.
        probe.fire();
        assertTrue(probe.succeeded());
        assertEq(vault.balanceOf(address(probe)), 5e18);
        assertEq(tokens[0].balanceOf(bob), 5e18);
        tokens[0].setCallback(address(probe), abi.encodeCall(probe.fire, ()));
        tokens[0].setMode(MockToken.TransferMode.Reenter);
        _redeem(20e18);
        assertFalse(probe.succeeded());
        assertEq(probe.failure(), BaskVault.Reentrant.selector);
        assertEq(vault.balanceOf(address(probe)), 5e18);
        assertEq(tokens[0].balanceOf(bob), 5e18);
        assertEq(vault.managed(address(tokens[0])), 75e18);
        assertEq(vault.totalSupply(), 75e18);
    }

    function test_LateDepositFailureRollsBackEarlierTransfersAndAllowances() public {
        address[] memory selected = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        for (uint256 i; i < 2; ++i) {
            selected[i] = address(tokens[i]);
            amounts[i] = 100e18;
            vm.prank(alice);
            tokens[i].approve(address(vault), amounts[i]);
        }
        // The second transfer really moves tokens before returning false.
        tokens[1].setMode(MockToken.TransferMode.FalseReturn);
        uint256 before0 = tokens[0].balanceOf(alice);
        uint256 before1 = tokens[1].balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(BaskVault.PaymentFailed.selector);
        vault.deposit(selected, amounts, bob, 0, vm.getBlockTimestamp());
        for (uint256 i; i < 2; ++i) {
            assertEq(tokens[i].balanceOf(address(vault)), 0);
            assertEq(tokens[i].allowance(alice, address(vault)), 100e18);
            assertEq(vault.managed(selected[i]), 0);
        }
        assertEq(tokens[0].balanceOf(alice), before0);
        assertEq(tokens[1].balanceOf(alice), before1);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.balanceOf(address(0xdEaD)), 0);
        assertEq(vault.balanceOf(bob), 0);
    }

    function test_LateRedeemSlippageRollsBackPaymentDebtFeeAndBurn() public {
        _feeOn();
        _depositAll(100e18);
        tokens[1].setMode(MockToken.TransferMode.Blocked);
        uint256 supply = vault.totalSupply();
        uint256 shares = vault.balanceOf(alice);
        uint256 feeShares = vault.balanceOf(recipient);
        uint256 bobBalance = tokens[0].balanceOf(bob);
        (uint256[] memory minimums,) = vault.previewRedeem(30e18);
        ++minimums[2];
        vm.prank(alice);
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.redeem(30e18, bob, minimums, vm.getBlockTimestamp());
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.balanceOf(recipient), feeShares);
        assertEq(tokens[0].balanceOf(bob), bobBalance);
        for (uint256 i; i < 3; ++i) {
            assertEq(vault.managed(address(tokens[i])), 100e18);
            assertEq(vault.owed(bob, address(tokens[i])), 0);
            assertEq(vault.totalOwed(address(tokens[i])), 0);
        }
    }

    function test_ClaimBatchFailureRollsBackEarlierPaymentAndDuplicateIsIdempotent() public {
        _depositAll(100e18);
        _setting(BaskVault.Setting.DirectLimit, 0);
        vm.prank(alice);
        vault.redeem(30e18, bob, new uint256[](0), vm.getBlockTimestamp());
        address[] memory selected = new address[](3);
        selected[0] = address(tokens[0]);
        selected[1] = address(tokens[0]);
        selected[2] = address(tokens[1]);
        tokens[1].setMode(MockToken.TransferMode.FalseReturn);
        vm.prank(bob);
        vm.expectRevert(BaskVault.PaymentFailed.selector);
        vault.claim(selected, recipient);
        assertEq(tokens[0].balanceOf(recipient), 0);
        assertEq(vault.owed(bob, selected[0]), 10e18);
        assertEq(vault.totalOwed(selected[0]), 10e18);
        tokens[1].setMode(MockToken.TransferMode.Normal);
        vm.prank(bob);
        vault.claim(selected, recipient);
        assertEq(tokens[0].balanceOf(recipient), 10e18);
        assertEq(tokens[1].balanceOf(recipient), 10e18);
        assertEq(vault.owed(bob, selected[0]), 0);
        assertEq(vault.totalOwed(selected[0]), 0);
        assertEq(vault.owed(bob, address(tokens[2])), 10e18);
        // An unrelated caller cannot consume Bob's remaining debt.
        vm.prank(alice);
        vault.claim(_one(address(tokens[2])), alice);
        assertEq(vault.owed(bob, address(tokens[2])), 10e18);
    }

    function test_ListingAndFeedProposalsRevalidateFeedUniqueness() public {
        MockToken first = new MockToken(6);
        MockToken second = new MockToken(18);
        MockFeed shared = new MockFeed(8, 1e8);
        BaskVault.ProposalData memory data = _data(BaskVault.Action.List, address(first));
        data.target = address(shared);
        uint256 firstId = _propose(data);
        data.token = address(second);
        uint256 secondId = _propose(data);
        data.action = BaskVault.Action.Feed;
        data.token = address(tokens[0]);
        uint256 feedId = _propose(data);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        _execute(firstId);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(shared)));
        vault.executeProposal(secondId);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(shared)));
        vault.executeProposal(feedId);
        assertEq(vault.assetCount(), 4);
        assertEq(vault.feedAsset(address(shared)), address(first));
        assertEq(vault.asset(address(tokens[0])).feed, address(feeds[0]));
    }

    function test_RetireRequiresClosedAgainAtExecutionAndCannotExecuteTwice() public {
        address token = address(tokens[0]);
        vm.prank(OWNER);
        vault.closeAsset(token);
        uint256 retire = _propose(_data(BaskVault.Action.Retire, token));
        uint256 reopen = _propose(_data(BaskVault.Action.Reopen, token));
        vm.warp(vm.getBlockTimestamp() + 2 days);
        _execute(reopen);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, token));
        vault.executeProposal(retire);
        vm.prank(GUARDIAN);
        vault.closeAsset(token);
        _execute(retire);
        assertTrue(vault.asset(token).retired);
        assertFalse(vault.asset(token).open);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.NotReady.selector);
        vault.executeProposal(retire);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, token));
        vault.propose(_data(BaskVault.Action.Reopen, token));
    }

    function test_AllProposalKindsRejectNonOwnersAndPayRejectsRoles() public {
        for (uint256 i; i <= uint256(BaskVault.Action.SettingChange); ++i) {
            BaskVault.ProposalData memory data;
            data.action = BaskVault.Action(i);
            vm.prank(alice);
            vm.expectRevert(BaskVault.Unauthorized.selector);
            vault.propose(data);
            vm.prank(GUARDIAN);
            vm.expectRevert(BaskVault.Unauthorized.selector);
            vault.propose(data);
        }
        _deposit(100e18);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.pay(address(tokens[0]), OWNER, 100e18);
        vm.prank(GUARDIAN);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.pay(address(tokens[0]), GUARDIAN, 100e18);
        assertEq(tokens[0].balanceOf(address(vault)), 100e18);
    }

    function test_FeeRecipientCanDepositAndRedeemWithoutLosingSelfTransferredFee() public {
        BaskVault.ProposalData memory data = _data(BaskVault.Action.FeeRecipient, address(0));
        data.target = alice;
        _run(data);
        _deposit(100e18);
        assertEq(vault.balanceOf(alice), 100e18 - 1e15);
        uint256 before = vault.balanceOf(alice);
        uint256[] memory legs = _redeem(200);
        assertEq(legs[0], 199);
        assertEq(vault.balanceOf(alice), before - 199);
        assertEq(vault.totalSupply(), 100e18 - 199);
        _redeem(1);
        assertEq(vault.balanceOf(alice), before - 199);
    }

    function test_ResyncUsesExecutionBalanceAndNeverCountsOwedOrWritesOffLoss() public {
        _deposit(100e18);
        _setting(BaskVault.Setting.DirectLimit, 0);
        _redeem(40e18);
        uint256 id = _propose(_data(BaskVault.Action.Resync, address(tokens[0])));
        tokens[0].mint(address(vault), 25e18);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        _execute(id);
        assertEq(vault.managed(address(tokens[0])), 85e18);
        assertEq(vault.totalOwed(address(tokens[0])), 40e18);
        tokens[0].confiscate(address(vault), 100e18);
        _run(_data(BaskVault.Action.Resync, address(tokens[0])));
        assertEq(vault.managed(address(tokens[0])), 85e18);
        assertEq(vault.totalOwed(address(tokens[0])), 40e18);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_RepeatedRoundTripsCannotCreateStockTokens(uint96 amountSeed, uint8 cycleSeed, bool fees) public {
        if (fees) _feeOn();
        _deposit(100e18);
        uint256 amount = bound(uint256(amountSeed), 201, 1_000e18);
        uint256 cycles = bound(uint256(cycleSeed), 2, 12);
        tokens[0].mint(bob, amount);
        vm.prank(bob);
        tokens[0].approve(address(vault), type(uint256).max);
        uint256 starting = tokens[0].balanceOf(bob);
        for (uint256 i; i < cycles; ++i) {
            uint256 input = tokens[0].balanceOf(bob);
            vm.prank(bob);
            uint256 shares = vault.deposit(_one(address(tokens[0])), _amount(input), bob, 1, vm.getBlockTimestamp());
            vm.prank(bob);
            vault.redeem(shares, bob, new uint256[](0), vm.getBlockTimestamp());
            uint256 output = tokens[0].balanceOf(bob);
            assertLe(output, input, "round trip created Stock Tokens");
            assertGe(output, input - (fees ? (input + 99) / 100 + 2 : 0), "exit lost more than fees and rounding");
            assertEq(vault.balanceOf(bob), 0);
        }
        assertLe(tokens[0].balanceOf(bob), starting);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_DonationCannotChangeDepositPriceBeforeResync(uint128 donation, uint96 inputSeed) public {
        _deposit(1e15 + 1);
        uint256 input = bound(uint256(inputSeed), 1, 1_000e18);
        address[] memory selected = _one(address(tokens[0]));
        (uint256 beforeShares,, uint256 beforeValue, uint256 beforeNAV) = vault.previewDeposit(selected, _amount(input));
        tokens[0].mint(address(vault), donation);
        (uint256 afterShares,, uint256 afterValue, uint256 afterNAV) = vault.previewDeposit(selected, _amount(input));
        assertEq(afterShares, beforeShares);
        assertEq(afterValue, beforeValue);
        assertEq(afterNAV, beforeNAV);
        assertGt(afterShares, 0);
        assertEq(_deposit(input), beforeShares);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_LossRecognitionCannotExceedRecordedOrCurrentDeficit(uint96 lossSeed, uint96 recoverySeed) public {
        _deposit(100e18);
        uint256 loss = bound(uint256(lossSeed), 1, 100e18);
        uint256 recovery = bound(uint256(recoverySeed), 0, loss);
        tokens[0].confiscate(address(vault), loss);
        vault.flagDeficit(address(tokens[0]));
        uint256 since = vm.getBlockTimestamp();
        tokens[0].mint(address(vault), recovery);
        vm.warp(since + 7 days - 1);
        vm.expectRevert(BaskVault.NotReady.selector);
        vault.recognizeLoss(address(tokens[0]));
        assertEq(vault.managed(address(tokens[0])), 100e18);
        vm.warp(since + 7 days);
        vault.recognizeLoss(address(tokens[0]));
        assertEq(vault.managed(address(tokens[0])), 100e18 - loss + recovery);
        (uint256 recorded, uint256 recordedAt) = vault.deficits(address(tokens[0]));
        assertEq(recorded, 0);
        assertEq(recordedAt, 0);
        vm.expectRevert(BaskVault.NotReady.selector);
        vault.recognizeLoss(address(tokens[0]));
    }
}
