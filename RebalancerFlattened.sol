// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20 ^0.8.28;

// lib/openzeppelin-contracts/contracts/utils/Context.sol

// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}

// src/interfaces/ICLGauge.sol

interface ICLGauge {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
    function deposit(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
}

// src/interfaces/IERC20.sol

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

// src/interfaces/INonfungiblePositionManager.sol

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function mint(MintParams calldata params) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function decreaseLiquidity(DecreaseLiquidityParams calldata params) external returns (uint256 amount0, uint256 amount1);
    function collect(CollectParams calldata params) external returns (uint256 amount0, uint256 amount1);
    function burn(uint256 tokenId) external;
    function approve(address spender, uint256 tokenId) external;
}

// lib/openzeppelin-contracts/contracts/access/Ownable.sol

// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable.sol)

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * The initial owner is set to the address provided by the deployer. This can
 * later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    /**
     * @dev The caller account is not authorized to perform an operation.
     */
    error OwnableUnauthorizedAccount(address account);

    /**
     * @dev The owner is not a valid owner account. (eg. `address(0)`)
     */
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the initial owner.
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(initialOwner);
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        if (owner() != _msgSender()) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby disabling any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

// src/Rebalancer.sol

contract Rebalancer is Ownable {
    INonfungiblePositionManager public nft;
    ICLGauge public gauge;
    uint256 public currentTokenId;

    constructor(address _nft, address _gauge, address _owner) Ownable(_owner) {
        nft = INonfungiblePositionManager(_nft);
        gauge = ICLGauge(_gauge);
    }

    function token0() public view returns (IERC20) {
        return IERC20(gauge.token0());
    }

    function token1() public view returns (IERC20) {
        return IERC20(gauge.token1());
    }

    function tickSpacing() public view returns (int24) {
        return gauge.tickSpacing();
    }

    function deposit(uint256 amount0, uint256 amount1) external onlyOwner {
        IERC20 token0_ = token0();
        IERC20 token1_ = token1();
        require(token0_.transferFrom(msg.sender, address(this), amount0), "transfer token0 failed");
        require(token1_.transferFrom(msg.sender, address(this), amount1), "transfer token1 failed");
    }

    function rebalance(int24 tickLower, int24 tickUpper) external onlyOwner {
        closeAllPositions();

        IERC20 token0_ = token0();
        IERC20 token1_ = token1();
        uint256 amount0 = token0_.balanceOf(address(this));
        uint256 amount1 = token1_.balanceOf(address(this));

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(token0_),
            token1: address(token1_),
            tickSpacing: tickSpacing(),
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 1 hours,
            sqrtPriceX96: 0
        });

        (uint256 tokenId, , , ) = nft.mint(params);
        currentTokenId = tokenId;
        nft.approve(address(gauge), tokenId);
        gauge.deposit(tokenId);
    }

    function closeAllPositions() public onlyOwner {
        if (currentTokenId != 0) {
            gauge.withdraw(currentTokenId);
            nft.collect(INonfungiblePositionManager.CollectParams(currentTokenId, address(this), type(uint128).max, type(uint128).max));
            nft.decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams(currentTokenId, type(uint128).max, 0, 0, block.timestamp + 1 hours));
            nft.burn(currentTokenId);
            currentTokenId = 0;
        }
    }

    function withdrawAll() external onlyOwner {
        IERC20 token0_ = token0();
        IERC20 token1_ = token1();
        require(token0_.transfer(owner(), token0_.balanceOf(address(this))), "withdraw token0 failed");
        require(token1_.transfer(owner(), token1_.balanceOf(address(this))), "withdraw token1 failed");
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }
}

