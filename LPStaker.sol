/*
     _____ _____ _____ ____  _____    __    _____    _____               
    |   __|  |  |  _  |    \|   __|  |  |  |  _  |  |   __|___ ___ _____ 
    |__   |     |     |  |  |   __|  |  |__|   __|  |   __| .'|  _|     |
    |_____|__|__|__|__|____/|_____|  |_____|__|     |__|  |__,|_| |_|_|_|

*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

// #0005 issue in audit report
// each contract in its own file
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

// ------------------------------------- IMasterChef -------------------------------------------
interface IMasterChef {
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. SHADEs to distribute per block.
        uint256 lastRewardTime;   // Last block time that SHADEs distribution occurs.
        uint256 accSHADEPerShare; // Accumulated SHADEs per share, times 1e12. See below.
    }
    function pendingSHADE(uint256 pid, address user) external view returns (uint256);
    function shadePerSecond() external view returns (uint256);
    function totalAllocPoint() external view returns (uint256);
    function poolInfo(uint256 pid) external view returns (PoolInfo memory);    
    function deposit(uint256 pid, uint256 amount) external;  
    function withdraw(uint256 pid, uint256 amount) external;  
}
// ------------------------------------- IRewardsStaker -------------------------------------------
interface IRewardsStaker {
    function stakeFrom(address account, uint256 amount) external returns (bool);
	function lockStakers(address account) external view returns (bool);	
}

// -------------------------------------------------------------------------------------------
// ------------------------------------- LP Staker -------------------------------------------
// -------------------------------------------------------------------------------------------
contract A_LP_Staker is ERC20, Ownable {
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }
	
	// #0004 issue in audit report
	// Mark variables as immutable	
    IERC20 public immutable lpToken;           // Address of LP token contract.
    uint256 public lpDeposited;   
    uint256 public startTime;
    uint256 public lastRewardTime;  // Last block time that SHADEs distribution occurs.
    uint256 public accSHADEPerShare; // Accumulated SHADEs per share, times 1e12. See below.
    
	// #0004 issue in audit report
	// Mark variables as immutable
    IERC20 public immutable shade;
    IMasterChef public immutable masterChef;
	// #0004 issue in audit report
	// This variable can't be set immutable since it set in setRewardsStaker() method
    IRewardsStaker public rewardsStaker;
    uint256 public masterPoolId;
    
    // Info of each user that stakes LP tokens.
    mapping (address => UserInfo) public userInfo;
   
    constructor() ERC20("ShadeDummy", "SHD") {
        shade = IERC20(0x3c88baD5dcd1EbF35a0BF9cD1AA341BB387fF73A);
        masterChef = IMasterChef(0x8b7bcce67d2566D26393A6b81cAE010762C196B2);
        lpToken = IERC20(0x3ba80AfDDcdcc301435A8fB8d198cCDb72Bc9a73);
    }
        
    // ---------- VIEWS ----------
    
    function masterPending() public view returns (uint256) {
        if (masterPoolId == 0) return 0;
        return masterChef.pendingSHADE(masterPoolId, address(this));
    }
    function shadePerSecond() public view returns (uint256) {
        if (masterPoolId == 0 || masterChef.totalAllocPoint() == 0) return 0;
        return masterChef.shadePerSecond() * masterChef.poolInfo(masterPoolId).allocPoint / masterChef.totalAllocPoint();
    }
    
    // View function to see pending SHADEs on frontend.
    function pendingSHADE(address account) public view returns (uint256) {
        UserInfo storage user = userInfo[account];
        if (user.amount == 0) return 0;
        
        uint256 _accSHADEPerShare = accSHADEPerShare;
        
        if (block.timestamp > lastRewardTime) {
            _accSHADEPerShare = _accSHADEPerShare + (masterPending() * 1e12 / lpDeposited);
        }
        return user.amount * _accSHADEPerShare / 1e12 - user.rewardDebt;
    }

    // Contract Data method for decrease number of request to contract from dApp UI
    function contractData() public view returns (
        uint256 _lpDeposited,           
        uint256 _shadePerSecond             
        ) { 
        _lpDeposited = lpDeposited; 
        _shadePerSecond = shadePerSecond();        
    }

    // User Data method for decrease number of request to contract from dApp UI
    function userData(address account) public view returns (
        UserInfo memory _userInfo,       // Balances
        uint256 _pendingSHADE,           
        uint256 _lpTokenAllowance,      
        uint256 _lpTokenBalance        
        ) {  
        _userInfo = userInfo[account]; 
        _pendingSHADE = pendingSHADE(account);
        _lpTokenAllowance = lpToken.allowance(account, address(this));
        _lpTokenBalance = lpToken.balanceOf(account);        
    }

    // ---------- MUTATIVE FUNCTIONS ----------
    //
    function updatePool() public {
        if (block.timestamp <= lastRewardTime) return;
        
        lastRewardTime = block.timestamp;
        
        if (lpDeposited == 0) return;
        
        uint256 shadeReward = masterPending();        
        
        if (shadeReward != 0) {

			// #0002 issue in audit report
			// situation when received rewards amount could be different than transferred 
			// is possible when masterChef will reach maxTotalSupply for Shade token with mint method
			// Contract designed to work ONLY with ONE predefined token and CURRENT masterChef contract and it can't have any fees.
			uint256 oldBalance = shade.balanceOf(address(this));
            masterChef.withdraw(masterPoolId, 0);
			uint256 received = shade.balanceOf(address(this)) - oldBalance;

			if (received != shadeReward) {
				shadeReward = received;
			} 
            accSHADEPerShare += shadeReward * 1e12 / lpDeposited;           
        }      
    }

	// #0001 deposit token used with this contract will never have a transfer fee
    // Deposit LP tokens to for SHADE allocation.
    function deposit(uint256 amount) public {        
        require(startTime != 0, "Not started");

        UserInfo storage user = userInfo[msg.sender];

        updatePool();

        uint256 pending = user.amount * accSHADEPerShare / 1e12 - user.rewardDebt;

        user.amount += amount;
        user.rewardDebt = user.amount * accSHADEPerShare / 1e12;

        _sendRewards(pending);
        
        lpToken.safeTransferFrom(address(msg.sender), address(this), amount);
        lpDeposited += amount;

        emit Deposit(msg.sender, amount);
    }

	// #0002 deposit token used with this contract will never have a transfer fee
    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 amount) public {  
        UserInfo storage user = userInfo[msg.sender];
        
        require(user.amount >= amount, "Not enough funds");

        updatePool();

        uint256 pending = user.amount * accSHADEPerShare / 1e12 - user.rewardDebt;
        
        user.amount -= amount;
        user.rewardDebt = user.amount * accSHADEPerShare / 1e12;

        _sendRewards(pending);

        lpDeposited -= amount;
        lpToken.safeTransfer(address(msg.sender), amount);        
        
        emit Withdraw(msg.sender, amount);
    }
    
    function claim() public {  
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount != 0, "User has 0 deposit");

        updatePool();

        uint256 pending = user.amount * accSHADEPerShare / 1e12 - user.rewardDebt;
        user.rewardDebt = user.amount * accSHADEPerShare / 1e12;

        _sendRewards(pending);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw() public {
        UserInfo storage user = userInfo[msg.sender];

        uint amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        lpDeposited -= amount;
        lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, amount);
    }

    // Rewards could be transfered in two ways    
    function _sendRewards(uint256 pending) internal {
        uint256 shadeBal = shade.balanceOf(address(this));

        if (pending > 0 && shadeBal != 0) {
            uint256 amount = shadeBal < pending ? shadeBal : pending;            
            
            // 1. If rewardsStaker is set then all goes to 3 month lock contract
			// added additional check if contract added to lockStakers list
            if (address(rewardsStaker) != address(0) && rewardsStaker.lockStakers(address(this))) {
                shade.approve(address(rewardsStaker), amount);
                bool success = rewardsStaker.stakeFrom(msg.sender, amount);  				
                require(success, "Stake to lock error");
                emit Stake(msg.sender, amount);  
            } 
            // 2. If rewardsStaker not set then all goes to user
            else {
                shade.safeTransfer(msg.sender, amount);
                emit Claim(msg.sender, amount);
            } 
        }
    }

    // after set this address to non zero address all rewards will be locked for 3 month
	// #0003 issue in audit report
	// Not sure I understand this issue. The rewardsStaker contract 100% will use a timelock and in method _sendRewards
	// we additionally check for stakeFrom success result. If no success funds not sending and revert with error
	// bool success = rewardsStaker.stakeFrom(msg.sender, amount);  				
    // require(success, "Stake to lock error");
	// added additional check if contract added to lockStakers list
    function setRewardsStaker(IRewardsStaker newRewardsStaker) external onlyOwner {
		require(newRewardsStaker.lockStakers(address(this)), "This contract not added to list of lock stakers");
        rewardsStaker = newRewardsStaker;
    }

    // deposit 1 dummy token to current master chef for rewards proxy    
    function depositToMaster(uint256 pid) external onlyOwner {
        require(masterPoolId == 0, "Already deposited");  // we can deposit only once
        require(pid != 0, "Can't deposit to 0 pid"); // pid 0 already busy on current master chef

        masterPoolId = pid;

        uint256 amount = 1e18;
        _mint(address(this), amount);
        _approve(address(this), address(masterChef), amount);
        
        masterChef.deposit(pid, amount);

        startTime = block.timestamp;
        lastRewardTime = block.timestamp;

		// #0006 issue in audit report
		// Emit event from function
		emit DepositToMaster(masterPoolId);
    }

    // ---------- EVENTS -----------
    event Deposit(address indexed account, uint256 amount);
    event Withdraw(address indexed account, uint256 amount);
    event EmergencyWithdraw(address indexed account, uint256 amount);
    event Claim(address indexed account, uint256 amount);
    event Stake(address indexed account, uint256 amount);     
	event DepositToMaster(uint256 pid);   
}