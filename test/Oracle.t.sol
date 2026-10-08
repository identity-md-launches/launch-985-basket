// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {BaseTest, BaskVault, MockToken, MockFeed, MockPool} from "./Base.t.sol";
import {PoolOracle} from "../src/libraries/PoolOracle.sol";
import {FullMath} from "../src/libraries/FullMath.sol";

contract OracleTest is BaseTest {
    function testValidPoolCanUseOlderFeedButFallbackCannot() public {
        feeds[0].set(1e8, vm.getBlockTimestamp() - 27 hours);
        _status(BaskVault.Reason.OK, address(0));
        pools[0].setMode(1);
        _status(BaskVault.Reason.NoPoolAge, address(tokens[0]));
        feeds[0].set(1e8, vm.getBlockTimestamp() - 26 hours);
        _status(BaskVault.Reason.OK, address(0));
        feeds[0].set(1e8, vm.getBlockTimestamp() - 26 hours - 1);
        _status(BaskVault.Reason.NoPoolAge, address(tokens[0]));
        pools[0].setMode(0);
        feeds[0].set(1e8, vm.getBlockTimestamp() - 80 hours);
        _status(BaskVault.Reason.OK, address(0));
        feeds[0].set(1e8, vm.getBlockTimestamp() - 80 hours - 1);
        _status(BaskVault.Reason.Feed, address(tokens[0]));
    }

    function testBadAnswerFutureAndMalformedRead() public {
        feeds[0].set(0, vm.getBlockTimestamp());
        _status(BaskVault.Reason.Feed, address(tokens[0]));
        feeds[0].set(-1, vm.getBlockTimestamp());
        _status(BaskVault.Reason.Feed, address(tokens[0]));
        feeds[0].set(1e8, vm.getBlockTimestamp() + 1);
        _status(BaskVault.Reason.Feed, address(tokens[0]));
        feeds[0].set(1e8, vm.getBlockTimestamp());
        for (uint8 i = 1; i < 4; ++i) {
            feeds[0].setMode(i);
            _status(BaskVault.Reason.Feed, address(tokens[0]));
        }
    }

    function testBandBoundariesWithoutPool() public {
        BaskVault.ProposalData memory d = _data(BaskVault.Action.Pool, address(tokens[0]));
        _run(d);
        feeds[0].set(4e8, vm.getBlockTimestamp());
        _status(BaskVault.Reason.OK, address(0));
        feeds[0].set(4e8 + 1, vm.getBlockTimestamp());
        _status(BaskVault.Reason.Band, address(tokens[0]));
        feeds[0].set(25_000_000, vm.getBlockTimestamp());
        _status(BaskVault.Reason.OK, address(0));
        feeds[0].set(24_999_999, vm.getBlockTimestamp());
        _status(BaskVault.Reason.Band, address(tokens[0]));
    }

    function testPauseDetectionAndUnreadablePause() public {
        assertTrue(vault.asset(address(tokens[0])).hasPause);
        tokens[0].setPause(true);
        _status(BaskVault.Reason.OraclePaused, address(tokens[0]));
        tokens[0].setPause(false);
        tokens[0].setPauseResponse(true, 0);
        _status(BaskVault.Reason.OraclePaused, address(tokens[0]));
        tokens[0].setPauseResponse(false, 2);
        _status(BaskVault.Reason.OraclePaused, address(tokens[0]));
        tokens[0].setPauseResponse(false, 0);
        _status(BaskVault.Reason.OK, address(0));
        MockToken optional = new MockToken(18);
        optional.setPauseResponse(true, 0);
        MockFeed feed = new MockFeed(8, 1e8);
        BaskVault.ProposalData memory d = _data(BaskVault.Action.List, address(optional));
        d.target = address(feed);
        _run(d);
        assertFalse(vault.asset(address(optional)).hasPause);
    }

    function testPoolDeviationAndQuoteFeedCannotFallBack() public {
        pools[0].set(400, 1e12, 1800);
        _status(BaskVault.Reason.PoolDeviation, address(tokens[0]));
        pools[0].set(0, 1e12, 1800);
        quoteFeed.set(0, vm.getBlockTimestamp());
        _status(BaskVault.Reason.QuoteFeed, address(tokens[0]));
        quoteFeed.set(1e8, vm.getBlockTimestamp() - 80 hours - 1);
        _status(BaskVault.Reason.QuoteFeed, address(tokens[0]));
        quoteFeed.set(1e8, vm.getBlockTimestamp());
        pools[0].set(200, 1e12, 1800);
        _status(BaskVault.Reason.OK, address(0));
        (BaskVault.Reason reason,,, uint256 poolPrice) = vault.assetPrice(address(tokens[0]));
        assertEq(uint256(reason), uint256(BaskVault.Reason.OK));
        assertGt(poolPrice, 1e18);
        assertLt(poolPrice, 1.03e18);
    }

    function testPoolLiquidityAndMalformedObserveFallBack() public {
        pools[0].set(400, 1, 1800);
        _status(BaskVault.Reason.OK, address(0));
        feeds[0].set(1e8, vm.getBlockTimestamp() - 27 hours);
        _status(BaskVault.Reason.NoPoolAge, address(tokens[0]));
        _refresh();
        for (uint8 i = 1; i <= 4; ++i) {
            pools[0].setMode(i);
            _status(BaskVault.Reason.OK, address(0));
        }
    }

    function testEveryManagedAssetValidatedAndUnmanagedStaleAllowed() public {
        feeds[1].setMode(1);
        _deposit(100e18);
        feeds[1].setMode(0);
        vm.prank(alice);
        vault.deposit(_one(address(tokens[1])), _amount(100e18), alice, 0, vm.getBlockTimestamp());
        feeds[1].setMode(2);
        _status(BaskVault.Reason.Feed, address(tokens[1]));
    }

    function testFreshnessCountAndBoundary() public {
        _setting(BaskVault.Setting.FreshCount, 2);
        feeds[1].set(1e8, vm.getBlockTimestamp() - 5 hours);
        feeds[2].set(1e8, vm.getBlockTimestamp() - 5 hours);
        _status(BaskVault.Reason.Freshness, address(0));
        feeds[1].set(1e8, vm.getBlockTimestamp() - 4 hours);
        _status(BaskVault.Reason.OK, address(0));
        feeds[1].set(1e8, vm.getBlockTimestamp() - 4 hours - 1);
        _status(BaskVault.Reason.Freshness, address(0));
    }

    function testHoursWeekdaysAndExactEdges() public {
        _setting(BaskVault.Setting.HoursTo, 17 hours);
        _setting(BaskVault.Setting.HoursFrom, 9 hours);
        uint256 monday = 25 days; // 1970-01-26 UTC.
        vm.warp(monday + 9 hours);
        _refresh();
        _status(BaskVault.Reason.OK, address(0));
        vm.warp(monday + 9 hours - 1);
        _refresh();
        _status(BaskVault.Reason.Hours, address(0));
        vm.warp(monday + 17 hours);
        _refresh();
        _status(BaskVault.Reason.Hours, address(0));
        vm.warp(monday + 4 days + 16 hours);
        _refresh();
        _status(BaskVault.Reason.OK, address(0));
        vm.warp(monday + 5 days + 10 hours);
        _refresh();
        _status(BaskVault.Reason.Hours, address(0));
        vm.warp(monday + 6 days + 10 hours);
        _refresh();
        _status(BaskVault.Reason.Hours, address(0));
    }

    function testMixedQuoteDecimalsAndReversePoolDirection() public {
        MockToken q6 = new MockToken(6);
        MockPool p = new MockPool(address(tokens[0]), address(q6));
        p.set(-276324, 1e12, 1800); // raw quote/base ratio ~1e-12
        BaskVault.ProposalData memory d = _data(BaskVault.Action.Pool, address(tokens[0]));
        d.pool = address(p);
        d.quoteFeed = address(quoteFeed);
        d.value = 100;
        _run(d);
        (,,, uint256 usd) = vault.assetPrice(address(tokens[0]));
        assertApproxEqRel(usd, 1e18, 0.001e18);
        _status(BaskVault.Reason.OK, address(0));
        MockPool reverse = new MockPool(address(q6), address(tokens[0]));
        reverse.set(276324, 1e12, 1800);
        d.pool = address(reverse);
        _run(d);
        (,,, uint256 reverseUSD) = vault.assetPrice(address(tokens[0]));
        assertApproxEqAbs(usd, reverseUSD, 1e6);
    }

    function testAllAssetsViewContainsBalancesAndFaults() public {
        _deposit(100e18);
        tokens[0].confiscate(address(vault), 5e18);
        BaskVault.AssetView[] memory info = vault.allAssets();
        assertEq(info.length, 3);
        assertEq(info[0].token, address(tokens[0]));
        assertTrue(info[0].short);
        assertEq(info[0].managed, 100e18);
        assertEq(info[0].answer, 1e8);
        assertEq(info[0].poolPrice, 1e18);
    }
}

