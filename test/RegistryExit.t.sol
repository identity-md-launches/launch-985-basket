// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaskVault} from "src/BaskVault.sol";
import {MockToken, MockFeed} from "./mocks/Mocks.sol";

interface RegistryColdVm {
    function cool(address target) external;
}

contract RegistryExitTest is Test {
    address private constant OWNER = 0x30B57ECf51D19ABcED7F6f70974e6fBb6f3b9Da3;
    address private constant GUARDIAN = 0x5ed39AF86f2C00ad99913B5d727bD68f2A904B68;
    BaskVault private vault;
    MockToken[] private tokens;
    MockFeed[] private feeds;

    function setUp() public {
        vm.warp(100 days);
        vm.chainId(4663);
        vault = new BaskVault(OWNER, GUARDIAN);
    }

    function _execute(BaskVault.ProposalData memory data) private {
        vm.prank(OWNER);
        uint256 id = vault.propose(data);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(OWNER);
        vault.executeProposal(id);
    }

    function _setting(BaskVault.Setting key, uint256 value) private {
        BaskVault.ProposalData memory data;
        data.action = BaskVault.Action.SettingChange;
        data.setting = key;
        data.value = value;
        _execute(data);
    }

    function _list(uint256 count) private {
        for (uint256 i; i < count; ++i) {
            MockToken token = new MockToken(18);
            MockFeed feed = new MockFeed(8, 1e8);
            tokens.push(token);
            feeds.push(feed);
            vm.prank(OWNER);
            vault.genesisList(address(token), address(feed), address(0), address(0), 0);
        }
        vm.prank(OWNER);
        vault.finalizeGenesis();
    }

    function _fund(uint256[] memory indices) private {
        address[] memory selected = new address[](indices.length);
        uint256[] memory amounts = new uint256[](indices.length);
        for (uint256 i; i < indices.length; ++i) {
            MockToken token = tokens[indices[i]];
            token.mint(address(this), 100e18);
            token.approve(address(vault), 100e18);
            selected[i] = address(token);
            amounts[i] = 100e18;
        }
        vault.deposit(selected, amounts, address(this), 0, vm.getBlockTimestamp());
    }

    function test_RemovalAcrossBitmapWordsLossAndResyncPreserveRedeemLegs() public {
        _setting(BaskVault.Setting.BalanceGas, 20_000);
        _setting(BaskVault.Setting.MaxAssets, 257);
        _list(257);
        uint256[] memory funded = new uint256[](3);
        funded[0] = 0;
        funded[1] = 255;
        funded[2] = 256;
        _fund(funded);
        vm.prank(GUARDIAN);
        vault.closeAsset(address(tokens[1]));
        BaskVault.ProposalData memory data;
        data.action = BaskVault.Action.Retire;
        data.token = address(tokens[1]);
        _execute(data);
        vault.removeAsset(address(tokens[1]));
        assertEq(vault.assets(1), address(tokens[256]));
        assertEq(vault.assetCount(), 256);
        uint256[] memory legs = vault.redeem(30e18, address(this), new uint256[](0), vm.getBlockTimestamp());
        assertEq(legs.length, 256);
        for (uint256 i; i < legs.length; ++i) {
            assertEq(legs[i], i == 0 || i == 1 || i == 255 ? 10e18 : 0);
        }
        assertEq(tokens[256].balanceOf(address(this)), 10e18);

        // Clear the moved bit through a real loss; then re-enable it through resync.
        tokens[256].confiscate(address(vault), 90e18);
        vault.flagDeficit(address(tokens[256]));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.recognizeLoss(address(tokens[256]));
        legs = vault.redeem(27e18, address(this), new uint256[](0), vm.getBlockTimestamp());
        assertEq(legs[0], 9e18);
        assertEq(legs[255], 9e18);
        assertEq(legs[1], 0);
        tokens[256].mint(address(vault), 20e18);
        data.action = BaskVault.Action.Resync;
        data.token = address(tokens[256]);
        _execute(data);
        legs = vault.redeem(24.3e18, address(this), new uint256[](0), vm.getBlockTimestamp());
        assertEq(legs[1], 2e18);
        assertEq(vault.managed(address(tokens[256])), 18e18);

        // Relisting reuses the now-empty second word at index 256.
        feeds[1].set(1e8, vm.getBlockTimestamp());
        data.action = BaskVault.Action.List;
        data.token = address(tokens[1]);
        data.target = address(feeds[1]);
        _execute(data);
        assertEq(vault.assets(256), address(tokens[1]));
        for (uint256 i; i < feeds.length; ++i) {
            feeds[i].set(1e8, vm.getBlockTimestamp());
        }
        uint256[] memory relisted = new uint256[](1);
        relisted[0] = 1;
        _fund(relisted);
        legs = vault.redeem(1e18, address(this), new uint256[](0), vm.getBlockTimestamp());
        assertGt(legs[256], 0, "relisted asset disappeared from redemption");
        assertGt(legs[1], 0, "moved asset disappeared from redemption");
        assertEq(vault.totalOwed(address(tokens[1])), 0);
    }

    function test_MaxAssetsWithMissingTokenCodeStillRedeemUnder28MillionAndCanClaimAfterRecovery() public {
        uint256 count = vault.setting(BaskVault.Setting.MaxAssets);
        _list(count);
        uint256[] memory indices = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            indices[i] = i;
        }
        _fund(indices);
        bytes memory runtime = address(tokens[0]).code;
        for (uint256 i; i < count; ++i) {
            vm.etch(address(tokens[i]), hex"");
            RegistryColdVm(address(vm)).cool(address(tokens[i]));
        }
        vm.prank(GUARDIAN);
        vault.setDepositsPaused(true);
        uint256 shares = vault.balanceOf(address(this));
        bytes memory input =
            abi.encodeCall(vault.redeem, (shares, address(this), new uint256[](count), vm.getBlockTimestamp()));
        RegistryColdVm(address(vm)).cool(address(vault));
        uint256 beforeGas = gasleft();
        (bool success, bytes memory output) = address(vault).call{gas: 27_925_000}(input);
        uint256 used = beforeGas - gasleft() + 21_000;
        for (uint256 i; i < input.length; ++i) {
            used += input[i] == 0 ? 4 : 16;
        }
        assertTrue(success, "missing Stock Token code blocked basket redemption");
        assertLt(used, 28_000_000);
        emit log_named_uint("250 upgraded assets: cold redemption gas including calldata", used);
        uint256[] memory legs = abi.decode(output, (uint256[]));
        assertEq(legs.length, count);
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.totalSupply(), 1e15);
        for (uint256 i; i < count; ++i) {
            assertGt(legs[i], 0);
            assertEq(vault.owed(address(this), address(tokens[i])), legs[i]);
            assertEq(vault.totalOwed(address(tokens[i])), legs[i]);
            assertEq(vault.managed(address(tokens[i])) + legs[i], 100e18);
        }
        // A later token recovery makes the deferred claim usable despite the vault pause.
        vm.etch(address(tokens[0]), runtime);
        address[] memory claimTokens = new address[](1);
        claimTokens[0] = address(tokens[0]);
        vault.claim(claimTokens, address(this));
        assertEq(tokens[0].balanceOf(address(this)), legs[0]);
        assertEq(vault.owed(address(this), address(tokens[0])), 0);
        assertEq(vault.totalOwed(address(tokens[0])), 0);
    }
}
