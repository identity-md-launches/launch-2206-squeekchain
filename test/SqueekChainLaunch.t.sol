// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqueekChain} from "../src/SqueekChain.sol";

/// @dev Test-only factory for exercising constructor-caller semantics and exact transfers.
contract TokenFactoryProbe {
    function deploy(bytes32 salt) external returns (SqueekChain) {
        return new SqueekChain{salt: salt}();
    }

    function move(SqueekChain token, address recipient, uint256 amount) external returns (bool) {
        return token.transfer(recipient, amount);
    }
}

contract SqueekChainLaunchTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    TokenFactoryProbe private factory;
    SqueekChain private token;
    address private requester;

    function setUp() public {
        requester = makeAddr("requester");
        factory = new TokenFactoryProbe();
        // Make both the external caller and transaction origin different from the factory.
        vm.prank(requester, requester);
        token = factory.deploy(keccak256("SQK test deployment"));
    }

    function test_Create2FactoryReceivesEntireSupply() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(requester), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_LaunchTransferRoutesDeliverExactAmounts() public {
        // Local test identities only; the token needs no configured launch addresses.
        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("pool manager");
        address claimant = makeAddr("claimant");
        address trader = makeAddr("trader");

        uint256 swarm = SUPPLY / 10;
        uint256 pool = SUPPLY * 8 / 10;
        uint256 remainder = SUPPLY - swarm - pool;
        assertTrue(factory.move(token, distributor, swarm));
        assertTrue(factory.move(token, poolManager, pool));
        assertTrue(factory.move(token, requester, remainder));
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(poolManager), pool);
        assertEq(token.balanceOf(requester), remainder);

        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarm));
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.balanceOf(claimant), swarm);

        // Exercise the token legs of a buy and sell. This does not simulate AMM pricing.
        vm.prank(poolManager);
        assertTrue(token.transfer(trader, 100 ether));
        assertEq(token.balanceOf(trader), 100 ether);
        assertEq(token.balanceOf(poolManager), pool - 100 ether);
        vm.prank(trader);
        assertTrue(token.transfer(poolManager, 100 ether));
        assertEq(token.balanceOf(trader), 0);
        assertEq(token.balanceOf(poolManager), pool);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(claimant) + token.balanceOf(poolManager) + token.balanceOf(requester), SUPPLY);
    }
}
