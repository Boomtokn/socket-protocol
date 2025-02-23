// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CounterDeployer} from "../../contracts/apps//counter/CounterDeployer.sol";
import {ETH_ADDRESS} from "../../contracts/common/Constants.sol";

contract CounterDeployOnchain is Script {
    function run() external {
        string memory rpc = vm.envString("EVMX_RPC");
        console.log(rpc);
        vm.createSelectFork(rpc);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        CounterDeployer deployer = CounterDeployer(vm.envAddress("DEPLOYER"));

        console.log("Counter Deployer:", address(deployer));

        console.log("Deploying contracts on Arbitrum Sepolia...");
        deployer.deployContracts(421614);
        // console.log("Deploying contracts on Optimism Sepolia...");
        // deployer.deployContracts(11155420);
        // console.log("Deploying contracts on Base Sepolia...");
        // deployer.deployContracts(84532);
        //console.log("Deploying contracts on Ethereum Sepolia...");
        //deployer.deployContracts(11155111);
    }
}
