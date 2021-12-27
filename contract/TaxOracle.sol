// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
 _    _    ______    ______    _________    ______    _______     
| |  | |  |   ___|  |  __  \  |         |  |   ___|  |  _____|
| |__| |  |  |__    | |  | |  | |\   /| |  |  |__     \ \__
|  __  |  |   __|   | | /_/   | | \_/ | |  |   __|     \__ \
| |  | |  |  |___   | | \ \   | |     | |  |  |___    ____\ \
|_|  |_|  |______|  |_|  \_\  |_|     |_|  |______|  |_______|

*/


contract TaxOracle is Ownable {
    using SafeMath for uint256;

    IERC20 public hermes;
    IERC20 public wavax;
    address public pair;

    constructor(
        address _hermes,
        address _wavax,
        address _pair
    ) public {
        require(_hermes != address(0), "hermes address cannot be 0");
        require(_wavax != address(0), "wavax address cannot be 0");
        require(_pair != address(0), "pair address cannot be 0");
        hermes = IERC20(_hermes);
        wavax = IERC20(_wavax);
        pair = _pair;
    }

    function consult(address _token, uint256 _amountIn) external view returns (uint144 amountOut) {
        require(_token == address(hermes), "token needs to be hermes");
        uint256 hermesBalance = hermes.balanceOf(pair);
        uint256 wavaxBalance = wavax.balanceOf(pair);
        return uint144(hermesBalance.mul(_amountIn).div(wavaxBalance));
    }

    function getHermesBalance() external view returns (uint256) {
	return hermes.balanceOf(pair);
    }

    function getBtcbBalance() external view returns (uint256) {
	return wavax.balanceOf(pair);
    }

    function getPrice() external view returns (uint256) {
        uint256 hermesBalance = hermes.balanceOf(pair);
        uint256 wavaxBalance = wavax.balanceOf(pair);
        return hermesBalance.mul(1e18).div(wavaxBalance);
    }

    function setHermes(address _hermes) external onlyOwner {
        require(_hermes != address(0), "hermes address cannot be 0");
        hermes = IERC20(_hermes);
    }

    function setWavax(address _wavax) external onlyOwner {
        require(_wavax != address(0), "wavax address cannot be 0");
        wavax = IERC20(_wavax);
    }

    function setPair(address _pair) external onlyOwner {
        require(_pair != address(0), "pair address cannot be 0");
        pair = _pair;
    }
}