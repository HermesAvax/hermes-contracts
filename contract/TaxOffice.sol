// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./owner/Operator.sol";
import "./interfaces/ITaxable.sol";

/*
 _    _    ______    ______    _________    ______    _______     
| |  | |  |   ___|  |  __  \  |         |  |   ___|  |  _____|
| |__| |  |  |__    | |  | |  | |\   /| |  |  |__     \ \__
|  __  |  |   __|   | | /_/   | | \_/ | |  |   __|     \__ \
| |  | |  |  |___   | | \ \   | |     | |  |  |___    ____\ \
|_|  |_|  |______|  |_|  \_\  |_|     |_|  |______|  |_______|

*/

contract TaxOffice is Operator {
    address public hermes;

    constructor(address _hermes) public {
        require(_hermes != address(0), "hermes address cannot be 0");
        hermes = _hermes;
    }

    function setTaxTiersTwap(uint8 _index, uint256 _value) public onlyOperator returns (bool) {
        return ITaxable(hermes).setTaxTiersTwap(_index, _value);
    }

    function setTaxTiersRate(uint8 _index, uint256 _value) public onlyOperator returns (bool) {
        return ITaxable(hermes).setTaxTiersRate(_index, _value);
    }

    function enableAutoCalculateTax() public onlyOperator {
        ITaxable(hermes).enableAutoCalculateTax();
    }

    function disableAutoCalculateTax() public onlyOperator {
        ITaxable(hermes).disableAutoCalculateTax();
    }

    function setTaxRate(uint256 _taxRate) public onlyOperator {
        ITaxable(hermes).setTaxRate(_taxRate);
    }

    function setBurnThreshold(uint256 _burnThreshold) public onlyOperator {
        ITaxable(hermes).setBurnThreshold(_burnThreshold);
    }

    function setTaxCollectorAddress(address _taxCollectorAddress) public onlyOperator {
        ITaxable(hermes).setTaxCollectorAddress(_taxCollectorAddress);
    }

    function excludeAddressFromTax(address _address) external onlyOperator returns (bool) {
        return ITaxable(hermes).excludeAddress(_address);
    }

    function includeAddressInTax(address _address) external onlyOperator returns (bool) {
        return ITaxable(hermes).includeAddress(_address);
    }

    function setTaxableHermesOracle(address _hermesOracle) external onlyOperator {
        ITaxable(hermes).setHermesOracle(_hermesOracle);
    }

    function transferTaxOffice(address _newTaxOffice) external onlyOperator {
        ITaxable(hermes).setTaxOffice(_newTaxOffice);
    }
}
