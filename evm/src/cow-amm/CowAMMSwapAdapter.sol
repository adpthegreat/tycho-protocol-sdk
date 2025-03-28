// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import {ISwapAdapter} from "src/interfaces/ISwapAdapter.sol";
import {
    IERC20,
    SafeERC20
} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBPool} from "./interfaces/IBPool.sol";

library BMath {
    function bdiv() {

    }

    function bmul() {
        
    }
}
/// @title CowAmmSwapAdapter
/// @dev 

uint256 constant RESERVE_LIMIT_FACTOR = 3;

contract CowAmmSwapAdapter is ISwapAdapter {

    IBPool immutable pool;
    IBCoWHelper immutable helper;

    constructor(address pool_, address helper_) {
        pool = IBPool(pool_);
        helper = IBCoWHelper(helper_);
    }

    function price(
        bytes32 poolId,
        address sellToken,
        address buyToken,
        uint256[] memory specifiedAmounts
    ) external view override returns (Fraction[] memory _prices) {
        prices = new Fraction[](specifiedAmounts.length);
        //we're just using the specified amounts for the length of prices
        for (uint256 i = 0; i < specifiedAmounts.length; i++) {
            prices[i] = pool.calcSpotPrice(
                IERC20(sellToken).balanceOf(address(poolId)),
                pool.getDenormalizedWeight(address(sellToken)), //token in
                IERC20(buyToken).balanceOf(address(poolId)),
                pool.getDenormalizedWeight(address(buyToken)), //token out
                0
            ); 
        }
    }



    function swap(
        bytes32 poolId,
        address sellToken,
        address buyToken,
        OrderSide side,
        uint256 specifiedAmount
    ) external returns (Trade memory trade) {
        require(sellToken != buyToken, "Tokens must be different");
        //make it so that there is an arg configuration that onluy invokes
        //join pool and exit pool, like, based on params 
        if (side == OrderSide.Sell) {
            if (sellToken != address(0) && buyToken != address(0)) {
                // Standard Token Swap
                uint256 amountOut = vault.swap(poolId, sellToken, buyToken, specifiedAmount);
                trade.calculatedAmount = amountOut;
                trade.price = Fraction(amountOut, specifiedAmount); // Example price calculation
            } 

        } else {
            //check if they are LP tokens then call joinpool
        }
        //just use calcingivenout?
        trade.gasUsed = gasBefore - gasLeft();
        trade.price = price(poolId, sellToken, buyToken)
    }
    
    /// @notice Executes a sell order on the contract.
    /// @param sellToken The token being sold.
    /// @param buyToken The token being bought.
    /// @param amount The amount to be traded.
    /// @return calculatedAmount The amount of tokens received.
    function sell(address sellToken, address buyToken, uint256 amount)
        internal
        returns (uint256 calculatedAmount)
    {
        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(sellToken).approve(address(pool), amount);
        calculatedAmount = pool.swapExactAmountIn(
            sellToken,
            amount, 
            buyToken, 
            0, 

        );
    }

    /// @notice Executes a buy order on the contract.
    /// @param sellToken The token being sold.
    /// @param buyToken The token being bought.
    /// @param amountOut The amount of buyToken to receive.
    /// @return calculatedAmount The amount of tokens received.
    function buy(address sellToken, address buyToken, uint256 amountOut)
        internal
        returns (uint256 calculatedAmount)
    {

        IERC20(sellToken).safeTransferFrom(
            msg.sender, address(this), calculatedAmount
        );
        IERC20(sellToken).approve(address(pool), calculatedAmount);
        pool.swapExactAmountOut(
            sellToken,
                    ,
            amountOut, 
            type(uint256).max, 
            msg.sender, 
            0
        );
    }
    

    function getLimits(bytes32 poolId, address sellToken, address buyToken)
        external
        returns (uint256[] memory limits)
    {
        
        //get reserves for buyToken in poolId
        uint256 sellTokenBalance = IERC20(buyToken).balanceOf(address(poolId));
        // uint256 normalizedWeight = pool.getNormalizedWeight(buyToken);
        // uint256 denormalizedWeight = pool.getDenormalizedWeight(buyToken); // do we need these ?

        // get reserves for SellToken in poolId
        uint256 buyTokenBalance = IERC20(sellToken).balanceOf(address(poolId));
        // uint256 normalizedWeight = pool.getNormalizedWeight(sellToken);
        // uint256 denormalizedWeight = pool.getDenormalizedWeight(sellToken);
        //did it based on balancers impl, didn't find any explicit limits for CowAMM 
        limits[0] = sellTokenBalance * RESERVE_LIMIT_FACTOR / 10
        limits[1] = buyTokenBalance * RESERVE_LIMIT_FACTOR / 10
    }

    function getCapabilities(
        bytes32 poolId,
        address sellToken,
        address buyToken
    ) external returns (Capability[] memory capabilities) 
    {
        capabilities = new Capability[](4);
        capabilities[0] = Capability.SellOrder;
        capabilities[1] = Capability.BuyOrder;
        capabilities[2] = Capability.PriceFunction;
        capabilities[3] = Capability.HardLimits;
    }

    function getTokens(bytes32 poolId)
        external
        view
        override
        returns (address[] memory tokens)
    {
        (tokens,,) = helper.tokens(poolId);
    }

    function getPoolIds(uint256 offset, uint256 limit)
        external
        returns (bytes32[] memory ids)
    {
        revert NotImplemented("TemplateSwapAdapter.getPoolIds");
    }

}


//we are interacting with already deployed CowAMM pools on top of balancer directly so we just need to define the interface 
// https://gnosisscan.io/token/0x079d2094e16210c42457438195042898a3cff72d#code

//Since IBCowPool implements IBPool then because IBCowPool is deployed, we can pass it as the CA to the constructor and it will work, we are using the IBPool interface to get access to some methods 
//Then we can pass in BCowHelper contract directly, its deployed

//only need for for loop is if the pool has more than two tokens (as we saw in balancer), bit CowAMM pool only have two tokens 

//we just made the RESERVE_LIMIT_FACTOR to be the same as balancers own 
