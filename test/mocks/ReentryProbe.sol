// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Records the precise nested-call result; avoids recursive mock callbacks.
contract ReentryProbe {
    address private target;
    bytes private payload;
    bool private entered;
    bool public succeeded;
    bytes4 public failure;

    function configure(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function fire() external {
        if (entered) return;
        entered = true;
        bytes memory output;
        (succeeded, output) = target.call(payload);
        failure = output.length >= 4 ? bytes4(output) : bytes4(0);
        entered = false;
    }
}
