// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {BaseTest, BaskVault, MockToken, MockFeed, MockPool} from "./Base.t.sol";

contract AccountingTest is BaseTest {
    function testDeploymentAndFirstDeposit() public {
        assertEq(vault.name(), "Basket");
        assertEq(vault.symbol(), "BASK");
        assertEq(vault.decimals(), 18);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.owner(), OWNER);
        assertEq(vault.guardian(), GUARDIAN);
        assertEq(vault.NAV_CAP(), 1_000_000e18);
        uint256 received = _deposit(100e18);
        assertEq(received, 100e18 - 1e15);
        assertEq(vault.balanceOf(address(0xdEaD)), 1e15);
        assertEq(vault.totalSupply(), 100e18);
        assertEq(vault.managed(address(tokens[0])), 100e18);
        assertEq(address(vault).code.length <= 24_000, true);
    }

    function testDonationIgnoredUntilResyncAndShareMath() public {
        _deposit(100e18);
        tokens[0].mint(address(vault), 100e18);
        (uint256 preview,, uint256 value, uint256 nav) = vault.previewDeposit(_one(address(tokens[0])), _amount(100e18));
        assertEq(preview, 100e18);
        assertEq(value, 100e18);
        assertEq(nav, 100e18);
        assertEq(_deposit(100e18), 100e18);
        _run(_data(BaskVault.Action.Resync, address(tokens[0])));
        assertEq(vault.managed(address(tokens[0])), 300e18);
        assertEq(_deposit(150e18), 100e18);
    }

    function testFeesRoundUpMintAndTransfer() public {
        _feeOn();
        uint256 amount = 100e18 + 1;
        uint256 fee = amount / 200 + 1;
        uint256 received = _deposit(amount);
        assertEq(received, amount - fee - 1e15);
        assertEq(vault.balanceOf(recipient), fee);
        assertEq(vault.totalSupply(), amount);
        uint256 shares = 11e18 + 1;
        uint256 redeemFee = shares / 200 + 1;
        uint256[] memory legs = _redeem(shares);
        assertEq(legs[0], shares - redeemFee);
        assertEq(vault.totalSupply(), amount - shares + redeemFee);
        assertEq(vault.balanceOf(recipient), fee + redeemFee);
    }

    function testRedeemDirectHasNoPriceDependency() public {
        _depositAll(100e18);
        for (uint256 i; i < 3; ++i) {
            feeds[i].setMode(2);
            vm.prank(GUARDIAN);
            vault.closeAsset(address(tokens[i]));
        }
        vm.prank(GUARDIAN);
        vault.setDepositsPaused(true);
        uint256 before = tokens[0].balanceOf(alice);
        uint256[] memory amounts = _redeem(30e18);
        for (uint256 i; i < 3; ++i) {
            assertEq(amounts[i], 10e18);
        }
        assertEq(tokens[0].balanceOf(alice), before + 10e18);
        assertEq(vault.totalSupply(), 270e18);
    }

    function testDeferredClaimAndPartialLiquidity() public {
        _depositAll(100e18);
        _setting(BaskVault.Setting.DirectLimit, 0);
        _redeem(150e18);
        assertEq(vault.owed(alice, address(tokens[0])), 50e18);
        assertEq(vault.totalOwed(address(tokens[0])), 50e18);
        assertEq(vault.managed(address(tokens[0])), 50e18);
        tokens[0].confiscate(address(vault), 75e18);
        vm.prank(alice);
        vault.claim(_one(address(tokens[0])), bob);
        assertEq(tokens[0].balanceOf(bob), 25e18);
        assertEq(vault.owed(alice, address(tokens[0])), 25e18);
        tokens[0].mint(address(vault), 25e18);
        vm.prank(alice);
        vault.claim(_one(address(tokens[0])), bob);
        assertEq(tokens[0].balanceOf(bob), 50e18);
        assertEq(vault.totalOwed(address(tokens[0])), 0);
    }

    function testResyncExcludesOwed() public {
        _deposit(100e18);
        _setting(BaskVault.Setting.DirectLimit, 0);
        _redeem(50e18);
        tokens[0].mint(address(vault), 20e18);
        _run(_data(BaskVault.Action.Resync, address(tokens[0])));
        assertEq(vault.managed(address(tokens[0])), 70e18);
        assertEq(vault.totalOwed(address(tokens[0])), 50e18);
    }

    function testNoAutomaticLossAndSevenDayRecognition() public {
        _deposit(100e18);
        tokens[0].confiscate(address(vault), 30e18);
        _status(BaskVault.Reason.Deficit, address(tokens[0]));
        vault.flagDeficit(address(tokens[0]));
        vm.expectRevert(BaskVault.NotReady.selector);
        vault.recognizeLoss(address(tokens[0]));
        _redeem(50e18);
        assertEq(vault.managed(address(tokens[0])), 65e18);
        tokens[0].mint(address(vault), 10e18);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.recognizeLoss(address(tokens[0]));
        assertEq(vault.managed(address(tokens[0])), 45e18);
        (uint256 deficit,) = vault.deficits(address(tokens[0]));
        assertEq(deficit, 0);
        _refresh();
        assertEq(_deposit(45e18), 50e18);
    }

    function testLargerDeficitRestartsClockAndDepositClears() public {
        _deposit(100e18);
        tokens[0].confiscate(address(vault), 10e18);
        vault.flagDeficit(address(tokens[0]));
        uint256 first = vm.getBlockTimestamp();
        vm.warp(first + 1 days);
        vm.expectRevert(BaskVault.NoDeficit.selector);
        vault.flagDeficit(address(tokens[0]));
        tokens[0].confiscate(address(vault), 10e18);
        vault.flagDeficit(address(tokens[0]));
        (uint256 amount, uint256 since) = vault.deficits(address(tokens[0]));
        assertEq(amount, 20e18);
        assertEq(since, first + 1 days);
        tokens[0].mint(address(vault), 20e18);
        _refresh();
        _deposit(1e18);
        (amount, since) = vault.deficits(address(tokens[0]));
        assertEq(amount, 0);
        assertEq(since, 0);
    }

    function testSlippageAndDeadlineAtomicity() public {
        vm.prank(alice);
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.deposit(_one(address(tokens[0])), _amount(1e18), alice, 1e18, vm.getBlockTimestamp());
        assertEq(vault.totalSupply(), 0);
        vm.prank(alice);
        vm.expectRevert(BaskVault.Expired.selector);
        vault.deposit(_one(address(tokens[0])), _amount(1e18), alice, 0, vm.getBlockTimestamp() - 1);
        _depositAll(100e18);
        vm.prank(alice);
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.redeem(3e18, alice, _amount(2e18), vm.getBlockTimestamp());
        assertEq(vault.totalSupply(), 300e18);
        vm.prank(alice);
        vm.expectRevert(BaskVault.Expired.selector);
        vault.redeem(3e18, alice, new uint256[](0), vm.getBlockTimestamp() - 1);
    }

    function testInputValidationAndCap() public {
        address[] memory twice = new address[](2);
        twice[0] = address(tokens[0]);
        twice[1] = twice[0];
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 1e18;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, BaskVault.Reason.Duplicate, twice[0])
        );
        vault.deposit(twice, amounts, alice, 0, vm.getBlockTimestamp());
        vm.prank(alice);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.deposit(_one(twice[0]), _amount(1e18), address(vault), 0, vm.getBlockTimestamp());
        vm.prank(alice);
        vm.expectRevert(BaskVault.InvalidInput.selector);
        vault.deposit(_one(twice[0]), _amount(0), alice, 0, vm.getBlockTimestamp());
        vm.prank(OWNER);
        vault.lowerNAVCap(1e18);
        vm.expectRevert(BaskVault.CapExceeded.selector);
        _deposit(2e18);
        _deposit(1e18);
    }

    function testERC20AllowancesAndNoBurnByTransfer() public {
        _deposit(10e18);
        vm.prank(alice);
        vault.approve(bob, 3e18);
        vm.prank(bob);
        vault.transferFrom(alice, bob, 2e18);
        assertEq(vault.allowance(alice, bob), 1e18);
        assertEq(vault.balanceOf(bob), 2e18);
        vm.prank(bob);
        vm.expectRevert(BaskVault.InsufficientShares.selector);
        vault.transferFrom(alice, bob, 2e18);
        vm.prank(bob);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.transfer(address(0), 1e18);
    }

    function testFuzzConservation(uint96 seedDeposit, uint96 seedRedeem, bool defer, bool fees) public {
        uint256 amount = bound(uint256(seedDeposit), 1e18, 100_000e18);
        if (fees) _feeOn();
        if (defer) _setting(BaskVault.Setting.DirectLimit, 0);
        uint256 received = _deposit(amount);
        uint256 shares = bound(uint256(seedRedeem), 1, received);
        (uint256[] memory preview, uint256 fee) = vault.previewRedeem(shares);
        uint256[] memory paid = _redeem(shares);
        assertEq(paid, preview);
        assertEq(vault.totalSupply(), amount - shares + fee);
        assertEq(
            vault.managed(address(tokens[0])) + vault.totalOwed(address(tokens[0])), tokens[0].balanceOf(address(vault))
        );
        assertEq(
            vault.balanceOf(alice) + vault.balanceOf(recipient) + vault.balanceOf(address(0xdEaD)), vault.totalSupply()
        );
        if (defer) {
            vm.prank(alice);
            vault.claim(_one(address(tokens[0])), alice);
        }
        assertEq(vault.managed(address(tokens[0])), tokens[0].balanceOf(address(vault)));
    }

    function testRemovalMovesFundedAssetIndexAndLossClearsBitmap() public {
        vm.prank(alice);
        vault.deposit(_one(address(tokens[2])), _amount(100e18), alice, 0, vm.getBlockTimestamp());
        vm.prank(OWNER);
        vault.closeAsset(address(tokens[0]));
        _run(_data(BaskVault.Action.Retire, address(tokens[0])));
        vault.removeAsset(address(tokens[0]));
        assertEq(vault.assets(0), address(tokens[2]));
        uint256[] memory legs = _redeem(50e18);
        assertEq(legs[0], 50e18);
        assertEq(vault.managed(address(tokens[2])), 50e18);
        tokens[2].confiscate(address(vault), 50e18);
        vault.flagDeficit(address(tokens[2]));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.recognizeLoss(address(tokens[2]));
        legs = _redeem(1e18);
        assertEq(legs[0], 0);
        tokens[2].mint(address(vault), 49e18);
        _run(_data(BaskVault.Action.Resync, address(tokens[2])));
        legs = _redeem(1e18);
        assertEq(legs[0], 1e18);
    }

    function testFirstDepositMustExceedLockAndFees() public {
        vm.expectRevert(BaskVault.Slippage.selector);
        _deposit(1e15);
        _feeOn();
        vm.expectRevert(BaskVault.Slippage.selector);
        _deposit(1e15 + 1);
        assertGt(_deposit(2e15), 0);
    }

    function testFuzzDecimalValuation(uint8 tokenSeed, uint8 feedSeed, uint32 amountSeed) public {
        uint8 td = uint8(bound(uint256(tokenSeed), 0, 18));
        uint8 fd = uint8(bound(uint256(feedSeed), 0, 18));
        uint256 answer = 7 * 10 ** uint256(fd) + 10 ** uint256(fd) / 3;
        uint256 amount = bound(uint256(amountSeed), 1, 1000) * 10 ** uint256(td);
        MockToken token = new MockToken(td);
        MockFeed feed = new MockFeed(fd, int256(answer));
        BaskVault.ProposalData memory d = _data(BaskVault.Action.List, address(token));
        d.target = address(feed);
        _run(d);
        feed.set(int256(answer), vm.getBlockTimestamp());
        token.mint(alice, amount);
        vm.prank(alice);
        token.approve(address(vault), amount);
        uint256 expected = amount * answer * 1e18 / 10 ** (uint256(td) + fd);
        vm.prank(alice);
        uint256 received = vault.deposit(_one(address(token)), _amount(amount), alice, 0, vm.getBlockTimestamp());
        assertEq(received, expected - 1e15);
        assertEq(vault.totalSupply(), expected);
    }

    function testRuntimeHasNoForbiddenOpcodes() public view {
        bytes memory code = address(vault).code;
        assertLe(code.length, 24_000);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }

    function testERC20TransferEventTopics() public {
        _deposit(10e18);
        vm.expectEmit(true, true, false, true, address(vault));
        emit BaskVault.Transfer(alice, bob, 1e18);
        vm.prank(alice);
        vault.transfer(bob, 1e18);
    }
}
