// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/Console.sol";
import {SuperTokenLockableAppGateway} from "../../contracts/apps/super-token-lockable/SuperTokenLockableAppGateway.sol";
import {SuperTokenLockableDeployer} from "../../contracts/apps/super-token-lockable/SuperTokenLockableDeployer.sol";
import {SuperTokenLockable} from "../../contracts/apps/super-token-lockable/SuperTokenLockable.sol";
import {FeesData} from "../../contracts/common/Structs.sol";
import {ETH_ADDRESS, FAST} from "../../contracts/common/Constants.sol";

contract DeployGateway is Script {
    function run() external {
        vm.startBroadcast();

        address addressResolver = vm.envAddress("ADDRESS_RESOLVER");
        address auctionManager = vm.envAddress("AUCTION_MANAGER");
        address owner = vm.envAddress("OWNER");

        FeesData memory feesData = FeesData({
            feePoolChain: 421614,
            feePoolToken: ETH_ADDRESS,
            maxFees: 0.001 ether
        });

        SuperTokenLockableDeployer deployer = new SuperTokenLockableDeployer(
            addressResolver,
            owner,
            address(auctionManager),
            FAST,
            SuperTokenLockableDeployer.ConstructorParams({
                _burnLimit: 1000000000 ether,
                _mintLimit: 1000000000 ether,
                name_: "SUPER TOKEN",
                symbol_: "SUPER",
                decimals_: 18,
                initialSupplyHolder_: owner,
                initialSupply_: 1000000000 ether
            }),
            feesData
        );

        SuperTokenLockableAppGateway gateway = new SuperTokenLockableAppGateway(
            addressResolver,
            address(deployer),
            address(auctionManager),
            feesData
        );

        bytes32 superToken = deployer.superTokenLockable();
        bytes32 limitHook = deployer.limitHook();

        console.log("Contracts deployed:");
        console.log("SuperTokenLockableAppGateway:", address(gateway));
        console.log("SuperTokenLockableDeployer:", address(deployer));
        console.log("SuperTokenLockableId:");
        console.logBytes32(superToken);
        console.log("LimitHookId:");
        console.logBytes32(limitHook);
    }
}
