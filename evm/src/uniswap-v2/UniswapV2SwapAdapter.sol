// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;
import "forge-std/Test.sol";
import {ISwapAdapter} from "src/interfaces/ISwapAdapter.sol";
import {
    IERC20,
    SafeERC20
} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeMath} from "./SafeMath.sol";
import {Babylonian} from "./Babylonian.sol";

// Uniswap handles arbirary amounts, but we limit the amount to 10x just in case
uint256 constant RESERVE_LIMIT_FACTOR = 10;

contract UniswapV2SwapAdapter is ISwapAdapter {
    using SafeERC20 for IERC20;
    using SafeMath for uint256; 

    IUniswapV2Factory immutable factory;

    constructor(address factory_) {
        factory = IUniswapV2Factory(factory_);
    }

    /// @inheritdoc ISwapAdapter
    function price(
        bytes32 poolId,
        address sellToken,
        address buyToken,
        uint256[] memory specifiedAmounts
    ) external view override returns (Fraction[] memory prices) {
        prices = new Fraction[](specifiedAmounts.length);
        IUniswapV2Pair pair = IUniswapV2Pair(address(bytes20(poolId)));
        uint112 r0;
        uint112 r1;
        if (sellToken < buyToken) {
            (r0, r1,) = pair.getReserves();
        } else {
            (r1, r0,) = pair.getReserves();
        }

        for (uint256 i = 0; i < specifiedAmounts.length; i++) {
            prices[i] = getPriceAt(specifiedAmounts[i], r0, r1);
        }
    }

    /// @notice Calculates pool prices for specified amounts
    /// @param amountIn The amount of the token being sold.
    /// @param reserveIn The reserve of the token being sold.
    /// @param reserveOut The reserve of the token being bought.
    /// @return The price as a fraction corresponding to the provided amount.
    function getPriceAt(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (Fraction memory)
    {
        if (reserveIn == 0 || reserveOut == 0) {
            revert Unavailable("At least one reserve is zero!");
        }
        uint256 amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        uint256 newReserveOut = reserveOut - amountOut;
        uint256 newReserveIn = reserveIn + amountIn;
        return Fraction(newReserveOut * 997, newReserveIn * 1000);
    }

    //FROM: https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2LiquidityMathLibrary.sol#L75
    // computes liquidity value given all the parameters of the pair
    function computeLiquidityValue(
        uint256 reservesA,
        uint256 reservesB,
        uint256 totalSupply,
        uint256 liquidityAmount,
        bool feeOn,
        uint kLast
    ) internal pure returns (uint256 token0Amount, uint256 token1Amount) {
        if (feeOn && kLast > 0) {
            uint rootK = Babylonian.sqrt(reservesA.mul(reservesB));
            uint rootKLast = Babylonian.sqrt(kLast);
            if (rootK > rootKLast) {
                uint numerator1 = totalSupply;
                uint numerator2 = rootK.sub(rootKLast);
                uint denominator = rootK.mul(5).add(rootKLast);
                uint numerator = numerator1.mul(numerator2);
                uint feeLiquidity = numerator / denominator;
                totalSupply = totalSupply.add(feeLiquidity);
            }
        }
        return (reservesA.mul(liquidityAmount) / totalSupply, reservesB.mul(liquidityAmount) / totalSupply); // overflow is not a mixing safemath and / issue dw
    }

    // get all current parameters from the pair and compute value of a liquidity amount
    // **note this is subject to manipulation, e.g. sandwich attacks**. prefer passing a manipulation resistant price to
    // #getLiquidityValueAfterArbitrageToPrice
    function getLiquidityValue(
        bytes32 poolId,
        uint256 liquidityAmount //lpTokenAmountIn
    ) internal view returns (uint256 token0Amount, uint256 token1Amount) {
        IUniswapV2Pair pair = IUniswapV2Pair(address(bytes20(poolId)));
        (uint256 reservesA, uint256 reservesB, ) = pair.getReserves();
        bool feeOn = factory.feeTo() != address(0);
        uint kLast = feeOn ? pair.kLast() : 0;
        uint totalSupply = pair.totalSupply();
        return computeLiquidityValue(reservesA, reservesB, totalSupply, liquidityAmount, feeOn, kLast);
    }

     /// @notice Checks if the specified amount is within the hard limits
    /// @dev If not, reverts
    /// @param limits The limits of the tokens being traded.
    /// @param side The side of the trade.
    /// @param specifiedAmount The amount to be traded.
    function _checkLimits(
        uint256[] memory limits,
        OrderSide side,
        uint256 specifiedAmount
    ) internal pure {
        if (side == OrderSide.Sell && specifiedAmount > limits[0]) {
            require(specifiedAmount < limits[0], "Limit exceeded");
        } else if (side == OrderSide.Buy && specifiedAmount > limits[1]) {
            require(specifiedAmount < limits[1], "Limit exceeded");
        }
    }

    enum SwapType { TokenToToken, RemoveLiquidity, AddLiquidity, Invalid }

    function _getSwapType(bytes32 poolId, address sellToken, address buyToken) private view returns (SwapType) {
        bool sellIsPool = (sellToken == address(bytes20(poolId)));
        bool buyIsPool = (buyToken == address(bytes20(poolId)));

        if (!sellIsPool && !buyIsPool) return SwapType.TokenToToken;
        if (sellIsPool && !buyIsPool) return SwapType.RemoveLiquidity;
        if (!sellIsPool && buyIsPool) return SwapType.AddLiquidity;
        return SwapType.Invalid; // Both are pool tokens
    }

    function _executeTokenSwap(
        bytes32 poolId,
        address sellToken,
        address buyToken,
        OrderSide side,
        uint256 specifiedAmount
    ) private returns (Trade memory trade) {
        if (specifiedAmount == 0) {
            return trade;
        }
        
        IUniswapV2Pair pair = IUniswapV2Pair(address(bytes20(poolId)));
        uint112 r0;
        uint112 r1;
        bool zero2one = sellToken < buyToken;
        if (zero2one) {
            (r0, r1,) = pair.getReserves();
        } else {
            (r1, r0,) = pair.getReserves();
        }
        uint256 gasBefore = gasleft();
        if (side == OrderSide.Sell) {
            trade.calculatedAmount =
                sell(pair, sellToken, zero2one, r0, r1, specifiedAmount);
        } else {
            trade.calculatedAmount =
                buy(pair, sellToken, zero2one, r0, r1, specifiedAmount);
        }
        trade.gasUsed = gasBefore - gasleft();
        if (side == OrderSide.Sell) {
            trade.price = getPriceAt(specifiedAmount, r0, r1);
        } else {
            trade.price = getPriceAt(trade.calculatedAmount, r0, r1);
        }
    }

    function _executeAddLiquidity( //minting tokens or buying lpTokens
        bytes32 poolId,
        address sellToken, //Actual token we want to receive
        address buyToken, //LP token address (LP Tokens we're selling)
        OrderSide side,
        uint256 specifiedAmount // amount of lp tokens we want to "buy"
    ) private returns (Trade memory trade) {
        address swapper = msg.sender;
        if (specifiedAmount == 0) {
            return trade;
        }
        IUniswapV2Pair pair = IUniswapV2Pair(address(bytes20(poolId)));
        address token0 = pair.token0();
        address token1 = pair.token1();
        // Determine which token we need to buy (the other token in the pair)
        address tokenToBuy;
        if (sellToken == token0) {
            tokenToBuy = token1;
        } else if (sellToken == token1) {
            tokenToBuy = token0;
        } else {
            revert("UniswapV2SwapAdapter: sellToken not in pool");
        }
       
        bool zero2one = sellToken < tokenToBuy;

        uint256 gasBefore = gasleft();
        // NOTE: Since we can't specify the amount of tokenA and tokenB that we want, we calculate the proportions needed to add to the pool 
        // Ideally, we want to make sure we deposit the two tokens at exactly the same ratio as what the pair currently has, otherwise 
        //the amount of LP tokens we mint is the worse of the two ratios between what we provide and what the pair balances are. However,
        // the ratio could change between when the liquidity provider attempts to add liquidity and when the transaction is confirmed. 
        //https://github.com/Uniswap/v2-periphery/blob/master/contracts/UniswapV2Router02.sol#L33 
        //https://rareskills.io/post/uniswap-v2-router

        uint256 totalSupply = pair.totalSupply();
        (uint256 requiredToken0, uint256 requiredToken1) = getLiquidityValue(poolId, specifiedAmount); 

        uint112 r0;
        uint112 r1;

        if (zero2one) {
            (r0, r1,) = pair.getReserves();  
        } else {
            (r1, r0,) = pair.getReserves();  
        }

        uint256 requiredSellAmount;
        uint256 requiredBuyAmount;
    
        if (zero2one) {
            //sellToken is token0, buyToken is token1
            requiredSellAmount = requiredToken0;
            requiredBuyAmount = requiredToken1;
        } else {
            //sellToken is Token1, buyToken is token0
            requiredSellAmount = requiredToken1;
            requiredBuyAmount = requiredToken0;
        }

        // Calculate how much buyToken we need to buy, provided we have enough sellToken
        trade.calculatedAmount = buy(pair, sellToken, zero2one, r0, r1, requiredBuyAmount); 
        trade.gasUsed = gasBefore - gasleft();
        trade.price = getPriceAt(trade.calculatedAmount, r0, r1);
        //After swapping to get the buy token to add liquidity, we transfer the required amounts of sellToken and buyToken 
        //(thats the equal proportions of the tokens we send to the pool so we can add liq) 
        IERC20(sellToken).safeTransferFrom(swapper, address(pair), requiredSellAmount);
        IERC20(tokenToBuy).safeTransferFrom(swapper, address(pair), requiredBuyAmount);
        // Mint LP token to the swapper
        pair.mint(swapper);
    }

    function _executeRemoveLiquidity(
        bytes32 poolId,
        address sellToken, //Pool address (LP Tokens we're selling)
        address buyToken,  // Actual token we want to receive
        OrderSide side,
        uint256 specifiedAmount
    ) private returns (Trade memory trade) {
        address swapper = msg.sender;
        if (specifiedAmount == 0) {
            return trade;
        }
        
        IUniswapV2Pair pair = IUniswapV2Pair(address(bytes20(poolId)));

        address token0 = pair.token0();
        address token1 = pair.token1();
        
        // Determine which token we want to end up with (buyToken)
        // and which token we'll need to swap away
        address tokenToKeep = buyToken;
        address tokenToSell;
        
        if (buyToken == token0) {
            tokenToSell = token1;
        } else if (buyToken == token1) {
            tokenToSell = token0;
        } else {
            revert("UniswapV2SwapAdapter: buyToken not in pool");
        }
        
        bool zero2one = tokenToSell < tokenToKeep;

        uint112 r0;
        uint112 r1;

        uint256 gasBefore = gasleft();
        //transfer amount of liquidity (lpToken) to burn to pair contract 
        IERC20(address(pair)).safeTransferFrom(swapper, address(pair), specifiedAmount); 
        (uint256 amount0, uint256 amount1) = pair.burn(address(this)); // transfers redeemed tokens to the adapter so tokens are held in the adapter first, then swapped after
        if (zero2one) {
            (r0, r1,) = pair.getReserves();  
        } else {
            (r1, r0,) = pair.getReserves(); 
        }
        // Determine how much of each token we received from burning
        uint256 receivedTokenToKeepAmt;
        uint256 receivedTokenToSellAmt;

        if (tokenToKeep == token0) {
            receivedTokenToKeepAmt = amount0;
            receivedTokenToSellAmt = amount1;
        } else {
            receivedTokenToKeepAmt = amount1;
            receivedTokenToSellAmt = amount0;
        }
        
        //swap superfluous token to buyToken (the > 0 check is because burn does not guarantee it will return a non zero value)
        if (receivedTokenToSellAmt > 0) {
            //Transfer the redeemed receivedTokenToSellAmt of tokens from the adapter to the pair
            IERC20(tokenToSell).safeTransfer(address(pair), receivedTokenToSellAmt);
            uint256 amountOut = getAmountOut(receivedTokenToSellAmt, r0, r1);
            if (zero2one) {
                pair.swap(0, amountOut, swapper, "");
            } else {
                pair.swap(amountOut, 0, swapper, "");
            }
            trade.calculatedAmount = amountOut;
        }
        trade.gasUsed = gasBefore - gasleft();
        trade.price = getPriceAt(trade.calculatedAmount, r0, r1); 
    }

    /// @inheritdoc ISwapAdapter
    function swap(
        bytes32 poolId,
        address sellToken,
        address buyToken,
        OrderSide side,
        uint256 specifiedAmount
    ) external override returns (Trade memory trade) {
        //if sellToken and BuyToken is uniswapV2pair addresss revert
        //buying and selling lp tokens 
         // Determine swap type based on token addresses
        SwapType swapType = _getSwapType(poolId, sellToken, buyToken);

        // Execute appropriate swap logic
        if (swapType == SwapType.TokenToToken) {
            trade = _executeTokenSwap(poolId, sellToken, buyToken, side, specifiedAmount);
        } else if (swapType == SwapType.RemoveLiquidity) {
            trade = _executeRemoveLiquidity(poolId, sellToken, buyToken, side, specifiedAmount);
        } else if (swapType == SwapType.AddLiquidity) {
            trade = _executeAddLiquidity(poolId, sellToken, buyToken, side, specifiedAmount);
        } else {
            revert("SwapAdapter: LP-to-LP swap not supported");
        }
    }

    /// @notice Executes a sell order on a given pool.
    /// @param pair The pair to trade on.
    /// @param sellToken The token being sold.
    /// @param zero2one Whether the sell token is token0 or token1.
    /// @param reserveIn The reserve of the token being sold.
    /// @param reserveOut The reserve of the token being bought.
    /// @param amount The amount to be traded.
    /// @return calculatedAmount The amount of tokens received.
    function sell(
        IUniswapV2Pair pair,
        address sellToken,
        bool zero2one,
        uint112 reserveIn,
        uint112 reserveOut,
        uint256 amount
    ) internal returns (uint256 calculatedAmount) {
        address swapper = msg.sender;
        uint256 amountOut = getAmountOut(amount, reserveIn, reserveOut);

        IERC20(sellToken).safeTransferFrom(swapper, address(pair), amount);
        if (zero2one) {
            pair.swap(0, amountOut, swapper, "");
        } else {
            pair.swap(amountOut, 0, swapper, "");
        }
        return amountOut;
    }

    /// @notice Given an input amount of an asset and pair reserves, returns the
    /// maximum output amount of the other asset
    /// @param amountIn The amount of the token being sold.
    /// @param reserveIn The reserve of the token being sold.
    /// @param reserveOut The reserve of the token being bought.
    /// @return amountOut The amount of tokens received.
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        if (amountIn == 0) {
            return 0;
        }
        if (reserveIn == 0 || reserveOut == 0) {
            revert Unavailable("At least one reserve is zero!");
        }
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Execute a buy order on a given pool.
    /// @param pair The pair to trade on.
    /// @param sellToken The token being sold.
    /// @param zero2one Whether the sell token is token0 or token1.
    /// @param reserveIn The reserve of the token being sold.
    /// @param reserveOut The reserve of the token being bought.
    /// @param amountOut The amount of tokens to be bought.
    /// @return calculatedAmount The amount of tokens sold.
    function buy(
        IUniswapV2Pair pair,
        address sellToken,
        bool zero2one,
        uint112 reserveIn,
        uint112 reserveOut,
        uint256 amountOut
    ) internal returns (uint256 calculatedAmount) {
        address swapper = msg.sender;
        uint256 amount = getAmountIn(amountOut, reserveIn, reserveOut);

        if (amount == 0) {
            return 0;
        }

        IERC20(sellToken).safeTransferFrom(swapper, address(pair), amount);
        if (zero2one) {
            pair.swap(0, amountOut, swapper, "");
        } else {
            pair.swap(amountOut, 0, swapper, "");
        }
        return amount;
    }

    /// @notice Given an output amount of an asset and pair reserves, returns a
    /// required input amount of the other asset
    /// @param amountOut The amount of the token being bought.
    /// @param reserveIn The reserve of the token being sold.
    /// @param reserveOut The reserve of the token being bought.
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        if (amountOut == 0) {
            return 0;
        }
        if (reserveIn == 0) {
            revert Unavailable("reserveIn is zero");
        }
        if (reserveOut == 0) {
            revert Unavailable("reserveOut is zero");
        }
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    /// @inheritdoc ISwapAdapter
    function getLimits(bytes32 poolId, address sellToken, address buyToken)
        external
        view
        override
        returns (uint256[] memory limits)
    {
        IUniswapV2Pair pair = IUniswapV2Pair(address(bytes20(poolId)));
        limits = new uint256[](2);
        (uint256 r0, uint256 r1,) = pair.getReserves();
        if (sellToken < buyToken) {
            limits[0] = r0 / RESERVE_LIMIT_FACTOR;
            limits[1] = r1 / RESERVE_LIMIT_FACTOR;
        } else {
            limits[0] = r1 / RESERVE_LIMIT_FACTOR;
            limits[1] = r0 / RESERVE_LIMIT_FACTOR;
        }
    }

    /// @inheritdoc ISwapAdapter
    function getCapabilities(bytes32, address, address)
        external
        pure
        override
        returns (Capability[] memory capabilities)
    {
        capabilities = new Capability[](4);
        capabilities[0] = Capability.SellOrder;
        capabilities[1] = Capability.BuyOrder;
        capabilities[2] = Capability.PriceFunction;
        capabilities[3] = Capability.MarginalPrice;
    }

    /// @inheritdoc ISwapAdapter
    function getTokens(bytes32 poolId)
        external
        view
        override
        returns (address[] memory tokens)
    {
        tokens = new address[](2);
        IUniswapV2Pair pair = IUniswapV2Pair(address(bytes20(poolId)));
        tokens[0] = address(pair.token0());
        tokens[1] = address(pair.token1());
    }

    /// @inheritdoc ISwapAdapter
    function getPoolIds(uint256 offset, uint256 limit)
        external
        view
        override
        returns (bytes32[] memory ids)
    {
        uint256 endIdx = offset + limit;
        if (endIdx > factory.allPairsLength()) {
            endIdx = factory.allPairsLength();
        }
        ids = new bytes32[](endIdx - offset);
        for (uint256 i = 0; i < ids.length; i++) {
            ids[i] = bytes20(factory.allPairs(offset + i));
        }
    }
}

interface IUniswapV2Pair {
    event Approval(
        address indexed owner, address indexed spender, uint256 value
    );
    event Transfer(address indexed from, address indexed to, uint256 value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value)
        external
        returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint256);

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint256);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function kLast() external view returns (uint256);

    function mint(address to) external returns (uint256 liquidity);
    function burn(address to)
        external
        returns (uint256 amount0, uint256 amount1);
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;
    function skim(address to) external;
    function sync() external;

    function initialize(address, address) external;
}

interface IUniswapV2Factory {
    event PairCreated(
        address indexed token0, address indexed token1, address pair, uint256
    );

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
    function allPairs(uint256) external view returns (address pair);
    function allPairsLength() external view returns (uint256);

    function createPair(address tokenA, address tokenB)
        external
        returns (address pair);

    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
}
