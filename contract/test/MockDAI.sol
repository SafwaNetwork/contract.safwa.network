
// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockDAI is ERC20 {
    constructor() ERC20("Mock DAI", "DAI") {
        _mint(msg.sender, 100000000 * 10**18); // Mint 100M DAI to deployer
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function name() public pure override returns (string memory) {
        return "Mock DAI";
    }

    function symbol() public pure override returns (string memory) {
        return "DAI";
    }
}
