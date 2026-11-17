///|
// The live UI/host flow owns timing and command ordering; OS resources remain
// leased by the host until its completion/failed acknowledgement arrives.
#derive(Eq)
priv enum FlowPhase {
  Idle
  Selecting
  Countdown
  Starting
  Recording
  Stopping
  Ready
  Failed
  Cancelled
}

///|
priv struct RecordingFlow {
  mut phase : FlowPhase
  mut now : Double
  mut deadline : Double
  mut started : Double?
  mut stopped : Double?
  mut cancel_pending : Bool
}

///|
let flows : Map[Int32, RecordingFlow] = Map([])

///|
let next_flow : Ref[Int32] = Ref(1)

///|
fn FlowPhase::code(self : FlowPhase) -> Int32 {
  match self {
    Idle => 0
    Selecting => 1
    Countdown => 2
    Starting => 3
    Recording => 4
    Stopping => 5
    Ready => 6
    Failed => 7
    Cancelled => 8
  }
}

///|
fn FlowPhase::busy(self : FlowPhase) -> Bool {
  match self {
    Selecting | Countdown | Starting | Recording | Stopping => true
    _ => false
  }
}

///|
pub fn recording_flow_open() -> Int32 {
  if flows.length() >= 64 || next_flow.val >= 2147483647 {
    return 0
  }
  let handle = next_flow.val
  next_flow.val += 1
  flows[handle] = {
    phase: Idle,
    now: 0,
    deadline: 0,
    started: None,
    stopped: None,
    cancel_pending: false,
  }
  handle
}

///|
pub fn recording_flow_event(
  handle : Int32,
  event : Int32,
  now : Double,
) -> Int32 {
  let flow = match flows.get(handle) {
    Some(flow) => flow
    None => return -1
  }
  // This form rejects NaN/infinities as well as backwards/stale clock samples.
  if !(now >= flow.now && now <= 1.0e15) {
    return -1
  }
  let effect = match (flow.phase, event) {
    (Idle, 1) => {
      flow.phase = Selecting
      1
    }
    (Selecting, 2) => {
      flow.deadline = now + preparation_countdown.to_double() * 1000
      flow.phase = Countdown
      0
    }
    (Countdown, 3) =>
      if now >= flow.deadline {
        flow.phase = Starting
        2
      } else {
        0
      }
    (Starting, 4) => {
      flow.started = Some(now)
      flow.phase = Recording
      0
    }
    (Selecting | Countdown, 5 | 8) => {
      flow.cancel_pending = true
      flow.phase = Stopping
      4
    }
    (Starting | Recording, 5 | 8) => {
      flow.stopped = Some(now)
      flow.phase = Stopping
      3
    }
    (Stopping, 6) =>
      if flow.cancel_pending {
        flow.phase = Cancelled
        0
      } else {
        flow.phase = Ready
        5
      }
    (Selecting | Countdown | Starting | Recording | Stopping, 7) => {
      if flow.stopped is None {
        flow.stopped = Some(now)
      }
      flow.phase = Failed
      0
    }
    (Selecting | Starting | Recording | Stopping, 3) => 0
    _ => return -1
  }
  flow.now = now
  effect
}

///|
pub fn recording_flow_value(handle : Int32, key : Int32) -> Int32 {
  let flow = match flows.get(handle) {
    Some(flow) => flow
    None => return -1
  }
  match key {
    0 => flow.phase.code()
    1 =>
      if flow.phase == Countdown {
        @double.ceil((flow.deadline - flow.now) / 1000).to_int()
      } else {
        0
      }
    2 =>
      match flow.started {
        Some(start) => {
          let end = match flow.stopped {
            Some(time) => time
            None => flow.now
          }
          @protocol.smaller(2147483647, @double.floor(end - start)).to_int()
        }
        None => 0
      }
    3 => if flow.phase.busy() { 1 } else { 0 }
    4 => if flow.phase == Selecting || flow.phase == Countdown { 1 } else { 0 }
    5 => if flow.phase == Starting || flow.phase == Recording { 1 } else { 0 }
    _ => -1
  }
}

///|
pub fn recording_flow_close(handle : Int32) -> Int32 {
  match flows.get(handle) {
    Some(flow) => {
      if flow.phase.busy() {
        return 0
      }
      flows.remove(handle)
    }
    None => ()
  }
  1
}
