// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';

// ------------------------------------- IWETH -------------------------------------------
interface IWETH {
    function deposit() external payable;
}
// ------------------------------------- IPenaltyReceiver -------------------------------------------
interface IPenaltyReceiver {
    function notifyReward(uint256 reward) external;
}

// Shade staked within this contact entitles stakers to a portion of the admin fees generated by Shade Payment contracts
contract ShadeStaker is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    
    // -------------------------------- VARIABLES -----------------------------------
    struct Reward {
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }
    struct LockedBalance {
        uint256 amount;
        uint256 unlockTime;
        uint256 id;
    }
    struct RewardData {
        address token;
        uint256 amount;
    }

    IERC20 public immutable stakingToken;
	IWETH public immutable WETH;
    address[] public rewardTokens;
	// AUDIT Finding Id: 12
	uint256 private constant maxRewardsTokens = 10; // maximum number of reward token instances 
	address public penaltyReceiver;
	
    mapping(address => Reward) public rewardData;

    // contract designed to work ONLY for 3 month (13 weeks) and 7 days (1 week) rewards distribution period
	// be carefull by setting lockDurationMultiplier to higher value it can sonsume lot of gas 
	// because lockDurationMultiplier represent number of possible user locks
	// if you want longer time for lock increase rewardsDuration instead
	// or make own research for suitable by gas consumption lockDurationMultiplier  
	// Duration that rewards are streamed over
    uint256 public constant rewardsDuration = 7 days; // 
	uint256 public constant lockDurationMultiplier = 13; // 7 * 13 = 91 days ~= 3 month 
    // Duration of lock penalty period
    uint256 public constant lockDuration = rewardsDuration * lockDurationMultiplier; 
    
    // reward token -> distributor -> is approved to add rewards
    mapping(address=> mapping(address => bool)) public rewardDistributors;
    
    // addresses that allowed to stake in lock
    mapping(address => bool) public lockStakers;

    // user -> reward token -> amount
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public rewards;

    uint256 public totalSupply;
    
    // Private mappings for balance data
    mapping(address => uint256) public balances;
    mapping(address => LockedBalance[]) public userLocks;
	mapping(address => uint256) public startIndex;
    // id's for users locks (unlock by id)
    uint256 public lockIds;
        
    // -------------------------------- CONSTRUCTOR -----------------------------------

    constructor() Ownable() {
        stakingToken = IERC20(0x3c88baD5dcd1EbF35a0BF9cD1AA341BB387fF73A); // SHADE
		WETH = IWETH(0x15c34D8b356F21112C07cA1811D84101F480a3F1); // wFTM address
        
        setLockStaker(0xa4873Ff784306A8B6f82cd1123D3b967CaFBdA6A, true);  // LP FARM address
        addRewardToken(address(WETH), 0x380Ff6e45b4606e21B686979060Cad429FB72548);  // Payments FTM contract
    }

    // -------------------------------- CONFIG -----------------------------------

    // Add a new reward token to be distributed to stakers
    function addRewardToken(address rewardsToken, address distributor) public onlyOwner {
        require(rewardData[rewardsToken].lastUpdateTime == 0, "Taken already added");
		// AUDIT Finding Id: 12	
		require(rewardTokens.length < maxRewardsTokens, "Maximun number of reward tokens reached");

        rewardTokens.push(rewardsToken);
        rewardData[rewardsToken].lastUpdateTime = block.timestamp;
        rewardData[rewardsToken].periodFinish = block.timestamp;
        rewardDistributors[rewardsToken][distributor] = true;
		emit AddRewardToken(rewardsToken, distributor);
    }

    // Modify approval for an address to call notifyRewardAmount
    function setRewardDistributor(address rewardsToken, address distributor, bool state) external onlyOwner {
        require(rewardData[rewardsToken].lastUpdateTime > 0, "Token not added");
		require(rewardDistributors[rewardsToken][distributor] != state, "Distributor already set");
        rewardDistributors[rewardsToken][distributor] = state;
		emit SetRewardDistributor(rewardsToken, distributor, state);
    }

    // Set PenaltyReceiver address for send penalty
    function setPenaltyReceiver(address newPenaltyReceiver) public onlyOwner {
        penaltyReceiver = newPenaltyReceiver;
		emit SetPenaltyReceiver(newPenaltyReceiver);
    }

    // Add lock staker for staking claimed rewards
    function setLockStaker(address lockStaker, bool state) public onlyOwner {
        require(lockStakers[lockStaker] != state, "LockStaker already set");
		lockStakers[lockStaker] = state;   
		emit SetLockStaker(lockStaker);     
    }

    // -------------------------------- VIEWS -----------------------------------
    //
    function rewardPerToken(address rewardsToken) internal view returns (uint256) {
        if (totalSupply == 0) {
            return rewardData[rewardsToken].rewardPerTokenStored;
        }        
        return rewardData[rewardsToken].rewardPerTokenStored + ( (lastTimeRewardApplicable(rewardsToken) - rewardData[rewardsToken].lastUpdateTime) * rewardData[rewardsToken].rewardRate * 1e18 / totalSupply );
    }

    //
    function earned(address user, address rewardsToken) internal view returns (uint256) {
        if (balances[user] == 0) return 0;
        return balances[user] * (rewardPerToken(rewardsToken) - userRewardPerTokenPaid[user][rewardsToken]) / 1e18 + rewards[user][rewardsToken];
    }

    //
    function lastTimeRewardApplicable(address rewardsToken) internal view returns (uint256) {
        return block.timestamp < rewardData[rewardsToken].periodFinish ? block.timestamp : rewardData[rewardsToken].periodFinish;
    }

    //
    function claimRewardForDuration(address rewardsToken) internal view returns (uint256) {
        return rewardData[rewardsToken].rewardRate * rewardsDuration;
    }

    // Address and claimable amount of all reward tokens for the given account
    function claimableRewards(address account) public view returns (RewardData[] memory rewardsAvailable) {
        uint256 length = rewardTokens.length;
		rewardsAvailable = new RewardData[](length);
        for (uint256 i = 0; i < length; i++) {
            rewardsAvailable[i].token = rewardTokens[i];
            rewardsAvailable[i].amount = earned(account, rewardsAvailable[i].token);
        }
        return rewardsAvailable;
    }

	function lockedBalance(address account) public view returns (uint256 amount) {
		LockedBalance[] memory locks = userLocks[account];
		for (uint i = startIndex[account]; i < locks.length; i++) {
            if (locks[i].unlockTime > block.timestamp) {
                amount += locks[i].amount;
			}  			         
        } 		
	}

    // Final balance received and penalty balance paid by user upon calling withdrawAll
    function withdrawableBalance(address account) public view returns (uint256 amount, uint256 penaltyAmount) {
        LockedBalance[] memory locks = userLocks[account];
        uint256 balance = balances[account];
        // how much account has locks
        uint256 length = locks.length;
        if (length == 0) {
            // if no locks unlocked balance is total
            amount = balance;
        } else {
            if (locks[length-1].unlockTime > block.timestamp) {
				uint256 locked = lockedBalance(account);
				uint256 unlocked = balance - locked;
				penaltyAmount = locked / 2;
				// total amount to withdraw
				amount = unlocked + (locked - penaltyAmount);
            } else {
                // if last lock expired than no need to check all locks since they already unlocked
                amount = balance; 
            }
        }   
        //return (amount, penaltyAmount);
    }

    // Contract Data method for decrease number of request to contract from dApp UI
    function contractData() public view returns (
        uint256 _totalStaked,            // totalSupply
        address[] memory _rewardTokens,   // rewardTokens
        uint256[] memory _rewardPerToken,   // rewardPerToken        
        uint256[] memory _claimRewardForDuration,   // claimRewardForDuration        
        uint256[] memory _rewardBalances,   // rewardBalances   
        uint256 _rewardsDuration,            // rewardsDuration   
        uint256 _lockDuration            // lockDuration   
        ) {
            _totalStaked = totalSupply;
			_rewardTokens = rewardTokens;
			_rewardPerToken = new uint256[](rewardTokens.length);
            _claimRewardForDuration = new uint256[](rewardTokens.length);
            _rewardBalances = new uint256[](rewardTokens.length);

			// AUDIT Finding Id: 4
			// rewardTokens.length limited by maxRewardsTokens            
            for (uint i; i < rewardTokens.length; i++) {
               _claimRewardForDuration[i] = claimRewardForDuration(rewardTokens[i]);
               _rewardPerToken[i] = rewardPerToken(rewardTokens[i]);
               _rewardBalances[i] = IERC20(rewardTokens[i]).balanceOf(address(this));
            }

			_rewardsDuration = rewardsDuration;
			_lockDuration = lockDuration;
    }

    // User Data method for decrease number of request to contract from dApp UI
    function userData(address account) public view returns (
        uint256 _staked,  // Staked balance
        uint256 _locked,  // Locked balance
        LockedBalance[] memory _userLocks,     // Locks
        RewardData[] memory _claimableRewards,        // claimableRewards
        uint256 _allowance,                     // allowance of staking token        
        uint256 _balance                    // balance of staking token        
        ) {
			// AUDIT Finding Id: 11 	
            // Balances and Locks
			// since some of lock could be expired at moment of call we need to recalculate actual locked balance
			// we can do it also on UI by adding all locks amounts together, but nicer to return it directly from contract
            _staked = balances[account];

            LockedBalance[] memory locks = userLocks[account];     			
			// AUDIT Finding Id: 4
			// length can't be more than 14            
			_userLocks = new LockedBalance[](locks.length - startIndex[account]);
			uint256 idx;
			for (uint i = startIndex[account]; i < locks.length; i++) {
				// AUDIT Finding Id: 7
                if (locks[i].unlockTime > block.timestamp) {
                   	_userLocks[idx] = locks[i]; 
					_locked += locks[i].amount;                    
                    idx ++;             
                }            
            }
			            
            _claimableRewards = claimableRewards(account);
            _allowance = stakingToken.allowance(account, address(this));
            _balance = stakingToken.balanceOf(account);        
    }

    // -------------------------------- MUTATIVE FUNCTIONS -----------------------------------
    function stakeFrom(address account, uint256 amount) external returns (bool){
        require(lockStakers[msg.sender], "Sender not allowed to stake with lock");
        _stake(account, amount, true);
        return true;
    }

    function stake(uint256 amount) external {
        _stake(msg.sender, amount, false);
    }
    
    // Stake tokens to receive rewards
    // Locked tokens can't be withdrawn for lockDuration and are eligible to receive staking rewards
    function _stake(address account, uint256 amount, bool lock) internal nonReentrant {        
        _updateReward(account);
        _updateUserLocks(account);

        require(amount != 0, "Can't stake 0");

        balances[account] += amount;
        if (lock) {            
            // AUDIT Finding Id: 6
			// AUDIT Finding Id: 10 
			// rounding here used for getting time multiple to one reward period (7 days).
			// block.timestamp / rewardsDuration * rewardsDuration gives us number seconds of full weeks since 'begining of time'.
			// it means than every lock created in this period will be added to existing (latest one).
			// so user can have maximum 14 locks because when last creted first will expired and handeled in _updateUserLocks method.
			
			// contract designed to lock for 13 weeks (3 month) with 1 week (7 days) rewards distribution ONLY.
			
			// example 
			// Thursday, 20 January 2022, 02:40:37  1642646437 / 604800 * 604800 = 1642636800
			// Thursday, 20 January 2022, 05:31:25  1642656685 / 604800 * 604800 = 1642636800
			// Saturday, 22 January 2022, 10:20:57  1642846857 / 604800 * 604800 = 1642636800
			
			// as you see all these times will be assigned to one lock with unlock time 1642636800.
			
			uint256 unlockTime = (block.timestamp / rewardsDuration * rewardsDuration) + lockDuration;
            uint256 locksLength = userLocks[account].length;
			
			// now we check to create new lock or add funds to existing (last)
			// AUDIT Finding Id: 7
			// if no locks then creating new or last lock in next distribution period 
            if (locksLength == 0 || userLocks[account][locksLength-1].unlockTime < unlockTime) {
                // AUDIT Finding Id: 8 
				// lock id required for withdraw exact lock dy this id
				// weird logic to withdraw certain lock 
				// initially contract allolow to withdraw any desired amount
				// if this amount less or equal to unlocked then no penalty
				// if amount grater than unlocked user pay penalty for extra unlocked tokens
				// all that left keeps locked 
				// I tried to explain it to client but he want this and dot  
				lockIds ++;
                userLocks[account].push(LockedBalance({
                    amount: amount, 
                    unlockTime: unlockTime,
                    id: lockIds
                }));
            } else {								
                userLocks[account][locksLength-1].amount += amount;
            }
        } 

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        totalSupply += amount;

        emit Staked(account, amount, lock);
    }
        
    // Claim all pending staking rewards
    function claimReward() public nonReentrant {
        _updateReward(msg.sender);
        _claimReward(msg.sender);        
    }
    
    // Withdraw defined amount of unlocked tokens
    function withdraw(uint256 amount) public nonReentrant {
        require(amount != 0, "Can't withdraw 0");            
        
        _updateUserLocks(msg.sender);
        _updateReward(msg.sender);
        _claimReward(msg.sender);       
     
        require(amount <= balances[msg.sender] - lockedBalance(msg.sender), "Not enough unlocked tokens to withdraw"); 
                
        balances[msg.sender] -= amount;    
		// AUDIT Finding Id: 1
		// it was my mechanical mistake and I fixed it as soon noticed it on testing
		_sendTokensAndPenalty(amount, 0);
                
        emit Withdrawn(msg.sender, amount);
    }

    // Withdraw all user locked tokens
    function withdrawLocked() public nonReentrant {
        // first let's update all user locks to determine locked balance
        _updateUserLocks(msg.sender); 
        _updateReward(msg.sender);
        _claimReward(msg.sender);
        
        // determine available tokens amount
        uint256 amount = lockedBalance(msg.sender);
        require(amount != 0, "Can't withdraw 0");       
        
        balances[msg.sender] -= amount;
       
        delete userLocks[msg.sender];
		startIndex[msg.sender] = 0;
        
		// AUDIT Finding Id: 6
		// if we divide not multiple by two amount (3, 23, 123123, 46234672364783...) by 2 then we will have presision error
		// that's why we subtrat penalty from amount to get leftover
		// so every such amount withdraw we give user 1 extra wei instead send it to penalty 
		// but we not lose this 1 wei
		uint256 penalty = amount / 2;
        amount -= penalty; 

        _sendTokensAndPenalty(amount, penalty);

        emit Withdrawn(msg.sender, amount);
    }

    // Withdraw exact lock by id
    function withdrawLock(uint256 id) public nonReentrant {
        require(id != 0 && id <= lockIds, "No such id"); 
        // first let's update all user locks to determine locked balance
        _updateUserLocks(msg.sender); 
        _updateReward(msg.sender);
        _claimReward(msg.sender);
         
        LockedBalance[] storage locks = userLocks[msg.sender];         
        uint256 amount; 

		uint256 locksLength = locks.length;

		// restriction to withdraw last lock, othrwise will broke stake method and tokens will be lost. Or maybe I'm wrong
		//require(locksLength > 1, "No locks to withdraw by id"); 
		//require(id != locks[locksLength - 1].id, "Can't withdraw last lock by id");    
		 

		// AUDIT Finding Id: 4
		// length can't be more than lockDurationMultiplier (14)
        for (uint i = startIndex[msg.sender]; i < locksLength; i++) {
            if (locks[i].id == id) {
                amount = locks[i].amount;
				delete locks[i];
				break;
            } 			         
        } 

        require(amount != 0, "Lock not found or already unlocked");		
        balances[msg.sender] -= amount;
        
		// AUDIT Finding Id: 6
		// if we divide not multiple by two amount (3, 23, 123123, 46234672364783...) by 2 then we will have presision error
		// that's why we subtrat penalty from amount to get leftover
		// so every such amount withdraw we give user 1 extra wei instead send it to penalty 
		// but we not lose this 1 wei
		uint256 penalty = amount / 2;
        amount -= penalty;     

        _sendTokensAndPenalty(amount, penalty);

        emit Withdrawn(msg.sender, amount); 
    }
    
    function updateUserLocks() public {
        _updateUserLocks(msg.sender);
    }

    function notifyRewardAmount(address rewardsToken, uint256 reward) external {
        require(rewardDistributors[rewardsToken][msg.sender], "Only distributor allowed to send rewards");
        require(reward != 0, "No reward");
        _updateReward(address(0));

        // handle the transfer of reward tokens via `transferFrom` 
        IERC20(rewardsToken).safeTransferFrom(msg.sender, address(this), reward);
        _notifyReward(rewardsToken, reward);
        emit RewardAdded(reward);
    }

	// 
    function notifyRewardAmountFTM() public payable {
        require(rewardDistributors[address(WETH)][msg.sender], "Only distributor allowed to send FTM");
        require(msg.value != 0, "No reward"); 
        _updateReward(address(0));

        // swapt ftm to wrapped ftm  
        IWETH(WETH).deposit{ value: msg.value }();
		_notifyReward(address(WETH), msg.value);
        emit FTMReceived(msg.sender, msg.value);     
    }

    // Added to support recovering 
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken), "Can't withdraw staking token");
        require(rewardData[tokenAddress].lastUpdateTime == 0, "Can't withdraw reward token");
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

	receive() external payable {
		notifyRewardAmountFTM();
    }

    // -------------------------------- RESTRICTED -----------------------------------

    // Update all currently locked tokens where the unlock time has passed
    function _updateUserLocks(address account) internal {
        // changed to memory, since we don't rewrite user locks
		LockedBalance[] memory locks = userLocks[account];
        
        uint256 locksLength = locks.length;
        // return if user has no locks
        if (locksLength == 0) return;
		
        // searching for expired locks from stratIndex untill first locked found or end reached        
        while (locks[startIndex[account]].unlockTime <= block.timestamp 
			&& startIndex[account] < locksLength) {
			startIndex[account] ++;
		} 
		
		// if end reached it means no lock found and we can reset startedIndex and clear all locks array
		if (startIndex[account] >= locksLength) {
            startIndex[account] = 0;
            delete userLocks[account];
        }
    }

    function _updateReward(address account) internal {
		// AUDIT Finding Id: 4
		// rewardTokens.length limited by maxRewardsTokens
        for (uint i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            rewardData[token].rewardPerTokenStored = rewardPerToken(token);            
            rewardData[token].lastUpdateTime = lastTimeRewardApplicable(token);
            if (account != address(0)) {
                rewards[account][token] = earned(account, token);
                userRewardPerTokenPaid[account][token] = rewardData[token].rewardPerTokenStored;
            }
        }        
    }

    // Claim all pending staking rewards
    function _claimReward(address account) internal {
        // AUDIT Finding Id: 4
		// rewardTokens.length limited by maxRewardsTokens
		for (uint i; i < rewardTokens.length; i++) {
            address rewardsToken = rewardTokens[i];
            uint256 reward = rewards[account][rewardsToken];
            if (reward > 0) {
                rewards[account][rewardsToken] = 0;
                IERC20(rewardsToken).safeTransfer(account, reward);
                emit RewardPaid(account, rewardsToken, reward);
            }
        }
    }

    // Transfer tokens to user and penalty to xShade rewards distributor or wallet
    function _sendTokensAndPenalty(uint256 tokensAmount, uint256 penaltyAmount) internal {
        if (penaltyAmount != 0 && penaltyReceiver != address(0)) {
			
			// AUDIT Finding Id: 2
			stakingToken.safeTransfer(penaltyReceiver, penaltyAmount);
			// AUDIT Finding Id: 5
			if (penaltyReceiver.code.length > 0) {
				// try catch just for case if owner set penaltyReceiver contract but it not have this method
				// if such can happen for some reason than we don't care in this case
				try IPenaltyReceiver(penaltyReceiver).notifyReward(penaltyAmount) {} catch {}
			}
			
			emit PenaltyPaid(msg.sender, penaltyAmount);   
			
			stakingToken.safeTransfer(msg.sender, tokensAmount);    
        } else {
            stakingToken.safeTransfer(msg.sender, tokensAmount + penaltyAmount);
        }
        totalSupply -= (tokensAmount + penaltyAmount);
    }

    //  
    function _notifyReward(address rewardsToken, uint256 reward) internal {
        if (block.timestamp >= rewardData[rewardsToken].periodFinish) {
            rewardData[rewardsToken].rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = rewardData[rewardsToken].periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardData[rewardsToken].rewardRate;
            rewardData[rewardsToken].rewardRate = (reward + leftover) / rewardsDuration;
        }

        rewardData[rewardsToken].lastUpdateTime = block.timestamp;
        rewardData[rewardsToken].periodFinish = block.timestamp + rewardsDuration;
    }

    // -------------------------------- EVENTS -----------------------------------

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount, bool locked);
    event Withdrawn(address indexed user, uint256 amount);
	event PenaltyPaid(address indexed user, uint256 amount);     
    event RewardPaid(address indexed user, address indexed rewardsToken, uint256 reward);
    event RewardsDurationUpdated(address token, uint256 newDuration);
    event Recovered(address token, uint256 amount);
	event FTMReceived(address indexed distributor, uint256 amount);
    event AddRewardToken(address rewardsToken, address distributor);
    event SetRewardDistributor(address rewardsToken, address distributor, bool state);
    event SetPenaltyReceiver(address penaltyReceiver);
    event SetLockStaker(address lockStaker); 
}