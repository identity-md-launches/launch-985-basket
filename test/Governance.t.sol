// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {BaseTest, BaskVault, MockToken, MockFeed, MockPool} from "./Base.t.sol";

contract GovernanceTest is BaseTest {
    function testConstructorsAndGenesis() public {
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        new BaskVault(address(0), GUARDIAN);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        new BaskVault(OWNER, address(0));
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        new BaskVault(OWNER, OWNER);
        BaskVault empty = new BaskVault(OWNER, GUARDIAN);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        empty.finalizeGenesis();
        (BaskVault.Reason reason,) = empty.depositStatus(new address[](0));
        assertEq(uint256(reason), uint256(BaskVault.Reason.Genesis));
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.finalizeGenesis();
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.genesisList(address(tokens[0]), address(feeds[0]), address(0), address(0), 0);
    }

    function testTimelockBoundariesAndPendingViews() public {
        BaskVault.ProposalData memory d = _data(BaskVault.Action.FeeRecipient, address(0));
        d.target = recipient;
        uint256 start = vm.getBlockTimestamp();
        uint256 id = _propose(d);
        _expectState(id, BaskVault.ProposalState.Waiting);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.NotReady.selector);
        vault.executeProposal(id);
        vm.warp(start + 2 days);
        _expectState(id, BaskVault.ProposalState.Ready);
        (uint256[] memory ids, BaskVault.Proposal[] memory pending) = vault.pendingProposals(0, 10);
        assertEq(ids.length, 1);
        assertEq(ids[0], id);
        assertEq(pending[0].data.target, recipient);
        vm.prank(alice);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.executeProposal(id);
        vm.warp(start + 9 days);
        _execute(id);
        assertEq(vault.feeRecipient(), recipient);
        _expectState(id, BaskVault.ProposalState.Executed);
        id = _propose(d);
        vm.warp(vm.getBlockTimestamp() + 9 days + 1);
        _expectState(id, BaskVault.ProposalState.Expired);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.NotReady.selector);
        vault.executeProposal(id);
        (ids,) = vault.pendingProposals(0, 100);
        assertEq(ids.length, 0);
    }

    function testOwnerAndGuardianPowers() public {
        vm.prank(alice);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.setDepositsPaused(true);
        vm.prank(GUARDIAN);
        vault.setDepositsPaused(true);
        vm.prank(GUARDIAN);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.setDepositsPaused(false);
        vm.prank(OWNER);
        vault.setDepositsPaused(false);
        BaskVault.ProposalData memory d = _data(BaskVault.Action.Guardian, address(0));
        d.target = bob;
        vm.prank(GUARDIAN);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.propose(d);
        uint256 id = _propose(d);
        vm.prank(GUARDIAN);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.cancelProposal(id);
        vm.prank(OWNER);
        vault.cancelProposal(id);
        _expectState(id, BaskVault.ProposalState.Cancelled);
        d.action = BaskVault.Action.FeeRecipient;
        id = _propose(d);
        vm.prank(GUARDIAN);
        vault.cancelProposal(id);
        _expectState(id, BaskVault.ProposalState.Cancelled);
        d.action = BaskVault.Action.Guardian;
        _run(d);
        assertEq(vault.guardian(), bob);
        vm.prank(GUARDIAN);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.closeAsset(address(tokens[0]));
    }

    function testTwoStepOwnerNeverGuardianEvenAfterProposal() public {
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.transferOwnership(GUARDIAN);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.transferOwnership(address(0));
        vm.prank(OWNER);
        vault.transferOwnership(bob);
        vm.prank(alice);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.acceptOwnership();
        BaskVault.ProposalData memory d = _data(BaskVault.Action.Guardian, address(0));
        d.target = bob;
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.propose(d);
        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(vault.owner(), bob);
        assertEq(vault.pendingOwner(), address(0));
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.lowerNAVCap(0);
    }

    function testLaterCloseVoidsReopen() public {
        address token = address(tokens[0]);
        vm.prank(OWNER);
        vault.closeAsset(token);
        uint256 id = _propose(_data(BaskVault.Action.Reopen, token));
        vm.prank(GUARDIAN);
        vault.closeAsset(token);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        _expectState(id, BaskVault.ProposalState.Voided);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.NotReady.selector);
        vault.executeProposal(id);
        _run(_data(BaskVault.Action.Reopen, token));
        assertTrue(vault.asset(token).open);
    }

    function testRetirementVoidsProposalsAndStopsDepositsButRedeems() public {
        _depositAll(100e18);
        address token = address(tokens[0]);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, token));
        vault.propose(_data(BaskVault.Action.Retire, token));
        vm.prank(OWNER);
        vault.closeAsset(token);
        uint256 reopen = _propose(_data(BaskVault.Action.Reopen, token));
        uint256 resync = _propose(_data(BaskVault.Action.Resync, token));
        _run(_data(BaskVault.Action.Retire, token));
        _expectState(reopen, BaskVault.ProposalState.Voided);
        _expectState(resync, BaskVault.ProposalState.Voided);
        assertTrue(vault.asset(token).retired);
        assertFalse(vault.asset(token).open);
        assertEq(vault.feedAsset(address(feeds[0])), address(0));
        tokens[0].setReadMode(MockToken.ReadMode.BurnGas);
        feeds[0].setMode(2);
        vm.expectRevert(
            abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, BaskVault.Reason.RetiredBacking, token)
        );
        vault.previewDeposit(_one(address(tokens[1])), _amount(1e18));
        vm.expectRevert(
            abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, BaskVault.Reason.RetiredBacking, token)
        );
        vm.prank(alice);
        vault.deposit(_one(address(tokens[1])), _amount(1e18), alice, 0, vm.getBlockTimestamp());
        _redeem(30e18);
        assertGt(vault.owed(alice, token), 0);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, token));
        vault.removeAsset(token);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, token));
        vault.propose(_data(BaskVault.Action.Resync, token));
    }

    function testRemoveAndRelistDoesNotReviveOldProposals() public {
        address token = address(tokens[0]);
        vm.prank(OWNER);
        vault.closeAsset(token);
        uint256 pending = _propose(_data(BaskVault.Action.Reopen, token));
        _run(_data(BaskVault.Action.Retire, token));
        vault.removeAsset(token);
        assertEq(vault.assetCount(), 2);
        BaskVault.ProposalData memory d = _data(BaskVault.Action.List, token);
        d.target = address(feeds[0]);
        d.pool = address(pools[0]);
        d.quoteFeed = address(quoteFeed);
        d.value = 100;
        _run(d);
        assertEq(vault.assetCount(), 3);
        assertTrue(vault.asset(token).open);
        assertFalse(vault.asset(token).retired);
        _expectState(pending, BaskVault.ProposalState.Voided);
    }

    function testListingChecksAtProposalAndExecution() public {
        MockToken token = new MockToken(6);
        MockFeed feed = new MockFeed(8, 2e8);
        BaskVault.ProposalData memory d = _data(BaskVault.Action.List, address(token));
        d.target = address(feeds[0]);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(feeds[0])));
        vault.propose(d);
        d.target = address(feed);
        uint256 id = _propose(d);
        token.setDecimals(19);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(token)));
        vault.executeProposal(id);
        token.setDecimals(6);
        feed.set(0, vm.getBlockTimestamp());
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(feed)));
        vault.executeProposal(id);
        feed.set(3e8, vm.getBlockTimestamp());
        _execute(id);
        assertEq(vault.asset(address(token)).centre, 3e8);
        token.mint(alice, 10e6);
        vm.prank(alice);
        token.approve(address(vault), 10e6);
        _refresh();
        vm.prank(alice);
        uint256 minted = vault.deposit(_one(address(token)), _amount(10e6), alice, 0, vm.getBlockTimestamp());
        assertEq(minted, 30e18 - 1e15);
    }

    function testFeedAndRecentreUseExecutionAnswer() public {
        MockFeed feed = new MockFeed(6, 2e6);
        BaskVault.ProposalData memory d = _data(BaskVault.Action.Feed, address(tokens[0]));
        d.target = address(feed);
        uint256 id = _propose(d);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        feed.set(3e6, vm.getBlockTimestamp());
        _execute(id);
        assertEq(vault.asset(address(tokens[0])).centre, 3e6);
        assertEq(vault.asset(address(tokens[0])).feedDecimals, 6);
        assertEq(vault.feedAsset(address(feeds[0])), address(0));
        id = _propose(_data(BaskVault.Action.Recentre, address(tokens[0])));
        vm.warp(vm.getBlockTimestamp() + 2 days);
        feed.set(4e6, vm.getBlockTimestamp());
        _execute(id);
        assertEq(vault.asset(address(tokens[0])).centre, 4e6);
    }

    function testLowerCapVoidsRaisesAndBounds() public {
        BaskVault.ProposalData memory d = _data(BaskVault.Action.RaiseCap, address(0));
        d.value = 2_000_000e18;
        uint256 id = _propose(d);
        vm.prank(OWNER);
        vault.lowerNAVCap(10e18);
        _expectState(id, BaskVault.ProposalState.Voided);
        _run(d);
        assertEq(vault.NAV_CAP(), d.value);
        d.value = 10_000_000_000e18 + 1;
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.propose(d);
        d.action = BaskVault.Action.FeeRecipient;
        d.target = address(vault);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.propose(d);
    }

    function testSettingGasBoundsAndRevalidation() public {
        _badSetting(BaskVault.Setting.Band, 1);
        _badSetting(BaskVault.Setting.Band, 101);
        _badSetting(BaskVault.Setting.MaxAge, 3599);
        _badSetting(BaskVault.Setting.NoPoolAge, 30 days + 1);
        _badSetting(BaskVault.Setting.FreshCount, 11);
        _badSetting(BaskVault.Setting.FreshHours, 49);
        _badSetting(BaskVault.Setting.HoursFrom, 1);
        _badSetting(BaskVault.Setting.HoursTo, 86401);
        _badSetting(BaskVault.Setting.PoolWindow, 299);
        _badSetting(BaskVault.Setting.PoolDeviation, 2001);
        _badSetting(BaskVault.Setting.FeedGas, 19999);
        _badSetting(BaskVault.Setting.PayGas, 500001);
        _badSetting(BaskVault.Setting.MaxAssets, 2);
        _badSetting(BaskVault.Setting.MaxAssets, type(uint256).max);
        _badSetting(BaskVault.Setting.DirectLimit, 78);
        _badSetting(BaskVault.Setting.BalanceGas, 52001);
        BaskVault.ProposalData memory d = _data(BaskVault.Action.SettingChange, address(0));
        d.setting = BaskVault.Setting.BalanceGas;
        d.value = 52000;
        uint256 id = _propose(d);
        _setting(BaskVault.Setting.MaxAssets, 254);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        vault.executeProposal(id);
    }

    function _badSetting(BaskVault.Setting key, uint256 value) private {
        BaskVault.ProposalData memory d = _data(BaskVault.Action.SettingChange, address(0));
        d.setting = key;
        d.value = value;
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        vault.propose(d);
    }

    function _expectState(uint256 id, BaskVault.ProposalState expected) private view {
        assertEq(uint256(vault.proposalStatus(id)), uint256(expected));
        assertEq(uint256(vault.proposal(id).state), uint256(expected));
    }
}
