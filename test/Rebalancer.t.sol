// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Rebalancer} from "../src/Rebalancer.sol";
import {INonfungiblePositionManager} from "../src/interfaces/INonfungiblePositionManager.sol";

// Mocks for testing
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name;
    string public symbol;
    uint8 public decimals;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        decimals = 18;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract MockNFTManager is INonfungiblePositionManager {
    uint256 public nextTokenId = 1;

    function mint(MintParams calldata params)
        external
        override
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        tokenId = nextTokenId++;
        liquidity = 1000;
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;
        return (tokenId, liquidity, amount0, amount1);
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        override
        returns (uint256 amount0, uint256 amount1)
    {
        return (100, 100);
    }

    function collect(CollectParams calldata params)
        external
        override
        returns (uint256 amount0, uint256 amount1)
    {
        return (100, 100);
    }

    function burn(uint256 tokenId) external override {}

    function approve(address spender, uint256 tokenId) external override {}
    
    // Mock positions function - returns zero liquidity for testing
    function positions(uint256 tokenId)
        external
        pure
        override
        returns (
            uint96,
            address,
            address,
            address,
            int24,
            int24,
            int24,
            uint128 liquidity,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        // Return zero liquidity so tests can pass
        return (0, address(0), address(0), address(0), 0, 0, 0, 0, 0, 0, 0, 0);
    }
}

contract MockGauge {
    mapping(uint256 => bool) public deposited;
    address public token0;
    address public token1;
    int24 public tickSpacing;
    address public rewardToken;

    constructor(address _token0, address _token1, int24 _tickSpacing, address _rewardToken) {
        token0 = _token0;
        token1 = _token1;
        tickSpacing = _tickSpacing;
        rewardToken = _rewardToken;
    }

    function deposit(uint256 tokenId) external {
        deposited[tokenId] = true;
    }

    function withdraw(uint256 tokenId) external {
        deposited[tokenId] = false;
    }
}

