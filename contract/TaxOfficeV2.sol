// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./utils/SafeMath.sol";
import "./owner/Operator.sol";
import "./interfaces/ITaxable.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IERC20.sol";

/*
 _    _    ______    ______    _________    ______    _______     
| |  | |  |   ___|  |  __  \  |         |  |   ___|  |  _____|
| |__| |  |  |__    | |  | |  | |\   /| |  |  |__     \ \__
|  __  |  |   __|   | | /_/   | | \_/ | |  |   __|     \__ \
| |  | |  |  |___   | | \ \   | |     | |  |  |___    ____\ \
|_|  |_|  |______|  |_|  \_\  |_|     |_|  |______|  |_______|

*/

contract TaxOfficeV2 is Operator {
    using SafeMath for uint256;

    address public hermes = address(0x522348779DCb2911539e76A1042aA922F9C47Ee3);
    address public weth = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address public uniRouter = address(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    mapping(address => bool) public taxExclusionEnabled;

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
        return _excludeAddressFromTax(_address);
    }

    function _excludeAddressFromTax(address _address) private returns (bool) {
        if (!ITaxable(hermes).isAddressExcluded(_address)) {
            return ITaxable(hermes).excludeAddress(_address);
        }
    }

    function includeAddressInTax(address _address) external onlyOperator returns (bool) {
        return _includeAddressInTax(_address);
    }

    function _includeAddressInTax(address _address) private returns (bool) {
        if (ITaxable(hermes).isAddressExcluded(_address)) {
            return ITaxable(hermes).includeAddress(_address);
        }
    }

    function taxRate() external returns (uint256) {
        return ITaxable(hermes).taxRate();
    }

    function addLiquidityTaxFree(
        address token,
        uint256 amtHermes,
        uint256 amtToken,
        uint256 amtHermesMin,
        uint256 amtTokenMin
    )
        external
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        require(amtHermes != 0 && amtToken != 0, "amounts can't be 0");
        _excludeAddressFromTax(msg.sender);

        IERC20(hermes).transferFrom(msg.sender, address(this), amtHermes);
        IERC20(token).transferFrom(msg.sender, address(this), amtToken);
        _approveTokenIfNeeded(hermes, uniRouter);
        _approveTokenIfNeeded(token, uniRouter);

        _includeAddressInTax(msg.sender);

        uint256 resultAmtHermes;
        uint256 resultAmtToken;
        uint256 liquidity;
        (resultAmtHermes, resultAmtToken, liquidity) = IUniswapV2Router(uniRouter).addLiquidity(
            hermes,
            token,
            amtHermes,
            amtToken,
            amtHermesMin,
            amtTokenMin,
            msg.sender,
            block.timestamp
        );

        if (amtHermes.sub(resultAmtHermes) > 0) {
            IERC20(hermes).transfer(msg.sender, amtHermes.sub(resultAmtHermes));
        }
        if (amtToken.sub(resultAmtToken) > 0) {
            IERC20(token).transfer(msg.sender, amtToken.sub(resultAmtToken));
        }
        return (resultAmtHermes, resultAmtToken, liquidity);
    }

    function addLiquidityETHTaxFree(
        uint256 amtHermes,
        uint256 amtHermesMin,
        uint256 amtEthMin
    )
        external
        payable
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        require(amtHermes != 0 && msg.value != 0, "amounts can't be 0");
        _excludeAddressFromTax(msg.sender);

        IERC20(hermes).transferFrom(msg.sender, address(this), amtHermes);
        _approveTokenIfNeeded(hermes, uniRouter);

        _includeAddressInTax(msg.sender);

        uint256 resultAmtHermes;
        uint256 resultAmtEth;
        uint256 liquidity;
        (resultAmtHermes, resultAmtEth, liquidity) = IUniswapV2Router(uniRouter).addLiquidityETH{value: msg.value}(
            hermes,
            amtHermes,
            amtHermesMin,
            amtEthMin,
            msg.sender,
            block.timestamp
        );

        if (amtHermes.sub(resultAmtHermes) > 0) {
            IERC20(hermes).transfer(msg.sender, amtHermes.sub(resultAmtHermes));
        }
        return (resultAmtHermes, resultAmtEth, liquidity);
    }

    function setTaxableHermesOracle(address _hermesOracle) external onlyOperator {
        ITaxable(hermes).setHermesOracle(_hermesOracle);
    }

    function transferTaxOffice(address _newTaxOffice) external onlyOperator {
        ITaxable(hermes).setTaxOffice(_newTaxOffice);
    }

    function taxFreeTransferFrom(
        address _sender,
        address _recipient,
        uint256 _amt
    ) external {
        require(taxExclusionEnabled[msg.sender], "Address not approved for tax free transfers");
        _excludeAddressFromTax(_sender);
        IERC20(hermes).transferFrom(_sender, _recipient, _amt);
        _includeAddressInTax(_sender);
    }

    function setTaxExclusionForAddress(address _address, bool _excluded) external onlyOperator {
        taxExclusionEnabled[_address] = _excluded;
    }

    function _approveTokenIfNeeded(address _token, address _router) private {
        if (IERC20(_token).allowance(address(this), _router) == 0) {
            IERC20(_token).approve(_router, type(uint256).max);
        }
    }
}
