// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SplitFactory} from "../src/SplitFactory.sol";
import {Series} from "../src/Series.sol";
import {SplitToken} from "../src/SplitToken.sol";
import {UniswapV3MedianOracle} from "../src/oracle/UniswapV3MedianOracle.sol";

/// @notice Full production lifecycle against REAL mainnet pools: deploy the Uniswap
///         median oracle + factory, create a series, split ETH, advance to maturity,
///         settle off the live TWAP, and redeem — asserting exact ETH conservation.
///
///   MAINNET_RPC_URL=https://… forge test --match-contract IntegrationForkTest -vv
contract IntegrationForkTest is Test {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant POOL_USDC = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address constant POOL_USDT = 0x11b815efB8f581194ae79006d24E0d814B7697F6;
    address constant POOL_DAI = 0xC2e9F25Be6257c210d7Adf0D4Cd6E3E881ba25f8;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function _oracle() internal returns (UniswapV3MedianOracle) {
        address[] memory pools = new address[](3);
        pools[0] = POOL_USDC;
        pools[1] = POOL_USDT;
        pools[2] = POOL_DAI;
        address[] memory quotes = new address[](3);
        quotes[0] = USDC;
        quotes[1] = USDT;
        quotes[2] = DAI;
        return new UniswapV3MedianOracle(WETH, 3600, pools, quotes);
    }

    function test_fork_full_lifecycle_conserves_eth() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("SKIP: set MAINNET_RPC_URL to run the integration fork test");
            return;
        }
        vm.createSelectFork(rpc);
        // makeAddr-derived addresses can collide with real mainnet contracts on a fork
        // (alice's address is a live forwarder!), which would re-route redeemed ETH.
        // Clear any forked code so they behave as plain EOAs that accept ETH.
        vm.etch(alice, "");
        vm.etch(bob, "");

        UniswapV3MedianOracle oracle = _oracle();
        uint256 px = oracle.price();
        emit log_named_decimal_uint("live ETH/USD", px, 18);

        // Strike well below current price so P is "in the money" and N has value.
        uint256 strike = (px * 60) / 100; // 60% of spot
        SplitFactory factory = new SplitFactory();
        Series series = factory.createSeries("fork", strike, block.timestamp + 7 days, oracle, "P", "P", "N", "N");
        SplitToken N = series.N();

        // Alice splits 5 ETH; sells all her N to Bob (simple transfer stands in).
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        series.split{value: 5 ether}();
        vm.prank(alice);
        N.transfer(bob, 5 ether);

        // Advance past maturity and settle off the live oracle TWAP.
        vm.warp(block.timestamp + 8 days);
        series.settle();
        assertTrue(series.settled());
        emit log_named_decimal_uint("settled price", series.settledPrice(), 18);

        uint256 f = series.f();
        uint256 aliceExpect = (5 ether * f) / 1e18;
        uint256 bobExpect = (5 ether * (1e18 - f)) / 1e18;

        vm.prank(alice);
        series.redeem(5 ether, 0);
        vm.prank(bob);
        series.redeem(0, 5 ether);

        assertEq(alice.balance, aliceExpect, "alice P payout");
        assertEq(bob.balance, bobExpect, "bob N payout");
        // The two legs together return the full deposit (minus <=1 wei dust).
        assertApproxEqAbs(alice.balance + bob.balance, 5 ether, 2, "P+N != deposit");
        assertLe(address(series).balance, 2, "series fully drained");
    }
}
