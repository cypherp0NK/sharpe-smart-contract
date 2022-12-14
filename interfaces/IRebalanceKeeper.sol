// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
interface KeeperCompatibleInterface{
    function checkUpkeep(bytes calldata checkData) external returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external;
}