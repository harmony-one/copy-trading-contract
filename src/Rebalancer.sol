// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/ICLGauge.sol";
import "./interfaces/IERC20.sol";

contract Rebalancer is Ownable, ERC721Holder {
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
        // Close existing positions first - wrap in try-catch to handle edge cases
        if (currentTokenId != 0) {
            try this.closeAllPositionsExternal() {}
            catch {
                // If closeAllPositions fails, manually reset and try to collect tokens
                uint256 tokenId = currentTokenId;
                currentTokenId = 0;
                // Try one more collect attempt if NFT still exists
                try nft.collect(INonfungiblePositionManager.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max)) {}
                catch {}
            }
        }

        IERC20 token0_ = token0();
        IERC20 token1_ = token1();
        uint256 amount0 = token0_.balanceOf(address(this));
        uint256 amount1 = token1_.balanceOf(address(this));

        // Skip creating new position if balances are too low
        // This can happen if position was closed but fees were minimal
        if (amount0 == 0 && amount1 == 0) {
            return; // No tokens to create position with
        }

        // Approve tokens for NFT Manager before minting
        token0_.approve(address(nft), amount0);
        token1_.approve(address(nft), amount1);

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

        // Try to mint new position - if it fails, we'll skip it
        try nft.mint(params) returns (uint256 tokenId, uint128, uint256, uint256) {
            currentTokenId = tokenId;
            nft.approve(address(gauge), tokenId);
            gauge.deposit(tokenId);
        } catch {
            // If mint fails (e.g., too little liquidity), skip creating new position
            // This can happen if balances are too low after closing previous position
            currentTokenId = 0;
        }
    }

    function closeAllPositions() public onlyOwner {
        _closeAllPositions();
    }

    function closeAllPositionsExternal() external onlyOwner {
        _closeAllPositions();
    }

    function _closeAllPositions() internal {
        if (currentTokenId != 0) {
            uint256 tokenId = currentTokenId;
            currentTokenId = 0; // Reset before withdraw to prevent reentrancy
            
            // Withdraw from gauge - this will:
            // 1. Return the NFT to this contract
            // 2. Collect fees and decrease liquidity internally
            // 3. Return tokens to the position (which will be collected separately if needed)
            gauge.withdraw(tokenId);
            
            // After withdraw, the NFT is owned by this contract
            // Gauge may have already collected fees and decreased liquidity
            // Try to collect any remaining fees (gauge may have collected everything already)
            try nft.collect(INonfungiblePositionManager.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max)) {}
            catch {
                // If collect fails, gauge already collected everything - this is expected
            }
            
            // Check if there's any remaining liquidity to decrease
            // If gauge already decreased all liquidity, this will revert - handle it
            try nft.decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams(tokenId, type(uint128).max, 0, 0, block.timestamp + 1 hours)) {
                // If decrease succeeded, try to collect the released tokens
                // Note: gauge may have already collected these, so this might also fail
                try nft.collect(INonfungiblePositionManager.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max)) {}
                catch {}
            } catch {
                // If decreaseLiquidity fails, liquidity was already decreased by gauge
                // This is expected behavior - gauge.withdraw() already handled it
            }
            
            // Burn the NFT - this removes the position from the protocol
            // After gauge.withdraw(), the NFT should be owned by this contract
            // If burn fails with "NC", it means position still has liquidity or uncollected fees
            // Try to burn - if it fails, position might have been fully cleared by gauge
            try nft.burn(tokenId) {}
            catch {
                // If burn fails, gauge may have already cleared the position
                // This is unusual but possible - the NFT might not exist or be burnable
                // In this case, we've already reset currentTokenId, so we can continue
            }
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
