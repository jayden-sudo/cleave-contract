// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {SplitFactory} from "../src/SplitFactory.sol";
import {Marketplace} from "../src/Marketplace.sol";
import {Series} from "../src/Series.sol";
import {MockOracle} from "../src/MockOracle.sol";

/// @notice Deploys the full Cleave stack to a local/anvil chain and seeds it with a
///         couple of live series and marketplace orders so the front-end has data to
///         show immediately. Writes deployment addresses to deployments/local.json.
///
///         Core contracts are deployed via CREATE2 (through the canonical deterministic
///         deployer at 0x4e59b44847b379578588920cA78FbF26c0B4956C, pre-funded on anvil),
///         so factory/marketplace addresses are stable across re-runs on a fresh chain.
///         Override CREATE2_SALT to deploy a parallel instance; re-running with the same
///         salt against a chain that already has the contracts will revert.
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        // The demo oracle owner (defaults to deployer). Locally we point this at the
        // in-app "Dev wallet" so the whole settlement lifecycle is driveable from the UI.
        address demoOwner = vm.envOr("DEMO_OWNER", deployer);
        bytes32 salt = vm.envOr("CREATE2_SALT", bytes32(keccak256("cleave.local.v1")));

        vm.startBroadcast(pk);

        SplitFactory factory = new SplitFactory{salt: salt}();
        Marketplace market = new Marketplace{salt: salt}();

        // --- Series A: stable floor at $1,500, matures in 30 days ---
        // The two mock oracles share initcode, so each needs its own derived salt to
        // avoid a CREATE2 address collision.
        MockOracle oa = new MockOracle{salt: keccak256(abi.encode(salt, "oracle-a"))}(2500e18); // current ETH ~ $2,500
        oa.transferOwnership(demoOwner);
        Series a = factory.createSeries(
            "ETH split @ $1,500",
            1500e18,
            block.timestamp + 30 days,
            oa,
            "Cleave Stable 1500",
            "sETH-1500",
            "Cleave Upside 1500",
            "uETH-1500"
        );

        // --- Series B: stable floor at $3,000, matures in 90 days ---
        MockOracle ob = new MockOracle{salt: keccak256(abi.encode(salt, "oracle-b"))}(2500e18);
        ob.transferOwnership(demoOwner);
        Series b = factory.createSeries(
            "ETH split @ $3,000",
            3000e18,
            block.timestamp + 90 days,
            ob,
            "Cleave Stable 3000",
            "sETH-3000",
            "Cleave Upside 3000",
            "uETH-3000"
        );

        // --- Seed liquidity: deployer splits ETH and lists both legs for sale ---
        a.split{value: 4 ether}(); // -> 4 P + 4 N
        a.P().approve(address(market), 2 ether);
        a.N().approve(address(market), 2 ether);
        market.list(address(a.P()), 2 ether, 0.58 ether); // stable leg ~0.58 ETH each
        market.list(address(a.N()), 2 ether, 0.42 ether); // upside leg ~0.42 ETH each

        b.split{value: 2 ether}();
        b.N().approve(address(market), 2 ether);
        market.list(address(b.N()), 2 ether, 0.18 ether); // cheap deep-OTM upside

        vm.stopBroadcast();

        // --- Persist addresses for the front-end generator ---
        string memory obj = "deployment";
        vm.serializeAddress(obj, "factory", address(factory));
        vm.serializeAddress(obj, "marketplace", address(market));
        vm.serializeUint(obj, "chainId", block.chainid);
        string memory json = vm.serializeAddress(obj, "deployer", deployer);
        vm.writeJson(json, "./deployments/local.json");

        console2.log("Factory:    ", address(factory));
        console2.log("Marketplace:", address(market));
        console2.log("Series A:   ", address(a));
        console2.log("Series B:   ", address(b));
    }
}