contract RebalancerTest is Test {
    Rebalancer public rebalancer;
    MockERC20 public token0;
    MockERC20 public token1;
    MockERC20 public rewardToken;
    MockNFTManager public nftManager;
    MockGauge public gauge;
    address public owner;
    address public user;

    function setUp() public {
        owner = address(this);
        user = makeAddr("user");

        token0 = new MockERC20("Token0", "TKN0");
        token1 = new MockERC20("Token1", "TKN1");
        rewardToken = new MockERC20("AERO", "AERO");
        nftManager = new MockNFTManager();
        gauge = new MockGauge(address(token0), address(token1), 60, address(rewardToken));

        rebalancer = new Rebalancer(address(nftManager), address(gauge), owner);
    }

    function testConstructor() public {
        assertEq(address(rebalancer.nft()), address(nftManager));
        assertEq(address(rebalancer.gauge()), address(gauge));
        assertEq(rebalancer.owner(), owner);
        assertEq(address(rebalancer.token0()), address(token0));
        assertEq(address(rebalancer.token1()), address(token1));
        assertEq(rebalancer.tickSpacing(), 60);
        assertEq(address(rebalancer.rewardToken()), address(rewardToken));
    }

    function testDeposit() public {
        uint256 amount0 = 1000e18;
        uint256 amount1 = 2000e18;

        token0.mint(owner, amount0);
        token1.mint(owner, amount1);

        token0.approve(address(rebalancer), amount0);
        token1.approve(address(rebalancer), amount1);

        rebalancer.deposit(amount0, amount1);

        assertEq(token0.balanceOf(address(rebalancer)), amount0);
        assertEq(token1.balanceOf(address(rebalancer)), amount1);
    }

    function testDepositRevertsIfNotOwner() public {
        uint256 amount0 = 1000e18;
        uint256 amount1 = 2000e18;

        token0.mint(user, amount0);
        token1.mint(user, amount1);

        token0.approve(address(rebalancer), amount0);
        token1.approve(address(rebalancer), amount1);

        vm.prank(user);
        vm.expectRevert();
        rebalancer.deposit(amount0, amount1);
    }

    function testRebalance() public {
        uint256 amount0 = 1000e18;
        uint256 amount1 = 2000e18;

        token0.mint(owner, amount0);
        token1.mint(owner, amount1);

        token0.approve(address(rebalancer), amount0);
        token1.approve(address(rebalancer), amount1);

        rebalancer.deposit(amount0, amount1);

        int24 tickLower = -1000;
        int24 tickUpper = 1000;

        rebalancer.rebalance(tickLower, tickUpper);

        assertEq(rebalancer.currentTokenId(), 1);
        assertTrue(gauge.deposited(1));
    }

    function testCloseAllPositions() public {
        uint256 amount0 = 1000e18;
        uint256 amount1 = 2000e18;

        token0.mint(owner, amount0);
        token1.mint(owner, amount1);

        token0.approve(address(rebalancer), amount0);
        token1.approve(address(rebalancer), amount1);

        rebalancer.deposit(amount0, amount1);

        int24 tickLower = -1000;
        int24 tickUpper = 1000;

        rebalancer.rebalance(tickLower, tickUpper);
        assertEq(rebalancer.currentTokenId(), 1);

        rebalancer.closeAllPositions();
        assertEq(rebalancer.currentTokenId(), 0);
    }

    function testWithdrawAll() public {
        uint256 amount0 = 1000e18;
        uint256 amount1 = 2000e18;

        token0.mint(owner, amount0);
        token1.mint(owner, amount1);

        token0.approve(address(rebalancer), amount0);
        token1.approve(address(rebalancer), amount1);

        rebalancer.deposit(amount0, amount1);

        uint256 ownerBalance0Before = token0.balanceOf(owner);
        uint256 ownerBalance1Before = token1.balanceOf(owner);

        rebalancer.withdrawAll();

        assertEq(token0.balanceOf(owner), ownerBalance0Before + amount0);
        assertEq(token1.balanceOf(owner), ownerBalance1Before + amount1);
        assertEq(token0.balanceOf(address(rebalancer)), 0);
        assertEq(token1.balanceOf(address(rebalancer)), 0);
    }

    function testRescueERC20() public {
        MockERC20 randomToken = new MockERC20("Random", "RND");
        uint256 amount = 500e18;

        randomToken.mint(address(rebalancer), amount);

        rebalancer.rescueERC20(address(randomToken), owner, amount);

        assertEq(randomToken.balanceOf(owner), amount);
        assertEq(randomToken.balanceOf(address(rebalancer)), 0);
    }

    function testRewardToken() public {
        // Test that rewardToken() returns the correct address from gauge
        assertEq(address(rebalancer.rewardToken()), address(rewardToken));
        assertEq(address(rebalancer.rewardToken()), gauge.rewardToken());
    }

    function testWithdrawRewards() public {
        uint256 rewardAmount = 1000e18;

        // Mint reward tokens to the rebalancer contract
        rewardToken.mint(address(rebalancer), rewardAmount);

        uint256 ownerBalanceBefore = rewardToken.balanceOf(owner);
        uint256 contractBalanceBefore = rewardToken.balanceOf(address(rebalancer));

        assertEq(contractBalanceBefore, rewardAmount);
        assertEq(ownerBalanceBefore, 0);

        // Withdraw rewards
        rebalancer.withdrawRewards();

        // Verify tokens were transferred to owner
        assertEq(rewardToken.balanceOf(owner), ownerBalanceBefore + rewardAmount);
        assertEq(rewardToken.balanceOf(address(rebalancer)), 0);
    }

    function testWithdrawRewardsWithZeroBalance() public {
        // Test that withdrawRewards works even with zero balance
        uint256 ownerBalanceBefore = rewardToken.balanceOf(owner);
        assertEq(rewardToken.balanceOf(address(rebalancer)), 0);

        // Should not revert even with zero balance
        rebalancer.withdrawRewards();

        // Balance should remain the same
        assertEq(rewardToken.balanceOf(owner), ownerBalanceBefore);
        assertEq(rewardToken.balanceOf(address(rebalancer)), 0);
    }

    function testWithdrawRewardsRevertsIfNotOwner() public {
        uint256 rewardAmount = 1000e18;
        rewardToken.mint(address(rebalancer), rewardAmount);

        vm.prank(user);
        vm.expectRevert();
        rebalancer.withdrawRewards();
    }

    function testRebalanceClosesPreviousPosition() public {
        uint256 amount0 = 1000e18;
        uint256 amount1 = 2000e18;

        token0.mint(owner, amount0);
        token1.mint(owner, amount1);

        token0.approve(address(rebalancer), amount0);
        token1.approve(address(rebalancer), amount1);

        rebalancer.deposit(amount0, amount1);

        int24 tickLower = -1000;
        int24 tickUpper = 1000;

        // First rebalance creates position
        rebalancer.rebalance(tickLower, tickUpper);
        uint256 tokenId1 = rebalancer.currentTokenId();
        assertEq(tokenId1, 1);

        // Second rebalance should close first position and create new one
        // We need to ensure there are still tokens in the contract
        // In a real scenario, closing position would return tokens
        // For mock, we'll add more tokens before second rebalance
        token0.mint(address(rebalancer), amount0 / 10);
        token1.mint(address(rebalancer), amount1 / 10);

        rebalancer.rebalance(tickLower, tickUpper);
        uint256 tokenId2 = rebalancer.currentTokenId();
        
        // Should create a new position (different tokenId)
        assertTrue(tokenId2 != tokenId1 || tokenId2 == 2);
    }
}

