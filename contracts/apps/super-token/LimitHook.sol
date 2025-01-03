// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "../../utils/Ownable.sol";
import {PlugBase} from "../../base/PlugBase.sol";

contract LimitHook is Ownable, PlugBase {
    // Define any state variables or functions for the LimitHook contract here
    uint256 public burnLimit;
    uint256 public mintLimit;

    error BurnLimitExceeded();
    error MintLimitExceeded();

    constructor(
        uint256 _burnLimit,
        uint256 _mintLimit,
        address socket_,
        uint32 chainSlug_
    ) Ownable(msg.sender) PlugBase(socket_, chainSlug_) {
        burnLimit = _burnLimit;
        mintLimit = _mintLimit;
    }

    function setLimits(
        uint256 _burnLimit,
        uint256 _mintLimit
    ) external onlyOwner {
        burnLimit = _burnLimit;
        mintLimit = _mintLimit;
    }

    function beforeBurn(uint256 amount_) external view {
        if (amount_ > burnLimit) revert BurnLimitExceeded();
    }

    function beforeMint(uint256 amount_) external view {
        if (amount_ > mintLimit) revert MintLimitExceeded();
    }

    function connectSocket(
        address appGateway_,
        address switchboard_
    ) external onlyOwner {
        _connectSocket(appGateway_, switchboard_);
    }
}
