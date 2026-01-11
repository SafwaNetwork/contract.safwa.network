// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title SafwaNetwork
 * @author Safwa Team
 * @notice A 5x10 Matrix MLM system on Polygon PoS acting as a full on-chain backend.
 * @dev Non-upgradeable, immutable, no owner override after deployment. deployed at: https://polygonscan.com/address/0xE023d2915F028c4a34a78BD87A0b20b3FF2cf0aC
 */

// Minimal IERC20 Interface
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Minimal ReentrancyGuard (Gas optimized)
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    error ReentrancyGuardReentrantCall();

    modifier nonReentrant() {
        if (_status == _ENTERED) revert ReentrancyGuardReentrantCall();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

contract SafwaNetwork is ReentrancyGuard {
    // =============================================================
    //                           CONSTANTS
    // =============================================================

    // Token Addresses
    address public constant DAI = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063; // Polygon DAI
    string public constant WEBSITE = "https://github.com/SafwaNetwork/contract.safwa.network";

    // IDs
    uint64 public constant ENGINEER_ID = 0x1000100000; // Engineer (one-time deployer)
    uint64 public constant FOUNDER_ID = 0x1000100001; // Founder (first member, fixed)
    uint64 public constant START_ID = 0x1000100002; // First partner ID after founder
    uint64 public constant MAX_ID = 0xFFFFFFFFFF;

    // Fees & Limits
    /// @notice Cost to join the matrix
    uint256 public constant PARTNERSHIP_FEE = 25e18; // 25 DAI (18 decimals)
    // PARTNERSHIP_FEE_SDOLLAR removed (unused)
    uint256 public constant MIN_WITHDRAWAL = 5e18; // Must have at least 5 SDOLLAR to withdraw

    // Role-based Free Add Limits
    uint8 public constant MAX_FREE_ADDS_FOUNDER = 10;
    uint8 public constant MAX_FREE_ADDS_COFOUNDER = 5;
    uint8 public constant MAX_FREE_ADDS_LEADER = 1;

    // Matrix Setup
    // Matrix Setup
    // MATRIX_DEPTH removed (unused variable)

    // Role Limits (Direct referrals Max)
    uint8 public constant LIMIT_PARTNER = 5; // 5x10 matrix
    uint8 public constant LIMIT_LEADER = 10; // 10x10 matrix
    uint8 public constant LIMIT_COFOUNDER = 25; // 25x10 matrix
    uint8 public constant LIMIT_FOUNDER = 50; // 50x10 matrix (max 50 CoFounders)

    // =============================================================
    //                            ENUMS
    // =============================================================

    enum Role {
        PARTNER,
        LEADER,
        COFOUNDER,
        FOUNDER,
        ENGINEER
    }

    // =============================================================
    //                           STRUCTS
    // =============================================================

    struct Partner {
        bool exists;
        address wallet;
        uint64 referralId;
        uint64 parentReferralId;
        Role role;
        // Upline: 10th grandparent... to ... 9th is direct parent, 10th is self.
        // Array size 11. Stores IDs to save storage space (uint64 vs address).
        uint64[11] upline;
        // Referrals of the partner
        uint64[5] referrals;
        // Economic fields
        uint256 sdollarBalance;
        uint256 totalEarned;
        uint256 totalWithdrawn;
        uint256[10] levelRevenue;
        uint32[10] levelPartnerCount;
    }

    // Lightweight struct for view function return to avoid stack too deep
    struct PartnerView {
        bool exists;
        address wallet;
        uint64 referralId;
        uint64 parentReferralId;
        Role role;
        uint256 sdollarBalance;
        uint256 totalEarned;
        uint256 totalWithdrawn;
        uint256 referralCount;
    }

    // =============================================================
    //                        STATE VARIABLES
    // =============================================================

    // Mapping from referral ID to Partner
    mapping(uint64 => Partner) private partners;

    // Mapping from Wallet to Referral ID
    mapping(address => uint64) public walletToId;

    // Fixed Engineer Wallet (set at deployment)
    address public immutable ENGINEER_WALLET;

    // Founder Deployment Tracking
    bool public founderDeployed; // True after Founder is deployed (Engineer locked)
    uint64 public founderId; // Track the single Founder (0x1000100001)

    // Role-based Free Add Tracking
    mapping(uint64 => uint8) public freeAddsUsed; // Track free adds used per partner ID

    // Global Stats
    uint64 public nextReferralId;
    uint256 public totalPartners;
    uint256 public totalPaidJoins; // Track joins that paid 25 DAI (excludes free adds)
    uint256 public totalSdollarMinted;
    uint256 public totalSdollarBurned;

    // Fund Wallet for collecting breakage
    uint256 public fundBalance; // Accumulated SDOLLAR from breakage (missing uplines, dust, taxes)

    // Dynamic referral storage for Engineer and Founder
    mapping(uint64 => uint64[]) private engineerReferrals;
    mapping(uint64 => uint64[]) private leaderReferrals;
    mapping(uint64 => uint64[]) private cofounderReferrals;
    mapping(uint64 => uint64[]) private founderReferrals;

    // =============================================================
    //                            EVENTS
    // =============================================================

    event PartnerJoined(
        address indexed partner,
        uint64 indexed referralId,
        uint64 indexed parentReferralId
    );
    event CommissionPaid(
        uint64 indexed fromReferralId,
        uint64 indexed toReferralId,
        uint8 level,
        uint256 amount
    );
    // RoleChanged event removed (unused)
    event SdollarTransferred(
        uint64 indexed fromId,
        uint64 indexed toId,
        uint256 amount
    );
    event Withdrawal(uint64 indexed referralId, uint256 amount);
    event FounderAddedPartner(
        address indexed partner,
        uint64 indexed referralId,
        uint64 indexed parentReferralId,
        Role role
    );
    event Deployed(address engineer);
    event FounderDeployed(address indexed founderWallet, uint64 founderId);
    event EngineerLocked();
    event FundCollected(
        uint64 indexed fromReferralId,
        uint256 amount,
        string reason
    );
    event FundDistributed(uint256 founderAmount, address indexed caller);
    event TokensRescued(
        address indexed token,
        uint256 amount,
        address indexed rescuer
    );
    event ExcessDAIRescued(uint256 amount, address indexed rescuer);

    // =============================================================
    //                            ERRORS
    // =============================================================

    error NotEngineer();
    error EngineerAccessLocked();
    error NotFounder();
    error FounderNotDeployed();
    error FounderAlreadyDeployed();
    // FounderAlreadyExists removed (unused)
    // CoFounderLimitExceeded removed (unused)
    // MustBeDirectReferralOfEngineer removed (unused)
    error FreeAddLimitExceeded();
    error PartnerAlreadyExists();
    error PartnerDoesNotExist();
    error InvalidReferral();
    error ReferralRequired();
    error InsufficientBalance();
    error WithdrawalTooSmall();
    error InsufficientReferrals();
    error ReferralCapacityExceeded();
    error InvalidIdRange();
    error TransferFailed();
    // SelfReferral removed (unused)
    error ZeroAddress();
    error ZeroAmount();
    error NoFundsToDistribute();
    // FounderNotSet removed (unused)
    error CannotRescueDAI(); // Prevent draining user deposits
    error InsufficientExcessDAI(); // Not enough excess DAI to rescue

    // =============================================================
    //                          MODIFIERS
    // =============================================================

    /**
     * @notice Restricts function access to the Engineer wallet only, and only before Founder is deployed.
     * @dev Reverts with EngineerAccessLocked if Founder has been deployed.
     *      Reverts with NotEngineer if caller is not the engineer.
     */
    modifier onlyEngineer() {
        if (founderDeployed) revert EngineerAccessLocked();
        if (msg.sender != ENGINEER_WALLET) revert NotEngineer();
        _;
    }

    /**
     * @notice Restricts function access to the Founder only.
     * @dev Reverts with FounderNotDeployed if Founder hasn't been deployed yet.
     *      Reverts with NotFounder if caller is not the Founder.
     */
    modifier onlyFounder() {
        if (!founderDeployed) revert FounderNotDeployed();
        uint64 id = walletToId[msg.sender];
        if (id != founderId) revert NotFounder();
        _;
    }

    /**
     * @notice Restricts function access to Founder, CoFounder, or Leader roles.
     * @dev Used for role-based free add functionality.
     */
    modifier onlyPrivilegedRole() {
        uint64 id = walletToId[msg.sender];
        if (id == 0) revert PartnerDoesNotExist();
        Partner storage u = partners[id];
        bool isPrivileged = false;
        if (u.role == Role.FOUNDER) isPrivileged = true;
        else if (u.role == Role.COFOUNDER) isPrivileged = true;
        else if (u.role == Role.LEADER) isPrivileged = true;

        if (!isPrivileged) {
            revert NotFounder(); // Reusing error for simplicity
        }
        _;
    }

    /**
     * @dev Internal helper for SafeERC20 transferFrom.
     * checks for code existence to avoid phantom success on empty addresses.
     */
    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        if (token.code.length == 0) revert TransferFailed();
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
                from,
                to,
                value
            )
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool))))
            revert TransferFailed();
    }

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    /**
     * @notice Initializes the SafwaNetwork contract with the deployer as Engineer.
     * @dev Sets up the Engineer partner with ID 0x1000100000, initializes upline array,
     *      and reserves ID 0x1000100001 for Founder. Validates deployer is not zero address.
     *      Engineer will lose access after deploying the Founder.
     */
    constructor() payable {
        // Validate engineer address
        if (msg.sender == address(0)) revert ZeroAddress();

        ENGINEER_WALLET = msg.sender;

        // Initialize Engineer Partner
        Partner storage engineer = partners[ENGINEER_ID];
        engineer.exists = true;
        engineer.wallet = ENGINEER_WALLET;
        engineer.referralId = ENGINEER_ID;
        // engineer.parentReferralId = 0; // Default is 0, redundant write
        engineer.role = Role.ENGINEER;

        // Initialize Engineer Upline (all point to engineer ID)
        for (uint i = 0; i < 11; ) {
            engineer.upline[i] = ENGINEER_ID;
            unchecked {
                ++i;
            }
        }

        walletToId[ENGINEER_WALLET] = ENGINEER_ID;

        // Setup globals
        nextReferralId = FOUNDER_ID; // Reserve 0x1000100001 for Founder
        totalPartners = 1;
        // Note: founderDeployed defaults to false (0)

        emit Deployed(ENGINEER_WALLET);
        emit PartnerJoined(ENGINEER_WALLET, ENGINEER_ID, 0);
    }

    /**
     * @notice Deploy the Founder (one-time function, Engineer only).
     * @dev Creates the first member as Founder with ID 0x1000100001.
     *      After this, Engineer permanently loses all access to the contract.
     *      Can only be called once.
     * @param _founderWallet The wallet address for the Founder.
     */
    function deployFounder(address _founderWallet) external onlyEngineer {
        if (founderDeployed) revert FounderAlreadyDeployed();
        if (_founderWallet == address(0)) revert ZeroAddress();
        if (walletToId[_founderWallet] != 0) revert PartnerAlreadyExists();

        // Create Founder partner with fixed ID
        Partner storage founder = partners[FOUNDER_ID];
        founder.exists = true;
        founder.wallet = _founderWallet;
        founder.referralId = FOUNDER_ID;
        founder.referralId = FOUNDER_ID;
        // founder.parentReferralId = 0; // Redundant initialization
        founder.role = Role.FOUNDER;

        // Initialize Founder Upline (all point to Founder ID - self-referencing)
        for (uint i = 0; i < 11; ) {
            founder.upline[i] = FOUNDER_ID;
            unchecked {
                ++i;
            }
        }

        walletToId[_founderWallet] = FOUNDER_ID;

        // Update globals
        founderId = FOUNDER_ID;
        nextReferralId = START_ID; // Next partner will be 0x1000100002
        totalPartners++; // Now 2 (Engineer + Founder)
        founderDeployed = true; // Lock Engineer access

        emit FounderDeployed(_founderWallet, FOUNDER_ID);
        emit PartnerJoined(_founderWallet, FOUNDER_ID, 0);
        emit EngineerLocked();
    }

    // =============================================================
    //                      EXTERNAL FUNCTIONS
    // =============================================================

    /**
     * @notice Join the SafwaNetwork by paying 25 USD and specifying exact placement.
     * @dev Transfers 25 DAI from caller, creates new partner, distributes commissions across 10 levels.
     *      User must specify exact parent ID with available slot (no automatic spillover).
     *      Assigns role based on parent's role.
     * @param _parentReferralId The referral ID of the parent (upline) partner. Must have available slot.
     */
    function join(uint64 _parentReferralId) external nonReentrant {
        if (walletToId[msg.sender] != 0) revert PartnerAlreadyExists();

        // Validate parent exists and has available slot
        if (_parentReferralId == 0) revert ReferralRequired();
        if (!partners[_parentReferralId].exists) revert InvalidReferral();
        if (!_hasAvailableSlot(_parentReferralId))
            revert ReferralCapacityExceeded();

        // Collect 25 DAI from new partner
        _safeTransferFrom(DAI, msg.sender, address(this), PARTNERSHIP_FEE);

        totalPaidJoins++; // Track paid joins for excess DAI calculation

        // Determine role based on parent
        Role newRole = _determineRole(_parentReferralId);

        // Register Partner
        _registerPartner(msg.sender, _parentReferralId, newRole);

        // Distribute Commissions (Internal SDOLLAR)
        _distributeCommissions(msg.sender);
    }

    /**
     * @notice Founder/CoFounder/Leader adds a partner for free (no DAI charge, no commission).
     * @dev
     * - Only callable by Founder, CoFounder, or Leader roles.
     * - Skips DAI payment and commission distribution (unlike `join`).
     * - Role-based limits: Founder (10), CoFounder (5), Leader (1).
     * - Reverts if `_wallet` is zero, already registered, or free add limit exceeded.
     * - Parent must have available slot (no automatic spillover).
     * - Emits `PartnerJoined` but **no `CommissionPaid`** (free addition).
     *
     * @param _wallet The partner's wallet address.
     * @param _parentReferralId Parent ID (defaults to caller's ID if 0).
     * @param _role Initial role (typically `Role.PARTNER`).
     */
    function addPartnerForFree(
        address _wallet,
        uint64 _parentReferralId,
        Role _role
    ) external onlyPrivilegedRole {
        uint64 callerId = walletToId[msg.sender];
        Partner storage caller = partners[callerId];

        // Check role-based free add limits
        uint8 maxFreeAdds;
        if (caller.role == Role.FOUNDER) {
            maxFreeAdds = MAX_FREE_ADDS_FOUNDER;
        } else if (caller.role == Role.COFOUNDER) {
            maxFreeAdds = MAX_FREE_ADDS_COFOUNDER;
        } else if (caller.role == Role.LEADER) {
            maxFreeAdds = MAX_FREE_ADDS_LEADER;
        } else {
            revert NotFounder(); // Should never reach here due to modifier
        }

        if (freeAddsUsed[callerId] >= maxFreeAdds)
            revert FreeAddLimitExceeded();
        if (_wallet == address(0)) revert ZeroAddress();
        if (walletToId[_wallet] != 0) revert PartnerAlreadyExists();

        uint64 requestedParent = _parentReferralId;
        if (requestedParent == 0) {
            requestedParent = callerId; // Default to caller as parent
        } else {
            if (!partners[requestedParent].exists) revert InvalidReferral();
        }

        // Validate parent has available slot (no automatic spillover)
        if (!_hasAvailableSlot(requestedParent))
            revert ReferralCapacityExceeded();

        _registerPartner(_wallet, requestedParent, _role);
        freeAddsUsed[callerId]++; // Increment free adds counter for caller

        emit FounderAddedPartner(
            _wallet,
            walletToId[_wallet],
            requestedParent,
            _role
        );
    }

    /**
     * @notice Transfer SDOLLAR balance to another partner by ID.
     * @dev
     * - Reverts if:
     *   - Sender or recipient does not exist (`PartnerDoesNotExist`).
     *   - Sender has insufficient balance (`InsufficientBalance`).
     *   - `_amount` is zero (`ZeroAmount`).
     * - Does **not** emit `CommissionPaid` (internal transfer only).
     * - Uses `_transferSdollar` internally (handles balance updates and emits `SdollarTransferred`).
     *
     * @param _toReferralId Recipient's referral ID.
     * @param _amount Amount of SDOLLAR to transfer.
     */
    function transferSdollarByReferral(
        uint64 _toReferralId,
        uint256 _amount
    ) external nonReentrant {
        uint64 senderId = walletToId[msg.sender];
        if (senderId == 0) revert PartnerDoesNotExist();

        _transferSdollar(senderId, _toReferralId, _amount);
    }

    /**
     * @notice Transfer SDOLLAR balance to another partner by Address.
     * @param _to Recipient's wallet address.
     * @param _amount Amount of SDOLLAR to transfer.
     */
    function transferSdollarByAddress(
        address _to,
        uint256 _amount
    ) external nonReentrant {
        uint64 senderId = walletToId[msg.sender];
        if (senderId == 0) revert PartnerDoesNotExist();

        if (_to == address(0)) revert ZeroAddress();

        uint64 toId = walletToId[_to];
        if (toId == 0) revert PartnerDoesNotExist();

        _transferSdollar(senderId, toId, _amount);
    }

    /**
     * @notice Withdraw SDOLLAR balance as USDC.
     * @dev Deducts 0.1% tax which goes to the FUND wallet.
     */
    function withdraw() external nonReentrant {
        uint64 id = walletToId[msg.sender];
        if (id == 0) revert PartnerDoesNotExist();

        Partner storage u = partners[id];

        // Requirement: Must have at least 3 referrals to withdraw
        uint256 referralCount = _getReferralCount(id);
        if (referralCount < 3) revert InsufficientReferrals();

        // Requirement: "If sender.sdollarBalance < MIN_WITHDRAWAL, revert"
        if (u.sdollarBalance < MIN_WITHDRAWAL) revert WithdrawalTooSmall();

        // Amount to withdraw = all balance
        uint256 amountSdollar = u.sdollarBalance;

        // Calculate tiered withdrawal tax
        uint256 taxAmount = _calculateWithdrawalTax(amountSdollar);
        uint256 netAmount = amountSdollar - taxAmount;

        // Clear partner balance
        delete u.sdollarBalance;

        // Send tax to FUND wallet
        fundBalance += taxAmount;
        emit FundCollected(id, taxAmount, "Withdrawal tax");

        // Update stats (net amount only)
        u.totalWithdrawn = u.totalWithdrawn + netAmount;
        // Update global stats
        totalSdollarBurned = totalSdollarBurned + netAmount;

        // Emit withdrawal event
        emit Withdrawal(id, netAmount);

        // Convert SDOLLAR (18 decimals) to DAI (18 decimals) - no conversion needed
        uint256 amountDai = netAmount;

        // Safe Transfer Inline
        address token = DAI;
        address to = msg.sender;
        uint256 value = amountDai;

        if (token.code.length == 0) revert TransferFailed();
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        if (!success) revert TransferFailed();
        if (data.length != 0) {
            if (!abi.decode(data, (bool))) revert TransferFailed();
        }
    }

    /**
     * @notice Rescue accidental tokens sent to contract (Founder only).
     * @dev Prevents rescuing DAI to protect user deposits. Other tokens can be rescued.
     * @param _token Address of the token to rescue.
     * @param _amount Amount to rescue.
     */
    function rescueTokens(
        address _token,
        uint256 _amount
    ) external nonReentrant onlyFounder {
        // Prevent rescuing DAI (the deposit token)
        if (_token == DAI) {
            revert CannotRescueDAI();
        }

        emit TokensRescued(_token, _amount, msg.sender);

        // Safe Transfer Inline
        if (_token.code.length == 0) revert TransferFailed();
        (bool success, bytes memory data) = _token.call(
            abi.encodeWithSelector(
                IERC20.transfer.selector,
                msg.sender,
                _amount
            )
        );
        if (!success) revert TransferFailed();
        if (data.length != 0) {
            if (!abi.decode(data, (bool))) revert TransferFailed();
        }
    }

    /**
     * @notice Rescue accidentally sent DAI (excess only, cannot touch user deposits).
     * @dev Calculates legitimate deposits from paid joins and only allows rescuing the excess.
     *      Free adds don't contribute DAI, so we track totalPaidJoins separately.
     *      This protects user deposits while allowing recovery of accidentally sent DAI.
     * @param _amount Amount of excess DAI to rescue.
     */
    function rescueExcessDAI(
        uint256 _amount
    ) external nonReentrant onlyFounder {
        if (_amount == 0) revert ZeroAmount();

        uint256 currentBalance = IERC20(DAI).balanceOf(address(this));

        // Calculate expected DAI backing needed for outstanding SDOLLAR
        // Liabilities = (Total Minted - Total Burned)
        uint256 outstandingSdollar = totalSdollarMinted - totalSdollarBurned;
        uint256 expectedDeposits = outstandingSdollar;

        // Calculate excess DAI (accidentally sent)
        uint256 excessDAI = currentBalance > expectedDeposits
            ? currentBalance - expectedDeposits
            : 0;

        if (_amount > excessDAI) revert InsufficientExcessDAI();

        emit ExcessDAIRescued(_amount, msg.sender);

        // Safe Transfer Inline
        address token = DAI;
        address to = msg.sender;

        if (token.code.length == 0) revert TransferFailed();
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, _amount)
        );
        if (!success) revert TransferFailed();
        if (data.length != 0) {
            if (!abi.decode(data, (bool))) revert TransferFailed();
        }
    }

    /**
     * @notice Receive function to accept ETH sent to contract.
     * @dev ETH sent to contract is tracked as FUND contribution.
     */
    receive() external payable {
        // Track ETH as fund contribution (stays in contract)
        emit FundCollected(0, msg.value, "Received ETH");
    }

    /**
     * @notice Distribute accumulated fund balance: 100% to Founder.
     * @dev Callable by Founder only.
     */
    function distributeFund() external onlyFounder nonReentrant {
        if (fundBalance == 0) revert NoFundsToDistribute();

        uint256 totalAmount = fundBalance;

        // Reset fund balance
        delete fundBalance;

        // Credit 100% to Founder
        partners[founderId].sdollarBalance += totalAmount;

        emit FundDistributed(totalAmount, msg.sender);
    }

    // =============================================================
    //                      INTERNAL FUNCTIONS
    // =============================================================

    /**
     * @dev Calculate tiered withdrawal tax based on amount.
     * Tiers:
     * - ≤100 SDOLLAR: 1 SDOLLAR flat fee
     * - 100-1000 SDOLLAR: 1%
     * - 1000-10000 SDOLLAR: 0.1%
     * - >10000 SDOLLAR: 0.01%
     */
    function _calculateWithdrawalTax(
        uint256 _amount
    ) internal pure returns (uint256) {
        if (_amount <= 100e18) {
            // Flat fee of 1 SDOLLAR
            return 1e18;
        } else if (_amount <= 1000e18) {
            // 1% tax
            return (_amount * 100) / 10000;
        } else if (_amount <= 10000e18) {
            // 0.1% tax
            return (_amount * 10) / 10000;
        } else {
            // 0.01% tax
            return (_amount * 1) / 10000;
        }
    }

    /**
     * @dev Get referral limit based on role.
     */
    function _getReferralLimit(Role _role) internal pure returns (uint256) {
        if (_role == Role.FOUNDER) return LIMIT_FOUNDER;
        if (_role == Role.COFOUNDER) return LIMIT_COFOUNDER;
        if (_role == Role.LEADER) return LIMIT_LEADER;
        return LIMIT_PARTNER; // Default for PARTNER and ENGINEER (Engineer has no referrals)
    }

    /**
     * @dev Get current referral count for a partner.
     */
    function _getReferralCount(
        uint64 _partnerId
    ) internal view returns (uint256) {
        Partner storage u = partners[_partnerId];

        if (u.role == Role.ENGINEER) {
            return engineerReferrals[_partnerId].length;
        } else if (u.role == Role.FOUNDER) {
            return founderReferrals[_partnerId].length;
        } else if (u.role == Role.COFOUNDER) {
            return cofounderReferrals[_partnerId].length;
        } else if (u.role == Role.LEADER) {
            return leaderReferrals[_partnerId].length;
        } else {
            // Partner: count non-zero entries in array
            uint256 count = 0;
            uint256 length = 5; // Cache array length
            for (uint i = 0; i < length; ) {
                if (u.referrals[i] != 0) {
                    unchecked {
                        count++;
                    }
                }
                unchecked {
                    ++i;
                }
            }
            return count;
        }
    }

    /**
     * @dev Check if partner has available referral slot.
     */
    function _hasAvailableSlot(uint64 _partnerId) internal view returns (bool) {
        Partner storage u = partners[_partnerId];
        uint256 limit = _getReferralLimit(u.role);
        uint256 count = _getReferralCount(_partnerId);
        return count < limit;
    }

    /**
     * @dev Add a referral to parent's list.
     */
    function _addReferral(uint64 _parentId, uint64 _childId) internal {
        Partner storage parent = partners[_parentId];

        if (parent.role == Role.ENGINEER) {
            engineerReferrals[_parentId].push(_childId);
        } else if (parent.role == Role.FOUNDER) {
            founderReferrals[_parentId].push(_childId);
        } else if (parent.role == Role.COFOUNDER) {
            cofounderReferrals[_parentId].push(_childId);
        } else if (parent.role == Role.LEADER) {
            leaderReferrals[_parentId].push(_childId);
        } else {
            // Partner: find first empty slot in array
            for (uint i = 0; i < 5; i++) {
                if (parent.referrals[i] == 0) {
                    parent.referrals[i] = _childId;
                    return;
                }
            }
            revert ReferralCapacityExceeded();
        }
    }

    /**
     * @dev Get all referrals for a partner (returns dynamic array).
     */
    function _getAllReferrals(
        uint64 _partnerId
    ) internal view returns (uint64[] memory) {
        Partner storage u = partners[_partnerId];

        if (u.role == Role.ENGINEER) {
            return engineerReferrals[_partnerId];
        } else if (u.role == Role.FOUNDER) {
            return founderReferrals[_partnerId];
        } else if (u.role == Role.COFOUNDER) {
            return cofounderReferrals[_partnerId];
        } else if (u.role == Role.LEADER) {
            return leaderReferrals[_partnerId];
        } else {
            // Partner: return non-zero entries
            uint256 count = _getReferralCount(_partnerId);
            uint64[] memory result = new uint64[](count);
            uint256 index = 0;
            uint256 length = 5; // Cache array length
            for (uint i = 0; i < length; ) {
                if (u.referrals[i] != 0) {
                    result[index++] = u.referrals[i];
                }
                unchecked {
                    ++i;
                }
            }
            return result;
        }
    }

    /**
     * @dev Determine role based on parent's role.
     * - Parent is Founder → CoFounder
     * - Parent is CoFounder → Leader
     * - Otherwise → Partner
     */
    function _determineRole(uint64 _parentId) internal view returns (Role) {
        Partner storage parent = partners[_parentId];

        if (parent.role == Role.FOUNDER) {
            return Role.COFOUNDER;
        } else if (parent.role == Role.COFOUNDER) {
            return Role.LEADER;
        } else {
            return Role.PARTNER;
        }
    }

    function _registerPartner(
        address _wallet,
        uint64 _parentId,
        Role _role
    ) internal {
        // Parent capacity is already validated by caller (join or addPartnerForFree)
        Partner storage parent = partners[_parentId];

        // Assign ID
        if (nextReferralId > MAX_ID) revert InvalidIdRange();
        uint64 newId = nextReferralId++;

        // Initialize Partner
        Partner storage newPartner = partners[newId];
        newPartner.exists = true;
        newPartner.wallet = _wallet;
        newPartner.referralId = newId;
        newPartner.parentReferralId = _parentId;
        newPartner.role = _role;

        // Link wallet
        walletToId[_wallet] = newId;

        // Add to parent's referral list
        _addReferral(_parentId, newId);

        // Build Upline
        // "Take parent’s upline array. Shift it left by one (drop index 0). Append the new partner’s wallet address at the last index (10)."
        // Upline array is uint64[11]
        // parent.upline is [10th gp, ..., parent, self]

        // Copy parent's upline 1..10 into newPartner 0..9
        for (uint i = 0; i < 10; ) {
            newPartner.upline[i] = parent.upline[i + 1];
            unchecked {
                ++i;
            }
        }
        // Slot 10 is self
        newPartner.upline[10] = newId;

        totalPartners++;
        emit PartnerJoined(_wallet, newId, _parentId);
    }

    /**
     * @dev Internal function to distribute commissions up 10 levels.
     * @param _originWallet The address of the partner who just joined (source of commission).
     */
    function _distributeCommissions(address _originWallet) internal {
        // Levels 1 to 10
        // Level 1: 25% (6.25 USDC Value)
        // Level 2: 10% (2.50 USDC Value)
        // Level 3: 10% (2.50 USDC Value)
        // Level 4:  5% (1.25 USDC Value)
        // Level 5: 10% (2.50 USDC Value)
        // Level 6: 10% (2.50 USDC Value)
        // Level 7:  5% (1.25 USDC Value)
        // Level 8: 10% (2.50 USDC Value)
        // Level 9: 10% (2.50 USDC Value)
        // Level 10: 5% (1.25 USDC Value)

        // The receiver for Level 1 is the direct parent.
        // In the new partner's `upline` array:
        // index 10 is self.
        // index 9 is Level 1 upline (direct parent).
        // index 8 is Level 2 upline.
        // ...
        // index 0 is Level 10 upline.

        uint64 originId = walletToId[_originWallet];
        uint64[11] memory upline = partners[originId].upline;

        // Percentages x 100 for easy calc?
        // 25 USDC Value = 25e18 (Internal SDOLLAR).
        uint256[10] memory payouts;
        payouts[0] = 6.25e18; // Lvl 1 (25%)
        payouts[1] = 2.50e18; // Lvl 2 (10%)
        payouts[2] = 2.50e18; // Lvl 3 (10%)
        payouts[3] = 1.25e18; // Lvl 4 (5%)
        payouts[4] = 2.50e18; // Lvl 5 (10%)
        payouts[5] = 2.50e18; // Lvl 6 (10%)
        payouts[6] = 1.25e18; // Lvl 7 (5%)
        payouts[7] = 2.50e18; // Lvl 8 (10%)
        payouts[8] = 2.50e18; // Lvl 9 (10%)
        payouts[9] = 1.25e18; // Lvl 10 (5%)

        for (uint i = 0; i < 10; ) {
            // Level is i+1
            // Upline index is 9 - i
            uint64 receiverId = upline[9 - i];
            uint256 amount = payouts[i];

            // If receiver is missing or not a registered partner, default to Founder
            if (receiverId == 0 || !partners[receiverId].exists) {
                receiverId = founderId; // Founder gets commission for missing uplines
            }

            _creditPartner(receiverId, amount, uint8(i + 1));
            emit CommissionPaid(originId, receiverId, uint8(i + 1), amount);

            unchecked {
                ++i;
            }
        }
    }

    function _creditPartner(
        uint64 _uid,
        uint256 _amount,
        uint8 _level
    ) internal {
        Partner storage u = partners[_uid];
        u.sdollarBalance = u.sdollarBalance + _amount;
        u.totalEarned = u.totalEarned + _amount;
        if (_level != 0 && _level <= 10) {
            u.levelRevenue[_level - 1] = u.levelRevenue[_level - 1] + _amount;
            u.levelPartnerCount[_level - 1]++;
        }

        totalSdollarMinted = totalSdollarMinted + _amount;
    }

    function _transferSdollar(
        uint64 _fromId,
        uint64 _toId,
        uint256 _amount
    ) internal {
        if (_amount == 0) revert ZeroAmount();
        Partner storage sender = partners[_fromId];
        Partner storage receiver = partners[_toId];

        if (!receiver.exists) revert PartnerDoesNotExist();
        if (sender.sdollarBalance < _amount) revert InsufficientBalance();

        sender.sdollarBalance = sender.sdollarBalance - _amount;
        receiver.sdollarBalance = receiver.sdollarBalance + _amount;

        emit SdollarTransferred(_fromId, _toId, _amount);
    }

    // =============================================================
    //                       VIEW FUNCTIONS
    // =============================================================

    function getPartnerByReferral(
        uint64 _id
    ) public view returns (PartnerView memory) {
        Partner storage u = partners[_id];
        uint256 count = 0;
        uint256 length = 5; // Cache array length
        for (uint i = 0; i < length; ) {
            if (u.referrals[i] != 0) {
                unchecked {
                    count++;
                }
            }
            unchecked {
                ++i;
            }
        }
        return
            PartnerView({
                exists: u.exists,
                wallet: u.wallet,
                referralId: u.referralId,
                parentReferralId: u.parentReferralId,
                role: u.role,
                sdollarBalance: u.sdollarBalance,
                totalEarned: u.totalEarned,
                totalWithdrawn: u.totalWithdrawn,
                referralCount: count
            });
    }

    function getPartnerByAddress(
        address _addr
    ) external view returns (PartnerView memory) {
        uint64 id = walletToId[_addr];
        if (id == 0)
            return
                PartnerView(false, address(0), 0, 0, Role.PARTNER, 0, 0, 0, 0);
        return getPartnerByReferral(id);
    }

    function getDirectReferrals(
        uint64 _id
    ) external view returns (uint64[] memory) {
        return _getAllReferrals(_id);
    }

    function getPartnerUpline(
        uint64 _id
    ) external view returns (uint64[11] memory) {
        return partners[_id].upline;
    }

    function getPartnerLevelStats(
        uint64 _id
    )
        external
        view
        returns (uint256[10] memory revenue, uint32[10] memory counts)
    {
        Partner storage u = partners[_id];
        return (u.levelRevenue, u.levelPartnerCount);
    }

    /**
     * @notice Get current fund balance.
     */
    function getFundBalance() external view returns (uint256) {
        return fundBalance;
    }
}
