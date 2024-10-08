// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ErrorLib, EventLib} from "./libraries/ExternalLib.sol";

interface ASTRO is IERC20 {
    function burn(uint256) external;

    function mint(address, uint256) external;

    function renounceRole(bytes32, address) external;
}

contract Migrator {
    IERC20 public oldToken;
    ASTRO public newToken;
    address public constant OPERATIONS =
        0xBFc57B070b1EDA0FCb9c203EDc1085c626F3A36d;

    /// @notice 10 million INT per 1 ITX
    uint256 public constant SPLIT = 10_000_000;

    /// @notice amount that each individual user migrated
    mapping(address => uint256) public amountMigrated;

    /// @notice amount of ITX tokens migrated (always <= 100)
    uint256 public totalItxMigrated;

    bool public migrationPaused;

    event Migrated(address user, uint256 amount, uint256 newAmount);

    constructor(address _oldToken, address _newToken) {
        oldToken = IERC20(_oldToken);
        newToken = ASTRO(_newToken);
        totalItxMigrated = 0;
        migrationPaused = false;
    }

    /// @notice migrate ITX --> INT at 1 per 10m
    function migrate(uint256 _amount) external {
        require(!migrationPaused, ErrorLib.Paused());
        /// @dev 100 cap which is the ITX total supply
        require(totalItxMigrated + _amount <= 100, ErrorLib.Failed());
        /// @dev collect the user's tokens
        oldToken.transferFrom(msg.sender, address(this), _amount);
        /// @dev cast as INT to call burn
        ASTRO(address(oldToken)).burn(_amount);
        /// @dev update accounting
        totalItxMigrated += _amount;
        amountMigrated[msg.sender] += _amount;
        /// @dev calculate ASTRO amount
        uint256 newAmount = _amount * SPLIT;
        /// @dev mint the ASTRO to the user
        newToken.mint(msg.sender, newAmount);
        emit Migrated(msg.sender, _amount, newAmount);
        /// @dev if the total amount migrated is at 100, prevent from minting ASTRO again
        if (totalItxMigrated >= 100) {
            newToken.renounceRole(
                bytes32(keccak256("MINTER_ROLE")),
                address(this)
            );
            migrationPaused = true;
        }
    }

    /// @notice in case of stuck funds, return to OPERATIONS msig to be redistributed
    /// @param _token the token to rescue
    function rescue(address _token) external {
        require(msg.sender == OPERATIONS, ErrorLib.Failed());
        IERC20(_token).transfer(
            OPERATIONS,
            IERC20(_token).balanceOf(address(this))
        );
    }

    /// @notice arbitrary call
    function execute(address _x, bytes calldata _data) public {
        require(msg.sender == OPERATIONS, ErrorLib.Failed());
        (bool success, ) = _x.call(_data);
        require(success, ErrorLib.Failed());
    }
}
