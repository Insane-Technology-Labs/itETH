// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import {OFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFT.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
/// @dev import external libraries for error and event handling
/// @dev implements ErrorLib & EventLib
import "./ExternalLib.sol";

contract itETH is OFT, AccessControl {
    /// @title Insane Technology Restaked Ether Basket (itETH)
    /// @author Insane Technology
    /// @custom:description ether wrapper which deposits into LRT protocols and uses a pass-through formula for distributing points to depositors

    /// @dev struct that holds the request payloads
    struct RequestPayload {
        /// @dev owner of the request
        address owner;
        /// @dev the amount of itETH requested for withdrawal
        uint256 amount;
        /// @dev whether the request has been filled already or not
        bool fulfilled;
    }
    /// @dev mapping for tracking requests
    mapping(uint256 => RequestPayload) public payloads;
    /// @dev mapping to track the referral status of users
    mapping(address => address) public referrals;
    /// @dev mapping that tracks the ref pts earned per user
    mapping(address => uint256) public earnedReferralPoints;
    /// @custom:accesscontrol Operator access control role
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    /// @custom:accesscontrol Minter access control role
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice multichain multisig address
    address public treasury = 0xBFc57B070b1EDA0FCb9c203EDc1085c626F3A36d;
    /// @notice WETH address on the chain
    IERC20 public immutable WETH;
    /// @notice whether mint/redeem functionality are paused
    bool public paused;

    /// @notice refbase is hardcoded to 1000 (100%)
    uint256 public constant REF_BASE = 1e3;
    /// @notice the minimum amount of weth needed to request a redemption
    uint256 public minReq = 0.001 ether;
    /// @notice 1% by default (10/1000)
    uint256 public refDivisor = 1e1;
    /// @notice last processed ID regardless of height
    uint256 public lastProcessedID;
    /// @notice the last request (by highest index) that was processed
    uint256 public highestProcessedID;
    /// @notice total referred deposit points given
    uint256 public totalReferralDeposits;
    /// @notice total deposits ever
    uint256 public totalDepositedEther;
    /// @dev internal counter to see what the next request ID would be
    uint256 internal _requestCounter;

    /// @notice odos router contract address
    address public odos;

    modifier WhileNotPaused() {
        if (paused) revert ErrorLib.Paused();
        _;
    }

    /// @dev layerzero endpoint address and weth address on the chain
    constructor(
        address _endpoint,
        address _weth,
        address _odos
    )
        OFT(
            "Insane Technology Restaked Ether Basket",
            "itETH",
            _endpoint,
            treasury
        )
        Ownable(treasury)
    {
        /// @dev iterative, start at 0
        _requestCounter = 0;
        /// @dev paused by default
        paused = true;
        /// @dev initialize the WETH variable
        WETH = IERC20(_weth);
        /// @dev initialize odos address
        odos = _odos;
        ///@dev start at 0
        totalReferralDeposits = 0;
        /// @dev grant the appropriate roles to the treasury
        _grantRole(DEFAULT_ADMIN_ROLE, treasury);
        _grantRole(OPERATOR_ROLE, treasury);
        _grantRole(MINTER_ROLE, treasury);
        /// @dev grant roles to deployer for initial testing
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    /// @notice "cook" itETH with your WETH
    /// @custom:description transfer the wrapped ether from your wallet and recieve minted itETH
    /// @custom:accesscontrol this function is not limited to anyone, only the paused boolean
    function cook(uint256 _amount, address _referral) public WhileNotPaused {
        if (!(_amount > 0)) revert ErrorLib.Zero();
        /// @dev prohibit direct self refers
        if (msg.sender == _referral) revert ErrorLib.SelfReferProhibited();

        address referral = referrals[msg.sender];
        if (referral == address(0)) {
            /// @dev if there is no bound referral
            _referral == address(0) ? referral = treasury : referral = referral;
            referrals[msg.sender] = _referral;
            referral = _referral;
        }
        WETH.transferFrom(msg.sender, address(this), _amount);
        _mint(msg.sender, _amount);
        totalDepositedEther += _amount;
        /// @dev emit the amount of eth deposited and by whom
        emit EventLib.EtherDeposited(msg.sender, _amount);
        /// @dev if it is above the min threshold
        if (_amount > minReq) {
            /// @dev refDivisor * amount of referral deposits are accounted to the referee
            uint256 refPts = ((_amount * refDivisor) / REF_BASE);
            earnedReferralPoints[referral] += refPts;
            totalReferralDeposits += refPts;
            emit EventLib.ReferralDeposit(msg.sender, referral, refPts);
        }
    }

    /// @notice request redemption from the treasury
    /// @dev non-atomic redemption queue system
    /// @custom:accesscontrol this function is not limited to anyone, only the paused boolean
    function requestRedemption(uint256 _amount) external WhileNotPaused {
        if (_amount < minReq) revert ErrorLib.BelowMinimum();
        _burn(msg.sender, _amount);
        ++_requestCounter;
        payloads[_requestCounter] = RequestPayload(msg.sender, _amount, false);
        emit EventLib.RequestRedemption(msg.sender, _amount);
    }

    /// @notice process a batch of redeem requests
    /// @custom:accesscontrol execution is limited to the OPERATOR_ROLE
    function processRedemptions(uint256[] calldata _redemptionIDs)
        public
        onlyRole(OPERATOR_ROLE)
    {
        uint256 _highestProcessedID = highestProcessedID;
        for (uint256 i = 0; i < _redemptionIDs.length; ++i) {
            _process(_redemptionIDs[i]);

            /// @dev ternary operator for updating the highest processed request ID
            if (_highestProcessedID < _redemptionIDs[i]) {
                highestProcessedID = _redemptionIDs[i];
            }
        }
        /// @dev stores the last processed ID regardless of height
        lastProcessedID = _redemptionIDs[_redemptionIDs.length - 1];
    }

    /// @custom:accesscontrol execution is limited to the MINTER_ROLE
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @custom:accesscontrol execution is limited to the DEFAULT_ADMIN_ROLE
    function setTreasury(address _treasury)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        treasury = _treasury;
        emit EventLib.TreasurySet(treasury);
    }

    /// @notice function to pause the printing of itETH
    /// @custom:accesscontrol execution is limited to the OPERATOR_ROLE
    function setPaused(bool _status) external onlyRole(OPERATOR_ROLE) {
        if (paused == _status) revert ErrorLib.NoChangeInBoolean();
        paused = _status;
        emit EventLib.PausedContract(_status);
    }

    /// @notice set the minimum eth amount for redemptions
    /// @custom:accesscontrol execution is limited to the OPERATOR_ROLE
    function setMinReq(uint256 _min) external onlyRole(OPERATOR_ROLE) {
        minReq = _min;
        emit EventLib.MinReqSet(minReq);
    }

    /// @notice set the referral divisor
    /// @custom:accesscontrol execution is limited to the OPERATOR_ROLE
    function setRefDivisor(uint256 _divisor) external onlyRole(OPERATOR_ROLE) {
        if (refDivisor < 1e1) revert ErrorLib.DivisorBelowMinimum();
        if (refDivisor > REF_BASE) revert ErrorLib.DivisorAboveMinimum();
        refDivisor = _divisor;
        emit EventLib.RefDivisorSet(refDivisor);
    }

    /// @notice convert weth and other tokens to desired LRT
    /// @custom:accesscontrol execution is limited to the OPERATOR_ROLE
    function performBasketSwap(
        address[] calldata _tokensOut,
        uint256[] calldata _minAmountsOut,
        bytes calldata _odosCalldata
    ) external onlyRole(OPERATOR_ROLE) {
        /// @dev define and map balances before the swap
        uint256[] memory balanceBefore = new uint256[](_tokensOut.length);
        for (uint256 i = 0; i < _tokensOut.length; ++i) {
            balanceBefore[i] = IERC20(_tokensOut[i]).balanceOf(treasury);
        }
        /// @dev give swap approval to odos
        WETH.approve(odos, WETH.balanceOf(address(this)));

        /// @dev ensure the swap succeeds
        (bool success, ) = odos.call(_odosCalldata);
        if (!success) revert ErrorLib.Failed();

        /// @dev check for improper output amounts
        for (uint256 i = 0; i < _tokensOut.length; ++i) {
            if (
                ((IERC20(_tokensOut[i]).balanceOf(treasury)) -
                    balanceBefore[i]) < _minAmountsOut[i]
            ) revert ErrorLib.SwapFailed();
        }
    }

    /// @notice arbitrary call
    /// @custom:accesscontrol execution is limited to the DEFAULT_ADMIN_ROLE
    function execute(address _x, bytes calldata _data)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        (bool success, ) = _x.call(_data);
        if (!success) revert ErrorLib.Failed();
    }

    /// @notice standard decimal return
    /// @return uint8 decimals
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function cooked(address user) external view returns (bool) {
        return referrals[user] != address(0);
    }

    /// @dev internal function to process each request
    function _process(uint256 _reqID) internal {
        RequestPayload storage pl = payloads[_reqID];
        (uint256 amt, address sendTo, bool filled) = (
            pl.amount,
            pl.owner,
            pl.fulfilled
        );
        /// @dev if fulfilled, revert
        if (filled) revert ErrorLib.Fulfilled();
        /// @dev if the amount is not greater than 0, revert
        if (!(amt > 0)) revert ErrorLib.Zero();
        WETH.transferFrom(treasury, sendTo, amt);
        /// @dev set the payload values to 0/true;
        pl.amount = 0;
        pl.fulfilled = true;
        /// @dev emit event for processing the request
        emit EventLib.ProcessRedemption(_reqID, amt);
    }

    /// @dev revert on msg.value being delivered to the address w/o data
    receive() external payable {
        revert ErrorLib.FailedOnSend();
    }

    /// @dev revert on non-existent function calls or payload eth sends
    fallback() external payable {
        revert ErrorLib.FallbackFailed();
    }
}
