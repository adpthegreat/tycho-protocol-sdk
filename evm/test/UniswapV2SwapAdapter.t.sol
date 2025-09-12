// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.13;

import "./AdapterTest.sol";
import "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import "src/uniswap-v2/UniswapV2SwapAdapter.sol";
import "src/interfaces/ISwapAdapterTypes.sol";
import "src/libraries/FractionMath.sol";

contract UniswapV2PairFunctionTest is AdapterTest {
    using FractionMath for Fraction;

    UniswapV2SwapAdapter adapter;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDC_WETH_PAIR = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;
    bytes32 pair = bytes32(bytes20(USDC_WETH_PAIR));

    uint256 constant TEST_ITERATIONS = 100; //500

    function setUp() public {
        uint256 forkBlock = 17000000;
        vm.createSelectFork(vm.rpcUrl("mainnet"), forkBlock);
        adapter =
            new UniswapV2SwapAdapter(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);

        vm.label(address(adapter), "UniswapV2SwapAdapter");
        vm.label(WETH, "WETH");
        vm.label(USDC, "USDC");
        vm.label(USDC_WETH_PAIR, "USDC_WETH_PAIR");
    }

    function testPriceFuzz(uint256 amount0, uint256 amount1) public {
        uint256[] memory limits = adapter.getLimits(pair, USDC, WETH);
        vm.assume(amount0 < limits[0]);
        vm.assume(amount1 < limits[0]); //why not limits[1]?

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;

        Fraction[] memory prices = adapter.price(pair, WETH, USDC, amounts);

        for (uint256 i = 0; i < prices.length; i++) {
            assertGt(prices[i].numerator, 0);
            assertGt(prices[i].denominator, 0);
        }
    }

    function testPriceDecreasing() public {
        uint256[] memory amounts = new uint256[](TEST_ITERATIONS);

        for (uint256 i = 0; i < TEST_ITERATIONS; i++) {
            amounts[i] = 1000 * i * 10 ** 6;
        }

        Fraction[] memory prices = adapter.price(pair, WETH, USDC, amounts);

        for (uint256 i = 0; i < TEST_ITERATIONS - 1; i++) {
            assertEq(prices[i].compareFractions(prices[i + 1]), 1);
            assertGt(prices[i].denominator, 0);
            assertGt(prices[i + 1].denominator, 0);
        }
    }

    function testSwapFuzz(uint256 specifiedAmount, bool isBuy) public {
        OrderSide side = isBuy ? OrderSide.Buy : OrderSide.Sell;

        uint256[] memory limits = adapter.getLimits(pair, USDC, WETH);

        if (side == OrderSide.Buy) {
            vm.assume(specifiedAmount < limits[1]);

            // TODO calculate the amountIn by using price function as in
            // BalancerV2 testPriceDecreasing
            deal(USDC, address(this), type(uint256).max);
            IERC20(USDC).approve(address(adapter), type(uint256).max);
        } else {
            vm.assume(specifiedAmount < limits[0]);

            deal(USDC, address(this), specifiedAmount);
            IERC20(USDC).approve(address(adapter), specifiedAmount);
        }

        uint256 usdc_balance = IERC20(USDC).balanceOf(address(this));
        uint256 weth_balance = IERC20(WETH).balanceOf(address(this));

        Trade memory trade =
            adapter.swap(pair, USDC, WETH, side, specifiedAmount);

        if (trade.calculatedAmount > 0) {
            if (side == OrderSide.Buy) {
                assertEq(
                    specifiedAmount,
                    IERC20(WETH).balanceOf(address(this)) - weth_balance
                );
                assertEq(
                    trade.calculatedAmount,
                    usdc_balance - IERC20(USDC).balanceOf(address(this))
                );
            } else {
                assertEq(
                    specifiedAmount,
                    usdc_balance - IERC20(USDC).balanceOf(address(this))
                );
                assertEq(
                    trade.calculatedAmount,
                    IERC20(WETH).balanceOf(address(this)) - weth_balance
                );
            }
        }
    }

    function testSwapSellIncreasing() public {
        executeIncreasingSwaps(OrderSide.Sell);
    }

    function executeIncreasingSwaps(OrderSide side) internal { 

        uint256[] memory amounts = new uint256[](TEST_ITERATIONS);
        for (uint256 i = 0; i < TEST_ITERATIONS; i++) {
            amounts[i] = 1000 * i * 10 ** 6;
        }

        Trade[] memory trades = new Trade[](TEST_ITERATIONS);
        uint256 beforeSwap;
        for (uint256 i = 0; i < TEST_ITERATIONS; i++) {
            beforeSwap = vm.snapshot();

            deal(USDC, address(this), amounts[i]);
            IERC20(USDC).approve(address(adapter), amounts[i]);

            trades[i] = adapter.swap(pair, USDC, WETH, side, amounts[i]);
            vm.revertTo(beforeSwap);
        }

        for (uint256 i = 1; i < TEST_ITERATIONS - 1; i++) {
            assertLe(trades[i].calculatedAmount, trades[i + 1].calculatedAmount);
            assertLe(trades[i].gasUsed, trades[i + 1].gasUsed);
            assertEq(trades[i].price.compareFractions(trades[i + 1].price), 1);
        }
    }

    function testSwapBuyIncreasing() public {
        executeIncreasingSwaps(OrderSide.Buy);
    }
    //So it tries to pull tokens from the test into the pair for the swap. 
    //That requires the test to have approved the adapter to spend those tokens.
    //three entities
    //adapter contract UniswapV2Adapter.sol
    //test contract UniswapV2Adapter.t.sol msg.sender 
    //uni v2 pair contract (pool)

    //so after callng pair.burn(msg.sender), because test contract is the msg.sender, the test contract owns the tokens,
    //so we now need to transfer it to the adapter 
    //flow ->
    // test_contract == msg.sender (burn) -> adapter -> (swap) -> pool ->  test_contract == msg.sender
    function testRemoveWETHLiquidityFuzz(
        uint256 specifiedAmount
    ) public {
        OrderSide side = OrderSide.Sell; // selling LP for tokenA = WETH

        vm.assume(specifiedAmount > 1e6 && specifiedAmount < 1e17);

        deal(USDC_WETH_PAIR , address(this), specifiedAmount);
        IERC20(USDC_WETH_PAIR).approve(address(adapter), specifiedAmount);

        deal(WETH, address(this), 10e20);
        IERC20(WETH).approve(address(adapter), 10e20);

        uint256 lpTokenBefore = IERC20(USDC_WETH_PAIR).balanceOf(address(this));
        uint256 WETHBefore = IERC20(WETH).balanceOf(address(this));
        uint256 USDCBefore = IERC20(USDC).balanceOf(address(this));
        //What swap does
        // 1. Sell LP token for WETH (i.e., exit liquidity) 
        // 2. Swap remaining USDC tokens to WETH convert full exit to WETH
        Trade memory exitTrade = adapter.swap(pair, USDC_WETH_PAIR, WETH, side, specifiedAmount);

        uint256 lpTokenAfter = IERC20(USDC_WETH_PAIR).balanceOf(address(this));
        uint256 WETHAfter = IERC20(WETH).balanceOf(address(this));
        uint256 USDCAfter = IERC20(USDC).balanceOf(address(this));
        uint256 tradeAmount = exitTrade.calculatedAmount;

        // Lp token was redeemed (burnt) for WETH and USDC, so balance before is > balance after 
        // WETH was received from the pool exit so, balance after > than the balance before
        // USDC was received from the pool exit as the superfluous token and converted to WETH, 
        //so balance remains at 0

        assertGt(lpTokenBefore, lpTokenAfter);
        assertGt(WETHAfter, WETHBefore);
        assertEq(USDCBefore, USDCAfter); 
        assertGt(tradeAmount, 0);
    }

    function testRemoveUSDCLiquidityFuzz(
        uint256 specifiedAmount
    ) public {
        OrderSide side = OrderSide.Sell; 
  
        vm.assume(specifiedAmount > 1e6 && specifiedAmount < 1e17);

        deal(USDC_WETH_PAIR, address(this), specifiedAmount);
        IERC20(USDC_WETH_PAIR).approve(address(adapter), specifiedAmount);

        deal(USDC, address(this), 10e20);
        IERC20(USDC).approve(address(adapter), 10e20);

        uint256 lpTokenBefore = IERC20(USDC_WETH_PAIR).balanceOf(address(this));
        uint256 USDCBefore = IERC20(USDC).balanceOf(address(this));
        uint256 WETHBefore = IERC20(WETH).balanceOf(address(this));

        Trade memory exitTrade = adapter.swap(pair, USDC_WETH_PAIR , USDC, side, specifiedAmount);

        uint256 LPTokenAfter = IERC20(USDC_WETH_PAIR ).balanceOf(address(this));
        uint256 USDCAfter = IERC20(USDC).balanceOf(address(this));
        uint256 WETHAfter = IERC20(WETH).balanceOf(address(this));
        uint256 tradeAmount = exitTrade.calculatedAmount;

        assertGt(lpTokenBefore, LPTokenAfter);
        assertGt(USDCAfter, USDCBefore);
        assertEq(WETHBefore, WETHAfter); 
        assertGt(tradeAmount, 0);
    }


    function testAddWETHLiquidityFuzz(uint256 specifiedAmount) public { //rename tis to be more explicit
        OrderSide side = OrderSide.Buy;
       
        vm.assume(specifiedAmount > 1e6 && specifiedAmount < 1e17);

        //we approve the tokens in the contract, first give the adapter tokens to join to the pool
        deal(USDC, address(this), 10e23);
        IERC20(USDC).approve(address(adapter), 10e23);

        deal(WETH, address(this), 10e23);
        IERC20(WETH).approve(address(adapter), 10e23);

        uint256 LPTokenBefore = IERC20(USDC_WETH_PAIR).balanceOf(address(this));
        uint256 WETHBefore = IERC20(WETH).balanceOf(address(this));
        uint256 USDCBefore = IERC20(USDC).balanceOf(address(this));

        Trade memory joinTrade = adapter.swap(pair, WETH, USDC_WETH_PAIR , side, specifiedAmount);

        uint256 LPTokenAfter = IERC20(USDC_WETH_PAIR ).balanceOf(address(this));
        uint256 WETHAfter = IERC20(WETH).balanceOf(address(this));
        uint256 USDCAfter = IERC20(USDC).balanceOf(address(this));

        uint256 calculatedAmount = joinTrade.calculatedAmount;
        //so its a little bit off 
        //i request: 52,775,318,509 LP tokens
        //i get: 52,775,311,209 LP tokens (7,300 fewer than requested)
        assertGt(LPTokenAfter, LPTokenBefore);
        assertGt(calculatedAmount, 0);
        // assertGt(USDCBefore, USDCAfter);
        // assertGt(WETHBefore, WETHAfter); 

        console2.log("USDC Before:", USDCBefore);
        console2.log("USDC After :", USDCAfter);

        console2.log("WETH Before:", WETHBefore);
        console2.log("WETH After :", WETHAfter);
    }  

    function testAddUSDCLiquidityFuzz(uint256 specifiedAmount) public {
        OrderSide side = OrderSide.Buy;

        vm.assume(specifiedAmount > 1e6 && specifiedAmount < 1e17);

        deal(USDC, address(this), 10e23);
        IERC20(USDC).approve(address(adapter), 10e23);

        deal(WETH, address(this), 10e23);
        IERC20(WETH).approve(address(adapter), 10e23);

        uint256 LPTokenBefore = IERC20(USDC_WETH_PAIR ).balanceOf(address(this));
        uint256 USDCBefore = IERC20(USDC).balanceOf(address(this));
        uint256 WETHBefore = IERC20(WETH).balanceOf(address(this));

        Trade memory joinTrade = adapter.swap(pair, USDC, USDC_WETH_PAIR , side, specifiedAmount);

        uint256 calculatedAmount = joinTrade.calculatedAmount;

        uint256 LPTokenAfter = IERC20(USDC_WETH_PAIR ).balanceOf(address(this));
        uint256 USDCAfter = IERC20(USDC).balanceOf(address(this));
        uint256 WETHAfter = IERC20(WETH).balanceOf(address(this));

        assertGt(LPTokenAfter, LPTokenBefore);
        assertGt(calculatedAmount, 0);
        // assertGt(USDCBefore, USDCAfter);
        // assertGt(WETHBefore, WETHAfter); 

        console2.log("USDC Before:", USDCBefore);
        console2.log("USDC After :", USDCAfter);

        console2.log("WETH Before:", WETHBefore);
        console2.log("WETH After :", WETHAfter);

    }


    // Normally, the price does not change when joining or exiting to a pool, but because we swap the superfluous token 
    // in this case USDC into WETH it will change 

    function testAddWETHLiquidityPriceIncreasing() public {
        uint256[] memory amounts = new uint256[](TEST_ITERATIONS);
        Trade[] memory trades = new Trade[](TEST_ITERATIONS);

        for (uint256 i = 0; i < TEST_ITERATIONS; i++) {
            amounts[i] = 1000 * (i + 1) * 10 ** 10;

            uint256 beforeSwap = vm.snapshot();

            deal(USDC, address(this), 10e23);
            IERC20(USDC).approve(address(adapter), 10e23);

            deal(WETH, address(this), 10e23);
            IERC20(WETH).approve(address(adapter), 10e23);

            trades[i] = adapter.swap(
                pair, WETH, USDC_WETH_PAIR , OrderSide.Buy, amounts[i]
            );

            vm.revertTo(beforeSwap);
        }

        for (uint256 i = 0; i < TEST_ITERATIONS - 1; i++) {
            assertLe(trades[i].calculatedAmount, trades[i + 1].calculatedAmount);
            assertLe(trades[i].gasUsed, trades[i + 1].gasUsed);
            assertEq(trades[i].price.compareFractions(trades[i + 1].price), 1);
        }
    }

    function testAddUSDCLiquidityPriceIncreasing() public {
        uint256[] memory amounts = new uint256[](TEST_ITERATIONS);
        Trade[] memory trades = new Trade[](TEST_ITERATIONS);

        for (uint256 i = 0; i < TEST_ITERATIONS; i++) {
            amounts[i] = 1000 * (i + 1) * 10 ** 10;

            uint256 beforeSwap = vm.snapshot();

            deal(USDC, address(this), 10e23);
            IERC20(USDC).approve(address(adapter), 10e23);

            deal(WETH, address(this), 10e23);
            IERC20(WETH).approve(address(adapter), 10e23);

            trades[i] = adapter.swap(
                pair, USDC, USDC_WETH_PAIR , OrderSide.Buy, amounts[i]
            );

            vm.revertTo(beforeSwap);
        }

        for (uint256 i = 0; i < TEST_ITERATIONS - 1; i++) {
            assertLe(trades[i].calculatedAmount, trades[i + 1].calculatedAmount);
            assertLe(trades[i].gasUsed, trades[i + 1].gasUsed);
            assertEq(trades[i].price.compareFractions(trades[i + 1].price), 1);
        }
    }

    function testRemoveWETHLiquidityPriceIncreasing() public {
        uint256[] memory amounts = new uint256[](TEST_ITERATIONS);
        Trade[] memory trades = new Trade[](TEST_ITERATIONS);

        for (uint256 i = 0; i < TEST_ITERATIONS; i++) {
            amounts[i] = 1000 * (i + 1) * 10 ** 12;

            uint256 beforeSwap = vm.snapshot();

            deal(USDC_WETH_PAIR , address(this), amounts[i]);
            IERC20(USDC_WETH_PAIR).approve(address(adapter), amounts[i]);

            deal(WETH, address(this), 10e20);
            IERC20(WETH).approve(address(adapter), 10e20);

            trades[i] = adapter.swap(
                pair, USDC_WETH_PAIR , WETH, OrderSide.Sell, amounts[i]
            );

            vm.revertTo(beforeSwap);
        }

        for (uint256 i = 0; i < TEST_ITERATIONS - 1; i++) {
            assertLe(trades[i].calculatedAmount, trades[i + 1].calculatedAmount);
            assertLe(trades[i].gasUsed, trades[i + 1].gasUsed);
            assertEq(trades[i].price.compareFractions(trades[i + 1].price), 1);
        }
    }

    function testRemoveUSDCLiquidityPriceIncreasing() public {
        uint256[] memory amounts = new uint256[](TEST_ITERATIONS);
        Trade[] memory trades = new Trade[](TEST_ITERATIONS);

        for (uint256 i = 0; i < TEST_ITERATIONS; i++) {
            amounts[i] = 1000 * (i + 1) * 10 ** 12;

            uint256 beforeSwap = vm.snapshot();

            deal(USDC_WETH_PAIR , address(this), amounts[i]);
            IERC20(USDC_WETH_PAIR).approve(address(adapter), amounts[i]);

            deal(USDC, address(this), 10e24);
            IERC20(USDC).approve(address(adapter), 10e24);

            trades[i] = adapter.swap(
                pair, USDC_WETH_PAIR , USDC, OrderSide.Sell, amounts[i]
            );

            vm.revertTo(beforeSwap);
        }

        for (uint256 i = 0; i < TEST_ITERATIONS - 1; i++) {
            assertLe(trades[i].calculatedAmount, trades[i + 1].calculatedAmount);
            assertLe(trades[i].gasUsed, trades[i + 1].gasUsed);
            assertEq(trades[i].price.compareFractions(trades[i + 1].price), 1);
        }
    }

    function testGetCapabilities(address t0, address t1) public {

        Capability[] memory res = adapter.getCapabilities(pair, t0, t1);

        assertEq(res.length, 4);
    }

    function testGetLimits() public {
        uint256[] memory limits = adapter.getLimits(pair, USDC, WETH);

        assertEq(limits.length, 2);
    }

    function testUsv2PoolBehaviour() public {
        bytes32[] memory poolIds = new bytes32[](1);
        poolIds[0] = bytes32(bytes20(USDC_WETH_PAIR));
        runPoolBehaviourTest(adapter, poolIds);
    }
}
