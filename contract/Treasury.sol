// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IOlympus.sol";

/*
 _    _    ______    ______    _________    ______    _______     
| |  | |  |   ___|  |  __  \  |         |  |   ___|  |  _____|
| |__| |  |  |__    | |  | |  | |\   /| |  |  |__     \ \__
|  __  |  |   __|   | | /_/   | | \_/ | |  |   __|     \__ \
| |  | |  |  |___   | | \ \   | |     | |  |  |___    ____\ \
|_|  |_|  |______|  |_|  \_\  |_|     |_|  |______|  |_______|

*/
contract Treasury is ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 6 hours;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // core components
    address public hermes;
    address public bbond;
    address public bshare;

    address public olympus;
    address public hermesOracle;

    // price
    uint256 public hermesPriceOne;
    uint256 public hermesPriceCeiling;

    uint256 public seigniorageSaved;

    uint256[] public supplyTiers;
    uint256[] public maxExpansionTiers;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 28 first epochs (1 week) with 4.5% expansion regardless of HERMES price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    /* =================== Added variables =================== */
    uint256 public previousEpochHermesPrice;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumThreshold;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra HERMES during debt phase

    address public daoFund;
    uint256 public daoFundSharedPercent;

    address public devFund;
    uint256 public devFundSharedPercent;
    address public team1Fund;
    uint256 public team1FundSharedPercent;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address indexed from, uint256 hermesAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 hermesAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event OlympusFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event DevFundFunded(uint256 timestamp, uint256 seigniorage);
    event TeamFundFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Treasury: caller is not the operator");
        _;
    }

    modifier checkCondition() {
        require(now >= startTime, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch() {
        require(now >= nextEpochPoint(), "Treasury: not opened yet");

        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = (getHermesPrice() > hermesPriceCeiling) ? 0 : getHermesCirculatingSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator() {
        require(
            IBasisAsset(hermes).operator() == address(this) &&
                IBasisAsset(bbond).operator() == address(this) &&
                IBasisAsset(bshare).operator() == address(this) &&
                Operator(olympus).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized() {
        require(!initialized, "Treasury: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getHermesPrice() public view returns (uint256 hermesPrice) {
        try IOracle(hermesOracle).consult(hermes, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult HERMES price from the oracle");
        }
    }

    function getHermesUpdatedPrice() public view returns (uint256 _hermesPrice) {
        try IOracle(hermesOracle).twap(hermes, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult HERMES price from the oracle");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableHermesLeft() public view returns (uint256 _burnableHermesLeft) {
        uint256 _hermesPrice = getHermesPrice();
        if (_hermesPrice <= hermesPriceOne) {
            uint256 _hermesSupply = getHermesCirculatingSupply();
            uint256 _bondMaxSupply = _hermesSupply.mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(bbond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableHermes = _maxMintableBond.mul(_hermesPrice).div(1e18);
                _burnableHermesLeft = Math.min(epochSupplyContractionLeft, _maxBurnableHermes);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256 _hermesPrice = getHermesPrice();
        if (_hermesPrice > hermesPriceCeiling) {
            uint256 _totalHermes = IERC20(hermes).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalHermes.mul(1e18).div(_rate);
            }
        }
    }

    function getBondDiscountRate() public view returns (uint256 _rate) {
        uint256 _hermesPrice = getHermesPrice();
        if (_hermesPrice <= hermesPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = hermesPriceOne;
            } else {
                uint256 _bondAmount = hermesPriceOne.mul(1e18).div(_hermesPrice); // to burn 1 HERMES
                uint256 _discountAmount = _bondAmount.sub(hermesPriceOne).mul(discountPercent).div(10000);
                _rate = hermesPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public view returns (uint256 _rate) {
        uint256 _hermesPrice = getHermesPrice();
        if (_hermesPrice > hermesPriceCeiling) {
            uint256 _hermesPricePremiumThreshold = hermesPriceOne.mul(premiumThreshold).div(100);
            if (_hermesPrice >= _hermesPricePremiumThreshold) {
                //Price > 1.10
                uint256 _premiumAmount = _hermesPrice.sub(hermesPriceOne).mul(premiumPercent).div(10000);
                _rate = hermesPriceOne.add(_premiumAmount);
                if (maxPremiumRate > 0 && _rate > maxPremiumRate) {
                    _rate = maxPremiumRate;
                }
            } else {
                // no premium bonus
                _rate = hermesPriceOne;
            }
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _hermes,
        address _bbond,
        address _bshare,
        address _hermesOracle,
        address _olympus,
        uint256 _startTime
    ) public notInitialized {
        hermes = _hermes;
        bbond = _bbond;
        bshare = _bshare;
        hermesOracle = _hermesOracle;
        olympus = _olympus;
        startTime = _startTime;

        hermesPriceOne = 10**18; // This is to allow a PEG of 1 HERMES per AVAX
        hermesPriceCeiling = hermesPriceOne.mul(101).div(100);

        // Dynamic max expansion percent
        supplyTiers = [0 ether, 5000 ether, 10000 ether, 15000 ether, 20000 ether, 50000 ether, 100000 ether, 200000 ether, 500000 ether];
        maxExpansionTiers = [450, 400, 350, 300, 250, 200, 150, 125, 100];

        maxSupplyExpansionPercent = 400; // Upto 4.0% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for olympus
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn HERMES and mint tBOND)
        maxDebtRatioPercent = 4500; // Upto 35% supply of tBOND to purchase

        premiumThreshold = 110;
        premiumPercent = 7000;

        // First 28 epochs with 4.5% expansion
        bootstrapEpochs = 0;
        bootstrapSupplyExpansionPercent = 450;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(hermes).balanceOf(address(this));

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setOlympus(address _olympus) external onlyOperator {
        olympus = _olympus;
    }

    function setHermesOracle(address _hermesOracle) external onlyOperator {
        hermesOracle = _hermesOracle;
    }

    function setHermesPriceCeiling(uint256 _hermesPriceCeiling) external onlyOperator {
        require(_hermesPriceCeiling >= hermesPriceOne && _hermesPriceCeiling <= hermesPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        hermesPriceCeiling = _hermesPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setSupplyTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        if (_index > 0) {
            require(_value > supplyTiers[_index - 1]);
        }
        if (_index < 8) {
            require(_value < supplyTiers[_index + 1]);
        }
        supplyTiers[_index] = _value;
        return true;
    }

    function setMaxExpansionTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        require(_value >= 10 && _value <= 1000, "_value: out of range"); // [0.1%, 10%]
        maxExpansionTiers[_index] = _value;
        return true;
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent) external onlyOperator {
        require(_maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function setBootstrap(uint256 _bootstrapEpochs, uint256 _bootstrapSupplyExpansionPercent) external onlyOperator {
        require(_bootstrapEpochs <= 120, "_bootstrapEpochs: out of range"); // <= 1 month
        require(_bootstrapSupplyExpansionPercent >= 100 && _bootstrapSupplyExpansionPercent <= 1000, "_bootstrapSupplyExpansionPercent: out of range"); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setExtraFunds(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _devFund,
        uint256 _devFundSharedPercent,
        address _team1Fund,
        uint256 _team1FundSharedPercent
    ) external onlyOperator {
        require(_daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 3000, "out of range"); // <= 30%
        require(_devFund != address(0), "zero");
        require(_devFundSharedPercent <= 500, "out of range"); // <= 5%
        require(_team1Fund != address(0), "zero");
        require(_team1FundSharedPercent <= 500, "out of range"); // <= 5%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        devFund = _devFund;
        devFundSharedPercent = _devFundSharedPercent;
        team1Fund = _team1Fund;
        team1FundSharedPercent = _team1FundSharedPercent;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOperator {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "_discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumThreshold(uint256 _premiumThreshold) external onlyOperator {
        require(_premiumThreshold >= hermesPriceCeiling, "_premiumThreshold exceeds hermesPriceCeiling");
        require(_premiumThreshold <= 150, "_premiumThreshold is higher than 1.5");
        premiumThreshold = _premiumThreshold;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "_premiumPercent is over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOperator {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateHermesPrice() internal {
        try IOracle(hermesOracle).update() {} catch {}
    }

    function getHermesCirculatingSupply() public view returns (uint256) {
        IERC20 hermesErc20 = IERC20(hermes);
        uint256 totalSupply = hermesErc20.totalSupply();
        uint256 balanceExcluded = 0;
        return totalSupply.sub(balanceExcluded);
    }

    function buyBonds(uint256 _hermesAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_hermesAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 hermesPrice = getHermesPrice();
        require(hermesPrice == targetPrice, "Treasury: HERMES price moved");
        require(
            hermesPrice < hermesPriceOne, // price < $1
            "Treasury: hermesPrice not eligible for bond purchase"
        );

        require(_hermesAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _bondAmount = _hermesAmount.mul(_rate).div(1e18);
        uint256 hermesSupply = getHermesCirculatingSupply();
        uint256 newBondSupply = IERC20(bbond).totalSupply().add(_bondAmount);
        require(newBondSupply <= hermesSupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(hermes).burnFrom(msg.sender, _hermesAmount);
        IBasisAsset(bbond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_hermesAmount);
        _updateHermesPrice();

        emit BoughtBonds(msg.sender, _hermesAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 hermesPrice = getHermesPrice();
        require(hermesPrice == targetPrice, "Treasury: HERMES price moved");
        require(
            hermesPrice > hermesPriceCeiling, // price > $1.01
            "Treasury: hermesPrice not eligible for bond purchase"
        );

        uint256 _rate = getBondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _hermesAmount = _bondAmount.mul(_rate).div(1e18);
        require(IERC20(hermes).balanceOf(address(this)) >= _hermesAmount, "Treasury: treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _hermesAmount));

        IBasisAsset(bbond).burnFrom(msg.sender, _bondAmount);
        IERC20(hermes).safeTransfer(msg.sender, _hermesAmount);

        _updateHermesPrice();

        emit RedeemedBonds(msg.sender, _hermesAmount, _bondAmount);
    }

    function _sendToOlympus(uint256 _amount) internal {
        IBasisAsset(hermes).mint(address(this), _amount);

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(hermes).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(now, _daoFundSharedAmount);
        }

        uint256 _devFundSharedAmount = 0;
        if (devFundSharedPercent > 0) {
            _devFundSharedAmount = _amount.mul(devFundSharedPercent).div(10000);
            IERC20(hermes).transfer(devFund, _devFundSharedAmount);
            emit DevFundFunded(now, _devFundSharedAmount);
        }

        uint256 _team1FundSharedAmount = 0;
        if (team1FundSharedPercent > 0) {
            _team1FundSharedAmount = _amount.mul(team1FundSharedPercent).div(10000);
            IERC20(hermes).transfer(team1Fund, _team1FundSharedAmount);
            emit TeamFundFunded(now, _team1FundSharedAmount);
        }

        _amount = _amount.sub(_daoFundSharedAmount).sub(_devFundSharedAmount).sub(_team1FundSharedAmount);

        IERC20(hermes).safeApprove(olympus, 0);
        IERC20(hermes).safeApprove(olympus, _amount);
        IOlympus(olympus).allocateSeigniorage(_amount);
        emit OlympusFunded(now, _amount);
    }

    function _calculateMaxSupplyExpansionPercent(uint256 _hermesSupply) internal returns (uint256) {
        for (uint8 tierId = 8; tierId >= 0; --tierId) {
            if (_hermesSupply >= supplyTiers[tierId]) {
                maxSupplyExpansionPercent = maxExpansionTiers[tierId];
                break;
            }
        }
        return maxSupplyExpansionPercent;
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updateHermesPrice();
        previousEpochHermesPrice = getHermesPrice();
        uint256 hermesSupply = getHermesCirculatingSupply().sub(seigniorageSaved);
        if (epoch < bootstrapEpochs) {
            // 28 first epochs with 4.5% expansion
            _sendToOlympus(hermesSupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochHermesPrice > hermesPriceCeiling) {
                // Expansion ($HERMES Price > 1 $ETH): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(bbond).totalSupply();
                uint256 _percentage = previousEpochHermesPrice.sub(hermesPriceOne);
                uint256 _savedForBond;
                uint256 _savedForOlympus;
                uint256 _mse = _calculateMaxSupplyExpansionPercent(hermesSupply).mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForOlympus = hermesSupply.mul(_percentage).div(1e18);
                } else {
                    // have not saved enough to pay debt, mint more
                    uint256 _seigniorage = hermesSupply.mul(_percentage).div(1e18);
                    _savedForOlympus = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForOlympus);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForOlympus > 0) {
                    _sendToOlympus(_savedForOlympus);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(hermes).mint(address(this), _savedForBond);
                    emit TreasuryFunded(now, _savedForBond);
                }
            }
        }
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(hermes), "hermes");
        require(address(_token) != address(bbond), "bond");
        require(address(_token) != address(bshare), "share");
        _token.safeTransfer(_to, _amount);
    }

    function olympusSetOperator(address _operator) external onlyOperator {
        IOlympus(olympus).setOperator(_operator);
    }

    function olympusSetLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        IOlympus(olympus).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function olympusAllocateSeigniorage(uint256 amount) external onlyOperator {
        IOlympus(olympus).allocateSeigniorage(amount);
    }

    function olympusGovernanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        IOlympus(olympus).governanceRecoverUnsupported(_token, _amount, _to);
    }
}
