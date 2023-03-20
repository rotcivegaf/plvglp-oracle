//SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./Interfaces/GLPManagerInterface.sol";
import "./Interfaces/plvGLPInterface.sol";
import "./Interfaces/ERC20Interface.sol";
import "./Whitelist.sol";

//TODO: optimize integer sizes for gas efficiency?

/** @title Oracle for Plutus Vault GLP employing moving average calculations for pricing
    @author Lodestar Finance
    @notice This contract uses a moving average calculation to report a plvGLP/GLP exchange
    rate. The "window size" is adjustable to allow for flexibility in calculation parameters. The price
    returned from the getPlvGLPPrice function is denominated in USD wei.
*/
contract PlvGLPOracle is Ownable {
    error FirstIndexCannotBeZero();
    error NOT_AUTHORIZED();

    uint256 public averageIndex;
    uint256 public windowSize;

    ERC20Interface public GLP;
    GLPManagerInterface public GLPManager;
    plvGLPInterface public plvGLP;
    Whitelist public immutable whitelist;
    uint256 public MAX_SWING;

    uint256 private constant BASE = 1e18;
    uint256 private constant DECIMAL_DIFFERENCE = 1e6;
    //1%

    struct IndexInfo {
        uint32  timestamp;
        uint224 recordedIndex;
    }

    IndexInfo[] public HistoricalIndices;

    event IndexAlert(uint256 previousIndex, uint256 possiblyBadIndex, uint256 timestamp);
    event updatePosted(uint256 averageIndex, uint256 timestamp);

    constructor(
        ERC20Interface _GLP,
        GLPManagerInterface _GLPManager,
        plvGLPInterface _plvGLP,
        Whitelist _whitelist,
        uint256 _windowSize
    ) payable {
        GLP = _GLP;
        GLPManager = _GLPManager;
        plvGLP = _plvGLP;
        whitelist = _whitelist;
        windowSize = _windowSize;
        MAX_SWING = 1000000000000000; //1%
        uint256 index = getPlutusExchangeRate();
        if (index == 0) { revert FirstIndexCannotBeZero(); }
        //initialize indices, this push will be stored in position 0
        HistoricalIndices.push(IndexInfo(
            uint32(block.timestamp),
            uint224(index)
        ));
    }

    /**
        @notice Pulls requisite data from GLP contract to calculate the current price of GLP
        @return Returns the price of GLP denominated in USD wei.
     */
    function getGLPPrice() public view returns (uint256) {
        //GLP Price = AUM / Total Supply
        unchecked {
            return (
                GLPManager.getAum(false) / GLP.totalSupply()
            ) * DECIMAL_DIFFERENCE;
        }
    }

    /**
        @notice Pulls requisite data from Plutus Vault contract to calculate the current exchange rate.
        @return Returns the current plvGLP/GLP exchange rate directly from Plutus vault contract.
     */
    function getPlutusExchangeRate() public view returns (uint256) {
        plvGLPInterface _plvGLP = plvGLP;
        //plvGLP/GLP Exchange Rate = Total Assets / Total Supply
        unchecked {
            return (
                _plvGLP.totalAssets() * BASE
            ) / _plvGLP.totalSupply();
        }
    }

    /**
        @notice Computes the moving average over a period of "windowSize". For the initialization period,
        the average is computed over the length of the indices array.
        @return Returns the moving average of the index over the specified window.
     */
    function computeAverageIndex() public returns (uint256) {
        uint256 latestIndexing = HistoricalIndices.length - 1;
        uint256 sum;
        uint256 _windowSize = windowSize;
        if (latestIndexing <= _windowSize) {
            for (uint256 i; i < latestIndexing; ) {
                sum += HistoricalIndices[i].recordedIndex;
                unchecked { ++i; }
            }
            averageIndex = sum / HistoricalIndices.length;
        } else {
            for (uint256 i = latestIndexing - _windowSize + 1; i <= latestIndexing;) {
                sum += HistoricalIndices[i].recordedIndex;
                unchecked { ++i; }
            }
            averageIndex = sum / _windowSize;
        }

        return averageIndex;
    }

    /**
        @notice Returns the value of the previously accepted exchange rate.
     */
    function getPreviousIndex() public view returns (uint256) {
        return HistoricalIndices[HistoricalIndices.length - 1].recordedIndex;
    }

    /**
        @notice Checks the currently reported exchange rate against the last accepted exchange rate.
        Requested updates are compared against a range of +/- 1% of the previous exchange rate.
        @param currentIndex the currently reported index from Plutus to check swing on
        @return returns TRUE if requested update is within the bounds of maximum swing, returns FALSE otherwise.
     */
    function checkSwing(uint256 currentIndex) public returns (bool) {
        uint256 previousIndex = getPreviousIndex();
        uint256 allowableSwing;
        uint256 minSwing;
        uint256 maxSwing;

        unchecked {
            allowableSwing = (previousIndex * MAX_SWING) / BASE;
            minSwing = previousIndex - allowableSwing;
            maxSwing = previousIndex + allowableSwing;
        }

        if (currentIndex > maxSwing || currentIndex < minSwing) {
            emit IndexAlert(previousIndex, currentIndex, block.timestamp);
            return false;
        }
        return true;
    }

    /**
        @notice Update the current, cumulative and average indices when required conditions are met.
        If the price fails to update, the posted price will fall back on the last previously
        accepted average index. Access is restricted to only whitelisted addresses.
        @dev we only ever update the index if requested update is within +/- 1% of previously accepted
        index.
     */
    function updateIndex() external {
        if (!whitelist.getWhitelisted(msg.sender)) { revert NOT_AUTHORIZED(); }
        uint256 currentIndex = getPlutusExchangeRate();

        if (!checkSwing(currentIndex)) {
            HistoricalIndices.push(IndexInfo(
                uint32(block.timestamp),
                uint224(getPreviousIndex())
            ));
        } else {
            HistoricalIndices.push(IndexInfo(
                uint32(block.timestamp),
                uint224(currentIndex)
            ));
        }

        averageIndex = computeAverageIndex();
        emit updatePosted(averageIndex, block.timestamp);
    }

    /**
        @notice Computes the TWAP price of plvGLP based on the current price of GLP and moving average of the
        plvGLP/GLP exchange rate.
        @return Returns the TWAP price of plvGLP denominated in USD wei.
     */
    function getPlvGLPPrice() external view returns (uint256) {
        return (averageIndex * getGLPPrice()) / BASE;
    }

    //* ADMIN FUNCTIONS */

    event newGLPAddress(ERC20Interface oldGLPAddress, ERC20Interface newGLPAddress);
    event newGLPManagerAddress(GLPManagerInterface oldManagerAddress, GLPManagerInterface newManagerAddress);
    event newPlvGLPAddress(plvGLPInterface oldPlvGLPAddress, plvGLPInterface newPlvGLPAddress);
    event newWindowSize(uint256 oldWindowSize, uint256 newWindowSize);
    event newMaxSwing(uint256 oldMaxSwing, uint256 newMaxSwing);

    /**
        @notice Admin function to update the address of GLP, restricted to only be
        usable by the contract owner.
     */
    function _updateGlpAddress(ERC20Interface _newGlpAddress) external payable onlyOwner {
        ERC20Interface oldGLPAddress = GLP;
        GLP = _newGlpAddress;
        emit newGLPAddress(oldGLPAddress, _newGlpAddress);
    }

    /**
        @notice Admin function to update the address of the GLP Manager Contract, restricted to only be
        usable by the contract owner.
     */
    function _updateGlpManagerAddress(GLPManagerInterface _newGlpManagerAddress) external payable onlyOwner {
        GLPManagerInterface oldManagerAddress = GLPManager;
        GLPManager = _newGlpManagerAddress;
        emit newGLPManagerAddress(oldManagerAddress, _newGlpManagerAddress);
    }

    /**
        @notice Admin function to update the address of plvGLP, restricted to only be
        usable by the contract owner.
     */
    function _updatePlvGlpAddress(plvGLPInterface _newPlvGlpAddress) external payable onlyOwner {
        plvGLPInterface oldPlvGLPAddress = plvGLP;
        plvGLP = _newPlvGlpAddress;
        emit newPlvGLPAddress(oldPlvGLPAddress, _newPlvGlpAddress);
    }

    /**
        @notice Admin function to update the moving average window size, restricted to only be
        usable by the contract owner.
     */
    function _updateWindowSize(uint256 _newWindowSize) external payable onlyOwner {
        uint256 oldWindowSize = windowSize;
        windowSize = _newWindowSize;
        emit newWindowSize(oldWindowSize, _newWindowSize);
    }

    function _updateMaxSwing(uint256 _newMaxSwing) external payable onlyOwner {
        uint256 oldMaxSwing = MAX_SWING;
        MAX_SWING = _newMaxSwing;
        emit newWindowSize(oldMaxSwing, _newMaxSwing);
    }
}
