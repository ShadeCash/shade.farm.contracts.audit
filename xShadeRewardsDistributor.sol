// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// ------------------------------------- Math -------------------------------------------
library Math {
	function min(uint256 a, uint256 b) internal pure returns (uint256) {
		return a < b ? a : b;
	}
}

// ------------------------------------- SignedMath -------------------------------------------
library SignedMath {
	function max(int256 a, int256 b) internal pure returns (int256) {
		return a >= b ? a : b;
	}
}

// ------------------------------------- IWETH -------------------------------------------
interface IWETH {
	function deposit() external payable;
}

// ------------------------------------- IXSHADE -------------------------------------------
interface IXSHADE {
	function userPointEpoch(address account) external view returns (uint256);

	function epoch() external view returns (uint256);

	function userPointHistory(address account, uint256 point) external view returns (Point memory);

	function pointHistory(uint256 point) external view returns (Point memory);

	function checkpoint() external;
}

struct Point {
	int256 bias;
	int256 slope; // - dweight / dt
	uint256 timeStamp; //timestamp
	uint256 blockNumber; // block
}

contract xShadeRewardsDistributor is ReentrancyGuard, Ownable {
	using SafeERC20 for IERC20;

	// -------------------------------- VARIABLES -----------------------------------
	IXSHADE public immutable xShadeToken;
	IERC20 public immutable rewardToken;
	bool private immutable isRewardsFTM; // if true reward token MUST be Wrapped FTM

	uint256 constant WEEK = 7 days;
	uint256 constant TOKEN_CHECKPOINT_DEADLINE = 1 days;

	uint256 public immutable startTime;
	uint256 public timeCursor;
	mapping(address => uint256) public timeCursorOf;
	mapping(address => uint256) public userEpochOf;

	uint256 public lastRewardsTime;
	mapping(uint256 => uint256) public rewardsPerWeek;

	uint256 public rewardTokenLastBalance;

	mapping(uint256 => uint256) public xShadeSupply; // total supply at week bounds

	bool public allowCheckpointToken = false;
	bool public expired = false;

	// -------------------------------- CONSTRUCT -----------------------------------
	/// @param _xShadeToken address of xSHADE
	/// @param _rewardToken address of rewad token
	/// @param _isRewardsFTM if reward token is wraped token of chain it MUST be set to true otherwise false
	constructor(
		IXSHADE _xShadeToken,
		IERC20 _rewardToken,
		bool _isRewardsFTM
	) Ownable() {
		xShadeToken = _xShadeToken;
		rewardToken = _rewardToken;
		isRewardsFTM = _isRewardsFTM;

		startTime = (block.timestamp / WEEK) * WEEK;
		lastRewardsTime = startTime;
		timeCursor = startTime;
	}

	// -------------------------------- ADMIN -----------------------------------
	//
	function setContractExpired() external onlyOwner {
		require(!expired, "Contract is expired");
		expired = true;
		emit Expired();
	}

	//
	function recoverERC20(address tokenAddress, uint256 amount) external onlyOwner {
		if (tokenAddress == address(rewardToken)) {
			require(expired, "Cannot withdraw while not expired");
		}
		IERC20(tokenAddress).safeTransfer(owner(), amount);
		emit Recovered(tokenAddress, amount);
	}

	//
	function toggleAllowCheckpointToken() external onlyOwner {
		allowCheckpointToken = !allowCheckpointToken;
		emit ToggleAllowCheckpointToken(allowCheckpointToken);
	}

	// -------------------------------- VIEWS -----------------------------------
	//
	function _findTimestampEpoch(uint256 timeStamp) internal view returns (uint256) {
		uint256 min;
		uint256 max = xShadeToken.epoch();
		for (uint256 i = 0; i < 128; i++) {
			if (min >= max) {
				break;
			}
			uint256 mid = (min + max + 2) / 2;
			Point memory point = xShadeToken.pointHistory(mid);

			if (point.timeStamp <= timeStamp) {
				min = mid;
			} else {
				max = mid - 1;
			}
		}
		return min;
	}

	//
	function _findTimestampUserEpoch(
		address user,
		uint256 timeStamp,
		uint256 maxUserEpoch
	) internal view returns (uint256) {
		uint256 min;
		uint256 max = maxUserEpoch;
		for (uint256 i = 0; i < 128; i++) {
			if (min >= max) {
				break;
			}
			uint256 mid = (min + max + 2) / 2;
			Point memory point = xShadeToken.userPointHistory(user, mid);

			if (point.timeStamp <= timeStamp) {
				min = mid;
			} else {
				max = mid - 1;
			}
		}
		return min;
	}

	//
	function xShadeUserBalanceAt(address user, uint256 timeStamp) external view returns (uint256) {
		uint256 maxUserEpoch = xShadeToken.userPointEpoch(user);
		uint256 epoch = _findTimestampUserEpoch(user, timeStamp, maxUserEpoch);
		Point memory point = xShadeToken.userPointHistory(user, epoch);

		return uint256(SignedMath.max(point.bias - (point.slope * int256(timeStamp - point.timeStamp)), 0));
	}

	//
	function userPointEpoch() external view returns (uint256) {
		return xShadeToken.userPointEpoch(msg.sender);
	}

	// -------------------------------- MUTATIVE -----------------------------------
	//
	function _checkpointToken() internal {
		uint256 rewardTokenBalance = rewardToken.balanceOf(address(this));
		uint256 rewardsToDistribute = rewardTokenBalance - rewardTokenLastBalance;

		rewardTokenLastBalance = rewardTokenBalance;

		uint256 _lastRewardsTime = lastRewardsTime; // 0
		uint256 sinceLast = block.timestamp - _lastRewardsTime; // 104
		lastRewardsTime = block.timestamp;

		uint256 thisWeek = (_lastRewardsTime / WEEK) * WEEK; // 0
		uint256 nextWeek; // 0

		for (uint256 i = 0; i < 104; i++) {
			nextWeek = thisWeek + WEEK;
			if (block.timestamp < nextWeek) {
				if (sinceLast == 0) {
					rewardsPerWeek[thisWeek] += rewardsToDistribute;
				} else {
					rewardsPerWeek[thisWeek] += (rewardsToDistribute * (block.timestamp - _lastRewardsTime)) / sinceLast;
				}
				break;
			} else {
				if (sinceLast == 0) {
					rewardsPerWeek[thisWeek] += rewardsToDistribute;
				} else {
					rewardsPerWeek[thisWeek] += (rewardsToDistribute * (nextWeek - _lastRewardsTime)) / sinceLast;
				}
			}
			_lastRewardsTime = nextWeek;
			thisWeek = nextWeek;
		}

		emit CheckpointToken(block.timestamp, rewardsToDistribute);
	}

	/// @notice Update the reward Token checkpoint
	/// @dev Calculates the total number of tokens to be distributed in a given week.
	///   During setup for the initial distribution this function is only callable
	///   by the contract owner. Beyond initial, it can be enabled for anyone to call.
	function checkpointToken() external {
		require(msg.sender == owner() || (allowCheckpointToken && (block.timestamp > lastRewardsTime + TOKEN_CHECKPOINT_DEADLINE)));
		_checkpointToken();
	}

	//
	function _checkpointTotalSupply() internal {
		uint256 _timeCursor = timeCursor;
		uint256 roundedTimestamp = (block.timestamp / WEEK) * WEEK;

		xShadeToken.checkpoint();

		for (uint256 i = 0; i < 104; i++) {
			if (_timeCursor >= roundedTimestamp) {
				break;
			} else {
				uint256 epoch = _findTimestampEpoch(_timeCursor);
				Point memory point = xShadeToken.pointHistory(epoch);
				int256 delta;
				if (_timeCursor > point.timeStamp) {
					delta = int256(_timeCursor - point.timeStamp);
				}
				xShadeSupply[_timeCursor] = uint256(SignedMath.max(point.bias - (point.slope * delta), 0));
			}
			_timeCursor += WEEK;
		}
		timeCursor = _timeCursor;
	}

	/// @notice Update the veCRV total supply checkpoint
	/// @dev The checkpoint is also updated by the first claimant each
	///   new epoch week. This function may be called independently
	///   of a claim, to reduce claiming gas costs.
	function checkpointTotalSupply() external {
		_checkpointTotalSupply();
	}

	//
	function _claim(address addr, uint256 _lastRewardsTime) internal returns (uint256) {
		// Minimal userEpoch is 0 (if user had no point)
		uint256 userEpoch;
		uint256 rewardsToDistribute;

		uint256 maxUserEpoch = xShadeToken.userPointEpoch(addr);

		if (maxUserEpoch == 0) {
			return 0;
		}

		uint256 _startTime = startTime;
		uint256 weekCursor = timeCursorOf[addr];
		if (weekCursor == 0) {
			userEpoch = _findTimestampUserEpoch(addr, _startTime, maxUserEpoch);
		} else {
			userEpoch = userEpochOf[addr];
		}

		if (userEpoch == 0) {
			userEpoch = 1;
		}
		Point memory userPoint = xShadeToken.userPointHistory(addr, userEpoch);

		if (weekCursor == 0) {
			weekCursor = ((userPoint.timeStamp + WEEK - 1) / WEEK) * WEEK;
		}
		if (weekCursor >= _lastRewardsTime) {
			return 0;
		}
		if (weekCursor < _startTime) {
			weekCursor = _startTime;
		}
		Point memory oldUserPoint;

		for (uint256 i = 0; i < 50; i++) {
			if (weekCursor >= _lastRewardsTime) {
				break;
			}
			if (weekCursor >= userPoint.timeStamp && userEpoch <= maxUserEpoch) {
				userEpoch += 1;
				oldUserPoint = userPoint;
				if (userEpoch > maxUserEpoch) {
					userPoint = Point({ bias: 0, slope: 0, timeStamp: 0, blockNumber: 0 });
				} else {
					userPoint = xShadeToken.userPointHistory(addr, userEpoch);
				}
			} else {
				int256 delta = int256(weekCursor - oldUserPoint.timeStamp);
				uint256 balanceOf = uint256(SignedMath.max(oldUserPoint.bias - (delta * oldUserPoint.slope), 0));
				if (balanceOf == 0 && userEpoch > maxUserEpoch) {
					break;
				}
				if (balanceOf > 0) {
					if (xShadeSupply[weekCursor] != 0) {
						rewardsToDistribute += (balanceOf * rewardsPerWeek[weekCursor]) / xShadeSupply[weekCursor];
					}
				}
				weekCursor += WEEK;
			}
		}
		userEpoch = Math.min(maxUserEpoch, userEpoch - 1);
		userEpochOf[addr] = userEpoch;
		timeCursorOf[addr] = weekCursor;

		emit Claimed(addr, rewardsToDistribute, userEpoch, maxUserEpoch);
		return rewardsToDistribute;
	}

	//
	function claim() external returns (uint256) {
		return claim(msg.sender);
	}

	/// @notice Claim fees for addr
	/// @dev Each call to claim look at a maximum of 50 user points. For accounts with many veCRV related actions,
	///   this function may need to be called more than once to claim all available
	///   fees. In the `Claimed` event that fires, if `claim_epoch` is
	///   less than `max_epoch`, the account may claim again.
	/// @param addr Address to claim fees for
	/// @return uint256 Amount of fees claimed in the call
	function claim(address addr) public nonReentrant returns (uint256) {
		if (block.timestamp >= timeCursor) {
			_checkpointTotalSupply();
		}
		uint256 _lastRewardsTime = lastRewardsTime;

		if (allowCheckpointToken && (block.timestamp > _lastRewardsTime + TOKEN_CHECKPOINT_DEADLINE)) {
			_checkpointToken();
			_lastRewardsTime = block.timestamp;
		}

		_lastRewardsTime = (_lastRewardsTime / WEEK) * WEEK;

		uint256 amount = _claim(addr, _lastRewardsTime);

		if (amount != 0) {
			rewardToken.safeTransfer(addr, amount);
			rewardTokenLastBalance -= amount;
		}

		return amount;
	}

	/// @notice Make multiple fee claims in a single call
	/// @dev Used to claim for many accounts at once, or to make multiple claims for the same address when that address has significant history
	/// @param accounts List of addresses to claim for. Claiming terminates at the first 0 address.
	function claimMany(address[20] memory accounts) external nonReentrant returns (bool) {
		if (block.timestamp >= timeCursor) {
			_checkpointTotalSupply();
		}
		uint256 _lastRewardsTime = lastRewardsTime;

		if (allowCheckpointToken && (block.timestamp > _lastRewardsTime + TOKEN_CHECKPOINT_DEADLINE)) {
			_checkpointToken();
			_lastRewardsTime = block.timestamp;
		}

		_lastRewardsTime = (_lastRewardsTime / WEEK) * WEEK;

		uint256 total;

		for (uint256 i = 0; i < accounts.length; i++) {
			if (accounts[i] == address(0)) {
				break;
			}
			uint256 amount = _claim(msg.sender, _lastRewardsTime);
			if (amount != 0) {
				rewardToken.safeTransfer(msg.sender, amount);
				total += amount;
			}
		}

		if (total != 0) {
			rewardTokenLastBalance -= total;
		}

		return true;
	}

	// For recieving token rewards
	function notifyReward(uint256 amount) public payable {
		if (isRewardsFTM) {
			require(msg.value != 0, "No reward");
			amount = msg.value;
			IWETH(address(rewardToken)).deposit{ value: amount }();
		} else {
			require(msg.value == 0, "Can't receive FTM");
			require(amount != 0, "No reward");
			rewardToken.safeTransferFrom(msg.sender, address(this), amount);
		}

		if (allowCheckpointToken && (block.timestamp > lastRewardsTime + TOKEN_CHECKPOINT_DEADLINE)) {
			_checkpointToken();
		}
	}

	// For recieving FTM rewards
	receive() external payable {
		notifyReward(0);
	}

	// ---------------------------------- EVENTS ----------------------------------------------
	event CheckpointToken(uint256 timeStamp, uint256 amount);
	event ToggleAllowCheckpointToken(bool flag);
	event Claimed(address indexed accouunt, uint256 amount, uint256 indexed claimEpoch, uint256 indexed maxEpoch);
	event Expired();
	event Recovered(address token, uint256 amount);
}
