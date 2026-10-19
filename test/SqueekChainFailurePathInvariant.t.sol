// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SqueekChain} from "../src/SqueekChain.sol";

/// @dev Deploys the token and performs the launch distribution in one call, as a factory would.
contract LaunchDeployer {
    SqueekChain public immutable token;

    constructor(address distributor, address pool, address requester, uint256 poolBps) {
        token = new SqueekChain();
        uint256 supply = token.totalSupply();
        uint256 swarm = supply / 10;
        uint256 seeded = supply * poolBps / 10_000;
        require(token.transfer(distributor, swarm), "swarm");
        require(token.transfer(pool, seeded), "seed");
        require(token.transfer(requester, supply - swarm - seeded), "remainder");
    }
}

/// @dev Drives successful and failing calls across the launch roles. Every failing call must revert with
///      the expected error and leave balances and allowances exactly as the model holds them.
contract FailurePathHandler is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    SqueekChain public immutable token;
    address[] private actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    uint256 public ghostMoved;
    uint256 public ghostRejected;
    bool public ghostStateChangedOnRevert;

    constructor(SqueekChain token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
        for (uint256 i; i < actors_.length; ++i) {
            expectedBalance[actors_[i]] = token_.balanceOf(actors_[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        ghostMoved += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) external {
        address owner = _actor(ownerSeed);
        address who = _actor(spenderSeed);
        if (unlimited) amount = type(uint256).max;
        else amount = bound(amount, 0, SUPPLY * 2);
        vm.prank(owner);
        assertTrue(token.approve(who, amount));
        expectedAllowance[owner][who] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address who = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = expectedAllowance[owner][who];
        uint256 limit = expectedBalance[owner] < allowed ? expectedBalance[owner] : allowed;
        amount = bound(amount, 0, limit);
        vm.prank(who);
        assertTrue(token.transferFrom(owner, to, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowed != type(uint256).max) expectedAllowance[owner][who] = allowed - amount;
        ghostMoved += amount;
    }

    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = expectedBalance[from];
        uint256 amount = held + bound(excess, 1, type(uint256).max - held);
        _expectRejected(
            from,
            abi.encodeCall(token.transfer, (to, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount),
            from,
            to,
            from,
            to
        );
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, expectedBalance[from]);
        _expectRejected(
            from,
            abi.encodeCall(token.transfer, (address(0), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)),
            from,
            from,
            from,
            from
        );
    }

    function transferFromOverAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excess)
        external
    {
        address owner = _actor(ownerSeed);
        address who = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = expectedAllowance[owner][who];
        if (allowed == type(uint256).max) return;
        uint256 amount = allowed + bound(excess, 1, type(uint256).max - allowed);
        _expectRejected(
            who,
            abi.encodeCall(token.transferFrom, (owner, to, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, who, allowed, amount),
            owner,
            to,
            owner,
            who
        );
    }

    function transferFromOverBalanceWithinAllowance(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 toSeed,
        uint256 excess
    ) external {
        address owner = _actor(ownerSeed);
        address who = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 held = expectedBalance[owner];
        uint256 allowed = expectedAllowance[owner][who];
        if (allowed <= held) return;
        uint256 amount = held + bound(excess, 1, allowed - held);
        _expectRejected(
            who,
            abi.encodeCall(token.transferFrom, (owner, to, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount),
            owner,
            to,
            owner,
            who
        );
    }

    function strangerTransferFrom(uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        address stranger = makeAddr("stranger");
        amount = bound(amount, 1, SUPPLY);
        _expectRejected(
            stranger,
            abi.encodeCall(token.transferFrom, (owner, to, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount),
            owner,
            to,
            owner,
            stranger
        );
    }

    /// @dev Calls the token as `caller`, requires the exact revert, and checks the touched state is unchanged.
    function _expectRejected(
        address caller,
        bytes memory data,
        bytes memory expectedError,
        address a,
        address b,
        address allowanceOwner,
        address allowanceSpender
    ) private {
        uint256 balanceA = token.balanceOf(a);
        uint256 balanceB = token.balanceOf(b);
        uint256 allowanceBefore = token.allowance(allowanceOwner, allowanceSpender);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(data);
        assertFalse(ok, "invalid call succeeded");
        assertEq(ret, expectedError, "unexpected revert reason");

        if (
            token.balanceOf(a) != balanceA || token.balanceOf(b) != balanceB
                || token.allowance(allowanceOwner, allowanceSpender) != allowanceBefore
                || token.totalSupply() != supplyBefore
        ) ghostStateChangedOnRevert = true;
        ++ghostRejected;
    }
}

contract SqueekChainFailurePathInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    SqueekChain private token;
    FailurePathHandler private handler;
    address private launcher;
    address private distributor;
    address private pool;
    address private requester;
    address private stranger;

    function setUp() public {
        distributor = makeAddr("distributor");
        pool = makeAddr("pool manager");
        requester = makeAddr("requester");
        stranger = makeAddr("stranger");
        LaunchDeployer deployer = new LaunchDeployer(distributor, pool, requester, 6_000);
        launcher = address(deployer);
        token = deployer.token();

        address[] memory actors = new address[](6);
        actors[0] = distributor;
        actors[1] = pool;
        actors[2] = requester;
        actors[3] = makeAddr("claimant");
        actors[4] = makeAddr("trader");
        actors[5] = launcher;
        handler = new FailurePathHandler(token, actors);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = FailurePathHandler.transfer.selector;
        selectors[1] = FailurePathHandler.approve.selector;
        selectors[2] = FailurePathHandler.transferFrom.selector;
        selectors[3] = FailurePathHandler.transferOverBalance.selector;
        selectors[4] = FailurePathHandler.transferToZero.selector;
        selectors[5] = FailurePathHandler.transferFromOverAllowance.selector;
        selectors[6] = FailurePathHandler.transferFromOverBalanceWithinAllowance.selector;
        selectors[7] = FailurePathHandler.strangerTransferFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function test_LaunchDistributionInOneCallIsExact() public view {
        assertEq(token.balanceOf(distributor), SUPPLY / 10);
        assertEq(token.balanceOf(pool), SUPPLY * 6_000 / 10_000);
        assertEq(token.balanceOf(requester), SUPPLY - SUPPLY / 10 - SUPPLY * 6_000 / 10_000);
        assertEq(token.balanceOf(launcher), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_FixedSupplyFullyHeldByActors() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actorAt(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor), "balance diverged from model");
            sum += balance;
        }
        assertEq(sum, SUPPLY, "actors no longer hold the whole supply");
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(token.balanceOf(stranger), 0, "a stranger obtained tokens");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_AllowancesMatchModel() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actorAt(i);
                address who = handler.actorAt(j);
                assertEq(token.allowance(owner, who), handler.expectedAllowance(owner, who), "allowance diverged");
            }
            assertEq(token.allowance(handler.actorAt(i), stranger), 0, "stranger gained allowance");
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_RejectedCallsChangeNothing() public view {
        assertFalse(handler.ghostStateChangedOnRevert(), "a reverted call changed state");
    }

    /// @dev Guards against a vacuous campaign: the failure paths must actually have been exercised.
    function afterInvariant() public view {
        assertGt(handler.ghostRejected(), 0, "no failing call was attempted");
    }
}
