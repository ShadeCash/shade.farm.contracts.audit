const rewardsDuration = 7
const lockDurationMultiplier = 13
const lockDuration = rewardsDuration * lockDurationMultiplier
let locks = []
let id = 0
let blockTimestamp = 0;
let locksIndex = 0;

setTimeout(function tick() {   
  blockTimestamp = Math.round(Date.now() / 1000)    
  stake(100) 

  console.clear()  
  console.log('BlockTimestamp: ', blockTimestamp, 'LocksLength: ', locks.length, 'LocksIndex: ', locksIndex)  
  console.log(locks)

  setTimeout(tick, 100)
}, 100)    

function stake(amount) {
  updateLocks()
  const unlockTime = ((blockTimestamp / rewardsDuration).toFixed(0) * rewardsDuration) + lockDuration;
  const locksLength = locks.length;
  if (locksLength == 0 || locks[locksLength-1].unlockTime < unlockTime) {  
    id ++;
    locks.push({ amount, unlockTime, id });
  } else {				
    locks[locksLength-1].amount += amount;
  }
}

function withdrawLock(id) {
  updateLocks()
  for (let i = locksIndex; i < locks.length; i++) {
    if (locks[i].id == id) {
      locks[i].unlockTime = 0;
      break;
    } 			         
  } 
}

function withdrawLocked() {
  updateLocks()
  locks = []
}

function updateLocks(){
  const length = locks.length
  if (length == 0) return
  if (locks[length-1].unlockTime > blockTimestamp) {
    while (locks[locksIndex].unlockTime <= blockTimestamp && locksIndex < length) {
      locksIndex ++
    }
  } else {
    locks = []
    locksIndex = 0	
  }
}