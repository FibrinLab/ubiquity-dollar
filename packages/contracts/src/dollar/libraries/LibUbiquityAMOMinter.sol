// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {LibAppStorage} from "./LibAppStorage.sol";
import {Modifiers} from "../libraries/LibAppStorage.sol";
import "./Constants.sol";
import "../interfaces/IAMO.sol";
import "../interfaces/IUbiquityDollarToken.sol";
import "../interfaces/IUbiquityGovernance.sol";
// import "../interfaces/IERC20Ubiquity.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IUbiquityAMOPool.sol";

/**
 * @notice Bonding curve library based on Bancor formula
 * @notice Inspired from Bancor protocol https://github.com/bancorprotocol/contracts
 * @notice Used on UbiquiStick NFT minting
 */
library LibUbiquityAMOMinter {
    bytes32 constant AMOMINTER_CONTROL_STORAGE_SLOT =
        bytes32(uint256(keccak256("ubiquity.contracts.amominter.storage")) - 1);

    struct AmoPoolData {
        uint256 uadDollarBalanceStored;
        uint256 collatDollarBalanceStored;
        uint256 missing_decimals;
        uint256 min_cr;
        uint256 col_idx;
        int256 uad_mint_sum;
        int256 gov_mint_sum;
        int256 collat_borrowed_sum;
        int256 collat_borrow_cap;
        int256 uad_mint_cap;
        int256 gov_mint_cap;
        address[] amos_array;
        address collateral_address;
        address custodian_address;
        address timelock_address;
        IERC20 collateral;
        IUbiquityDollarToken UAD;
        IUbiquityGovernanceToken GOV;
        IUbiquityAMOPool POOL;
        mapping(address => bool) amos;
        mapping(address => int256[2]) correction_offsets_amos;
        mapping(address => int256) uad_mint_balances;
        mapping(address => int256) gov_mint_balances;
        mapping(address => int256) collat_borrowed_balances;
    }

    event AMOAdded(address amo_address);
    event AMORemoved(address amo_address);
    event Recovered(address token, uint256 amount);

    /**
     * @notice Returns struct used as a storage for this library
     * @return l Struct used as a storage
     */
    function amoMinterStorage() internal pure returns (AmoPoolData storage l) {
        bytes32 slot = AMOMINTER_CONTROL_STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }

    function collatDollarBalance() external view returns (uint256) {
        (, uint256 collat_val_e18) = dollarBalances();
        return collat_val_e18;
    }

    function dollarBalances()
        internal
        view
        returns (uint256 uad_val_e18, uint256 collat_val_e18)
    {
        uad_val_e18 = amoMinterStorage().uadDollarBalanceStored;
        collat_val_e18 = amoMinterStorage().collatDollarBalanceStored;
    }

    function allAMOAddresses() internal view returns (address[] memory) {
        return amoMinterStorage().amos_array;
    }

    function allAMOsLength() internal view returns (uint256) {
        return amoMinterStorage().amos_array.length;
    }

    function uADTrackedGlobal() internal view returns (int256) {
        return
            int256(amoMinterStorage().uadDollarBalanceStored) -
            amoMinterStorage().uad_mint_sum -
            (amoMinterStorage().collat_borrowed_sum *
                int256(10 ** amoMinterStorage().missing_decimals));
    }

    function uADTrackedAMO(
        address _amo_address
    ) internal view returns (int256) {
        (uint256 uad_val_e18, ) = IAMO(_amo_address).dollarBalances();
        int256 uad_val_e18_corrected = int256(uad_val_e18) +
            amoMinterStorage().correction_offsets_amos[_amo_address][0];
        return
            uad_val_e18_corrected -
            amoMinterStorage().uad_mint_balances[_amo_address] -
            ((amoMinterStorage().collat_borrowed_balances[_amo_address]) *
                int256(10 ** amoMinterStorage().missing_decimals));
    }

    function syncDollarBalances() internal {
        uint256 total_uad_value_d18 = 0;
        uint256 total_collateral_value_d18 = 0;
        for (uint i = 0; i < amoMinterStorage().amos_array.length; i++) {
            // Exclude null addresses
            address amo_address = amoMinterStorage().amos_array[i];
            if (amo_address != address(0)) {
                (uint256 uad_val_e18, uint256 collat_val_e18) = IAMO(
                    amo_address
                ).dollarBalances();
                total_uad_value_d18 += uint256(
                    int256(uad_val_e18) +
                        amoMinterStorage().correction_offsets_amos[amo_address][
                            0
                        ]
                );
                total_collateral_value_d18 += uint256(
                    int256(collat_val_e18) +
                        amoMinterStorage().correction_offsets_amos[amo_address][
                            1
                        ]
                );
            }
        }
        amoMinterStorage().uadDollarBalanceStored = total_uad_value_d18;
        amoMinterStorage()
            .collatDollarBalanceStored = total_collateral_value_d18;
    }

    function mintUadForAMO(
        address _destination_amo,
        uint256 _uad_amount
    ) internal {
        require(amoMinterStorage().amos[_destination_amo], "Invalid AMO");

        int256 uad_amt_i256 = int256(_uad_amount);

        // Make sure you aren't minting more than the mint cap
        require(
            (amoMinterStorage().uad_mint_sum + uad_amt_i256) <= UAD_MINT_CAP,
            "Mint cap reached"
        );
        amoMinterStorage().uad_mint_balances[_destination_amo] += uad_amt_i256;
        amoMinterStorage().uad_mint_sum += uad_amt_i256;

        // Make sure the UAD minting wouldn't push the CR down too much
        // This is also a sanity check for the int256 math
        uint256 current_collateral_E18 = amoMinterStorage()
            .UAD
            .globalCollateralValue();
        uint256 cur_uad_supply = amoMinterStorage().UAD.totalSupply();
        uint256 new_uad_supply = cur_uad_supply + _uad_amount;
        uint256 new_cr = (current_collateral_E18 * PRICE_PRECISION) /
            new_uad_supply;
        require(new_cr >= MIN_CR, "CR would be too low");

        // Mint the FRAX to the AMO
        amoMinterStorage().UAD.mint(_destination_amo, _uad_amount);

        // Sync
        syncDollarBalances();
    }

    function burnUadFromAMO(uint256 _uad_amount) internal {
        require(amoMinterStorage().amos[msg.sender], "Invalid AMO");

        int256 uad_amt_i256 = int256(_uad_amount);

        // Burn first
        amoMinterStorage().UAD.pool_burn_from(msg.sender, _uad_amount);

        // Then update the balances
        amoMinterStorage().uad_mint_balances[msg.sender] -= uad_amt_i256;
        amoMinterStorage().uad_mint_sum -= uad_amt_i256;

        // Sync
        syncDollarBalances();
    }

    function initialize(
        address _uad_addr,
        address _gov_addr,
        address _collateral_token
    ) internal {
        amoMinterStorage().UAD = IUbiquityDollarToken(_uad_addr);
        amoMinterStorage().GOV = IUbiquityGovernanceToken(_gov_addr);
        amoMinterStorage().collateral = IERC20(_collateral_token);
    }

    // ------------------------------------------------------------------
    // ------------------------------- GOV ------------------------------
    // ------------------------------------------------------------------

    function mintGovForAMO(
        address _destination_amo,
        uint256 _gov_amount
    ) internal {
        require(amoMinterStorage().amos[_destination_amo], "Invalid AMO");
        int256 gov_amt_i256 = int256(_gov_amount);

        // Make sure you aren't minting more than the mint cap
        require(
            (amoMinterStorage().gov_mint_sum + gov_amt_i256) <= GOV_MINT_CAP,
            "Mint cap reached"
        );
        amoMinterStorage().gov_mint_balances[_destination_amo] += gov_amt_i256;
        amoMinterStorage().gov_mint_sum += gov_amt_i256;

        // Mint the FXS to the AMO
        amoMinterStorage().GOV.mint(_destination_amo, _gov_amount);

        // Sync
        syncDollarBalances();
    }

    function burnGovFromAMO(uint256 _gov_amount) external {
        require(amoMinterStorage().amos[msg.sender], "Invalid AMO");
        int256 gov_amt_i256 = int256(_gov_amount);

        // Burn first
        amoMinterStorage().GOV.pool_burn_from(msg.sender, _gov_amount);

        // Then update the balances
        amoMinterStorage().gov_mint_balances[msg.sender] -= gov_amt_i256;
        amoMinterStorage().gov_mint_sum -= gov_amt_i256;

        // Sync
        syncDollarBalances();
    }

    // ------------------------------------------------------------------
    // --------------------------- Collateral ---------------------------
    // ------------------------------------------------------------------

    function giveCollatToAMO(
        address _destination_amo,
        uint256 _collateral_amount
    ) internal {
        require(amoMinterStorage().amos[_destination_amo], "Invalid AMO");
        int256 collat_amount_i256 = int256(_collateral_amount);

        require(
            (amoMinterStorage().collat_borrowed_sum + collat_amount_i256) <=
                amoMinterStorage().collat_borrow_cap,
            "Borrow cap"
        );
        amoMinterStorage().collat_borrowed_balances[
            _destination_amo
        ] += collat_amount_i256;
        amoMinterStorage().collat_borrowed_sum += collat_amount_i256;

        // Borrow the collateral
        amoMinterStorage().POOL.amoMinterBorrow(_collateral_amount);

        // Give the collateral to the AMO
        address collateral_address = amoMinterStorage().collateral_address;
        IERC20(collateral_address).transfer(
            _destination_amo,
            _collateral_amount
        );

        // Sync
        syncDollarBalances();
    }

    function receiveCollatFromAMO(uint256 usdc_amount) internal {
        require(amoMinterStorage().amos[msg.sender], "Invalid AMO");
        int256 collat_amt_i256 = int256(usdc_amount);

        // Give back first
        IERC20 collateral = amoMinterStorage().collateral;
        address pool = address(amoMinterStorage().POOL);
        SafeERC20.safeTransferFrom(collateral, msg.sender, pool, usdc_amount);

        // Then update the balances
        amoMinterStorage().collat_borrowed_balances[
            msg.sender
        ] -= collat_amt_i256;
        amoMinterStorage().collat_borrowed_sum -= collat_amt_i256;

        // Sync
        syncDollarBalances();
    }

    // Adds an AMO
    function addAMO(address _amo_address, bool _sync_too) internal {
        require(_amo_address != address(0), "Zero address detected");

        (uint256 uad_val_e18, uint256 collat_val_e18) = IAMO(_amo_address)
            .dollarBalances();
        require(uad_val_e18 >= 0 && collat_val_e18 >= 0, "Invalid AMO");

        require(
            amoMinterStorage().amos[_amo_address] == false,
            "Address already exists"
        );
        amoMinterStorage().amos[_amo_address] = true;
        amoMinterStorage().amos_array.push(_amo_address);

        // Mint balances
        amoMinterStorage().uad_mint_balances[_amo_address] = 0;
        amoMinterStorage().gov_mint_balances[_amo_address] = 0;
        amoMinterStorage().collat_borrowed_balances[_amo_address] = 0;

        // Offsets
        amoMinterStorage().correction_offsets_amos[_amo_address][0] = 0;
        amoMinterStorage().correction_offsets_amos[_amo_address][1] = 0;

        if (_sync_too) syncDollarBalances();

        emit AMOAdded(_amo_address);
    }

    // Removes an AMO
    function removeAMO(address _amo_address, bool _sync_too) external {
        require(_amo_address != address(0), "Zero address detected");
        require(
            amoMinterStorage().amos[_amo_address] == true,
            "Address nonexistent"
        );

        // Delete from the mapping
        delete amoMinterStorage().amos[_amo_address];

        // 'Delete' from the array by setting the address to 0x0
        for (uint i = 0; i < amoMinterStorage().amos_array.length; i++) {
            if (amoMinterStorage().amos_array[i] == _amo_address) {
                amoMinterStorage().amos_array[i] = address(0); // This will leave a null in the array and keep the indices the same
                break;
            }
        }

        if (_sync_too) syncDollarBalances();

        emit AMORemoved(_amo_address);
    }

    function setTimelock(address _new_timelock) internal {
        require(_new_timelock != address(0), "Timelock address cannot be 0");
        amoMinterStorage().timelock_address = _new_timelock;
    }

    function setCustodian(address _custodian_address) internal {
        require(
            _custodian_address != address(0),
            "Custodian address cannot be 0"
        );
        amoMinterStorage().custodian_address = _custodian_address;
    }

    function setUadMintCap(uint256 _uad_mint_cap) internal {
        amoMinterStorage().uad_mint_cap = int256(_uad_mint_cap);
    }

    function setGovMintCap(uint256 _gov_mint_cap) internal {
        amoMinterStorage().uad_mint_cap = int256(_gov_mint_cap);
    }

    function setCollatBorrowCap(uint256 _collat_borrow_cap) internal {
        amoMinterStorage().collat_borrow_cap = int256(_collat_borrow_cap);
    }

    function setMinimumCollateralRatio(uint256 _min_cr) internal {
        amoMinterStorage().min_cr = _min_cr;
    }

    function setAMOCorrectionOffsets(
        address _amo_address,
        int256 _uad_e18_correction,
        int256 _collat_e18_correction
    ) internal {
        amoMinterStorage().correction_offsets_amos[_amo_address][
            0
        ] = _uad_e18_correction;
        amoMinterStorage().correction_offsets_amos[_amo_address][
            1
        ] = _collat_e18_correction;

        syncDollarBalances();
    }

    function setUadPool(address _pool_address) internal {
        amoMinterStorage().POOL = IUbiquityAMOPool(_pool_address);

        // Make sure the collaterals match, or balances could get corrupted
        require(
            amoMinterStorage().POOL.collateralAddrToIdx(
                amoMinterStorage().collateral_address
            ) == amoMinterStorage().col_idx,
            "col_idx mismatch"
        );
    }

    function recoverERC20(
        address _tokenAddress,
        address _owner,
        uint256 _tokenAmount
    ) internal {
        // Can only be triggered by owner or governance
        IERC20(_tokenAddress).transfer(_owner, _tokenAmount);

        emit Recovered(_tokenAddress, _tokenAmount);
    }

    // Generic proxy
    function execute(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) internal returns (bool, bytes memory) {
        (bool success, bytes memory result) = _to.call{value: _value}(_data);
        return (success, result);
    }
}
