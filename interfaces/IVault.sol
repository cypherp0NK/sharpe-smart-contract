// SPDX-License-Identifier: Unlicense

pragma solidity ^0.8.0;

interface IVault {
    enum SwapKind {None, ToAmount0, ToAmount1}
    
    function deposit(
        uint256,
        uint256,
        uint256,
        uint256,
        address
    )
        external
        returns (
            uint256,
            uint256,
            uint256
        );

    function withdraw(
        uint256,
        uint256,
        uint256,
        address,
        SwapKind
    ) external returns (uint256, uint256);

    function getTotalAmounts() external view returns (uint256, uint256);
}