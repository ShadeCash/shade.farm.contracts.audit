// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// ---------------------------------------------------------------------------------------
// ------------------------------------- xShade ---------------------------------------
// ---------------------------------------------------------------------------------------

// Converted from vyper to solidity from SnowBall Voting Escrow
// Time-weighted balance
// The balance in this implementation is linear, and lock can't be more than maxtime
// B ^
// 1 +        /
//   |      /
//   |    /
//   |  /
//   |/
// 0 +--------+------> T
//   maxtime (2 years)

contract xShade is ReentrancyGuard, Ownable {
	using SafeERC20 for IERC20Metadata;

	// -------------------------------- VARIABLES -----------------------------------
	struct Point {
		int256 bias;
		int256 slope; // - dweight / dt
		uint256 timeStamp; //timestamp
		uint256 blockNumber; // block
	}

	struct LockedBalance {
		uint256 amount;
		uint256 end;
	}

	struct Reward {
		uint256 rewardsDuration;
		uint256 periodFinish;
		uint256 rewardRate;
		uint256 lastUpdateTime;
		uint256 rewardPerTokenStored;
	}

	enum LockAction {
		CREATE_LOCK,
		INCREASE_LOCK_AMOUNT,
		INCREASE_LOCK_TIME
	}

	uint256 constant WEEK = 7 days; // all future times are rounded by week
	uint256 constant MINTIME = WEEK * 2; //
	uint256 constant MAXTIME = WEEK * 104; // 2 years
	uint256 constant MULTIPLIER = 10**18;

	IERC20Metadata public stakingToken;

	mapping(address => LockedBalance) public lockedBalances;
	uint256 public stakedTotal;
	LockedBalance private oldLockedStorage;

	//everytime user deposit/withdraw/change_locktime, these values will be updated;
	uint256 public epoch;
	mapping(uint256 => Point) public pointHistory; // epoch -> unsigned point.
	mapping(address => mapping(uint256 => Point)) public userPointHistory; // user -> Point[user_epoch]
	mapping(address => uint256) public userPointEpoch;
	mapping(uint256 => int256) public slopeChanges; // time -> signed slope change

	string public name;
	string public symbol;
	uint256 public decimals;

	bool public expired = false;

	// -------------------------------- CONSTRUCT -----------------------------------
	/// @param _stakingToken address of SHADE
	constructor(IERC20Metadata _stakingToken) Ownable() {
		name = "xSHADE Token";
		symbol = "xSHADE";
		stakingToken = _stakingToken;
		decimals = _stakingToken.decimals();

		pointHistory[0].blockNumber = block.number;
		pointHistory[0].timeStamp = block.timestamp;
	}

	// -------------------------------- ADMIN -----------------------------------
	function setContractExpired() external onlyOwner notExpired {
		expired = true;
		emit Expired();
	}

	//
	function recoverERC20(address tokenAddress, uint256 amount) external onlyOwner {
		require(tokenAddress != address(stakingToken), "Cannot withdraw staking token");
		IERC20Metadata(tokenAddress).safeTransfer(owner(), amount);
		emit Recovered(tokenAddress, amount);
	}

	// -------------------------------- VIEWS -----------------------------------
	//
	function getLastUserSlope(address account) external view returns (uint256) {
		uint256 userEpoch = userPointEpoch[account];
		return uint256(userPointHistory[account][userEpoch].slope);
	}

	//
	function userPointHistoryTs(address account, uint256 idx) external view returns (uint256) {
		return userPointHistory[account][idx].timeStamp;
	}

	//
	function balanceOf(address account) public view returns (uint256) {
		return balanceOfAtTime(account, block.timestamp);
	}

	//
	function balanceOfAtTime(address account, uint256 timeStamp) public view returns (uint256) {
		uint256 userEpoch = userPointEpoch[account];
		if (userEpoch == 0) {
			return 0;
		} else {
			Point memory lastPoint = userPointHistory[account][userEpoch];
			lastPoint.bias -= lastPoint.slope * int256(timeStamp - lastPoint.timeStamp);
			if (lastPoint.bias < 0) {
				lastPoint.bias = 0;
			}
			return uint256(lastPoint.bias);
		}
	}

	/// @notice Because the balance can change within a block, this function should not be used on the current block number
	function balanceOfAt(address account, uint256 blockNumber) external view returns (uint256) {
		require(blockNumber <= block.number, "Wrong block number");

		uint256 min;
		uint256 max = userPointEpoch[account];
		for (uint256 i; i <= 255; i++) {
			if (min >= max) {
				break;
			}
			uint256 mid = (min + max + 1) / 2;
			if (userPointHistory[account][mid].blockNumber <= blockNumber) {
				min = mid;
			} else {
				max = mid - 1;
			}
		}

		Point memory userPoint = userPointHistory[account][min];

		uint256 blockEpoch = findBlockEpoch(blockNumber, epoch);

		Point memory point0 = pointHistory[blockEpoch];
		uint256 deltaBlockNumber;
		uint256 deltaTimeStamp;

		if (blockEpoch < epoch) {
			Point memory point1 = pointHistory[blockEpoch + 1];
			deltaBlockNumber = point1.blockNumber - point0.blockNumber;
			deltaTimeStamp = point1.timeStamp - point0.timeStamp;
		} else {
			deltaBlockNumber = block.number - point0.blockNumber;
			deltaTimeStamp = block.timestamp - point0.timeStamp;
		}

		uint256 blockTime = point0.timeStamp;
		if (deltaBlockNumber != 0) {
			blockTime += (deltaTimeStamp * (blockNumber - point0.blockNumber)) / deltaBlockNumber;
		}

		userPoint.bias -= userPoint.slope * int256(blockTime - userPoint.timeStamp);
		if (userPoint.bias >= 0) {
			return uint256(userPoint.bias);
		} else {
			return 0;
		}
	}

	//
	function _supplyAt(Point memory point, uint256 timeStamp) internal view returns (uint256) {
		uint256 _timeStamp = (point.timeStamp / WEEK) * WEEK;
		for (uint256 i; i < 255; i++) {
			_timeStamp += WEEK;
			int256 slope = 0;

			if (_timeStamp > timeStamp) {
				_timeStamp = timeStamp;
			} else {
				slope = slopeChanges[_timeStamp];
			}
			point.bias -= point.slope * int256(_timeStamp - point.timeStamp);

			if (_timeStamp == timeStamp) {
				break;
			}
			point.slope += slope;
			point.timeStamp = _timeStamp;
		}

		if (point.bias < 0) {
			point.bias = 0;
		}
		return uint256(point.bias);
	}

	//
	function totalSupplyAt(uint256 blockNumber) external view returns (uint256) {
		require(blockNumber <= block.number, "Only current or past block number");

		uint256 targetEpoch = findBlockEpoch(blockNumber, epoch);

		Point memory point = pointHistory[targetEpoch];
		uint256 delta;
		if (targetEpoch < epoch) {
			Point memory pointNext = pointHistory[targetEpoch + 1];
			if (point.blockNumber != pointNext.blockNumber) {
				delta = ((blockNumber - point.blockNumber) * (pointNext.timeStamp - point.timeStamp)) / (pointNext.blockNumber - point.blockNumber);
			}
		} else {
			if (point.blockNumber != block.number) {
				delta = ((blockNumber - point.blockNumber) * (block.timestamp - point.timeStamp)) / (block.number - point.blockNumber);
			}
		}

		return _supplyAt(point, point.timeStamp + delta);
	}

	//
	function totalSupply() public view returns (uint256) {
		return _supplyAt(pointHistory[epoch], block.timestamp);
	}

	//
	function getUserPointEpoch(address _user) external view returns (uint256) {
		return userPointEpoch[_user];
	}

	//
	function findBlockEpoch(uint256 blockNumber, uint256 maxEpoch) internal view returns (uint256) {
		uint256 min;
		uint256 max = maxEpoch;
		for (uint256 i; i < 255; i++) {
			if (min >= max) {
				break;
			}
			uint256 mid = (min + max + 1) / 2;
			if (pointHistory[mid].blockNumber <= blockNumber) {
				min = mid;
			} else {
				max = mid - 1;
			}
		}
		return min;
	}

	// Contract Data method for decrease number of request to contract from dApp UI
	function contractData()
		public
		view
		returns (
			uint256 _stakedTotal, // stakedTotal
			uint256 _totalSupply, // totalSupply
			uint256 _minTime, // minimum Lock Time MINTIME
			uint256 _maxTime // maximum Lock Time MAXTIME
		)
	{
		_stakedTotal = stakedTotal;
		_totalSupply = totalSupply();
		_minTime = MINTIME;
		_maxTime = MAXTIME;
	}

	// User Data method for decrease number of request to contract from dApp UI
	function userData(address account)
		public
		view
		returns (
			LockedBalance memory _lockedBalance, // Balances [] amount, end
			uint256 _balanceXShade, // SHADEx balance
			uint256 _allowance, // allowance of staking token
			uint256 _balance // balance of staking token
		)
	{
		_lockedBalance = lockedBalances[account];
		_balanceXShade = balanceOf(account);
		_allowance = stakingToken.allowance(account, address(this));
		_balance = stakingToken.balanceOf(account);
	}

	// -------------------------------- MUTATIVE -----------------------------------
	/// Creates a new lock
	function createLock(uint256 amount, uint256 unlockTime) external nonReentrant notContract notExpired {
		LockedBalance memory locked = lockedBalances[msg.sender];

		require(amount != 0, "Must stake non zero amount");
		require(locked.amount == 0, "Withdraw old tokens first");

		unlockTime = (unlockTime / WEEK) * WEEK; // Locktime is rounded down to weeks

		require(unlockTime > block.timestamp, "Can only lock until time in the future");

		uint256 roundedMin = (block.timestamp / WEEK) * WEEK + MINTIME;
		uint256 roundedMax = (block.timestamp / WEEK) * WEEK + MAXTIME;
		if (unlockTime < roundedMin) {
			unlockTime = roundedMin;
		} else if (unlockTime > roundedMax) {
			unlockTime = roundedMax;
		}

		_depositFor(msg.sender, amount, unlockTime, locked, LockAction.CREATE_LOCK);
	}

	/// Increases amount of staked tokens
	function increaseLockAmount(uint256 amount) external nonReentrant notContract notExpired {
		LockedBalance memory locked = lockedBalances[msg.sender];

		require(amount != 0, "Must stake non zero amount");
		require(locked.amount != 0, "No existing lock found");
		require(locked.end >= block.timestamp, "Can't add to expired lock. Withdraw old tokens first");

		_depositFor(msg.sender, amount, 0, locked, LockAction.INCREASE_LOCK_AMOUNT);
	}

	/// Increases length of staked tokens unlock time
	function increaseLockTime(uint256 unlockTime) external nonReentrant notContract notExpired {
		LockedBalance memory locked = lockedBalances[msg.sender];

		require(locked.amount != 0, "No existing lock found");
		require(locked.end >= block.timestamp, "Lock expired. Withdraw old tokens first");

		uint256 roundedMax = (block.timestamp / WEEK) * WEEK + MAXTIME;
		require(locked.end != roundedMax, "Already locked for maximum time");

		unlockTime = (unlockTime / WEEK) * WEEK; // Locktime is rounded down to weeks
		require(unlockTime <= roundedMax, "Can't lock for more than max time");
		require(unlockTime > locked.end, "New unlock time must be higer than current");

		_depositFor(msg.sender, 0, unlockTime, locked, LockAction.INCREASE_LOCK_TIME);
	}

	/// Withdraw all tokens  if the lock has expired
	function withdraw() external nonReentrant {
		LockedBalance storage locked = lockedBalances[msg.sender];
		LockedBalance memory oldLocked = locked;

		require(block.timestamp >= locked.end || expired, "The lock didn't expire");

		stakedTotal -= locked.amount;
		locked.amount = 0;
		locked.end = 0;

		_checkpoint(msg.sender, oldLocked, locked);

		stakingToken.safeTransfer(msg.sender, oldLocked.amount);

		emit Withdraw(msg.sender, oldLocked.amount, block.timestamp);
	}

	/// Record global and per-user data to checkpoint
	function _checkpoint(
		address account,
		LockedBalance memory oldLocked,
		LockedBalance memory newLocked
	) internal {
		Point memory userOldPoint;
		Point memory userNewPoint;
		int256 oldSlope = 0;
		int256 newSlope = 0;
		uint256 _epoch = epoch;

		if (account != address(0)) {
			// Calculate slopes and biases
			// Kept at zero when they have to
			if (oldLocked.end > block.timestamp && oldLocked.amount > 0) {
				userOldPoint.slope = int256(oldLocked.amount / MAXTIME);
				userOldPoint.bias = userOldPoint.slope * int256(oldLocked.end - block.timestamp);
			}
			if (newLocked.end > block.timestamp && newLocked.amount > 0) {
				userNewPoint.slope = int256(newLocked.amount / MAXTIME);
				userNewPoint.bias = userNewPoint.slope * int256(newLocked.end - block.timestamp);
			}

			// Read values of scheduled changes in the slope
			// oldLocked.end can be in the past and in the future
			// newLocked.end can ONLY by in the FUTURE unless everything expired than zeros
			oldSlope = slopeChanges[oldLocked.end];
			if (newLocked.end != 0) {
				if (newLocked.end == oldLocked.end) {
					newSlope = oldSlope;
				} else {
					newSlope = slopeChanges[newLocked.end];
				}
			}
		}

		Point memory lastPoint = Point({ bias: 0, slope: 0, timeStamp: block.timestamp, blockNumber: block.number });
		if (_epoch > 0) {
			lastPoint = pointHistory[_epoch];
		}
		uint256 lastCheckpoint = lastPoint.timeStamp;

		// initialLastPoint is used for extrapolation to calculate block number
		// (approximately, for *At methods) and save them
		// as we cannot figure that out exactly from inside the contract
		Point memory initialLastPoint = Point({ bias: 0, slope: 0, timeStamp: lastPoint.timeStamp, blockNumber: lastPoint.blockNumber });

		// If last point is already recorded in this block, slope=0
		// But that's ok b/c we know the block in such case
		uint256 blockSlope = 0; // dblock/dt
		if (block.timestamp > lastPoint.timeStamp) {
			blockSlope = (MULTIPLIER * (block.number - lastPoint.blockNumber)) / (block.timestamp - lastPoint.timeStamp);
		}

		// Go over weeks to fill history and calculate what the current point is
		uint256 timeStamp = (lastCheckpoint / WEEK) * WEEK;
		for (uint256 i; i < 255; i++) {
			// Hopefully it won't happen that this won't get used in 5 years!
			// If it does, users will be able to withdraw but vote weight will be broken
			timeStamp += WEEK;
			int256 slope = 0;
			if (timeStamp > block.timestamp) {
				timeStamp = block.timestamp;
			} else {
				slope = slopeChanges[timeStamp];
			}

			lastPoint.bias -= lastPoint.slope * int256(timeStamp - lastCheckpoint);
			lastPoint.slope += slope;

			if (lastPoint.bias < 0) {
				lastPoint.bias = 0; // This can happen
			}

			if (lastPoint.slope < 0) {
				lastPoint.slope = 0; // This cannot happen - just in case
			}

			lastCheckpoint = timeStamp;
			lastPoint.timeStamp = timeStamp;
			lastPoint.blockNumber = initialLastPoint.blockNumber + ((blockSlope * (timeStamp - initialLastPoint.timeStamp)) / MULTIPLIER);

			_epoch += 1;

			if (timeStamp == block.timestamp) {
				lastPoint.blockNumber = block.number;
				break;
			} else {
				pointHistory[_epoch] = lastPoint;
			}
		}
		// Now pointHistory is filled until timeStamp=now

		address accountCopy = account; // To avoid being "Stack Too Deep"

		if (accountCopy != address(0)) {
			// If last point was in this block, the slope change has been applied already
			// But in such case we have 0 slope(s)
			lastPoint.slope += userNewPoint.slope - userOldPoint.slope;
			lastPoint.bias += userNewPoint.bias - userOldPoint.bias;
			if (lastPoint.slope < 0) {
				lastPoint.slope = 0;
			}
			if (lastPoint.bias < 0) {
				lastPoint.bias = 0;
			}

			// Schedule the slope changes (slope is going down)
			// We subtract new_user_slope from [newLocked.end]
			// and add old_user_slope to [oldLocked.end]
			if (oldLocked.end > block.timestamp) {
				// oldSlope was <something> - userOldPoint.slope, so we cancel that
				oldSlope += userOldPoint.slope;
				if (newLocked.end == oldLocked.end) {
					oldSlope -= userNewPoint.slope; // It was a new deposit, not extension
				}
				slopeChanges[oldLocked.end] = oldSlope;
			}
			if (newLocked.end > block.timestamp) {
				if (newLocked.end > oldLocked.end) {
					newSlope -= userNewPoint.slope; // old slope disappeared at this point
					slopeChanges[newLocked.end] = newSlope;
				}
				// else we recorded it already in oldSlope
			}

			// Now handle user history
			uint256 userEpoch = userPointEpoch[accountCopy] + 1;

			userPointEpoch[accountCopy] = userEpoch;
			userNewPoint.timeStamp = block.timestamp;
			userNewPoint.blockNumber = block.number;
			userPointHistory[accountCopy][userEpoch] = userNewPoint;
		}
		// Record the changed point into history
		pointHistory[_epoch] = lastPoint;
		epoch = _epoch;
	}

	/// Record global data to checkpoint
	function checkpoint() external {
		LockedBalance memory a;
		LockedBalance memory b;
		_checkpoint(address(0), a, b);
	}

	/// Deposits or creates a stake for a given account
	function _depositFor(
		address account,
		uint256 amount,
		uint256 unlockTime,
		LockedBalance memory locked,
		LockAction action
	) internal {
		LockedBalance memory oldLocked = LockedBalance({ amount: locked.amount, end: locked.end });

		if (amount != 0) {
			locked.amount += amount;
			stakedTotal += amount;
			stakingToken.safeTransferFrom(account, address(this), amount);
		}

		if (unlockTime != 0) {
			locked.end = unlockTime;
		}

		lockedBalances[account] = locked;

		_checkpoint(account, oldLocked, locked);

		emit Deposit(account, amount, locked.end, action, block.timestamp);
	}

	// ------------------------------------ EVENTS --------------------------------------
	event Deposit(address indexed accouunt, uint256 value, uint256 indexed locktime, LockAction indexed action, uint256 timestamp);
	event Withdraw(address indexed accouunt, uint256 value, uint256 timestamp);
	event WithdrawEmergency(address indexed accouunt, uint256 value, uint256 timestamp);
	event Expired();
	event Recovered(address token, uint256 amount);

	// ------------------------------------ MODIFIERS ------------------------------------
	modifier notExpired() {
		require(!expired, "Contract is expired");
		_;
	}

	modifier notContract() {
		require(!Address.isContract(msg.sender), "Not allowed for contract address");
		_;
	}
}
