// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { UUPSHelper } from "./utils/UUPSHelper.sol";
import { IAccessControlManager } from "./interfaces/IAccessControlManager.sol";
import { Errors } from "./utils/Errors.sol";
import { CampaignParameters } from "./struct/CampaignParameters.sol";
import { DistributionParameters } from "./struct/DistributionParameters.sol";
import { RewardTokenAmounts } from "./struct/RewardTokenAmounts.sol";

contract DistributionCreator is UUPSHelper, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    uint32 public constant HOUR = 3600;
    uint256 public constant BASE_9 = 1e9;
    uint256 public immutable CHAIN_ID = block.chainid;
    IAccessControlManager public accessControlManager;
    address public distributor;
    address public feeRecipient;
    uint256 public defaultFees;
    string public message;
    bytes32 public messageHash;
    DistributionParameters[] public distributionList;
    mapping(address => uint256) public feeRebate;
    mapping(address => uint256) public isWhitelistedToken;
    mapping(address => uint256) public _nonces;
    mapping(address => bytes32) public userSignatures;
    mapping(address => uint256) public userSignatureWhitelist;
    mapping(address => uint256) public rewardTokenMinAmounts;
    address[] public rewardTokens;
    CampaignParameters[] public campaignList;
    mapping(bytes32 => uint256) internal _campaignLookup;
    mapping(uint32 => uint256) public campaignSpecificFees;
    mapping(bytes32 => CampaignParameters) public campaignOverrides;
    mapping(bytes32 => uint256[]) public campaignOverridesTimestamp;
    mapping(bytes32 => mapping(address => address)) public campaignReallocation;
    mapping(bytes32 => address[]) public campaignListReallocation;
    mapping(address => mapping(address => uint256)) public creatorBalance;
    mapping(address => mapping(address => mapping(address => uint256))) public creatorAllowance;
    mapping(address => mapping(address => uint256)) public campaignOperators;

    event CreatorAllowanceUpdated(address indexed user, address indexed operator, address indexed token, uint256 amount);
    event CreatorBalanceUpdated(address indexed user, address indexed token, uint256 amount);
    event DistributorUpdated(address indexed _distributor);
    event FeeRebateUpdated(address indexed user, uint256 userFeeRebate);
    event FeeRecipientUpdated(address indexed _feeRecipient);
    event FeesSet(uint256 _fees);
    event CampaignOperatorToggled(address indexed user, address indexed operator, bool isWhitelisted);
    event CampaignOverride(bytes32 _campaignId, CampaignParameters campaign);
    event CampaignReallocation(bytes32 _campaignId, address[] indexed from, address indexed to);
    event CampaignSpecificFeesSet(uint32 campaignType, uint256 _fees);
    event MessageUpdated(bytes32 _messageHash);
    event NewCampaign(CampaignParameters campaign);
    event RewardTokenMinimumAmountUpdated(address indexed token, uint256 amount);
    event UserSigningWhitelistToggled(address indexed user, uint256 toggleStatus);

    modifier onlyGovernorOrGuardian() {
        if (!accessControlManager.isGovernorOrGuardian(msg.sender)) revert Errors.NotGovernorOrGuardian();
        _;
    }

    modifier onlyGovernor() {
        if (!accessControlManager.isGovernor(msg.sender)) revert Errors.NotGovernor();
        _;
    }

    modifier hasSigned() {
        if (
            userSignatureWhitelist[msg.sender] == 0 &&
            userSignatureWhitelist[tx.origin] == 0 &&
            userSignatures[msg.sender] != messageHash &&
            userSignatures[tx.origin] != messageHash
        ) revert Errors.NotSigned();
        _;
    }

    modifier onlyUserOrGovernor(address user) {
        if (user != msg.sender && !accessControlManager.isGovernor(msg.sender)) revert Errors.NotAllowed();
        _;
    }

    function initialize(IAccessControlManager _accessControlManager, address _distributor, uint256 _fees) external initializer {
        if (address(_accessControlManager) == address(0) || _distributor == address(0)) revert Errors.ZeroAddress();
        if (_fees >= BASE_9) revert Errors.InvalidParam();
        distributor = _distributor;
        accessControlManager = _accessControlManager;
        defaultFees = _fees;
    }

    constructor() initializer {}

    function _authorizeUpgrade(address) internal view override onlyGovernorUpgrader(accessControlManager) {}

    function createCampaign(CampaignParameters memory newCampaign) external nonReentrant hasSigned returns (bytes32) {
        return _createCampaign(newCampaign);
    }

    function createCampaigns(CampaignParameters[] memory campaigns) external nonReentrant hasSigned returns (bytes32[] memory) {
        uint256 campaignsLength = campaigns.length;
        bytes32[] memory campaignIds = new bytes32[](campaignsLength);
        for (uint256 i; i < campaignsLength; ) {
            campaignIds[i] = _createCampaign(campaigns[i]);
            unchecked {
                ++i;
            }
        }
        return campaignIds;
    }

    function acceptConditions() external {
        userSignatures[msg.sender] = messageHash;
    }

    function acceptConditions(bytes memory signature) external {
        bytes32 messageHashFromSignature = ECDSA.toEthSignedMessageHash(bytes(message));
        if (messageHashFromSignature != messageHash) revert Errors.InvalidMessageHash();
        if (ECDSA.recover(messageHashFromSignature, signature) != msg.sender) revert Errors.InvalidSignature();
        userSignatures[msg.sender] = messageHash;
    }

    function depositTokens(address rewardToken, uint256 amount) external onlyUserOrGovernor(msg.sender) {
        _depositTokens(msg.sender, rewardToken, amount);
    }

    function withdrawTokens(address rewardToken, uint256 amount) external onlyUserOrGovernor(msg.sender) {
        _withdrawTokens(msg.sender, rewardToken, amount);
    }

    function increaseTokenAllowance(address user, address operator, address rewardToken, uint256 amount) external onlyUserOrGovernor(user) {
        _updateAllowance(user, operator, rewardToken, creatorAllowance[user][operator][rewardToken] + amount);
    }

    function decreaseTokenAllowance(address user, address operator, address rewardToken, uint256 amount) external onlyUserOrGovernor(user) {
        _updateAllowance(user, operator, rewardToken, creatorAllowance[user][operator][rewardToken] - amount);
    }

    function toggleCampaignOperator(address user, address operator) external onlyUserOrGovernor(user) {
        uint256 currentStatus = campaignOperators[user][operator];
        campaignOperators[user][operator] = 1 - currentStatus;
        emit CampaignOperatorToggled(user, operator, currentStatus == 0);
    }

    function overrideCampaign(bytes32 _campaignId, CampaignParameters memory newCampaign) external {
        CampaignParameters memory _campaign = campaign(_campaignId);
        _isValidOperator(_campaign.creator);
        _overrideCampaign(_campaignId, newCampaign);
    }

    function reallocateCampaignRewards(bytes32 _campaignId, address[] memory froms, address to) external {
        CampaignParameters memory _campaign = campaign(_campaignId);
        _isValidOperator(_campaign.creator);
        if (block.timestamp < _campaign.startTimestamp + _campaign.duration) revert Errors.InvalidReallocation();
        uint256 fromsLength = froms.length;
        for (uint256 i; i < fromsLength; ) {
            campaignReallocation[_campaignId][froms[i]] = to;
            campaignListReallocation[_campaignId].push(froms[i]);
            unchecked {
                ++i;
            }
        }
        emit CampaignReallocation(_campaignId, froms, to);
    }

    function campaign(bytes32 _campaignId) public view returns (CampaignParameters memory) {
        uint256 index = _campaignLookup[_campaignId];
        if (index == 0) revert Errors.CampaignNotFound();
        return campaignList[index - 1];
    }

    function getValidRewardTokens() external view returns (RewardTokenAmounts[] memory) {
        (RewardTokenAmounts[] memory validRewardTokens, ) = _getValidRewardTokens(0, type(uint32).max);
        return validRewardTokens;
    }

    function getValidRewardTokens(uint32 skip, uint32 first) external view returns (RewardTokenAmounts[] memory, uint256) {
        return _getValidRewardTokens(skip, first);
    }

    function getCampaignOverridesTimestamp(bytes32 _campaignId) external view returns (uint256[] memory) {
        return campaignOverridesTimestamp[_campaignId];
    }

    function setMessage(string memory _message) external onlyGovernorOrGuardian {
        message = _message;
        bytes32 _messageHash = ECDSA.toEthSignedMessageHash(bytes(_message));
        messageHash = _messageHash;
        emit MessageUpdated(_messageHash);
    }

    function setFees(uint256 _defaultFees) external onlyGovernorOrGuardian {
        if (_defaultFees >= BASE_9) revert Errors.InvalidParam();
        defaultFees = _defaultFees;
        emit FeesSet(_defaultFees);
    }

    function setCampaignSpecificFees(uint32[] calldata campaignTypes, uint256[] calldata _fees) external onlyGovernorOrGuardian {
        if (campaignTypes.length != _fees.length) revert Errors.InvalidLengths();
        uint256 feesLength = _fees.length;
        for (uint256 i; i < feesLength; ) {
            if (_fees[i] >= BASE_9) revert Errors.InvalidParam();
            campaignSpecificFees[campaignTypes[i]] = _fees[i];
            emit CampaignSpecificFeesSet(campaignTypes[i], _fees[i]);
            unchecked {
                ++i;
            }
        }
    }

    function setFeeRebate(address[] calldata users, uint256[] calldata rebates) external onlyGovernorOrGuardian {
        if (users.length != rebates.length) revert Errors.InvalidLengths();
        uint256 usersLength = users.length;
        for (uint256 i; i < usersLength; ) {
            if (rebates[i] >= BASE_9) revert Errors.InvalidParam();
            feeRebate[users[i]] = rebates[i];
            emit FeeRebateUpdated(users[i], rebates[i]);
            unchecked {
                ++i;
            }
        }
    }

    function setDistributor(address _distributor) external onlyGovernor {
        if (_distributor == address(0)) revert Errors.ZeroAddress();
        distributor = _distributor;
        emit DistributorUpdated(_distributor);
    }

    function setFeeRecipient(address _feeRecipient) external onlyGovernor {
        if (_feeRecipient == address(0)) revert Errors.ZeroAddress();
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    function setRewardTokenMinAmounts(address[] calldata tokens, uint256[] calldata amounts) external onlyGovernorOrGuardian {
        uint256 tokensLength = tokens.length;
        if (tokensLength != amounts.length) revert Errors.InvalidLengths();
        for (uint256 i; i < tokensLength; ) {
            uint256 amount = amounts[i];
            if (amount != 0 && rewardTokenMinAmounts[tokens[i]] == 0) rewardTokens.push(tokens[i]);
            rewardTokenMinAmounts[tokens[i]] = amount;
            emit RewardTokenMinimumAmountUpdated(tokens[i], amount);
            unchecked {
                ++i;
            }
        }
    }

    function toggleUserSigningWhitelist(address[] calldata users, uint256[] calldata statuses) external onlyGovernorOrGuardian {
        if (users.length != statuses.length) revert Errors.InvalidLengths();
        uint256 usersLength = users.length;
        for (uint256 i; i < usersLength; ) {
            if (statuses[i] > 1) revert Errors.InvalidParam();
            userSignatureWhitelist[users[i]] = statuses[i];
            emit UserSigningWhitelistToggled(users[i], statuses[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _createCampaign(CampaignParameters memory newCampaign) internal returns (bytes32) {
        if (newCampaign.duration < HOUR) revert Errors.InvalidDuration();
        if (newCampaign.rewardToken == address(0)) revert Errors.ZeroAddress();
        if (newCampaign.distributionAmount == 0) revert Errors.ZeroAmount();
        if (newCampaign.creator == address(0)) newCampaign.creator = msg.sender;
        else if (newCampaign.creator != msg.sender) _isValidOperator(newCampaign.creator);

        uint256 distributionAmountMinusFees = _computeFees(newCampaign.campaignType, newCampaign.creator, newCampaign.distributionAmount, newCampaign.rewardToken);
        if (distributionAmountMinusFees < rewardTokenMinAmounts[newCampaign.rewardToken]) revert Errors.InsufficientRewardAmount();

        bytes32 campaignId = keccak256(abi.encode(newCampaign, campaignList.length, CHAIN_ID));
        if (_campaignLookup[campaignId] != 0) revert Errors.CampaignAlreadyExists();
        
        newCampaign.campaignId = campaignId;
        _campaignLookup[campaignId] = campaignList.length + 1;
        campaignList.push(newCampaign);

        _pullTokens(newCampaign.creator, newCampaign.rewardToken, newCampaign.distributionAmount, distributionAmountMinusFees);
        
        emit NewCampaign(newCampaign);
        return campaignId;
    }

    function _overrideCampaign(bytes32 _campaignId, CampaignParameters memory newCampaign) internal {
        newCampaign.campaignId = _campaignId;
        campaignOverrides[_campaignId] = newCampaign;
        campaignOverridesTimestamp[_campaignId].push(block.timestamp);
        emit CampaignOverride(_campaignId, newCampaign);
    }

    function _isValidOperator(address creator) internal view {
        if (campaignOperators[creator][msg.sender] == 0 && !accessControlManager.isGovernor(msg.sender)) revert Errors.NotAllowed();
    }

    function _depositTokens(address user, address rewardToken, uint256 amount) internal {
        if (rewardToken == address(0) || amount == 0) revert Errors.InvalidParam();
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);
        _updateBalance(user, rewardToken, creatorBalance[user][rewardToken] + amount);
    }

    function _withdrawTokens(address user, address rewardToken, uint256 amount) internal {
        if (rewardToken == address(0) || amount == 0) revert Errors.InvalidParam();
        if (creatorBalance[user][rewardToken] < amount) revert Errors.InsufficientBalance();
        _updateBalance(user, rewardToken, creatorBalance[user][rewardToken] - amount);
        IERC20(rewardToken).safeTransfer(msg.sender, amount);
    }

    function _updateAllowance(address user, address operator, address rewardToken, uint256 newAllowance) internal {
        creatorAllowance[user][operator][rewardToken] = newAllowance;
        emit CreatorAllowanceUpdated(user, operator, rewardToken, newAllowance);
    }

    function _updateBalance(address user, address rewardToken, uint256 newBalance) internal {
        creatorBalance[user][rewardToken] = newBalance;
        emit CreatorBalanceUpdated(user, rewardToken, newBalance);
    }

    function _pullTokens(address creator, address rewardToken, uint256 campaignAmount, uint256 distributionAmountMinusFees) internal {
        uint256 fees = campaignAmount - distributionAmountMinusFees;
        uint256 remainingAmount = campaignAmount;

        if (creatorBalance[creator][rewardToken] >= remainingAmount) {
            _updateBalance(creator, rewardToken, creatorBalance[creator][rewardToken] - remainingAmount);
            remainingAmount = 0;
        } else {
            remainingAmount -= creatorBalance[creator][rewardToken];
            _updateBalance(creator, rewardToken, 0);
            if (creatorAllowance[creator][msg.sender][rewardToken] >= remainingAmount) {
                _updateAllowance(creator, msg.sender, rewardToken, creatorAllowance[creator][msg.sender][rewardToken] - remainingAmount);
            } else if (creatorAllowance[creator][tx.origin][rewardToken] >= remainingAmount) {
                _updateAllowance(creator, tx.origin, rewardToken, creatorAllowance[creator][tx.origin][rewardToken] - remainingAmount);
            } else {
                IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), remainingAmount);
            }
        }
        
        if (fees > 0) IERC20(rewardToken).safeTransfer(feeRecipient, fees);
        if (distributionAmountMinusFees > 0) IERC20(rewardToken).safeTransfer(distributor, distributionAmountMinusFees);
    }

    function _computeFees(uint32 campaignType, address creator, uint256 distributionAmount, address rewardToken) internal view returns (uint256 distributionAmountMinusFees) {
        uint256 baseFeesValue = campaignSpecificFees[campaignType];
        if (baseFeesValue == 1) baseFeesValue = 0;
        else if (baseFeesValue == 0) baseFeesValue = defaultFees;

        if (baseFeesValue == 0) return distributionAmount;

        uint256 fees = distributionAmount * baseFeesValue / BASE_9;
        uint256 creatorRebate = feeRebate[creator] * baseFeesValue / BASE_9;

        fees -= distributionAmount * creatorRebate / BASE_9;
        
        if (fees >= distributionAmount) return 0;
        return distributionAmount - fees;
    }

    function _getValidRewardTokens(uint32 skip, uint32 first) internal view returns (RewardTokenAmounts[] memory, uint256) {
        uint256 length;
        uint256 rewardTokenListLength = rewardTokens.length;
        uint256 returnSize = first > rewardTokenListLength ? rewardTokenListLength : first;
        RewardTokenAmounts[] memory validRewardTokens = new RewardTokenAmounts[](returnSize);
        uint32 i = skip;
        while (i < rewardTokenListLength) {
            address token = rewardTokens[i];
            uint256 minAmount = rewardTokenMinAmounts[token];
            if (minAmount > 0) {
                validRewardTokens[length] = RewardTokenAmounts(token, minAmount);
                length += 1;
            }
            unchecked {
                ++i;
            }
            if (length == returnSize) break;
        }
        assembly {
            mstore(validRewardTokens, length)
        }
        return (validRewardTokens, i);
    }

    uint256[28] private __gap;
}
