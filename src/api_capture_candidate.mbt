///|
#export_name("capture_candidate_count")
pub fn capture_candidate_count(ticket : Int32) -> Int32 {
  @capture.candidate_count(ticket)
}

///|
#export_name("capture_candidate_value")
pub fn capture_candidate_value(
  ticket : Int32,
  index : Int32,
  field : Int32,
) -> Double {
  @capture.candidate_value(ticket, index, field)
}

///|
#export_name("capture_candidate_text")
pub fn capture_candidate_text(ticket : Int32, index : Int32) -> String {
  @capture.candidate_text(ticket, index)
}

///|
#export_name("capture_candidate_viewport_value")
pub fn capture_candidate_viewport_value(
  ticket : Int32,
  field : Int32,
) -> Double {
  @capture.candidate_viewport_value(ticket, field)
}
