// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.17;

interface plvGLPInterface {
    function totalAssets() external view returns (uint256);

    function totalSupply() external view returns (uint256);
}
