// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {SplitFactory} from "../src/SplitFactory.sol";
import {Marketplace} from "../src/Marketplace.sol";
import {Series} from "../src/Series.sol";
import {UniswapV3MedianOracle} from "../src/oracle/UniswapV3MedianOracle.sol";

/// @notice Full mainnet deployment of the Cleave stack — all immutable, no admin keys:
///         the Uniswap V3 median-TWAP oracle, the SplitFactory, the Marketplace, and a
///         first series wired to the oracle. Writes deployments/mainnet.json.
///
///   PRIVATE_KEY=$PK STRIKE_USD=2000 DURATION_DAYS=90 TWAP_WINDOW=3600 \
///   forge script script/DeployMainnet.s.sol \
///     --rpc-url $MAINNET_RPC_URL --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
///
/// Always dry-run first WITHOUT --broadcast (and ideally against a fork) to sanity-check
/// the logged oracle price before spending real ETH.
///
/// Deployments are deterministic: the oracle, factory and marketplace go through the
/// canonical CREATE2 deployer (0x4e59b44847b379578588920cA78FbF26c0B4956C), so their
/// addresses depend only on CREATE2_SALT + creation code — not on the deployer account
/// or its nonce. The same salt yields the same addresses on any chain (note the oracle
/// address also moves with TWAP_WINDOW, since constructor args are part of the initcode).
/// Re-deploying with an already-used salt reverts; bump CREATE2_SALT for a new instance.
contract DeployMainnet is Script {
    // Ethereum mainnet
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant POOL_USDC = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // USDC/WETH 0.05%
    address constant POOL_USDT = 0x11b815efB8f581194ae79006d24E0d814B7697F6; // USDT/WETH 0.05%
    address constant POOL_DAI = 0xC2e9F25Be6257c210d7Adf0D4Cd6E3E881ba25f8; // DAI/WETH 0.30%

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 strikeUsd = vm.envOr("STRIKE_USD", uint256(2000));
        bytes32 salt = vm.envOr("CREATE2_SALT", bytes32(keccak256("cleave.v1")));

        vm.startBroadcast(pk);
        UniswapV3MedianOracle oracle = _deployOracle(salt);
        SplitFactory factory = new SplitFactory{salt: salt}();
        Marketplace market = new Marketplace{salt: salt}();
        Series series = _createSeries(factory, oracle, strikeUsd);
        vm.stopBroadcast();

        _report(oracle, factory, market, series, strikeUsd, vm.addr(pk));
    }

    function _deployOracle(bytes32 salt) internal returns (UniswapV3MedianOracle) {
        uint32 window = uint32(vm.envOr("TWAP_WINDOW", uint256(3600)));
        address[] memory pools = new address[](3);
        pools[0] = POOL_USDC;
        pools[1] = POOL_USDT;
        pools[2] = POOL_DAI;
        address[] memory quotes = new address[](3);
        quotes[0] = USDC;
        quotes[1] = USDT;
        quotes[2] = DAI;
        return new UniswapV3MedianOracle{salt: salt}(WETH, window, pools, quotes);
    }

    function _createSeries(SplitFactory factory, UniswapV3MedianOracle oracle, uint256 strikeUsd)
        internal
        returns (Series)
    {
        uint256 durationDays = vm.envOr("DURATION_DAYS", uint256(90));
        string memory name = string.concat("Cleave ETH @ $", vm.toString(strikeUsd));
        return factory.createSeries(
            name,
            strikeUsd * 1e18,
            block.timestamp + durationDays * 1 days,
            oracle,
            string.concat(name, " Stable"),
            string.concat("sETH-", vm.toString(strikeUsd)),
            string.concat(name, " Upside"),
            string.concat("uETH-", vm.toString(strikeUsd))
        );
    }

    function _report(
        UniswapV3MedianOracle oracle,
        SplitFactory factory,
        Marketplace market,
        Series series,
        uint256 strikeUsd,
        address deployer
    ) internal {
        console2.log("Oracle:      ", address(oracle));
        console2.log("Factory:     ", address(factory));
        console2.log("Marketplace: ", address(market));
        console2.log("Series:      ", address(series));
        console2.log("  P token:   ", address(series.P()));
        console2.log("  N token:   ", address(series.N()));
        console2.log("strike (USD):", strikeUsd);
        console2.log("oracle price (USD/ETH, 1e18):", oracle.price());

        string memory o = "mainnet";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "oracle", address(oracle));
        vm.serializeAddress(o, "factory", address(factory));
        vm.serializeAddress(o, "marketplace", address(market));
        vm.serializeAddress(o, "deployer", deployer);
        string memory json = vm.serializeAddress(o, "firstSeries", address(series));
        vm.writeJson(json, "./deployments/mainnet.json");
    }
}