contract OracleMathTest is BaseTest {
    function testNegativeTickRoundsDownAndWrapsAccumulators() public {
        uint160 delta = uint160((uint256(1800) << 128) / 1e12);
        pools[0].setRaw(0, -1, 0, delta);
        (bool ok, int24 tick, uint128 liq) = PoolOracle.consult(address(pools[0]), 1800, 150_000);
        assertTrue(ok);
        assertEq(tick, -1);
        assertApproxEqAbs(liq, 1e12, 1);
        int56 t0 = type(int56).max - 100;
        int56 t1;
        uint160 l0 = type(uint160).max - 100;
        uint160 l1;
        unchecked {
            t1 = t0 + 1800;
            l1 = l0 + delta;
        }
        pools[0].setRaw(t0, t1, l0, l1);
        (ok, tick, liq) = PoolOracle.consult(address(pools[0]), 1800, 150_000);
        assertTrue(ok);
        assertEq(tick, 1);
        assertApproxEqAbs(liq, 1e12, 1);
    }

    function testFullPrecisionMultiplicationAvoidsIntermediateOverflow() public pure {
        assertEq(FullMath.mulDiv(type(uint256).max, 1e18, type(uint256).max), 1e18);
        assertEq(FullMath.mulDiv(2 ** 200, 2 ** 100, 2 ** 100), 2 ** 200);
    }

    function testFuzzQuoteReciprocal(int24 tickSeed) public pure {
        int24 tick = int24(bound(int256(tickSeed), -100_000, 100_000));
        uint256 forward = PoolOracle.quote(tick, 1e18, true);
        uint256 reverse = PoolOracle.quote(tick, 1e18, false);
        assertApproxEqRel(FullMath.mulDiv(forward, reverse, 1e18), 1e18, 0.000000001e18);
    }
}
