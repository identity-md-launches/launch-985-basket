// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaskVault} from "src/BaskVault.sol";
import {BasketHandler, SequenceStockToken} from "./handlers/BasketHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract BasketInvariantTest is Test {
    BasketHandler internal handler;
    BaskVault internal vault;

    function setUp() public {
        vm.warp(100 days);
        vm.chainId(4663);
        handler = new BasketHandler();
        vault = handler.vault();
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.redeem.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.confiscate.selector;
        selectors[5] = handler.flag.selector;
        selectors[6] = handler.recognize.selector;
        selectors[7] = handler.resync.selector;
        selectors[8] = handler.transferShares.selector;
        selectors[9] = handler.tokenState.selector;
        selectors[10] = handler.advanceTime.selector;
        selectors[11] = handler.pause.selector;
        selectors[12] = handler.configure.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_CustodyAndLiabilitiesMatchIndependentFlows() public view {
        for (uint256 i; i < 3; ++i) {
            SequenceStockToken token = handler.tokens(i);
            assertEq(
                token.custody(address(vault)) + handler.paid(i) + handler.confiscated(i),
                handler.deposited(i) + handler.donated(i),
                "physical custody does not conserve Stock Tokens"
            );
            assertEq(
                vault.managed(address(token)) + vault.totalOwed(address(token)) + handler.paid(i)
                    + handler.recognized(i),
                handler.deposited(i) + handler.resynced(i),
                "accounted backing was lost or fabricated"
            );
            uint256 debts;
            for (uint256 j; j < 4; ++j) {
                debts += vault.owed(handler.actors(j), address(token));
            }
            assertEq(vault.totalOwed(address(token)), debts, "aggregate debt differs from claimants' debts");
        }
    }

    function invariant_ShareSupplyAndPermanentLock() public view {
        uint256 supply = vault.balanceOf(address(0xdEaD));
        assertEq(supply, 1e15, "first deposit lock changed");
        for (uint256 j; j < 4; ++j) {
            supply += vault.balanceOf(handler.actors(j));
        }
        assertEq(vault.totalSupply(), supply, "share supply does not equal balances");
        assertEq(vault.balanceOf(address(0)), 0);
        assertEq(vault.balanceOf(address(vault)), 0);
    }

    /// Every generated terminal state must permit all users, including the fee recipient, to exit.
    function afterInvariant() public {
        for (uint256 j; j < 4; ++j) {
            handler.redeem(j, j, 0, true);
        }
        invariant_CustodyAndLiabilitiesMatchIndependentFlows();
        invariant_ShareSupplyAndPermanentLock();
    }

    function test_HandlerReachesDebtRecoveryAndLossRecognition() public {
        handler.advanceTime(0, true);
        handler.configure(1, 0);
        handler.redeem(0, 1, 20e18, false);
        handler.claim(1, 2, 0);
        assertGt(handler.successfulClaims(), 0);
        handler.confiscate(1, 10e18);
        handler.flag(1);
        handler.advanceTime(7 days, true);
        handler.recognize(1);
        assertGt(handler.recognized(1), 0);
        handler.donate(2, 10e18);
        handler.resync(2);
        assertGt(handler.resynced(2), 0);
        handler.advanceTime(0, true);
        handler.deposit(2, 2, 10e18);
        assertGt(handler.successfulDeposits(), 3);
        invariant_CustodyAndLiabilitiesMatchIndependentFlows();
        invariant_ShareSupplyAndPermanentLock();
    }
}
