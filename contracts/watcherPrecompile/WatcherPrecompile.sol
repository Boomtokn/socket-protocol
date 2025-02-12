// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.21;

import "./WatcherPrecompileConfig.sol";
import "../interfaces/IAppGateway.sol";
import "../interfaces/IPromise.sol";
import "../interfaces/IFeesManager.sol";
import "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

import {PayloadRootParams, AsyncRequest, FinalizeParams, TimeoutRequest, CallFromInboxParams} from "../common/Structs.sol";
import {TimeoutDelayTooLarge, TimeoutAlreadyResolved, InvalidInboxCaller, ResolvingTimeoutTooEarly, CallFailed, AppGatewayAlreadyCalled} from "../common/Errors.sol";

/// @title WatcherPrecompile
/// @notice Contract that handles payload verification, execution and app configurations
contract WatcherPrecompile is WatcherPrecompileConfig, Initializable {
    uint256 public maxTimeoutDelayInSeconds;
    /// @notice Counter for tracking query requests
    uint256 public queryCounter;
    /// @notice Counter for tracking payload execution requests
    uint256 public payloadCounter;
    /// @notice Counter for tracking timeout requests
    uint256 public timeoutCounter;
    /// @notice The expiry time for the payload
    uint256 public expiryTime;

    /// @notice Mapping to store async requests
    /// @dev payloadId => AsyncRequest struct
    mapping(bytes32 => AsyncRequest) public asyncRequests;
    /// @notice Mapping to store timeout requests
    /// @dev timeoutId => TimeoutRequest struct
    mapping(bytes32 => TimeoutRequest) public timeoutRequests;
    /// @notice Mapping to store watcher signatures
    /// @dev payloadId => signature bytes
    mapping(bytes32 => bytes) public watcherSignatures;

    /// @notice Mapping to store if appGateway has been called with trigger from on-chain Inbox
    /// @dev callId => bool
    mapping(bytes32 => bool) public appGatewayCalled;

    /// @notice Error thrown when an invalid chain slug is provided
    error InvalidChainSlug();
    /// @notice Error thrown when an invalid app gateway reaches a plug
    error InvalidConnection();
    /// @notice Error thrown if winning bid is assigned to an invalid transmitter
    error InvalidTransmitter();

    event CalledAppGateway(
        bytes32 callId,
        uint32 chainSlug,
        address plug,
        address appGateway,
        bytes32 params,
        bytes payload
    );

    /// @notice Emitted when a new query is requested
    /// @param chainSlug The identifier of the destination chain
    /// @param targetAddress The address of the target contract
    /// @param payloadId The unique identifier for the query
    /// @param payload The query data
    event QueryRequested(uint32 chainSlug, address targetAddress, bytes32 payloadId, bytes payload);

    /// @notice Emitted when a finalize request is made
    /// @param payloadId The unique identifier for the request
    /// @param asyncRequest The async request details
    event FinalizeRequested(bytes32 indexed payloadId, AsyncRequest asyncRequest);

    /// @notice Emitted when a request is finalized
    /// @param payloadId The unique identifier for the request
    /// @param asyncRequest The async request details
    /// @param watcherSignature The signature from the watcher
    event Finalized(bytes32 indexed payloadId, AsyncRequest asyncRequest, bytes watcherSignature);

    /// @notice Emitted when a promise is resolved
    /// @param payloadId The unique identifier for the resolved promise
    event PromiseResolved(bytes32 indexed payloadId, bool success, address asyncPromise);

    event TimeoutRequested(
        bytes32 timeoutId,
        address target,
        bytes payload,
        uint256 executeAt // Epoch time when the task should execute
    );

    /// @notice Emitted when a timeout is resolved
    /// @param timeoutId The unique identifier for the timeout
    /// @param target The target address for the timeout
    /// @param payload The payload data
    /// @param executedAt The epoch time when the task was executed
    event TimeoutResolved(bytes32 timeoutId, address target, bytes payload, uint256 executedAt);

    constructor() {
        _disableInitializers(); // disable for implementation
    }

    /// @notice Initializer function to replace constructor
    /// @param owner_ Address of the contract owner
    /// @param addressResolver_ The address resolver contract address
    function initialize(
        address owner_,
        address addressResolver_,
        uint256 maxLimit_
    ) public initializer {
        _setAddressResolver(addressResolver_);
        _claimOwner(owner_);
        maxTimeoutDelayInSeconds = 24 * 60 * 60; // 24 hours

        LIMIT_DECIMALS = 18;

        // limit per day
        maxLimit = maxLimit_ * 10 ** LIMIT_DECIMALS;
        // limit per second
        ratePerSecond = maxLimit / (24 * 60 * 60);
    }

    // ================== Timeout functions ==================

    /// @notice Sets a timeout for a payload execution on app gateway
    /// @param payload_ The payload data
    /// @param delayInSeconds_ The delay in seconds
    function setTimeout(
        address appGateway_,
        bytes calldata payload_,
        uint256 delayInSeconds_
    ) external {
        if (delayInSeconds_ > maxTimeoutDelayInSeconds) revert TimeoutDelayTooLarge();

        // from auction manager
        _consumeLimit(appGateway_, SCHEDULE, 1);
        uint256 executeAt = block.timestamp + delayInSeconds_;
        bytes32 timeoutId = _encodeTimeoutId(timeoutCounter++);
        timeoutRequests[timeoutId] = TimeoutRequest(
            timeoutId,
            msg.sender,
            delayInSeconds_,
            executeAt,
            0,
            false,
            payload_
        );
        emit TimeoutRequested(timeoutId, msg.sender, payload_, executeAt);
    }

    /// @notice Ends the timeouts and calls the target address with the callback payload
    /// @param timeoutId_ The unique identifier for the timeout
    /// @dev Only callable by the contract owner
    function resolveTimeout(bytes32 timeoutId_) external onlyOwner {
        TimeoutRequest storage timeoutRequest_ = timeoutRequests[timeoutId_];
        if (timeoutRequest_.isResolved) revert TimeoutAlreadyResolved();
        if (block.timestamp < timeoutRequest_.executeAt) revert ResolvingTimeoutTooEarly();
        (bool success, ) = address(timeoutRequest_.target).call(timeoutRequest_.payload);
        if (!success) revert CallFailed();
        timeoutRequest_.isResolved = true;
        timeoutRequest_.executedAt = block.timestamp;
        emit TimeoutResolved(
            timeoutId_,
            timeoutRequest_.target,
            timeoutRequest_.payload,
            block.timestamp
        );
    }

    // ================== Finalize functions ==================

    /// @notice Finalizes a payload request, requests the watcher to release the signatures to execute on chain
    /// @param params_ The finalization parameters
    /// @return payloadId The unique identifier for the finalized request
    /// @return root The merkle root of the payload parameters
    function finalize(
        FinalizeParams memory params_,
        address originAppGateway_
    ) external returns (bytes32 payloadId, bytes32 root) {
        if (params_.transmitter == address(0)) revert InvalidTransmitter();

        // The app gateway is the caller of this function
        _consumeLimit(originAppGateway_, FINALIZE, 1);

        // Verify that the app gateway is properly configured for this chain and target
        _verifyConnections(
            params_.payloadDetails.chainSlug,
            params_.payloadDetails.target,
            params_.payloadDetails.appGateway
        );

        // Generate a unique payload ID by combining chain, target, and counter
        payloadId = _encodePayloadId(
            params_.payloadDetails.chainSlug,
            params_.payloadDetails.target,
            payloadCounter++
        );

        // Construct parameters for root calculation
        PayloadRootParams memory rootParams_ = PayloadRootParams(
            params_.payloadDetails.appGateway,
            params_.transmitter,
            params_.payloadDetails.target,
            payloadId,
            params_.payloadDetails.executionGasLimit,
            expiryTime,
            params_.payloadDetails.payload
        );

        // Calculate merkle root from payload parameters
        root = getRoot(rootParams_);

        // Get the switchboard address from plug configurations
        (, address switchboard) = getPlugConfigs(
            params_.payloadDetails.chainSlug,
            params_.payloadDetails.target
        );

        // Create and store the async request with all necessary details
        AsyncRequest memory asyncRequest = AsyncRequest(
            params_.payloadDetails.appGateway,
            params_.transmitter,
            params_.payloadDetails.target,
            switchboard,
            params_.payloadDetails.executionGasLimit,
            params_.asyncId,
            root,
            params_.payloadDetails.payload,
            params_.payloadDetails.next
        );
        asyncRequests[payloadId] = asyncRequest;
        emit FinalizeRequested(payloadId, asyncRequest);
    }

    // ================== Query functions ==================
    /// @notice Creates a new query request
    /// @param chainSlug_ The identifier of the destination chain
    /// @param targetAddress_ The address of the target contract
    /// @param asyncPromises_ Array of promise addresses to be resolved
    /// @param payload_ The query payload data
    /// @return payloadId The unique identifier for the query
    function query(
        uint32 chainSlug_,
        address targetAddress_,
        address appGateway_,
        address[] memory asyncPromises_,
        bytes memory payload_
    ) public returns (bytes32 payloadId) {
        // from payload delivery
        _consumeLimit(appGateway_, QUERY, 1);
        // Generate unique payload ID from query counter
        payloadId = bytes32(queryCounter++);

        // Create async request with minimal information for queries
        // Note: addresses set to 0 as they're not needed for queries
        AsyncRequest memory asyncRequest_ = AsyncRequest(
            address(0),
            address(0),
            targetAddress_,
            address(0),
            0,
            bytes32(0),
            bytes32(0),
            payload_,
            asyncPromises_
        );
        asyncRequests[payloadId] = asyncRequest_;
        emit QueryRequested(chainSlug_, targetAddress_, payloadId, payload_);
    }

    /// @notice Marks a request as finalized with a signature on root
    /// @param payloadId_ The unique identifier of the request
    /// @param signature_ The watcher's signature
    /// @dev Only callable by the contract owner
    function finalized(bytes32 payloadId_, bytes calldata signature_) external onlyOwner {
        watcherSignatures[payloadId_] = signature_;
        emit Finalized(payloadId_, asyncRequests[payloadId_], signature_);
    }

    /// @notice Resolves multiple promises with their return data
    /// @param resolvedPromises_ Array of resolved promises and their return data
    /// @dev Only callable by the contract owner
    function resolvePromises(ResolvedPromises[] calldata resolvedPromises_) external onlyOwner {
        for (uint256 i = 0; i < resolvedPromises_.length; i++) {
            // Get the array of promise addresses for this payload
            AsyncRequest memory asyncRequest_ = asyncRequests[resolvedPromises_[i].payloadId];
            address[] memory next = asyncRequest_.next;

            // Resolve each promise with its corresponding return data
            bool success;
            for (uint256 j = 0; j < next.length; j++) {
                success = IPromise(next[j]).markResolved(
                    asyncRequest_.asyncId,
                    resolvedPromises_[i].payloadId,
                    resolvedPromises_[i].returnData[j]
                );

                if (!success) continue;
                emit PromiseResolved(resolvedPromises_[i].payloadId, success, next[j]);
            }
        }
    }

    // wait till expiry time to assign fees
    function markRevert(bytes32 payloadId_, bool isRevertingOnchain_) external onlyOwner {
        AsyncRequest memory asyncRequest_ = asyncRequests[payloadId_];
        address[] memory next = asyncRequest_.next;

        for (uint256 j = 0; j < next.length; j++) {
            if (isRevertingOnchain_)
                IPromise(next[j]).markOnchainRevert(asyncRequest_.asyncId, payloadId_);

            // assign fees after expiry time
            IFeesManager(asyncRequest_.appGateway).unblockAndAssignFees(
                asyncRequest_.asyncId,
                asyncRequest_.transmitter,
                asyncRequest_.appGateway
            );
        }
    }

    /// @notice Calculates the root hash of payload parameters
    /// @param params_ The payload parameters
    /// @return root The calculated merkle root
    function getRoot(PayloadRootParams memory params_) public pure returns (bytes32 root) {
        root = keccak256(
            abi.encode(
                params_.payloadId,
                params_.appGateway,
                params_.transmitter,
                params_.target,
                params_.executionGasLimit,
                params_.payload
            )
        );
    }

    function setMaxTimeoutDelayInSeconds(uint256 maxTimeoutDelayInSeconds_) external onlyOwner {
        maxTimeoutDelayInSeconds = maxTimeoutDelayInSeconds_;
    }

    // ================== On-Chain Inbox ==================

    function callAppGateways(CallFromInboxParams[] calldata params_) external onlyOwner {
        for (uint256 i = 0; i < params_.length; i++) {
            if (appGatewayCalled[params_[i].callId]) revert AppGatewayAlreadyCalled();
            if (!isValidInboxCaller[params_[i].appGateway][params_[i].chainSlug][params_[i].plug])
                revert InvalidInboxCaller();
            appGatewayCalled[params_[i].callId] = true;
            IAppGateway(params_[i].appGateway).callFromInbox(
                params_[i].chainSlug,
                params_[i].plug,
                params_[i].payload,
                params_[i].params
            );
            emit CalledAppGateway(
                params_[i].callId,
                params_[i].chainSlug,
                params_[i].plug,
                params_[i].appGateway,
                params_[i].params,
                params_[i].payload
            );
        }
    }

    // ================== Helper functions ==================

    /// @notice Verifies the connection between chain slug, target, and app gateway
    /// @param chainSlug_ The identifier of the chain
    /// @param target_ The target address
    /// @param appGateway_ The app gateway address to verify
    /// @dev Internal function to validate connections
    function _verifyConnections(
        uint32 chainSlug_,
        address target_,
        address appGateway_
    ) internal view {
        (address appGateway, ) = getPlugConfigs(chainSlug_, target_);
        if (appGateway != appGateway_) revert InvalidConnection();
    }

    /// @notice Encodes a unique payload ID from chain slug, plug address, and counter
    /// @param chainSlug_ The identifier of the chain
    /// @param plug_ The plug address
    /// @param counter_ The current counter value
    /// @return The encoded payload ID as bytes32
    /// @dev Reverts if chainSlug is 0
    function _encodePayloadId(
        uint32 chainSlug_,
        address plug_,
        uint256 counter_
    ) internal view returns (bytes32) {
        if (chainSlug_ == 0) revert InvalidChainSlug();
        (, address switchboard) = getPlugConfigs(chainSlug_, plug_);
        // Encode payload ID by bit-shifting and combining:
        // chainSlug (32 bits) | switchboard address (160 bits) | counter (64 bits)

        return
            bytes32(
                (uint256(chainSlug_) << 224) | (uint256(uint160(switchboard)) << 64) | counter_
            );
    }

    function _encodeTimeoutId(uint256 timeoutCounter_) internal view returns (bytes32) {
        // watcher address (160 bits) | counter (64 bits)
        return bytes32((uint256(uint160(address(this))) << 64) | timeoutCounter_);
    }

    function setExpiryTime(uint256 expiryTime_) external onlyOwner {
        expiryTime = expiryTime_;
    }
}
