// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../contracts/common/Structs.sol";
import "../contracts/common/Constants.sol";
import "../contracts/watcherPrecompile/WatcherPrecompile.sol";
import "../contracts/interfaces/IForwarder.sol";
import "../contracts/socket/utils/AccessRoles.sol";
import {Socket} from "../contracts/socket/Socket.sol";
import {SignatureVerifier} from "../contracts/socket/utils/SignatureVerifier.sol";
import {Hasher} from "../contracts/socket/utils/Hasher.sol";
import "../contracts/socket/switchboard/FastSwitchboard.sol";
import "../contracts/socket/SocketBatcher.sol";
import "../contracts/AddressResolver.sol";
import {ContractFactoryPlug} from "../contracts/apps/payload-delivery/ContractFactoryPlug.sol";
import {FeesPlug} from "../contracts/apps/payload-delivery/FeesPlug.sol";

import {ETH_ADDRESS} from "../contracts/common/Constants.sol";
import {ResolvedPromises} from "../contracts/common/Structs.sol";

import "solady/utils/ERC1967Factory.sol";

contract SetupTest is Test {
    uint public c = 1;
    address owner = address(uint160(c++));

    uint256 watcherPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 transmitterPrivateKey =
        0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;

    address watcherEOA = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address transmitterEOA = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    uint32 arbChainSlug = 421614;
    uint32 optChainSlug = 11155420;
    uint32 vmChainSlug = 1;

    uint256 public writePayloadIdCounter = 0;
    uint256 public readPayloadIdCounter = 0;
    uint256 public timeoutPayloadIdCounter = 0;

    uint256 public maxLimit = 1000;

    bytes public asyncPromiseBytecode = type(AsyncPromise).creationCode;

    struct SocketContracts {
        uint32 chainSlug;
        Socket socket;
        FastSwitchboard switchboard;
        SocketBatcher socketBatcher;
        ContractFactoryPlug contractFactoryPlug;
        FeesPlug feesPlug;
    }

    AddressResolver public addressResolver;
    WatcherPrecompile public watcherPrecompile;
    SignatureVerifier public signatureVerifier;
    SocketContracts public arbConfig;
    SocketContracts public optConfig;

    // Add new variables for proxy admin and implementation contracts
    WatcherPrecompile public watcherPrecompileImpl;
    AddressResolver public addressResolverImpl;
    SignatureVerifier public signatureVerifierImpl;
    ERC1967Factory public proxyFactory;

    event Initialized(uint64 version);

    function deploySocket(uint32 chainSlug_) internal returns (SocketContracts memory) {
        SignatureVerifier verifier = new SignatureVerifier();
        verifier.initialize(owner);

        Hasher hasher = new Hasher(owner);
        Socket socket = new Socket(chainSlug_, address(hasher), address(verifier), owner, "test");
        SocketBatcher socketBatcher = new SocketBatcher(owner, socket);
        FastSwitchboard switchboard = new FastSwitchboard(chainSlug_, socket, verifier, owner);

        FeesPlug feesPlug = new FeesPlug(address(socket), owner);
        ContractFactoryPlug contractFactoryPlug = new ContractFactoryPlug(address(socket), owner);

        vm.startPrank(owner);
        // socket
        socket.grantRole(GOVERNANCE_ROLE, address(owner));

        // switchboard
        switchboard.registerSwitchboard();
        switchboard.grantWatcherRole(watcherEOA);
        vm.stopPrank();

        hoax(watcherEOA);
        watcherPrecompile.setSwitchboard(chainSlug_, FAST, address(switchboard));

        return
            SocketContracts({
                chainSlug: chainSlug_,
                socket: socket,
                switchboard: switchboard,
                socketBatcher: socketBatcher,
                contractFactoryPlug: contractFactoryPlug,
                feesPlug: feesPlug
            });
    }

    function deployOffChainVMCore() internal {
        // Deploy implementations
        signatureVerifierImpl = new SignatureVerifier();
        addressResolverImpl = new AddressResolver();
        watcherPrecompileImpl = new WatcherPrecompile();
        proxyFactory = new ERC1967Factory();

        // Deploy and initialize proxies
        bytes memory signatureVerifierData = abi.encodeWithSelector(
            SignatureVerifier.initialize.selector,
            owner
        );

        vm.expectEmit(true, true, true, false);
        emit Initialized(1);
        address signatureVerifierProxy = proxyFactory.deployAndCall(
            address(signatureVerifierImpl),
            watcherEOA,
            signatureVerifierData
        );

        bytes memory addressResolverData = abi.encodeWithSelector(
            AddressResolver.initialize.selector,
            watcherEOA
        );
        vm.expectEmit(true, true, true, false);
        emit Initialized(1);
        address addressResolverProxy = proxyFactory.deployAndCall(
            address(addressResolverImpl),
            watcherEOA,
            addressResolverData
        );

        bytes memory watcherPrecompileData = abi.encodeWithSelector(
            WatcherPrecompile.initialize.selector,
            watcherEOA,
            address(addressResolverProxy),
            maxLimit
        );
        vm.expectEmit(true, true, true, false);
        emit Initialized(1);
        address watcherPrecompileProxy = proxyFactory.deployAndCall(
            address(watcherPrecompileImpl),
            watcherEOA,
            watcherPrecompileData
        );

        // Assign proxy addresses to public variables
        signatureVerifier = SignatureVerifier(address(signatureVerifierProxy));
        addressResolver = AddressResolver(address(addressResolverProxy));
        watcherPrecompile = WatcherPrecompile(address(watcherPrecompileProxy));

        hoax(watcherEOA);
        addressResolver.setWatcherPrecompile(address(watcherPrecompile));
    }

    function _createSignature(
        bytes32 digest_,
        uint256 privateKey_
    ) internal pure returns (bytes memory sig) {
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest_));
        (uint8 sigV, bytes32 sigR, bytes32 sigS) = vm.sign(privateKey_, digest);
        sig = new bytes(65);
        bytes1 v32 = bytes1(sigV);

        assembly {
            mstore(add(sig, 96), v32)
            mstore(add(sig, 32), sigR)
            mstore(add(sig, 64), sigS)
        }
    }

    function getSocketConfig(uint32 chainSlug_) internal view returns (SocketContracts memory) {
        return chainSlug_ == arbChainSlug ? arbConfig : optConfig;
    }

    function createFees(uint256 maxFees_) internal view returns (Fees memory) {
        return Fees({feePoolChain: arbChainSlug, feePoolToken: ETH_ADDRESS, amount: maxFees_});
    }

    function relayTx(
        uint32 chainSlug_,
        bytes32 payloadId,
        bytes32 root,
        PayloadDetails memory payloadDetails,
        bytes memory watcherSignature
    ) internal returns (bytes memory) {
        SocketContracts memory socketConfig = getSocketConfig(chainSlug_);
        bytes32 transmitterDigest = keccak256(abi.encode(address(socketConfig.socket), payloadId));
        bytes memory transmitterSig = _createSignature(transmitterDigest, transmitterPrivateKey);

        vm.startPrank(transmitterEOA);
        ExecutePayloadParams memory params = ExecutePayloadParams({
            switchboard: address(socketConfig.switchboard),
            root: root,
            watcherSignature: watcherSignature,
            payloadId: payloadId,
            appGateway: payloadDetails.appGateway,
            executionGasLimit: payloadDetails.executionGasLimit,
            transmitterSignature: transmitterSig,
            payload: payloadDetails.payload,
            target: payloadDetails.target
        });

        bytes memory returnData = socketConfig.socketBatcher.attestAndExecute(params);
        vm.stopPrank();
        return returnData;
    }

    function resolvePromises(bytes32[] memory payloadIds, bytes[] memory returnDatas_) internal {
        for (uint i = 0; i < payloadIds.length; i++) {
            resolvePromise(payloadIds[i], returnDatas_[i]);
        }
    }

    function resolvePromise(bytes32 payloadId, bytes memory returnData) internal {
        ResolvedPromises[] memory resolvedPromises = new ResolvedPromises[](1);

        bytes[] memory returnDatas = new bytes[](2);
        returnDatas[0] = returnData;

        resolvedPromises[0] = ResolvedPromises({payloadId: payloadId, returnData: returnDatas});
        vm.prank(watcherEOA);
        watcherPrecompile.resolvePromises(resolvedPromises);
    }

    function getWritePayloadId(
        uint32 chainSlug_,
        address switchboard_,
        uint256 counter_
    ) internal pure returns (bytes32) {
        return
            bytes32(
                (uint256(chainSlug_) << 224) | (uint256(uint160(switchboard_)) << 64) | counter_
            );
    }

    function getWritePayloadIds(
        uint32 chainSlug_,
        address switchboard_,
        uint256 numPayloads
    ) internal returns (bytes32[] memory) {
        bytes32[] memory payloadIds = new bytes32[](numPayloads);
        for (uint256 i = 0; i < numPayloads; i++) {
            payloadIds[i] = getWritePayloadId(chainSlug_, switchboard_, i + writePayloadIdCounter);
        }

        writePayloadIdCounter += numPayloads;
        return payloadIds;
    }

    function encodeTimeoutId(uint256 timeoutCounter_) internal view returns (bytes32) {
        // watcher address (160 bits) | counter (64 bits)
        return bytes32((uint256(uint160(address(watcherPrecompile))) << 64) | timeoutCounter_);
    }
}
