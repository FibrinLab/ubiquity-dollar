// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.19;

import "./IERC20Ubiquity.sol";

/**
 * @notice Ubiquity Governance token interface
 */
interface IUbiquityGovernanceToken is IERC20Ubiquity {
    function pool_burn_from(address account, uint256 amount) external view;
}
