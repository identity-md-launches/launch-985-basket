// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest, BaskVault, MockToken, MockFeed} from "./Base.t.sol";

contract SettingsTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _depositAll(100e18);
        // Isolate each setting's own bounds from the two aggregate gas limits.
        _setting(BaskVault.Setting.MaxAssets, 3);
        _setting(BaskVault.Setting.DirectLimit, 0);
        _setting(BaskVault.Setting.HoursTo, 1 days);
    }

    function _bounds(uint256 key) private pure returns (uint256 low, uint256 high) {
        if (key == 0) return (2, 100);
        if (key == 1 || key == 2) return (1 hours, 30 days);
        if (key == 3) return (0, 10);
        if (key == 4) return (1, 48);
        if (key == 5) return (0, 1 days - 1);
        if (key == 6) return (0, 1 days);
        if (key == 7) return (300, 86400);
        if (key == 8) return (50, 2000);
        if (key <= 13) return (20_000, 500_000);
        // 254 * 110,000 <= 28M; 77 * 360,000 <= 28M at default gas settings.
        if (key == 14) return (3, 254);
        return (0, 77);
    }

    function _change(BaskVault.Setting key, uint256 value) private pure returns (BaskVault.ProposalData memory d) {
        d.action = BaskVault.Action.SettingChange;
        d.setting = key;
        d.value = value;
    }

    function _assertAccepted(BaskVault.Setting key, uint256 value) private {
        uint256[16] memory beforeSettings = vault.settings();
        uint256 id = _propose(_change(key, value));
        assertEq(abi.encode(vault.settings()), abi.encode(beforeSettings), "proposal changed active settings");
        vm.warp(vault.proposal(id).readyAt - 1);
        vm.expectRevert(BaskVault.NotReady.selector);
        _execute(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        _execute(id);
        beforeSettings[uint256(key)] = value;
        assertEq(abi.encode(vault.settings()), abi.encode(beforeSettings), "changed an unrelated setting");
        assertEq(uint256(vault.proposalStatus(id)), uint256(BaskVault.ProposalState.Executed));
        vm.expectRevert(BaskVault.NotReady.selector);
        _execute(id);
    }

    function _assertRejected(BaskVault.Setting key, uint256 value) private {
        bytes32 beforeSettings = keccak256(abi.encode(vault.settings()));
        uint256 beforeCount = vault.proposalCount();
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        _propose(_change(key, value));
        assertEq(vault.proposalCount(), beforeCount, "invalid setting created a proposal");
        assertEq(keccak256(abi.encode(vault.settings())), beforeSettings);
    }

    function _assertExit() private {
        vm.prank(GUARDIAN);
        vault.setDepositsPaused(true);
        for (uint256 i; i < 3; ++i) {
            feeds[i].setMode(2);
            tokens[i].setPause(true);
        }
        uint256[] memory legs = _redeem(30e18);
        assertEq(vault.totalSupply(), 270e18);
        assertEq(legs.length, 3);
        for (uint256 i; i < 3; ++i) {
            address token = address(tokens[i]);
            assertEq(legs[i], 10e18);
            assertEq(vault.managed(token), 90e18);
            assertEq(vault.owed(alice, token), 10e18);
            assertEq(vault.totalOwed(token), 10e18);
            assertEq(tokens[i].balanceOf(address(vault)), 100e18);
            tokens[i].setPause(false);
            vm.prank(alice);
            vault.claim(_one(token), bob);
            assertEq(tokens[i].balanceOf(bob), 10e18);
            assertEq(tokens[i].balanceOf(address(vault)), 90e18);
            assertEq(vault.owed(alice, token), 0);
            assertEq(vault.totalOwed(token), 0);
        }
    }

    function test_EverySettingAcceptsBothEndpointsAndPreservesExit() public {
        for (uint256 i; i < 16; ++i) {
            (uint256 low, uint256 high) = _bounds(i);
            for (uint256 endpoint; endpoint < 2; ++endpoint) {
                uint256 snapshot = vm.snapshotState();
                _assertAccepted(BaskVault.Setting(i), endpoint == 0 ? low : high);
                _assertExit();
                assertTrue(vm.revertToStateAndDelete(snapshot));
            }
        }
    }

    function test_EverySettingRejectsOutsideBoundsAndMaxUintAtomically() public {
        for (uint256 i; i < 16; ++i) {
            (uint256 low, uint256 high) = _bounds(i);
            if (low != 0) _assertRejected(BaskVault.Setting(i), low - 1);
            _assertRejected(BaskVault.Setting(i), high + 1);
            _assertRejected(BaskVault.Setting(i), type(uint256).max);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_AnyAllowedSettingPreservesRedemptionAndClaim(uint8 keySeed, uint256 valueSeed) public {
        uint256 key = bound(keySeed, 0, 15);
        (uint256 low, uint256 high) = _bounds(key);
        _assertAccepted(BaskVault.Setting(key), bound(valueSeed, low, high));
        _assertExit();
    }

    function test_PendingDirectLimitRechecksRaisedPaymentBudget() public {
        uint256 id = _propose(_change(BaskVault.Setting.DirectLimit, 77));
        _setting(BaskVault.Setting.PayGas, 500_000);
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        _execute(id);
        assertEq(vault.setting(BaskVault.Setting.DirectLimit), 0);
        assertEq(uint256(vault.proposalStatus(id)), uint256(BaskVault.ProposalState.Ready));
        // A failed execution remains retryable within the original window.
        _setting(BaskVault.Setting.PayGas, 250_000);
        _execute(id);
        assertEq(vault.setting(BaskVault.Setting.DirectLimit), 77);
        _assertExit();
    }

    function test_PendingAssetLimitRechecksNewListing() public {
        _setting(BaskVault.Setting.MaxAssets, 4);
        uint256 id = _propose(_change(BaskVault.Setting.MaxAssets, 3));
        MockToken token = new MockToken(18);
        MockFeed feed = new MockFeed(8, 1e8);
        BaskVault.ProposalData memory data = _data(BaskVault.Action.List, address(token));
        data.target = address(feed);
        _run(data);
        assertEq(vault.assetCount(), 4);
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        _execute(id);
        assertEq(vault.setting(BaskVault.Setting.MaxAssets), 4);
        assertEq(uint256(vault.proposalStatus(id)), uint256(BaskVault.ProposalState.Ready));
    }

    function test_PendingHoursRecheckOtherEndpoint() public {
        uint256 id = _propose(_change(BaskVault.Setting.HoursFrom, 12 hours));
        _setting(BaskVault.Setting.HoursTo, 10 hours);
        vm.expectRevert(BaskVault.InvalidSetting.selector);
        _execute(id);
        assertEq(vault.setting(BaskVault.Setting.HoursFrom), 0);
        assertEq(vault.setting(BaskVault.Setting.HoursTo), 10 hours);
        _assertExit();
    }
}
