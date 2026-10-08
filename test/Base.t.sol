// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {BaskVault} from "../src/BaskVault.sol";
import {MockToken, MockFeed, MockPool} from "./mocks/Mocks.sol";

abstract contract BaseTest is Test {
    address internal constant OWNER = 0x30B57ECf51D19ABcED7F6f70974e6fBb6f3b9Da3;
    address internal constant GUARDIAN = 0x5ed39AF86f2C00ad99913B5d727bD68f2A904B68;
    address internal alice;
    address internal bob;
    address internal recipient;
    BaskVault internal vault;
    MockToken[3] internal tokens;
    MockFeed[3] internal feeds;
    MockPool[3] internal pools;
    MockToken internal quote;
    MockFeed internal quoteFeed;

    function setUp() public virtual {
        vm.warp(10 days);
        vm.chainId(4663);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        recipient = makeAddr("feeRecipient");
        vault = new BaskVault(OWNER, GUARDIAN);
        quote = new MockToken(18);
        quoteFeed = new MockFeed(8, 1e8);
        for (uint256 i; i < 3; ++i) {
            tokens[i] = new MockToken(18);
            feeds[i] = new MockFeed(8, 1e8);
            pools[i] = new MockPool(address(tokens[i]), address(quote));
            pools[i].set(0, 1e12, 1800);
            vm.prank(OWNER);
            vault.genesisList(address(tokens[i]), address(feeds[i]), address(pools[i]), address(quoteFeed), 100);
            tokens[i].mint(alice, 1_000_000e18);
            vm.prank(alice);
            tokens[i].approve(address(vault), type(uint256).max);
        }
        vm.prank(OWNER);
        vault.finalizeGenesis();
    }

    function _refresh() internal {
        for (uint256 i; i < 3; ++i) {
            feeds[i].set(feeds[i].answer(), vm.getBlockTimestamp());
        }
        quoteFeed.set(1e8, vm.getBlockTimestamp());
    }

    function _one(address token) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = token;
    }

    function _amount(uint256 amount) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = amount;
    }

    function _deposit(uint256 amount) internal returns (uint256) {
        vm.prank(alice);
        return vault.deposit(_one(address(tokens[0])), _amount(amount), alice, 0, vm.getBlockTimestamp());
    }

    function _depositAll(uint256 amount) internal returns (uint256) {
        address[] memory ts = new address[](3);
        uint256[] memory amts = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            ts[i] = address(tokens[i]);
            amts[i] = amount;
        }
        vm.prank(alice);
        return vault.deposit(ts, amts, alice, 0, vm.getBlockTimestamp());
    }

    function _redeem(uint256 amount) internal returns (uint256[] memory) {
        vm.prank(alice);
        return vault.redeem(amount, alice, new uint256[](0), vm.getBlockTimestamp());
    }

    function _data(BaskVault.Action action, address token) internal pure returns (BaskVault.ProposalData memory d) {
        d.action = action;
        d.token = token;
    }

    function _propose(BaskVault.ProposalData memory d) internal returns (uint256 id) {
        vm.prank(OWNER);
        return vault.propose(d);
    }

    function _execute(uint256 id) internal {
        vm.prank(OWNER);
        vault.executeProposal(id);
    }

    function _run(BaskVault.ProposalData memory d) internal returns (uint256 id) {
        id = _propose(d);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        _refresh();
        _execute(id);
    }

    function _setting(BaskVault.Setting key, uint256 value) internal {
        BaskVault.ProposalData memory d;
        d.action = BaskVault.Action.SettingChange;
        d.setting = key;
        d.value = value;
        _run(d);
    }

    function _feeOn() internal {
        BaskVault.ProposalData memory d;
        d.action = BaskVault.Action.FeeRecipient;
        d.target = recipient;
        _run(d);
    }

    function _status(BaskVault.Reason expected, address fault) internal view {
        (BaskVault.Reason reason, address actual) = vault.depositStatus(_one(address(tokens[0])));
        assertEq(uint256(reason), uint256(expected));
        assertEq(actual, fault);
    }
}
