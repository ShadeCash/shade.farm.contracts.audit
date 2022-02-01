const rewardsDuration = 7
const lockDurationMultiplier = 13
const lockDuration = rewardsDuration * lockDurationMultiplier
let locks = []
let id = 0
let blockTimestamp = 0;

setTimeout(function tick() {   
  blockTimestamp = Math.round(Date.now() / 1000)    
  stake(100) 

  console.clear()  
  console.log('BlockTimestamp: ', blockTimestamp, 'LocksLength: ', locks.length)  
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
  for (let i = 0; i < locks.length; i++) {
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
    let lockedCount = 0
    const newLocks = Array(length)
    for (let i = 0; i < length; i++) {
      if (locks[i].unlockTime > blockTimestamp) {
        newLocks[lockedCount] = locks[i]
        lockedCount ++                                        
      } 				 
    }
    if (lockedCount != length) {
      locks = []	      
      for (let i = 0; i < lockedCount; i++) {
        locks.push(newLocks[i])
      }                
    }
  } else {
    locks = []	
  }
}