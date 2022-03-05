// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

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
	}
	struct RewardData {
		address token;
		uint256 amount;
	}

	IERC20 public immutable stakingToken;
	IWETH public immutable WETH;
	address[] public rewardTokens;

	uint256 private constant maxRewardsTokens = 10; // maximum number of reward token instances
	address public penaltyReceiver;

	mapping(address => Reward) public rewardData;

	// contract designed to work ONLY for 3 month (13 weeks) and 7 days (1 week) rewards distribution period
	// be carefull by setting lockDurationMultiplier to higher value it can sonsume lot of gas
	// because lockDurationMultiplier represent number of possible user locks
	// if you want longer time for lock increase rewardsDuration instead
	// or make own research for suitable by gas consumption lockDurationMultiplier
	// Duration that rewards are streamed over
	uint256 public constant rewardsDuration = 7 days;
	uint256 public constant lockDurationMultiplier = 13;
	// Duration of lock period
	uint256 public constant lockDuration = rewardsDuration * lockDurationMultiplier;

	// reward token -> distributor -> is approved to add rewards
	mapping(address => mapping(address => bool)) public rewardDistributors;
	// If you need to to view all rewardDistributors for reward token you can get array of all added addresses by one
	// And then check them in rewardDistributors nested mapping
	mapping(address => address[]) public rewardDistributorsMirror;

	// addresses that allowed to stake in lock
	mapping(address => bool) public lockStakers;
	// If you need to to view all lockStakers you can get array of all added addresses by one
	// And then check them in lockStakers mapping
	address[] public lockStakersMirror;

	// user -> reward token -> amount
	mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
	mapping(address => mapping(address => uint256)) public rewards;

	uint256 public totalSupply;

	mapping(address => uint256) public balances;
	mapping(address => mapping(uint256 => LockedBalance)) public userLocks;
	mapping(address => uint256) public startIndex;
	mapping(address => uint256) public userLocksLength;

	// -------------------------------- CONSTRUCTOR -----------------------------------

	constructor() Ownable() {
		stakingToken = IERC20(0x3c88baD5dcd1EbF35a0BF9cD1AA341BB387fF73A); // SHADE
		WETH = IWETH(0x15c34D8b356F21112C07cA1811D84101F480a3F1); // wFTM address

		setLockStaker(0xa4873Ff784306A8B6f82cd1123D3b967CaFBdA6A, true); // LP FARM address
		addRewardToken(address(WETH), 0x380Ff6e45b4606e21B686979060Cad429FB72548); // Payments FTM contract
	}

	// -------------------------------- CONFIG -----------------------------------

	// Add a new reward token to be distributed to stakers
	function addRewardToken(address rewardsToken, address distributor) public onlyOwner {
		require(rewardData[rewardsToken].lastUpdateTime == 0, "Taken already added");
		require(rewardTokens.length < maxRewardsTokens, "Maximun number of reward tokens reached");

		rewardTokens.push(rewardsToken);
		rewardData[rewardsToken].lastUpdateTime = block.timestamp;
		rewardData[rewardsToken].periodFinish = block.timestamp;
		setRewardDistributor(rewardsToken, distributor, true);
		emit AddRewardToken(rewardsToken, distributor);
	}

	// Modify approval for an address to call notifyRewardAmount
	function setRewardDistributor(
		address rewardsToken,
		address distributor,
		bool state
	) public onlyOwner {
		require(rewardData[rewardsToken].lastUpdateTime > 0, "Token not added");
		require(rewardDistributors[rewardsToken][distributor] != state, "Distributor already set");
		rewardDistributors[rewardsToken][distributor] = state;
		if (state) {
			rewardDistributorsMirror[rewardsToken].push(distributor);
		}
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
		if (state) {
			lockStakersMirror.push(lockStaker);
		}
		emit SetLockStaker(lockStaker);
	}

	// -------------------------------- VIEWS -----------------------------------

	//
	function rewardPerToken(address rewardsToken) internal view returns (uint256) {
		if (totalSupply == 0) {
			return rewardData[rewardsToken].rewardPerTokenStored;
		}
		return rewardData[rewardsToken].rewardPerTokenStored + (((lastTimeRewardApplicable(rewardsToken) - rewardData[rewardsToken].lastUpdateTime) * rewardData[rewardsToken].rewardRate * 1e18) / totalSupply);
	}

	//
	function earned(address user, address rewardsToken) internal view returns (uint256) {
		if (balances[user] == 0) return 0;
		return (balances[user] * (rewardPerToken(rewardsToken) - userRewardPerTokenPaid[user][rewardsToken])) / 1e18 + rewards[user][rewardsToken];
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
		for (uint256 i = startIndex[account]; i < userLocksLength[account]; i++) {
			if (userLocks[account][i].unlockTime > block.timestamp) {
				amount += userLocks[account][i].amount;
			}
		}
	}

	// Contract Data method for decrease number of request to contract from dApp UI
	function contractData()
		public
		view
		returns (
			uint256 _totalStaked, // totalSupply
			address[] memory _rewardTokens, // rewardTokens
			uint256[] memory _rewardPerToken, // rewardPerToken
			uint256[] memory _claimRewardForDuration, // claimRewardForDuration
			uint256[] memory _rewardBalances, // rewardBalances
			uint256 _rewardsDuration, // rewardsDuration
			uint256 _lockDuration // lockDuration
		)
	{
		_totalStaked = totalSupply;
		_rewardTokens = rewardTokens;
		_rewardPerToken = new uint256[](rewardTokens.length);
		_claimRewardForDuration = new uint256[](rewardTokens.length);
		_rewardBalances = new uint256[](rewardTokens.length);

		for (uint256 i; i < rewardTokens.length; i++) {
			_rewardPerToken[i] = rewardPerToken(rewardTokens[i]);
			_claimRewardForDuration[i] = claimRewardForDuration(rewardTokens[i]);
			_rewardBalances[i] = IERC20(rewardTokens[i]).balanceOf(address(this));
		}

		_rewardsDuration = rewardsDuration;
		_lockDuration = lockDuration;
	}

	// User Data method for decrease number of request to contract from dApp UI
	function userData(address account)
		public
		view
		returns (
			uint256 _staked, // Staked balance
			uint256 _locked, // Locked balance
			LockedBalance[] memory _userLocks, // Locks
			RewardData[] memory _claimableRewards, // claimableRewards
			uint256 _allowance, // allowance of staking token
			uint256 _balance // balance of staking token
		)
	{
		_staked = balances[account];

		_userLocks = new LockedBalance[](userLocksLength[account] - startIndex[account]);
		uint256 idx;
		for (uint256 i = startIndex[account]; i < userLocksLength[account]; i++) {
			// AUDIT Finding Id: 7
			if (userLocks[account][i].unlockTime > block.timestamp) {
				_locked += userLocks[account][i].amount;
				_userLocks[idx] = userLocks[account][i];
				idx++;
			}
		}

		_claimableRewards = claimableRewards(account);
		_allowance = stakingToken.allowance(account, address(this));
		_balance = stakingToken.balanceOf(account);
	}

	// -------------------------------- MUTATIVE FUNCTIONS -----------------------------------
	function stakeFrom(address account, uint256 amount) external returns (bool) {
		require(lockStakers[msg.sender], "Sender not allowed to stake with lock");
		_stake(account, amount, true);
		return true;
	}

	function stake(uint256 amount) external {
		_stake(msg.sender, amount, false);
	}

	// Stake tokens to receive rewards
	// Locked tokens can't be withdrawn for lockDuration and are eligible to receive staking rewards
	function _stake(
		address account,
		uint256 amount,
		bool lock
	) internal nonReentrant {
		_updateReward(account);
		_updateUserLocks(account);

		require(amount != 0, "Can't stake 0");

		balances[account] += amount;
		if (lock) {
			uint256 unlockTime = ((block.timestamp / rewardsDuration) * rewardsDuration) + lockDuration;
			uint256 locksLength = userLocksLength[account];

			if (locksLength == 0 || userLocks[account][locksLength - 1].unlockTime < unlockTime) {
				userLocks[account][locksLength] = LockedBalance({amount: amount, unlockTime: unlockTime});
				userLocksLength[account]++;
			} else {
				userLocks[account][locksLength - 1].amount += amount;
			}
		}

		stakingToken.safeTransferFrom(msg.sender, address(this), amount);
		totalSupply += amount;

		emit Staked(account, amount, lock);
	}

	// Withdraw defined amount of staked tokens
	// If amount higher than unlocked we get extra from locks and pay penalty
	function withdraw(uint256 amount) public nonReentrant {
		require(amount != 0, "Can't withdraw 0");

		_updateUserLocks(msg.sender);
		_updateReward(msg.sender);
		_claimReward(msg.sender);

		uint256 balance = balances[msg.sender];
		require(balance >= amount, "Not enough tokens to withdraw");
		balances[msg.sender] -= amount;

		uint256 unlocked = balance - lockedBalance(msg.sender);
		uint256 penalty;

		if (amount > unlocked) {
			uint256 remaining = amount - unlocked;
			penalty = remaining / 2;
			amount = unlocked + remaining - penalty;

			for (uint256 i = startIndex[msg.sender]; i < userLocksLength[msg.sender]; i++) {
				uint256 lockAmount = userLocks[msg.sender][i].amount;
				if (lockAmount < remaining) {
					remaining = remaining - lockAmount;
					delete userLocks[msg.sender][i];
				} else if (lockAmount == remaining) {
					delete userLocks[msg.sender][i];
					break;
				} else {
					userLocks[msg.sender][i].amount = lockAmount - remaining;
					break;
				}
			}
		}
		_sendTokensAndPenalty(amount, penalty);
		emit Withdrawn(msg.sender, amount);
	}

	// Withdraw defined amount of unlocked tokens
	function withdrawUnlocked() public nonReentrant {
		_updateUserLocks(msg.sender);
		_updateReward(msg.sender);
		_claimReward(msg.sender);

		uint256 balance = balances[msg.sender];
		require(balance != 0, "No tokens on balance");
		uint256 locked = lockedBalance(msg.sender);

		uint256 amount = balance - locked;
		require(amount != 0, "No unlocked tokens");

		balances[msg.sender] -= amount;

		_sendTokensAndPenalty(amount, 0);
		emit Withdrawn(msg.sender, amount);
	}

	// Withdraw all user locked tokens
	function withdrawLocked() public nonReentrant {
		_updateUserLocks(msg.sender);
		_updateReward(msg.sender);
		_claimReward(msg.sender);

		uint256 amount = lockedBalance(msg.sender);
		require(amount != 0, "Can't withdraw 0");

		balances[msg.sender] -= amount;

		for (uint256 i = startIndex[msg.sender]; i < userLocksLength[msg.sender]; i++) {
			delete userLocks[msg.sender][i];
		}
		startIndex[msg.sender] = 0;
		userLocksLength[msg.sender] = 0;

		uint256 penalty = amount / 2;
		amount -= penalty;

		_sendTokensAndPenalty(amount, penalty);
		emit Withdrawn(msg.sender, amount);
	}

	// Withdraw full unlocked balance and claim pending rewards
	function withdrawAll() public nonReentrant {
		_updateUserLocks(msg.sender);
		_updateReward(msg.sender);
		_claimReward(msg.sender);

		uint256 balance = balances[msg.sender];
		require(balance != 0, "Can't withdraw 0");

		uint256 locked = lockedBalance(msg.sender);
		uint256 unlocked = balance - locked;

		uint256 penalty = locked / 2;
		uint256 amount = unlocked + locked - penalty;

		balances[msg.sender] = 0;
		for (uint256 i = startIndex[msg.sender]; i < userLocksLength[msg.sender]; i++) {
			delete userLocks[msg.sender][i];
		}
		startIndex[msg.sender] = 0;
		userLocksLength[msg.sender] = 0;

		_sendTokensAndPenalty(amount, penalty);

		emit Withdrawn(msg.sender, amount);
	}

	// Claim all pending staking rewards
	function claimReward() public nonReentrant {
		_updateReward(msg.sender);
		_claimReward(msg.sender);
	}

	function updateUserLocks() public {
		_updateUserLocks(msg.sender);
	}

	function notifyRewardAmount(address rewardsToken, uint256 reward) external {
		require(rewardDistributors[rewardsToken][msg.sender], "Only distributor allowed to send rewards");
		require(reward != 0, "No reward");
		_updateReward(address(0));

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
		IWETH(WETH).deposit{value: msg.value}();
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

		uint256 locksLength = userLocksLength[account];
		// return if user has no locks
		if (locksLength == 0) return;

		// searching for expired locks from stratIndex untill first locked found or end reached
		while (userLocks[account][startIndex[account]].unlockTime <= block.timestamp && startIndex[account] < locksLength) {
			startIndex[account]++;
		}

		// if end reached it means no lock found and we can reset startedIndex and clear all locks array
		if (startIndex[account] >= locksLength) {
			startIndex[account] = 0;
			userLocksLength[account] = 0;
		}
	}

	function _updateReward(address account) internal {
		for (uint256 i = 0; i < rewardTokens.length; i++) {
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
		for (uint256 i; i < rewardTokens.length; i++) {
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
			stakingToken.safeTransfer(penaltyReceiver, penaltyAmount);

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
