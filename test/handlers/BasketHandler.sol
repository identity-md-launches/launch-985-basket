// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaskVault} from "src/BaskVault.sol";
import {MockToken, MockFeed} from "../mocks/Mocks.sol";

/// The harness can inspect custody even while the public ERC-20 read is broken.
contract SequenceStockToken is MockToken {
    constructor() MockToken(18) {}

    function custody(address account) external view returns (uint256) {
        return _balances[account];
    }
}

/// Four independent actors; the fourth initially receives fees. No storage injection.
contract BasketHandler is Test {
    address public constant OWNER = 0x30B57ECf51D19ABcED7F6f70974e6fBb6f3b9Da3;
    address public constant GUARDIAN = 0x5ed39AF86f2C00ad99913B5d727bD68f2A904B68;
    BaskVault public vault;
    SequenceStockToken[3] public tokens;
    MockFeed[3] public feeds;
    address[4] public actors;

    uint256[3] public deposited;
    uint256[3] public donated;
    uint256[3] public paid;
    uint256[3] public confiscated;
    uint256[3] public recognized;
    uint256[3] public resynced;
    uint256 public successfulDeposits;
    uint256 public successfulRedeems;
    uint256 public successfulClaims;

    constructor() {
        vault = new BaskVault(OWNER, GUARDIAN);
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("sequence actor ", vm.toString(i)));
        }
        for (uint256 i; i < 3; ++i) {
            tokens[i] = new SequenceStockToken();
            feeds[i] = new MockFeed(8, 1e8);
            vm.prank(OWNER);
            vault.genesisList(address(tokens[i]), address(feeds[i]), address(0), address(0), 0);
        }
        vm.prank(OWNER);
        vault.finalizeGenesis();
        // Seed all assets and several shareholders through the same checked handlers.
        for (uint256 i; i < 3; ++i) {
            deposit(i, i, 100e18);
        }
        configure(0, 3);
    }

    function _one(address token) private pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = token;
    }

    function _amount(uint256 amount) private pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = amount;
    }

    function _readable(uint256 i) private view returns (bool) {
        return tokens[i].readMode() == MockToken.ReadMode.Normal;
    }

    function _canTransfer(uint256 i) private view returns (bool) {
        MockToken.TransferMode mode = tokens[i].mode();
        return !tokens[i].paused() && (mode == MockToken.TransferMode.Normal || mode == MockToken.TransferMode.NoReturn);
    }

    function _shortfall(uint256 i) private view returns (uint256) {
        uint256 balance = tokens[i].custody(address(vault));
        uint256 debt = vault.totalOwed(address(tokens[i]));
        uint256 available = balance > debt ? balance - debt : 0;
        uint256 managed = vault.managed(address(tokens[i]));
        return managed > available ? managed - available : 0;
    }

    function deposit(uint256 actorSeed, uint256 tokenSeed, uint256 amountSeed) public {
        uint256 i = tokenSeed % 3;
        address actor = actors[actorSeed % 4];
        uint256 amount = bound(amountSeed, 1e16, 1_000e18);
        address[] memory selected = _one(address(tokens[i]));
        tokens[i].mint(actor, amount);
        vm.prank(actor);
        tokens[i].approve(address(vault), amount);
        (BaskVault.Reason reason, address fault) = vault.depositStatus(selected);
        if (reason != BaskVault.Reason.OK) {
            vm.prank(actor);
            vm.expectRevert(abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, reason, fault));
            vault.deposit(selected, _amount(amount), actor, 0, vm.getBlockTimestamp());
            return;
        }
        uint256 nav;
        for (uint256 j; j < 3; ++j) {
            nav += vault.managed(address(tokens[j]));
        }
        if (nav == 0 && vault.totalSupply() != 0) {
            vm.prank(actor);
            vm.expectRevert(BaskVault.ZeroNAV.selector);
            vault.deposit(selected, _amount(amount), actor, 0, vm.getBlockTimestamp());
            return;
        }
        (uint256 preview,,,) = vault.previewDeposit(selected, _amount(amount));
        if (!_canTransfer(i)) {
            vm.prank(actor);
            vm.expectRevert(BaskVault.PaymentFailed.selector);
            vault.deposit(selected, _amount(amount), actor, 0, vm.getBlockTimestamp());
            return;
        }
        uint256 beforeBalance = tokens[i].custody(actor);
        uint256 beforeShares = vault.balanceOf(actor);
        address feeRecipient = vault.feeRecipient();
        uint256 feeBefore = vault.balanceOf(feeRecipient);
        uint256 supplyBefore = vault.totalSupply();
        vm.prank(actor);
        uint256 shares = vault.deposit(selected, _amount(amount), actor, preview, vm.getBlockTimestamp());
        assertEq(shares, preview, "deposit preview mismatch");
        assertEq(beforeBalance - tokens[i].custody(actor), amount, "wrong deposit debit");
        assertGe(vault.balanceOf(actor) - beforeShares, shares, "receiver not credited");
        if (feeRecipient != actor && feeRecipient != address(0)) {
            assertEq(vault.totalSupply() - supplyBefore, shares + vault.balanceOf(feeRecipient) - feeBefore);
        }
        deposited[i] += amount;
        ++successfulDeposits;
        for (uint256 j; j < 3; ++j) {
            (uint256 record,) = vault.deficits(address(tokens[j]));
            assertEq(record, 0, "deposit did not clear deficit record");
        }
    }

    function redeem(uint256 actorSeed, uint256 receiverSeed, uint256 shareSeed, bool entireBalance) public {
        address actor = actors[actorSeed % 4];
        address receiver = actors[receiverSeed % 4];
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) return;
        uint256 shares = entireBalance ? balance : bound(shareSeed, 1, balance);
        uint256 supply = vault.totalSupply();
        uint256[3] memory beforePaid;
        uint256[3] memory beforeManaged;
        uint256[3] memory beforeOwed;
        for (uint256 i; i < 3; ++i) {
            beforePaid[i] = tokens[i].custody(receiver);
            beforeManaged[i] = vault.managed(address(tokens[i]));
            beforeOwed[i] = vault.owed(receiver, address(tokens[i]));
        }
        (uint256[] memory preview,) = vault.previewRedeem(shares);
        vm.prank(actor);
        uint256[] memory legs = vault.redeem(shares, receiver, new uint256[](0), vm.getBlockTimestamp());
        uint256 fee = vault.feeRecipient() == address(0) ? 0 : (shares + 199) / 200;
        assertEq(vault.totalSupply(), supply - shares + fee, "redeem burned the fee");
        for (uint256 i; i < 3; ++i) {
            uint256 payout = tokens[i].custody(receiver) - beforePaid[i];
            uint256 debt = vault.owed(receiver, address(tokens[i])) - beforeOwed[i];
            paid[i] += payout;
            assertEq(legs[i], preview[i], "redeem preview mismatch");
            assertEq(payout + debt, legs[i], "leg lost or counted twice");
            assertEq(vault.managed(address(tokens[i])) + legs[i], beforeManaged[i], "automatic loss or lost leg");
        }
        ++successfulRedeems;
    }

    function claim(uint256 actorSeed, uint256 receiverSeed, uint256 tokenSeed) public {
        uint256 i = tokenSeed % 3;
        address actor = actors[actorSeed % 4];
        address receiver = actors[receiverSeed % 4];
        address token = address(tokens[i]);
        uint256 debt = vault.owed(actor, token);
        if (debt != 0 && !_readable(i)) {
            vm.prank(actor);
            vm.expectRevert(abi.encodeWithSelector(BaskVault.BalanceUnreadable.selector, token));
            vault.claim(_one(token), receiver);
            assertEq(vault.owed(actor, token), debt);
            return;
        }
        uint256 balance = tokens[i].custody(address(vault));
        uint256 amount = debt < balance ? debt : balance;
        if (amount != 0 && !_canTransfer(i)) {
            vm.prank(actor);
            vm.expectRevert(BaskVault.PaymentFailed.selector);
            vault.claim(_one(token), receiver);
            assertEq(vault.owed(actor, token), debt);
            return;
        }
        uint256 beforeBalance = tokens[i].custody(receiver);
        vm.prank(actor);
        vault.claim(_one(token), receiver);
        uint256 payout = tokens[i].custody(receiver) - beforeBalance;
        assertEq(payout, amount, "claim did not pay min(debt,balance)");
        assertEq(vault.owed(actor, token), debt - payout);
        paid[i] += payout;
        if (payout > 0) ++successfulClaims;
    }

    function donate(uint256 tokenSeed, uint256 amountSeed) public {
        uint256 i = tokenSeed % 3;
        uint256 amount = bound(amountSeed, 1, 100e18);
        uint256 managed = vault.managed(address(tokens[i]));
        tokens[i].mint(address(vault), amount);
        donated[i] += amount;
        assertEq(vault.managed(address(tokens[i])), managed, "unsolicited tokens entered accounting");
    }

    function confiscate(uint256 tokenSeed, uint256 amountSeed) public {
        uint256 i = tokenSeed % 3;
        uint256 balance = tokens[i].custody(address(vault));
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        uint256 managed = vault.managed(address(tokens[i]));
        tokens[i].confiscate(address(vault), amount);
        confiscated[i] += amount;
        assertEq(vault.managed(address(tokens[i])), managed, "loss was recognized immediately");
    }

    function flag(uint256 tokenSeed) public {
        uint256 i = tokenSeed % 3;
        address token = address(tokens[i]);
        (uint256 record,) = vault.deficits(token);
        uint256 shortfall = _shortfall(i);
        if (!_readable(i)) {
            vm.expectRevert(abi.encodeWithSelector(BaskVault.BalanceUnreadable.selector, token));
        } else if (shortfall <= record) {
            vm.expectRevert(BaskVault.NoDeficit.selector);
        }
        vault.flagDeficit(token);
        if (_readable(i) && shortfall > record) {
            (uint256 recorded, uint256 since) = vault.deficits(token);
            assertEq(recorded, shortfall);
            assertEq(since, vm.getBlockTimestamp());
        }
    }

    function recognize(uint256 tokenSeed) public {
        uint256 i = tokenSeed % 3;
        address token = address(tokens[i]);
        (uint256 record, uint256 since) = vault.deficits(token);
        if (record == 0 || vm.getBlockTimestamp() < since + 7 days) {
            vm.expectRevert(BaskVault.NotReady.selector);
            vault.recognizeLoss(token);
            return;
        }
        if (!_readable(i)) {
            vm.expectRevert(abi.encodeWithSelector(BaskVault.BalanceUnreadable.selector, token));
            vault.recognizeLoss(token);
            return;
        }
        uint256 shortfall = _shortfall(i);
        uint256 loss = record < shortfall ? record : shortfall;
        uint256 managed = vault.managed(token);
        vault.recognizeLoss(token);
        assertEq(managed - vault.managed(token), loss, "wrong recognized loss");
        recognized[i] += loss;
        (record, since) = vault.deficits(token);
        assertEq(record, 0);
        assertEq(since, 0);
    }

    function resync(uint256 tokenSeed) public {
        uint256 i = tokenSeed % 3;
        address token = address(tokens[i]);
        BaskVault.ProposalData memory data;
        data.action = BaskVault.Action.Resync;
        data.token = token;
        vm.prank(OWNER);
        uint256 id = vault.propose(data);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        if (!_readable(i)) {
            vm.prank(OWNER);
            vm.expectRevert(abi.encodeWithSelector(BaskVault.BalanceUnreadable.selector, token));
            vault.executeProposal(id);
            return;
        }
        uint256 liabilities = vault.managed(token) + vault.totalOwed(token);
        uint256 balance = tokens[i].custody(address(vault));
        uint256 extra = balance > liabilities ? balance - liabilities : 0;
        vm.prank(OWNER);
        vault.executeProposal(id);
        resynced[i] += extra;
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, bool allowancePath) public {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = bound(amountSeed, 0, vault.balanceOf(from));
        uint256 supply = vault.totalSupply();
        uint256 fromBefore = vault.balanceOf(from);
        uint256 toBefore = vault.balanceOf(to);
        if (allowancePath) {
            vm.prank(from);
            vault.approve(address(this), amount);
            vault.transferFrom(from, to, amount);
            assertEq(vault.allowance(from, address(this)), 0);
        } else {
            vm.prank(from);
            vault.transfer(to, amount);
        }
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.balanceOf(from), from == to ? fromBefore : fromBefore - amount);
        assertEq(vault.balanceOf(to), from == to ? toBefore : toBefore + amount);
    }

    function tokenState(uint256 tokenSeed, uint256 stateSeed) public {
        uint256 i = tokenSeed % 3;
        uint256 state = stateSeed % 7;
        tokens[i].setPause(state == 1);
        tokens[i].setReadMode(state == 2 ? MockToken.ReadMode.RevertRead : MockToken.ReadMode.Normal);
        tokens[i].setMode(
            state == 3
                ? MockToken.TransferMode.Blocked
                : state == 4
                    ? MockToken.TransferMode.FalseReturn
                    : state == 5
                        ? MockToken.TransferMode.NoMove
                        : state == 6 ? MockToken.TransferMode.NoReturn : MockToken.TransferMode.Normal
        );
    }

    function advanceTime(uint256 elapsed, bool refresh) public {
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, 8 days));
        if (refresh) {
            for (uint256 i; i < 3; ++i) {
                feeds[i].set(1e8, vm.getBlockTimestamp());
            }
        }
    }

    function pause(bool paused) public {
        vm.prank(paused ? GUARDIAN : OWNER);
        vault.setDepositsPaused(paused);
    }

    function configure(uint256 settingSeed, uint256 valueSeed) public {
        BaskVault.ProposalData memory data;
        if (settingSeed % 2 == 0) {
            data.action = BaskVault.Action.FeeRecipient;
            data.target = actors[valueSeed % 4];
        } else {
            data.action = BaskVault.Action.SettingChange;
            data.setting = BaskVault.Setting.DirectLimit;
            data.value = valueSeed % 4;
        }
        vm.prank(OWNER);
        uint256 id = vault.propose(data);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(OWNER);
        vault.executeProposal(id);
    }
}
