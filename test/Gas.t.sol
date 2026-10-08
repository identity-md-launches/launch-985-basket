// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {BaskVault} from "../src/BaskVault.sol";
import {MockToken, MockFeed} from "./mocks/Mocks.sol";

interface VmCold {
    function cool(address target) external;
}

contract GasTest is Test {
    address internal constant OWNER = 0x30B57ECf51D19ABcED7F6f70974e6fBb6f3b9Da3;
    address internal constant GUARDIAN = 0x5ed39AF86f2C00ad99913B5d727bD68f2A904B68;
    BaskVault internal vault;
    address[] internal tokens;

    function setUp() public {
        vm.warp(10 days);
        vault = new BaskVault(OWNER, GUARDIAN);
    }

    function _setting(BaskVault.Setting key, uint256 value) internal {
        BaskVault.ProposalData memory d;
        d.action = BaskVault.Action.SettingChange;
        d.setting = key;
        d.value = value;
        vm.prank(OWNER);
        uint256 id = vault.propose(d);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(OWNER);
        vault.executeProposal(id);
    }

    function _setup(uint256 count, uint256 funded) internal {
        address[] memory selected = new address[](funded);
        uint256[] memory amounts = new uint256[](funded);
        for (uint256 i; i < count; ++i) {
            MockToken token = new MockToken(18);
            MockFeed feed = new MockFeed(8, 1e8);
            tokens.push(address(token));
            vm.prank(OWNER);
            vault.genesisList(address(token), address(feed), address(0), address(0), 0);
            if (i < funded) {
                token.mint(address(this), 1e18);
                token.approve(address(vault), 1e18);
                selected[i] = address(token);
                amounts[i] = 1e18;
            }
        }
        vm.prank(OWNER);
        vault.finalizeGenesis();
        vault.deposit(selected, amounts, address(this), 0, vm.getBlockTimestamp());
    }

    function _inflateSupply(uint256 funded) internal {
        address[] memory selected = new address[](funded);
        uint256[] memory amounts = new uint256[](funded);
        // Three legitimate loss/deposit cycles force the 512-bit redemption branch.
        for (uint256 round; round < 3; ++round) {
            for (uint256 i; i < funded; ++i) {
                MockToken token = MockToken(tokens[i]);
                token.confiscate(address(vault), token.balanceOf(address(vault)) - 1);
                vault.flagDeficit(tokens[i]);
            }
            vm.warp(vm.getBlockTimestamp() + 7 days);
            for (uint256 i; i < funded; ++i) {
                vault.recognizeLoss(tokens[i]);
                MockFeed(vault.asset(tokens[i]).feed).set(1e8, vm.getBlockTimestamp());
                MockToken(tokens[i]).mint(address(this), 1e18);
                MockToken(tokens[i]).approve(address(vault), 1e18);
                selected[i] = tokens[i];
                amounts[i] = 1e18;
            }
            vault.deposit(selected, amounts, address(this), 0, vm.getBlockTimestamp());
        }
        assertGt(vault.totalSupply(), type(uint256).max / 1e18);
    }

    function _attack(bool balanceBurn, bool transferBurn, uint256 funded) internal {
        for (uint256 i; i < tokens.length; ++i) {
            if (i < funded) {
                if (balanceBurn) {
                    MockToken(tokens[i]).setReadMode(MockToken.ReadMode.BurnGas);
                } else if (transferBurn) {
                    MockToken(tokens[i]).setReadMode(MockToken.ReadMode.SlowRead);
                    MockToken(tokens[i]).setMode(MockToken.TransferMode.BurnGas);
                } else {
                    MockToken(tokens[i]).setPause(true);
                }
            }
            VmCold(address(vm)).cool(tokens[i]);
        }
        uint256 shares = vault.balanceOf(address(this));
        bytes memory callData =
            abi.encodeCall(vault.redeem, (shares, address(this), new uint256[](tokens.length), vm.getBlockTimestamp()));
        VmCold(address(vm)).cool(address(vault));
        uint256 start = gasleft();
        (bool ok,) = address(vault).call{gas: 27_925_000}(callData);
        uint256 used = start - gasleft();
        // Include transaction intrinsic calldata gas, in addition to the measured cold call.
        used += 21_000;
        for (uint256 i; i < callData.length; ++i) {
            used += callData[i] == 0 ? 4 : 16;
        }
        emit log_named_uint("redemption gas (cold state, before refunds)", used);
        assertTrue(ok, "redeem exceeded 28M or a hostile token reverted the basket");
        assertLt(used, 28_000_000);
        if (balanceBurn || transferBurn) assertGt(used, 20_000_000, "hostile calls must consume their gas budgets");
        assertGt(vault.owed(address(this), tokens[0]), 0);
    }

    function testGas250AllBalancesBurnStipend() public {
        _setup(250, 250);
        _attack(true, false, 250);
    }

    function testGas250Paused() public {
        _setup(250, 250);
        _attack(false, false, 250);
    }

    function testGas254AtDefaultBalanceGasBound() public {
        _setting(BaskVault.Setting.MaxAssets, 254);
        _setup(254, 254);
        _attack(true, false, 254);
    }

    function testGas350AtMinimumBalanceGas() public {
        _setting(BaskVault.Setting.BalanceGas, 20_000);
        _setting(BaskVault.Setting.MaxAssets, 350);
        _setup(350, 350);
        _attack(true, false, 350);
    }

    function testGasMaximumDirectPaymentsBurnEntireBudget() public {
        _setting(BaskVault.Setting.DirectLimit, 77);
        _setup(250, 77);
        _attack(false, true, 77);
    }

    function testGasSparse350AssetsMaximumPayBudget() public {
        _setting(BaskVault.Setting.BalanceGas, 20_000);
        _setting(BaskVault.Setting.MaxAssets, 350);
        _setting(BaskVault.Setting.PayGas, 500_000);
        _setting(BaskVault.Setting.DirectLimit, 48);
        _setup(350, 48);
        _inflateSupply(48);
        BaskVault.ProposalData memory d;
        d.action = BaskVault.Action.FeeRecipient;
        d.target = makeAddr("sparse-fee-recipient");
        vm.prank(OWNER);
        uint256 id = vault.propose(d);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(OWNER);
        vault.executeProposal(id);
        _attack(false, true, 48);
    }

    function testGasMaximumBalanceBudgetWithFees() public {
        _setting(BaskVault.Setting.MaxAssets, 50);
        _setting(BaskVault.Setting.BalanceGas, 500_000);
        _setup(50, 50);
        _inflateSupply(50);
        BaskVault.ProposalData memory d;
        d.action = BaskVault.Action.FeeRecipient;
        d.target = makeAddr("gas-fee-recipient");
        vm.prank(OWNER);
        uint256 id = vault.propose(d);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(OWNER);
        vault.executeProposal(id);
        _attack(true, false, 50);
    }
}
