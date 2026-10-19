// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SqueekChain} from "../src/SqueekChain.sol";

/// @dev Edge inputs the main suite does not pin: the zero address as caller, the exact balance
///      boundary on transferFrom, raw ABI return data, and launch splits at arbitrary basis points.
contract SqueekChainEdgeCasesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    SqueekChain private token;
    address private deployer;
    address private alice;
    address private bob;
    address private spender;

    function setUp() public {
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        vm.prank(deployer);
        token = new SqueekChain();
    }

    function test_SupplyIsOneBillionWholeTokensAtDecimals() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** uint256(token.decimals()));
        assertEq(token.totalSupply(), 1e27);
    }

    function test_EachDeploymentMintsOnlyToItsOwnCaller() public {
        vm.prank(alice);
        SqueekChain second = new SqueekChain();
        assertEq(second.balanceOf(alice), SUPPLY);
        assertEq(second.balanceOf(deployer), 0);
        // The first deployment is untouched by the second.
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhenZeroAddressSends() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(alice, 0);
    }

    function test_RevertWhenZeroAddressApproves() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(spender, 1);
    }

    function test_OwnerNeedsAllowanceToUseTransferFromOnItself() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(deployer, alice, 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_TransferFromAtExactBalanceSucceedsAndOneMoreFails() public {
        vm.prank(deployer);
        token.transfer(alice, 5 ether);
        vm.prank(alice);
        token.approve(spender, type(uint256).max - 1);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5 ether, 5 ether + 1)
        );
        vm.prank(spender);
        token.transferFrom(alice, bob, 5 ether + 1);
        assertEq(token.allowance(alice, spender), type(uint256).max - 1, "failed spend kept the allowance");

        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 5 ether));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 5 ether);
        // One below max is a finite allowance and is spent.
        assertEq(token.allowance(alice, spender), type(uint256).max - 1 - 5 ether);
    }

    function test_SpentAllowanceCannotBeReplayed() public {
        vm.prank(deployer);
        token.approve(spender, 3 ether);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(deployer, alice, 2 ether));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 1 ether, 2 ether)
        );
        token.transferFrom(deployer, alice, 2 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 2 ether);
        assertEq(token.allowance(deployer, spender), 1 ether);
    }

    function test_TransferAndApproveReturnExactlyAbiTrue() public {
        vm.prank(deployer);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(token.transfer, (alice, 1)));
        assertTrue(ok);
        assertEq(ret, abi.encode(true));

        vm.prank(alice);
        (ok, ret) = address(token).call(abi.encodeCall(token.approve, (spender, 1)));
        assertTrue(ok);
        assertEq(ret, abi.encode(true));

        vm.prank(spender);
        (ok, ret) = address(token).call(abi.encodeCall(token.transferFrom, (alice, bob, 1)));
        assertTrue(ok);
        assertEq(ret, abi.encode(true));
    }

    function test_TokensSentToTheTokenContractAreCountedButStuck() public {
        vm.prank(deployer);
        token.transfer(address(token), 1 ether);
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ApproveSetsExactValue(address owner, address who, uint256 amount) public {
        owner = address(uint160(bound(uint160(owner), 1, type(uint160).max)));
        who = address(uint160(bound(uint160(who), 1, type(uint160).max)));
        vm.prank(owner);
        assertTrue(token.approve(who, amount));
        assertEq(token.allowance(owner, who), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_RevertWhenTransferFromExceedsBalanceWithinAllowance(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(spender, amount);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount));
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, spender), amount);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ChainedTransfersConserve(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);
        vm.prank(deployer);
        token.transfer(alice, a);
        vm.prank(alice);
        token.transfer(bob, b);
        vm.prank(bob);
        token.transfer(deployer, c);
        assertEq(token.balanceOf(deployer), SUPPLY - a + c);
        assertEq(token.balanceOf(alice), a - b);
        assertEq(token.balanceOf(bob), b - c);
        assertEq(token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Any split of the supply among swarm, pool and remainder arrives whole: no fee or burn.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_LaunchSplitAtAnyBpsArrivesWhole(uint256 poolBps) public {
        poolBps = bound(poolBps, 0, 9_000);
        address distributor = makeAddr("distributor");
        address pool = makeAddr("pool");
        uint256 swarm = SUPPLY * 1_000 / 10_000;
        uint256 seeded = SUPPLY * poolBps / 10_000;
        uint256 remainder = SUPPLY - swarm - seeded;

        vm.startPrank(deployer);
        assertTrue(token.transfer(distributor, swarm));
        assertTrue(token.transfer(pool, seeded));
        assertTrue(token.transfer(alice, remainder));
        vm.stopPrank();

        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(pool), seeded);
        assertEq(token.balanceOf(alice), remainder);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
