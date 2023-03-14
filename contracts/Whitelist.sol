//SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";

contract Whitelist is Ownable {
    mapping(address => bool) private _isWhitelisted;

    constructor() payable { }

    function updateWhitelist(address _address, bool _isActive) external payable onlyOwner {
        _isWhitelisted[_address] = _isActive;
    }

    function getWhitelisted(address _address) external view returns (bool) {
        return _isWhitelisted[_address];
    }
}
